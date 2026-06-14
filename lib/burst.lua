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
    level = seqx.new{0.6},
    harm  = seqx.new{2},
    env   = seqx.new{0},
    divB   = seqx.new{0},
    repsB  = seqx.new{0},
    noteB  = seqx.new{0},
    levelB = seqx.new{0},
    harmB  = seqx.new{0},
    envB   = seqx.new{0},
    burstProb = 1,
    probHit = false,
    envMode = 0,    -- 0=shape 1=burst 2=hit
    geodeMode = 0,  -- 0=off 1=transient 2=sustain 3=cycle
    pitchEnv = 0,
    harmEnv = 0,
    resetInterval = 0,
    rate = 1,
    octave = 0,     -- -2..2, whole-octave pitch shift (perf page)
  }
end

function Burst.new()
  local self = setmetatable({}, Burst)
  self.launchGrid = 4   -- launches snap to the next quarter-note boundary
  self.quantize = 32    -- global event snap grid (events per whole note); 0 = off
  self.scale = scales.by_name.major
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
  self.modIndex = 8     -- FM modulation index (FMVoice default)
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
  for _, k in ipairs{'div','reps','note','level','harm','env',
                     'divB','repsB','noteB','levelB','harmB','envB'} do
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
  if self.running[ch] then self:launch(ch) end
end

-- ---- launch / stop -----------------------------------------------------

function Burst:launch(ch)
  if ch < 1 or ch > NUM_CHANNELS then return end
  if self.clocks[ch] then clock.cancel(self.clocks[ch]); self.clocks[ch] = nil end
  self.tokens[ch] = self.tokens[ch] + 1
  local token = self.tokens[ch]
  self.running[ch] = true
  self:emit{ type = 'launch', ch = ch }
  self.clocks[ch] = clock.run(function() self:run_channel(ch, token) end)
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
-- (length-1 finite reps on both A and B) completes.
function Burst:run_channel(ch, token)
  local target = quantize.snap_beat(get_beats(), self.launchGrid)
  while self.tokens[ch] == token do
    local r = self:run_burst(ch, token, target)
    if r == nil then return end
    target = r.target
    local c = self.channels[ch]
    local reps_len = math.max(seqx.len(c.reps), seqx.len(c.repsB))
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
    local div_seqB, reps_seqB, note_seqB = c.divB, c.repsB, c.noteB
    local div = math.max(1, div_seq() + div_seqB())
    local repsA = reps_seq()
    local repsBv = reps_seqB()
    local reps = (repsA == -1) and -1 or (repsA + repsBv)
    local degree = note_seq() + note_seqB()
    local level = c.level() + c.levelB()
    local harm = c.harm() + c.harmB()
    local env = c.env() + c.envB()
    local freq = scales.degree_to_freq(degree, self.scale)
    -- finite bursts clamp to >=1 hit so a 0/negative B offset can't tight-loop.
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
         or c.divB ~= div_seqB or c.repsB ~= reps_seqB or c.noteB ~= note_seqB then
        restarted = true
        break
      end
      self:wait_until_beat(target)
      if self.tokens[ch] ~= token then return nil end
      if c.probHit and math.random() > c.burstProb then
        -- per-hit skip: advance the playhead but don't trigger a voice.
        self:emit{ type = 'fire', ch = ch, beat = target,
                   freq = freq, level = level, harm = harm, env = env }
      else
        self:fire(ch, target, freq, level, harm, env, div, total, i)
      end
      target = target + (4 / div) / c.rate
      i = i + 1
    end

    if self.tokens[ch] ~= token then return nil end
    if not restarted then return { reps = reps, div = div, target = target } end
  end
  return nil
end

function Burst:fire(ch, beat, freq, level, harm, env, div, total, hit_idx)
  local c = self.channels[ch]
  -- octave shift is applied per hit, not per burst: looping channels
  -- (reps = -1) never redraw freq, so a burst-start shift would be inaudible
  -- on them. Shifting here also feeds the final freq to external outputs.
  freq = freq * (2 ^ c.octave)
  local geo_run = clamp(level, 0, 1)
  local actual_level = Burst.burst_level_for_hit(level, c.geodeMode, env, hit_idx, total)

  -- Pitch geode: g=1 -> target, g=0 -> -1 octave.
  local geo_freq = freq
  if c.pitchEnv > 0 then
    local g = Burst.geode_mod(c.pitchEnv, geo_run, hit_idx, total)
    geo_freq = freq * (2 ^ (g - 1))
  end

  -- Harm geode: g=1 -> target harm, g=0 -> unison (2).
  local geo_harm = harm
  if c.harmEnv > 0 then
    local g = Burst.geode_mod(c.harmEnv, geo_run, hit_idx, total)
    geo_harm = 2 + g * math.max(0, harm - 2)
  end

  -- decaySec from envMode (1=burst-length, 2=per-hit).
  local decay_sec = nil
  if c.envMode ~= 0 then
    local sec_per_beat = 60 / get_tempo()
    local interval_sec = (4 / div) * sec_per_beat
    if c.envMode == 1 and total ~= INF then
      decay_sec = total * interval_sec
    else
      decay_sec = interval_sec
    end
  end

  -- env -> time mapping (ported from FMVoice.triggerAt).
  local attack, amp_dec, mod_dec
  if decay_sec ~= nil then
    attack = 0.001
    amp_dec = math.max(0.01, decay_sec)
    mod_dec = amp_dec * 0.4
  else
    local e = clamp(env, 0, 1)
    attack = 0.001 + e * 0.024
    amp_dec = 0.4 + e * 0.8
    mod_dec = 0.05 + e * 0.25
  end

  -- output routing (lib/outputs.lua): non-audio destinations replace the
  -- internal voice; midi/crow get the same final freq/level/length it would
  -- have played. Hook lives here (not on emit) because the per-hit prob skip
  -- emits a 'fire' event for the playhead without sounding anything.
  local out = self.outputs
  if engine and engine.trig and ((not out) or out:wants_audio(ch)) then
    engine.trig(geo_freq, actual_level, geo_harm, self.modIndex, attack, amp_dec, mod_dec)
  end
  if out then
    out:note(ch, { freq = geo_freq, level = actual_level, dur = attack + amp_dec })
  end

  self:emit{ type = 'fire', ch = ch, beat = beat,
             freq = geo_freq, level = actual_level, harm = geo_harm, env = env }
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
  local t_len = 1
  c.level = seqx.new(fill(t_len, function() return (ri(16) + 1) / 31 end))
  c.harm  = seqx.new(fill(t_len, function() return 2 + ri(16) * 0.75 end))
  c.env   = seqx.new(fill(t_len, function() return ri(16) / 31 end))
  c.envMode   = ri(3)
  c.geodeMode = ri(4)
  c.pitchEnv  = ri(4)
  c.harmEnv   = ri(4)
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
  c.level = map(c.level, function(v) return clamp(v + jitter(amount * 0.5), 0, 1) end)
  c.harm  = map(c.harm,  function(v) return clamp(v + jitter(amount * 2), 2, 4) end)
  c.env   = map(c.env,   function(v) return clamp(v + jitter(amount * 0.6), 0, 1) end)
end

return Burst
