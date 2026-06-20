-- burst.lua
-- Six-channel FM burst sequencer core, ported from src/burst.ts (which in turn
-- ports er301_geode.lua). Scheduling is a 1:1 port of the web app's
-- runChannel/runBurst coroutines onto norns `clock`: each launched channel runs
-- a `clock.run` coroutine that pulls the next value from each sequins per burst,
-- waits until the (quantized) target beat via `clock.sleep`, fires, and advances.
--
-- Quantization: every event's target beat is snapped FORWARD to the global
-- quantize grid (`quantize.snap_beat`) before sleeping, so all channels lock to
-- a shared sub-beat grid regardless of each channel's division — exactly the web
-- behaviour. quantize = 0 disables snapping.
--
-- Cancellation uses a per-channel token (bumped on launch/stop) AND
-- clock.cancel, mirroring the web's token check so a stale coroutine exits at
-- its next sleep even if a relaunch raced ahead.

local quantize = require 'quantize'
local scales   = require 'scales'
local seqx     = require 'seqx'

local NUM_CHANNELS = 6
local INF = math.huge

local Burst = {}
Burst.__index = Burst
Burst.NUM_CHANNELS = NUM_CHANNELS

-- Rhythmically meaningful divisors for randomize/mutate (matches src/burst.ts).
local MUSICAL_DIVS = {2, 3, 4, 6, 8, 12, 16}
Burst.MUSICAL_DIVS = MUSICAL_DIVS

-- Curated per-operator FM ratios (op1 is pinned to 1.0 = fundamental). Mirrors
-- GridUI.RATIO_VALUES (the grid ratio picker) — keep the two in sync; the
-- reachability test asserts every randomized ratio lands on this set. Sub-unity
-- ratios (0.125..0.75) give sub-octave / bass timbres.
local RATIO_VALUES = {0.125, 0.25, 0.5, 0.75, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 7, 9, 11, 14}
Burst.RATIO_VALUES = RATIO_VALUES

-- Which operators are modulators (appear as a 'from' in some edge) per algorithm
-- 1..8. Mirrors Engine_Potionshop.algorithms (SC) — keep in sync; used only to
-- pick the brightness proxy (largest active modulator ratio) for MIDI/crow out.
local ALGO_MODULATORS = {
  {2, 3, 4}, {2, 3, 4}, {2, 3, 4}, {2, 3, 4},
  {2, 4}, {4}, {4}, {},  -- 8 = additive (no modulators)
}
Burst.ALGO_MODULATORS = ALGO_MODULATORS

local function round(x) return math.floor(x + 0.5) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function get_beats()
  return (clock and clock.get_beats and clock.get_beats()) or 0
end
local function get_tempo()
  return (clock and clock.get_tempo and clock.get_tempo()) or 120
end

-- ---- pure geode math (exposed for testing) -----------------------------

-- Geode-style per-hit modulation. `run` is a bipolar RUN CV: 0.5 = neutral,
-- 0 = full negative, 1 = full positive. Returns 0..1; at run≈0.5 returns 1.0.
-- `i` is the 0-based hit index; `total` is a number or math.huge.
function Burst.geode_mod(mode, run, i, total)
  local r = (run - 0.5) * 2  -- -1..+1

  if mode == 1 then  -- Transient: sawtooth accent cycle
    if math.abs(r) < 0.01 then return 1.0 end
    local cycle_len = math.max(1, round(1 + math.abs(r) * 9))
    local pos = i % cycle_len
    if r > 0 then
      return 1.0 - pos / cycle_len   -- sawtooth down from accent
    else
      return (pos + 1) / cycle_len   -- reversed: rises to accent
    end
  end

  if mode == 2 then  -- Sustain: decay with triangle fold/reflect
    local period = (total == INF) and 8 or math.max(2, total)
    local idx = (total == INF) and (i % period) or i
    local t = idx / (period - 1)
    local rate = (r >= 0) and (1 + r * 4) or math.max(0.05, 1 + r)
    local raw = t * rate
    return math.abs(((raw % 2) + 2) % 2 - 1)  -- triangle 1->0->1...
  end

  -- mode == 3: Cycle — sinusoidal, continuous period
  if math.abs(r) < 0.01 then return 1.0 end
  local freq
  if r > 0 then freq = 1 / (2 + r * 8) else freq = 1 + math.abs(r) * 9 end
  return 0.5 + 0.5 * math.cos(2 * math.pi * i * freq)
