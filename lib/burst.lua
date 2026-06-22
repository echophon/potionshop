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

local Burst = {}
Burst.__index = Burst
Burst.NUM_CHANNELS = NUM_CHANNELS

-- Rhythmically meaningful divisors for randomize/mutate (matches src/burst.ts).
local MUSICAL_DIVS = {2, 3, 4, 6, 8, 12, 16}
Burst.MUSICAL_DIVS = MUSICAL_DIVS

-- Curated per-operator FM ratios (op1 default 1.0 = fundamental, now editable
-- like op2/3/4 — randomize/mutate still leave op1 at 1.0 as a pitch anchor), 32 values.
-- Mirrors GridUI.RATIO_VALUES (the grid ratio picker) — keep the two in sync; the
-- reachability test asserts every randomized ratio lands on this set. Sub-unity
-- ratios (0.125..0.875) give sub-octave / bass timbres; half-integer ratios
-- (2.25, 3.5, ...) give inharmonic bell/metallic colours.
local RATIO_VALUES = {
  0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1,
  1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3,
  3.5, 4, 4.5, 5, 5.5, 6, 6.5, 7,
  7.5, 8, 9, 10, 11, 12, 13, 14,
}
Burst.RATIO_VALUES = RATIO_VALUES

-- Which operators are modulators (appear as a 'from' in some edge) per algorithm
-- 1..16. Mirrors Engine_Potionshop.algorithms (SC) — keep in sync; used only to
-- pick the brightness proxy (largest active modulator ratio) for MIDI/crow out.
local ALGO_MODULATORS = {
  {2, 3, 4}, {2, 3, 4}, {2, 3, 4}, {2, 3, 4},
  {2, 4}, {4}, {4}, {},  -- 8 = additive (no modulators)
  {2, 3, 4},             -- 9:  (4,3,2)->1
  {2, 3},                -- 10: 3->2->1 + pure op4
  {2, 4},                -- 11: 4->2->1 + pure op3
  {3, 4},                -- 12: 4->3->2 + pure op1
  {3, 4},                -- 13: 4->3->1 + pure op2
  {3, 4},                -- 14: (4,3)->1 + pure op2
  {4},                   -- 15: op4 mods 2 carriers + pure op3
  {3, 4},                -- 16: twin 2-op stacks (4->2, 3->1)
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
    local period = math.max(2, total)
    local idx = i
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

-- reps encoding: a positive value is that many hits; a value <= 0 is a REST that
-- fires nothing but still consumes time. The rest spans (1 - reps) div-steps, so
-- 0 = a one-step rest, -1 = two steps, -2 = three, and so on. Unlike level=0 (a
-- silent but still-triggered voice) or probability (nondeterministic), a rest is a
-- deterministic absence of any trigger.
function Burst.reps_is_rest(reps) return reps <= 0 end
function Burst.reps_rest_len(reps) return 1 - reps end

-- ---- channel state -----------------------------------------------------

local function default_channel()
  return {
    div   = seqx.new{4, 8},
    reps  = seqx.new{2, 2},
    note  = seqx.new{0},
    -- volume is a fixed constant (no longer randomized/mutated). 16/31 ≈ 0.52 is
    -- the grid-exact form of the old 0.5 neutral, so it stays picker-editable.
    level = seqx.new{16 / 31},
    -- envelope SHAPE is sequenced as a paired param (like div/reps): `attack`
    -- (A/left lane) and `decay` (B/right lane), each normalized 0..1 mapped to
    -- time in fire. attack default = 0 (instant); decay default = medium.
    attack = seqx.new{0},
    decay  = seqx.new{16 / 31},
    -- MODULATOR envelope SHAPE, sequenced as a second paired param (mirrors the
    -- carrier attack/decay above): modatk (A/left) + moddec (B/right), each
    -- normalized 0..1 mapped to time in fire. Drives the FM brightness env
    -- independently of the amp env. modatk default = 0 (instant, matching the old
    -- fixed 0.001s); moddec default = 8/31 (a short FM body so brightness plucks
    -- shorter than the note, in the spirit of the retired fmDecay 0.4 macro).
    modatk = seqx.new{0},
    moddec = seqx.new{8 / 31},
    -- div/reps/attack/decay/modatk/moddec have no B layer; note/level keep one.
    noteB  = seqx.new{0},
    levelB = seqx.new{0},
    -- per-operator FM ratios (op1 default 1.0 = fundamental, now editable) and
    -- output levels (0..1) are per-channel STATIC timbre, edited on the OP page — not
    -- sequenced. ratios 1,1,1 = unison (cleanest, ~2-op); levels: FM depth when
    -- the op is a modulator, mix gain when it's a carrier.
    opRatio1 = 1, opRatio2 = 1, opRatio3 = 1, opRatio4 = 1,
    opLevel1 = 1, opLevel2 = 15/31, opLevel3 = 15/31, opLevel4 = 15/31,  -- ~0.48, grid-exact on the i/31 OP page
    burstProb = 1,
    probHit = false,
    envMode = 0,      -- amp decay timing:  0=shape 1=burst 2=hit
    geodeMode = 0,    -- amp per-hit geode: 0=transient 1=sustain 2=cycle (always on)
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
  self.quantize = 16    -- global event snap grid (events per whole note); 0 = off
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
  self.modIndex = 2     -- FM modulation index (low default = clean, ~2-op tone; up to 24 = bright)
  -- (FM body length is no longer a global macro: the per-channel modatk/moddec
  -- sequences own the modulator envelope; the old self.fmDecay was retired.)
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
  for _, k in ipairs{'div','reps','note','level','attack','decay',
                     'modatk','moddec',     -- modulator envelope (paired, A-only)
                     'noteB','levelB'} do   -- note/level keep a B layer
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
    -- a single-step reps sequence is one-shot (play once, stop); two or more
    -- steps loop forever, cycling the sequence. (A rest step is just another step.)
    local reps_len = seqx.len(c.reps)
    if reps_len <= 1 then
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
    local attack_n = c.attack()  -- normalized carrier-env shape (paired, A-only)
    local decay_n = c.decay()
    local modatk_n = c.modatk()  -- normalized modulator-env shape (paired, A-only)
    local moddec_n = c.moddec()
    local freq = scales.degree_to_freq(degreeA + degreeB, self.scale, self.root)

    -- REST: reps <= 0 fires nothing but still consumes (1 - reps) div-steps of
    -- time so the rhythm holds. We drew all the sequins above (so they advance
    -- like any burst step), then just wait out the slot and advance. Deterministic
    -- silence, distinct from level=0 (a triggered-but-silent voice) and from
    -- probability (random). Not subject to the probability gate below.
    if Burst.reps_is_rest(reps) then
      target = target + Burst.reps_rest_len(reps) * (4 / div) / c.rate
      self:wait_until_beat(target)
      if self.tokens[ch] ~= token then return nil end
      return { reps = reps, div = div, target = target }
    end

    local total = math.max(1, reps)

    -- burst-mode probability gate: skip the whole burst, advance time once.
    if (not c.probHit) and math.random() > c.burstProb then
      target = target + total * (4 / div) / c.rate
      self:wait_until_beat(target)
      if self.tokens[ch] ~= token then return nil end
      return { reps = reps, div = div, target = target }
    end

    local restarted = false
    local i = 0
    while i < total and self.tokens[ch] == token do
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
                   freq = freq, level = level }
      else
        self:fire(ch, target, freq, level, attack_n, decay_n, modatk_n, moddec_n, div, total, i)
      end
      target = target + (4 / div) / c.rate
      i = i + 1
    end

    if self.tokens[ch] ~= token then return nil end
    if not restarted then return { reps = reps, div = div, target = target } end
  end
  return nil
end

function Burst:fire(ch, beat, freq, level, attack_n, decay_n, modatk_n, moddec_n, div, total, hit_idx)
  local c = self.channels[ch]
  -- octave shift is applied per hit, not per burst: a single long burst never
  -- redraws freq mid-burst, so a burst-start shift would be inaudible across its
  -- hits. Shifting here also feeds the final freq to external outputs.
  freq = freq * (2 ^ c.octave)
  -- geodeMode is 0-based {transient,sustain,cycle}; geode_mod wants 1/2/3, so +1
  -- at the call site. The amp geode is always on (no 'off'). decay_n gates the
  -- geode's 0.7 build-up clamp (a longer decay overlaps more, like the old env).
  local actual_level = Burst.burst_level_for_hit(level, c.geodeMode + 1, decay_n, hit_idx, total)

  -- geo_freq stays at the target pitch (this voice has no pitch envelope).
  local geo_freq = freq

  -- per-channel static FM ratios (op1 default 1.0 = fundamental, now editable like
  -- the others). The brightness proxy handed to external outputs is the largest
  -- ratio among this algo's active modulators (or op1's ratio for additive) — a
  -- stand-in for the old harm.
  local ratios = {c.opRatio1, c.opRatio2, c.opRatio3, c.opRatio4}
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
    if c.envMode == 1 then
      decay_sec = total * interval_sec
    else
      decay_sec = interval_sec
    end
  end

  -- envelope shape from a sequenced attack/decay pair (each normalized 0..1).
  -- Two independent envelopes share this mapping: the CARRIER amp env (attack_n/
  -- decay_n) and the MODULATOR brightness env (modatk_n/moddec_n).
  --   attack -> absolute time 0.001..0.4 s (a^2 curve: low values stay snappy),
  --             so a slow attack reads the same regardless of tempo (pads etc).
  --   decay  -> gap-RELATIVE (inter-hit gap / rate), 0.15x..1.85x the gap, so
  --             dense/fast channels self-shorten and a 6-voice mix stays legible
  --             (this is the behaviour the old `env` had, widened). burst/hit
  --             envMode still override the decay timing to lock it to the grid --
  --             applied to both envelopes so they track the same beat grid.
  local gap_sec = interval_sec / math.max(0.01, c.rate)
  local function attack_time(norm) local a = clamp(norm, 0, 1); return 0.001 + a * a * 0.4 end
  local function decay_time(norm)
    if decay_sec ~= nil then return math.max(0.01, decay_sec) end
    local d = clamp(norm, 0, 1)
    return clamp(gap_sec * (0.15 + d * 1.85), 0.02, 3.0)
  end
  local attack  = attack_time(attack_n)
  local amp_dec = decay_time(decay_n)
  -- modulator (FM body) envelope: its own attack + decay, no longer derived from
  -- the amp decay (the global fmDecay macro was retired in favour of this).
  local mod_attack = attack_time(modatk_n)
  local mod_dec    = decay_time(moddec_n)

  -- output routing (lib/outputs.lua): non-audio destinations replace the
  -- internal voice; midi/crow get the same final freq/level/length it would
  -- have played. Hook lives here (not on emit) because the per-hit prob skip
  -- emits a 'fire' event for the playhead without sounding anything.
  -- global voice timbre macros (lib/params_sync.lua 'VOICE' group).
  local mod_index = self.modIndex
  local amp_curve = -self.ampPunch
  local feedback  = self.fmFeedback
  local drive     = self.drive
  -- per-channel static operator levels, passed straight to the voice.
  local ol = {c.opLevel1, c.opLevel2, c.opLevel3, c.opLevel4}
  local out = self.outputs
  if engine and engine.trig and ((not out) or out:wants_audio(ch)) then
    -- 4-op FM (lib/Engine_Potionshop.sc): per-channel algorithm selects the
    -- operator routing; opRatio1..4 are the static per-op FM ratios (op1 default
    -- 1.0, now editable); the rest are the final hit envelope; ol[1..4] are this
    -- channel's static operator levels, geode-shaped per hit above. opRatio1 rides
    -- as r1 (arg 20, appended) so the older positional args keep their indices.
    engine.trig(geo_freq, actual_level, c.algo,
                c.opRatio2, c.opRatio3, c.opRatio4, mod_index,
                attack, amp_dec, amp_curve, mod_dec, feedback, drive, ch,
                ol[1], ol[2], ol[3], ol[4], mod_attack, c.opRatio1)
  end
  if out then
    -- external voices can't render FM timbre; hand them the channel's brightness
    -- proxy (largest active modulator ratio) so MIDI/crow track its character.
    out:note(ch, { freq = geo_freq, level = actual_level, harm = bright_ratio,
                   dur = attack + amp_dec })
  end

  self:emit{ type = 'fire', ch = ch, beat = beat,
             freq = geo_freq, level = actual_level }
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
  -- envelope shape: snappy-biased attack, medium-spread decay (grid-reachable k/31)
  c.attack = seqx.new(fill(len, function() return ri(8) / 31 end))
  c.decay  = seqx.new(fill(len, function() return (8 + ri(16)) / 31 end))
  -- modulator envelope shape, same grid-reachable k/31 spread as the carrier
  c.modatk = seqx.new(fill(len, function() return ri(8) / 31 end))
  c.moddec = seqx.new(fill(len, function() return (8 + ri(16)) / 31 end))
  -- op2/3/4 FM ratios ARE scrambled (timbral variety) — picked from the curated
  -- grid-reachable set so the OP-page picker can still highlight/edit them. op1's
  -- ratio is hand-editable but deliberately left at its 1.0 default here, so a
  -- randomized channel keeps a fundamental and stays pitched (mutate likewise).
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
    if Burst.reps_is_rest(v) then return v end  -- leave rests intact (like level)
    return clamp(round(v + jitter(amount * 4)), 1, 8)
  end)
  c.note  = map(c.note,  function(v) return round(v + jitter(amount * 4)) end)
  -- volume (level) left untouched: a constant, never jittered (see randomize).
  c.attack = map(c.attack, function(v) return clamp(v + jitter(amount * 0.6), 0, 1) end)
  c.decay  = map(c.decay,  function(v) return clamp(v + jitter(amount * 0.6), 0, 1) end)
  c.modatk = map(c.modatk, function(v) return clamp(v + jitter(amount * 0.6), 0, 1) end)
  c.moddec = map(c.moddec, function(v) return clamp(v + jitter(amount * 0.6), 0, 1) end)
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