end

-- Per-hit amplitude for a burst. Always multiply by `level` so level=0 is
-- silent; the 0.7 clamp prevents energy buildup when accents/long envelopes
-- overlap across hits.
function Burst.burst_level_for_hit(level, geode_mode, env_shape, hit_idx, total)
  local geo_run = clamp(level, 0, 1)
  local geo_shape = (geode_mode ~= 0)
    and Burst.geode_mod(geode_mode, geo_run, hit_idx, total) or 1
  local raw = level * geo_shape
  if geode_mode ~= 0 or env_shape > 0 then return math.min(0.7, raw) end
  return raw
end

-- ---- channel state -----------------------------------------------------

local function default_channel()
  return {
    div   = seqx.new{4, 8},
    reps  = seqx.new{2, 2},
    note  = seqx.new{0},
    -- volume is a fixed constant (no longer randomized/mutated). 16/31 ≈ 0.52 is
    -- the grid-exact form of the old 0.5 neutral, so it stays picker-editable.
    level = seqx.new{16 / 31},
    env   = seqx.new{0},
    -- div/reps/harm have no B layer; note/level/env keep an additive B layer.
    noteB  = seqx.new{0},
    levelB = seqx.new{0},
    envB   = seqx.new{0},
    -- per-operator FM ratios (op1 pinned to 1.0 = fundamental) and output levels
    -- (0..1) are per-channel STATIC timbre, edited on the grid OP page — not
    -- sequenced. ratios 1,1,1 = unison (cleanest, ~2-op); levels: FM depth when
    -- the op is a modulator, mix gain when it's a carrier.
    opRatio2 = 1, opRatio3 = 1, opRatio4 = 1,
    opLevel1 = 1, opLevel2 = 1, opLevel3 = 1, opLevel4 = 1,
    burstProb = 1,
    probHit = false,
    envMode = 0,      -- amp decay timing:  0=shape 1=burst 2=hit
    geodeMode = 0,    -- amp per-hit geode: 0=transient 1=sustain 2=cycle (always on)
    opEnvMode = 0,    -- op-level geode timing: 0=off 1=hit 2=burst (SND page)
    opGeode = 0,      -- op-level per-hit geode shape: 0=transient 1=sustain 2=cycle
    algo = 1,         -- FM algorithm (1..8): DX-style operator routing for this channel
    resetInterval = 0,
    rate = 1,
    octave = 0,     -- -2..2, whole-octave pitch shift (perf page)
    altTrig = 0,    -- alt(B) note layering: 0=hold (add&hold) 1=step (per-hit)
  }
end

function Burst.new()
  local self = setmetatable({}, Burst)
  self.launchGrid = 4   -- launches snap to the next quarter-note boundary
  self.quantize = 32    -- global event snap grid (events per whole note); 0 = off
  self.scale = scales.by_name.major
  self.root = 0         -- tonic transposition in semitones (0..11; 0 = C)
  self.channels = {}
  self.running = {}
  self.clocks = {}      -- per-channel clock.run id (or nil)
  self.tokens = {}      -- per-channel cancellation token
  for i = 1, NUM_CHANNELS do
    self.channels[i] = default_channel()
    self.running[i] = false
    self.tokens[i] = 0
  end
  self.listeners = {}
  -- engine-wide voice timbre macros (lib/params_sync.lua 'VOICE' group). Global,
  -- not per-channel: the non-audio output types can't render them. Read straight
  -- at fire time; these ARE the values handed to the SC voice.
  self.modIndex = 3     -- FM modulation index (low default = clean, ~2-op tone; up to 24 = bright)
  self.fmDecay = 0.4    -- mod-depth decay as a fraction of amp decay (FM body length)
  self.ampPunch = 4     -- perc-curve magnitude (-> Env.perc curve = -ampPunch); 0 = linear
  self.fmFeedback = 0   -- SinOscFB feedback (radians): 0 = pure sine modulator
  self.drive = 1        -- tanh soft-clip drive: 1 = clean, higher = saturated
  -- per-operator output levels are NOT global anymore: each channel sequences its
  -- own op1..op4 (A/B) sequins (see default_channel), drawn per burst in run_burst.
  self.outputs = nil    -- optional lib/outputs.lua router (set by the host)
  return self
end

-- Kept for call-site compatibility; the clock model needs no setup.
function Burst:setup() end

-- ---- event listeners ---------------------------------------------------

function Burst:on(fn)
  self.listeners[fn] = true
  return function() self.listeners[fn] = nil end
end

function Burst:emit(ev)
  for fn, _ in pairs(self.listeners) do fn(ev) end
end

-- ---- transport queries -------------------------------------------------

function Burst:is_running(ch) return self.running[ch] == true end

function Burst:running_channels()
  local out = {}
  for i = 1, NUM_CHANNELS do out[i] = self.running[i] end
  return out
end

-- ---- sequins reset -----------------------------------------------------

function Burst:reset_channel(ch)
  local c = self.channels[ch]
  for _, k in ipairs{'div','reps','note','level','env',
                     'noteB','levelB','envB'} do  -- note/level/env keep a B layer
    c[k]:reset()
  end
end

function Burst:reset_sequins()
  for i = 1, NUM_CHANNELS do self:reset_channel(i) end
end

-- Bar-boundary reset (driven by the per-bar reset scheduler in potionshop.lua):
-- rewind the channel's sequins to step 1 AND, if it's running, hard-restart its
-- burst so the firing instants re-anchor to the bar grid. A soft sequins rewind
-- alone only re-syncs *values* at each channel's next burst boundary and never
-- touches the burst `target` phase, so two identical / copy-pasted channels stay
-- offset. Relaunching snaps both to the same bar beat (launch ->
-- snap_beat(now, launchGrid)), so channels sharing a reset interval fire in
-- lockstep. (A hit landing exactly on the bar can briefly double-trigger as the
-- old coroutine is replaced — an acceptable artifact of the realign.)
function Burst:bar_reset(ch)
  self:reset_channel(ch)
  if self.running[ch] then
    -- Anchor the relaunch to the launchGrid boundary we're sitting on. clock.sync
    -- wakes us just AFTER the boundary, so get_beats() is N*step + a tiny epsilon;
    -- the default run_channel path would snap that FORWARD a full step, landing the
    -- first hit late and leaving an audible gap each bar. Floor back onto the
    -- boundary instead (the +1e-9 keeps an exactly-on-grid value from dropping a
    -- step). clock.sync guarantees epsilon >= 0, so flooring never rewinds into
    -- already-played time.
    local step = 4 / self.launchGrid
    local anchor = math.floor(get_beats() / step + 1e-9) * step
    self:launch(ch, anchor)
  end
end

-- ---- launch / stop -----------------------------------------------------

-- `start_beat` (optional): explicit absolute beat to anchor the first burst to,
-- bypassing the forward launchGrid snap. Used by bar_reset, which is already
-- sitting on the bar boundary it wants to start from.
function Burst:launch(ch, start_beat)
  if ch < 1 or ch > NUM_CHANNELS then return end
  if self.clocks[ch] then clock.cancel(self.clocks[ch]); self.clocks[ch] = nil end
  self.tokens[ch] = self.tokens[ch] + 1
  local token = self.tokens[ch]
  self.running[ch] = true
  self:emit{ type = 'launch', ch = ch }
  self.clocks[ch] = clock.run(function() self:run_channel(ch, token, start_beat) end)
end

function Burst:stop(ch)
  if ch < 1 or ch > NUM_CHANNELS then return end
  self.tokens[ch] = self.tokens[ch] + 1  -- invalidate any in-flight coroutine
  if self.clocks[ch] then clock.cancel(self.clocks[ch]); self.clocks[ch] = nil end
  if self.running[ch] then
    self.running[ch] = false
    self:emit{ type = 'stop', ch = ch }
  end
end

function Burst:stop_all()
  for i = 1, NUM_CHANNELS do self:stop(i) end
end

-- ---- scheduling (clock coroutines) -------------------------------------

-- Wait until absolute beat `target`, snapping forward to the next quantize
-- grid point. Tempo is preserved: target progresses at the natural rate; the
-- snap only nudges the firing instant. (Direct port of clock.ts waitUntilBeat.)
function Burst:wait_until_beat(target)
  local fire = quantize.snap_beat(target, self.quantize)
  local wait_secs = (fire - get_beats()) * (60 / get_tempo())
  if wait_secs > 0 then clock.sleep(wait_secs) end
end

-- Outer loop: keep firing bursts until cancelled, or until a single-shot burst
-- (length-1 finite reps) completes.
function Burst:run_channel(ch, token, start_beat)
  local target = start_beat or quantize.snap_beat(get_beats(), self.launchGrid)
  while self.tokens[ch] == token do
    local r = self:run_burst(ch, token, target)
    if r == nil then return end
    target = r.target
    local c = self.channels[ch]
    local reps_len = seqx.len(c.reps)
    if r.reps ~= -1 and reps_len <= 1 then
      if self.tokens[ch] == token then
        self.running[ch] = false
        self.clocks[ch] = nil
        self:emit{ type = 'stop', ch = ch }
      end
      return
    end
  end
end

-- Inner burst: capture sequins refs, draw one value each, fire `reps` events
-- spaced by 4/div beats (scaled by rate). If a captured ref was replaced (live
-- grid edit / relaunch), bail and let the outer loop redraw fresh values.
-- Returns {reps, div, target} or nil if cancelled.
function Burst:run_burst(ch, token, target_in)
  local target = target_in
  while self.tokens[ch] == token do
    local c = self.channels[ch]
    local div_seq, reps_seq, note_seq = c.div, c.reps, c.note
    local note_seqB = c.noteB  -- note keeps an A/B layer (alt-trig)
    local div = math.max(1, div_seq())
    local reps = reps_seq()
    -- A/B note degrees kept separate so the alt-trig 'step' mode can advance the
    -- B (alt) pitch sequins per hit while the A degree stays held for the burst.
    local degreeA = note_seq()
    local degreeB = note_seqB()
    local level = c.level() + c.levelB()
    local env = c.env() + c.envB()
    local freq = scales.degree_to_freq(degreeA + degreeB, self.scale, self.root)
    -- finite bursts clamp to >=1 hit so a 0/negative reps value can't tight-loop.
    local total = (reps == -1) and INF or math.max(1, reps)

    -- burst-mode probability gate: skip the whole burst, advance time once.
    if (not c.probHit) and reps ~= -1 and math.random() > c.burstProb then
      target = target + total * (4 / div) / c.rate
      self:wait_until_beat(target)
      if self.tokens[ch] ~= token then return nil end
      return { reps = reps, div = div, target = target }
    end

    local restarted = false
    local i = 0
    while (total == INF or i < total) and self.tokens[ch] == token do
      -- identity check: a live grid edit / relaunch replaced a timing or
      -- position sequins, so restart this burst with the new values now.
      if c.div ~= div_seq or c.reps ~= reps_seq or c.note ~= note_seq
         or c.noteB ~= note_seqB then
        restarted = true
        break
      end
      self:wait_until_beat(target)
      if self.tokens[ch] ~= token then return nil end

      -- ALT-TRIG STEP MODE: when c.altTrig == 1 the alt (B) pitch layer
      -- arpeggiates — advance the captured B note sequins per hit and re-sum
      -- with the held degreeA. i == 0 already consumed the burst-start draw.
      -- Advancing here (above the probHit skip) keeps the arpeggio locked to the
      -- beat grid: a skipped hit still consumes a B value.
      if c.altTrig == 1 and i > 0 then
        degreeB = note_seqB()
        freq = scales.degree_to_freq(degreeA + degreeB, self.scale, self.root)
      end

      if c.probHit and math.random() > c.burstProb then
        -- per-hit skip: advance the playhead but don't trigger a voice.
        self:emit{ type = 'fire', ch = ch, beat = target,
                   freq = freq, level = level, env = env }
      else
        self:fire(ch, target, freq, level, env, div, total, i)
      end
      target = target + (4 / div) / c.rate
      i = i + 1
    end

    if self.tokens[ch] ~= token then return nil end
    if not restarted then return { reps = reps, div = div, target = target } end
  end
  return nil
end

function Burst:fire(ch, beat, freq, level, env, div, total, hit_idx)
  local c = self.channels[ch]
  -- octave shift is applied per hit, not per burst: looping channels
  -- (reps = -1) never redraw freq, so a burst-start shift would be inaudible
  -- on them. Shifting here also feeds the final freq to external outputs.
  freq = freq * (2 ^ c.octave)
  local geo_run = clamp(level, 0, 1)
  -- geodeMode is 0-based {transient,sustain,cycle}; geode_mod wants 1/2/3, so +1
  -- at the call site. The amp geode is always on (no 'off').
  local actual_level = Burst.burst_level_for_hit(level, c.geodeMode + 1, env, hit_idx, total)

  -- geo_freq stays at the target pitch (this voice has no pitch envelope).
  local geo_freq = freq

  -- per-channel static FM ratios (op1 = 1.0 fundamental). The brightness proxy
  -- handed to external outputs is the largest ratio among this algo's active
  -- modulators (or the fundamental for additive) — a stand-in for the old harm.
  local ratios = {1, c.opRatio2, c.opRatio3, c.opRatio4}
  local bright_ratio = 0
  for _, op in ipairs(ALGO_MODULATORS[c.algo] or {}) do
    if ratios[op] > bright_ratio then bright_ratio = ratios[op] end
  end
  if bright_ratio == 0 then bright_ratio = ratios[1] end  -- additive: no modulators

  -- per-hit timing, drives the amp-envelope decay maths below.
  local sec_per_beat = 60 / get_tempo()
  local interval_sec = (4 / div) * sec_per_beat

  -- amp decaySec from envMode (1=burst-length, 2=per-hit).
  local decay_sec = nil
  if c.envMode ~= 0 then
    if c.envMode == 1 and total ~= INF then
      decay_sec = total * interval_sec
    else
      decay_sec = interval_sec
    end
  end

  -- env -> time mapping. In shape mode the hit length tracks the inter-hit gap
  -- (interval / rate), so faster divisions & higher rates give proportionally
  -- shorter hits and a 6-voice mix doesn't pile up; env `e` scales staccato ->
  -- slightly-legato within that gap. Diverges from the web FMVoice (fixed
  -- 0.4..1.2s) to keep a dense norns mix legible. burst/hit keep decay_sec.
  -- FM body length: mod-depth decay as a fraction of the amp decay (global
  -- `fmDecay` voice macro, default 0.4) -- how long the FM brightness sings.
  local fm_decay_ratio = self.fmDecay
  local attack, amp_dec, mod_dec
  if decay_sec ~= nil then
    attack = 0.001
    amp_dec = math.max(0.01, decay_sec)
    mod_dec = amp_dec * fm_decay_ratio
  else
    local e = clamp(env, 0, 1)
    local gap_sec = interval_sec / math.max(0.01, c.rate)
    attack  = 0.001 + e * 0.018
    amp_dec = clamp(gap_sec * (0.3 + e * 0.95), 0.04, 2.2)
    mod_dec = amp_dec * fm_decay_ratio
  end

  -- output routing (lib/outputs.lua): non-audio destinations replace the
  -- internal voice; midi/crow get the same final freq/level/length it would
  -- have played. Hook lives here (not on emit) because the per-hit prob skip
  -- emits a 'fire' event for the playhead without sounding anything.
  -- global voice timbre macros (lib/params_sync.lua 'VOICE' group).
  local mod_index = self.modIndex
  local amp_curve = -self.ampPunch
  local feedback  = self.fmFeedback
  local drive     = self.drive
  -- per-channel static operator levels. Copied so the op geode below can shape
  -- this hit without mutating the channel's held values.
  local ol = {c.opLevel1, c.opLevel2, c.opLevel3, c.opLevel4}
  -- Op-level geode (SND op-env / op-geode): shape all four op levels per hit,
  -- mirroring the amp geode. opEnvMode 0=off -> levels pass through. The opGeode
  -- shape (transient/sustain/cycle) is driven by geo_run (= level), so a mid
  -- level is neutral (x1.0) and the modulation deepens as level moves away.
  -- Timing: 1=hit uses a per-hit timescale (total INF), 2=burst spans the whole
  -- finite burst (its length).
  if c.opEnvMode ~= 0 then
    local op_total = (c.opEnvMode == 2) and total or INF
    local og = Burst.geode_mod(c.opGeode + 1, geo_run, hit_idx, op_total)
    for k = 1, 4 do ol[k] = clamp(ol[k] * og, 0, 1) end
  end
  local out = self.outputs
  if engine and engine.trig and ((not out) or out:wants_audio(ch)) then
    -- 4-op FM (lib/Engine_Potionshop.sc): per-channel algorithm selects the
    -- operator routing; opRatio2/3/4 are the static per-op FM ratios (op1 = 1.0),
    -- the rest are the final hit envelope; ol[1..4] are this channel's static
    -- operator levels, geode-shaped per hit above.
    engine.trig(geo_freq, actual_level, c.algo,
                c.opRatio2, c.opRatio3, c.opRatio4, mod_index,
                attack, amp_dec, amp_curve, mod_dec, feedback, drive, ch,
                ol[1], ol[2], ol[3], ol[4])
  end
  if out then
    -- external voices can't render FM timbre; hand them the channel's brightness
    -- proxy (largest active modulator ratio) so MIDI/crow track its character.
    out:note(ch, { freq = geo_freq, level = actual_level, harm = bright_ratio,
                   dur = attack + amp_dec })
  end

  self:emit{ type = 'fire', ch = ch, beat = beat,
             freq = geo_freq, level = actual_level, env = env }
end

-- ---- randomize / mutate (grid-aligned values) --------------------------

local function pick(arr) return arr[math.random(1, #arr)] end
local function ri(n) return math.random(0, n - 1) end  -- 0..n-1, like JS floor(random()*n)

-- Replace all A-layer sequins with musically-constrained random values, using
-- the same discrete sets as the grid's STEP_PICKER_VALUES so the picker can
-- highlight (and the user can edit) the results.
function Burst:randomize(ch)
  if ch < 1 or ch > NUM_CHANNELS then return end
  local c = self.channels[ch]
  local len = pick{2, 3, 4}
  local function fill(n, f) local t = {} for i = 1, n do t[i] = f() end return t end
  c.div  = seqx.new(fill(len, function() return pick(MUSICAL_DIVS) end))
  c.reps = seqx.new(fill(len, function() return pick{1, 2, 2, 3, 4} end))
  c.note = seqx.new(fill(len, function() return ri(16) end))
  -- volume (level) is intentionally NOT randomized: it stays the channel's fixed
  -- constant so the mix loudness is stable.
  c.env   = seqx.new(fill(1, function() return ri(16) / 31 end))
  -- per-op FM ratios ARE scrambled (timbral variety) — picked from the curated
  -- grid-reachable set so the OP-page picker can still highlight/edit them. op1
  -- stays pinned to 1.0 (fundamental).
  c.opRatio2 = pick(RATIO_VALUES)
  c.opRatio3 = pick(RATIO_VALUES)
  c.opRatio4 = pick(RATIO_VALUES)
  -- Sound-page modes (envMode/geodeMode/opEnvMode/opGeode) and per-op LEVELS are
  -- left untouched: a randomized op1 = 0 would silently kill the channel (op1 is
  -- usually the carrier), so the operator level balance stays a deliberate,
  -- user-set timbre while only the ratios scramble.
end

-- Perturb A-layer values by ±amount, preserving length and clamping to range.
function Burst:mutate(ch, amount)
  if ch < 1 or ch > NUM_CHANNELS then return end
  amount = amount or 0.25
  local c = self.channels[ch]
  local function jitter(scale) return (math.random() * 2 - 1) * scale end
  local function nearest_musical_div(v)
    local best = MUSICAL_DIVS[1]
    for _, d in ipairs(MUSICAL_DIVS) do
      if math.abs(d - v) < math.abs(best - v) then best = d end
    end
    return best
  end
  local function map(seq, f)
    local out = {}
    local d = seqx.values(seq)
    for i = 1, #d do out[i] = f(d[i]) end
    return seqx.new(out)
  end
  c.div  = map(c.div,  function(v) return nearest_musical_div(v * (1 + jitter(amount))) end)
  c.reps = map(c.reps, function(v)
    if v == -1 then return -1 end
    return clamp(round(v + jitter(amount * 4)), 1, 8)
  end)
  c.note  = map(c.note,  function(v) return round(v + jitter(amount * 4)) end)
  -- volume (level) left untouched: a constant, never jittered (see randomize).
  c.env   = map(c.env,   function(v) return clamp(v + jitter(amount * 0.6), 0, 1) end)
  -- nudge per-op ratios to a neighbouring curated value (keeps them grid-exact).
  local function nudge_ratio(v)
    local idx = 1
    for i, r in ipairs(RATIO_VALUES) do if r == v then idx = i break end end
    return RATIO_VALUES[clamp(idx + (jitter(amount) > 0 and 1 or -1), 1, #RATIO_VALUES)]
  end
  c.opRatio2 = nudge_ratio(c.opRatio2)
  c.opRatio3 = nudge_ratio(c.opRatio3)
  c.opRatio4 = nudge_ratio(c.opRatio4)
end

return Burst
