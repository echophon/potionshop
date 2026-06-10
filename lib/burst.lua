-- burst.lua
-- Six-channel FM burst sequencer core, ported from src/burst.ts.
--
-- Scheduling uses the stock `lattice` library: one lattice (clock-driven), one
-- sprocket per channel. A channel's `div` ("events per whole note") maps to a
-- lattice division of 1/div (scaled by `rate`); the sprocket's action does the
-- per-burst bookkeeping the web app's runChannel/runBurst coroutines did. Each
-- action fires one hit and, after firing, sets the division that governs the
-- gap to the NEXT hit — so changing div at a burst boundary takes effect for
-- the following hit, matching the web timing. (lattice re-arms a sprocket's
-- phase from self.division right after action() returns.)
--
-- Geode modulation, the env->time mapping, and randomize/mutate value sets are
-- ported verbatim so audio behaviour and grid-reachability match the original.

local lattice = require 'lattice'
local scales  = require 'scales'
local seqx    = require 'seqx'

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
    locked = false,
    resetInterval = 0,
    rate = 1,
    voiceType = 'fm',  -- 'fm' | 'jf' | 'mg'  (jf/mg route to FM this pass)
  }
end

function Burst.new()
  local self = setmetatable({}, Burst)
  self.launchGrid = 4
  self.quantize = 32  -- stored; under lattice the division grid is the snap
  self.scale = scales.by_name.major
  self.channels = {}
  self.running = {}
  self.rt = {}        -- per-channel runtime burst state
  for i = 1, NUM_CHANNELS do
    self.channels[i] = default_channel()
    self.running[i] = false
    self.rt[i] = { remaining = 0 }
  end
  self.listeners = {}
  self.lattice = nil
  self.sprockets = {}
  self.modIndex = 8   -- FM modulation index (FMVoice default)
  return self
end

-- ---- lattice setup -----------------------------------------------------

function Burst:setup_lattice()
  self.lattice = lattice:new{ auto = true }
  for i = 1, NUM_CHANNELS do
    self.sprockets[i] = self.lattice:new_sprocket{
      action = function() self:_tick(i) end,
      division = 1 / 4,
      enabled = false,  -- created stopped; launch() starts it
    }
  end
  self.lattice:start()
end

local function division_for(div, rate)
  return 1 / (math.max(1, div) * rate)
end

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

function Burst:get_voice_type(ch) return self.channels[ch].voiceType end

function Burst:toggle_voice(ch)
  local c = self.channels[ch]
  c.voiceType = (c.voiceType == 'fm') and 'jf'
    or (c.voiceType == 'jf') and 'mg' or 'fm'
end

-- ---- sequins reset -----------------------------------------------------

function Burst:reset_channel(ch)
  local c = self.channels[ch]
  for _, k in ipairs{'div','reps','note','level','harm','env',
                     'divB','repsB','noteB','levelB','harmB','envB'} do
    c[k]:reset()
  end
  self.rt[ch].remaining = 0
end

function Burst:reset_sequins()
  for i = 1, NUM_CHANNELS do self:reset_channel(i) end
end

-- ---- launch / stop -----------------------------------------------------

function Burst:launch(ch)
  if ch < 1 or ch > NUM_CHANNELS then return end
  self.rt[ch] = { remaining = 0 }  -- force a fresh burst on the next tick
  local sp = self.sprockets[ch]
  if sp then
    -- start one division out so the first hit is musically placed, not instant
    sp.phase = sp.division * self.lattice.ppqn * 4
    sp:start()
  end
  self.running[ch] = true
  self:emit{ type = 'launch', ch = ch }
end

function Burst:stop(ch)
  if ch < 1 or ch > NUM_CHANNELS then return end
  if self.sprockets[ch] then self.sprockets[ch]:stop() end
  if self.running[ch] then
    self.running[ch] = false
    self:emit{ type = 'stop', ch = ch }
  end
end

function Burst:stop_all()
  for i = 1, NUM_CHANNELS do self:stop(i) end
end

-- ---- the per-channel tick (lattice sprocket action) --------------------

function Burst:_pull_burst(ch)
  local c = self.channels[ch]
  local st = self.rt[ch]
  local div = math.max(1, c.div() + c.divB())
  local repsA = c.reps()
  local repsBv = c.repsB()
  local reps = (repsA == -1) and -1 or (repsA + repsBv)
  local degree = c.note() + c.noteB()
  local level = c.level() + c.levelB()
  local harm = c.harm() + c.harmB()
  local env = c.env() + c.envB()

  st.div = div
  st.freq = scales.degree_to_freq(degree, self.scale)
  st.level = level
  st.harm = harm
  st.env = env
  st.rate = c.rate
  st.hit_idx = 0
  if reps == -1 then
    st.total = INF
    st.remaining = INF
  else
    st.total = math.max(1, reps)   -- guard against 0/negative B offsets
    st.remaining = st.total
  end
  -- single-shot: A's reps length-1 AND B's reps length-1 (a multi-step B-reps
  -- layer is a "make this loop" signal even if A is single-step).
  local reps_len = math.max(seqx.len(c.reps), seqx.len(c.repsB))
  st.single_shot = (reps ~= -1) and (reps_len <= 1)
  -- burst-mode probability gate (only when not per-hit; infinite unaffected)
  st.muted = (not c.probHit) and (reps ~= -1) and (math.random() > c.burstProb)
end

function Burst:_fire_hit(ch)
  local c = self.channels[ch]
  local st = self.rt[ch]
  local i = st.hit_idx
  local total = st.total

  local geo_run = clamp(st.level, 0, 1)
  local actual_level = Burst.burst_level_for_hit(st.level, c.geodeMode, st.env, i, total)

  -- Pitch geode: g=1 -> target, g=0 -> -1 octave.
  local geo_freq = st.freq
  if c.pitchEnv > 0 then
    local g = Burst.geode_mod(c.pitchEnv, geo_run, i, total)
    geo_freq = st.freq * (2 ^ (g - 1))
  end

  -- Harm geode: g=1 -> target harm, g=0 -> unison (2).
  local geo_harm = st.harm
  if c.harmEnv > 0 then
    local g = Burst.geode_mod(c.harmEnv, geo_run, i, total)
    geo_harm = 2 + g * math.max(0, st.harm - 2)
  end

  -- decaySec from envMode (1=burst-length, 2=per-hit).
  local decay_sec = nil
  if c.envMode ~= 0 then
    local tempo = (clock and clock.tempo) or 120
    local sec_per_beat = 60 / tempo
    local interval_sec = (4 / st.div) * sec_per_beat
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
    local e = clamp(st.env, 0, 1)
    attack = 0.001 + e * 0.024
    amp_dec = 0.4 + e * 0.8
    mod_dec = 0.05 + e * 0.25
  end

  -- per-hit probability gate: skip the voice but still advance the playhead.
  local skip = c.probHit and (math.random() > c.burstProb)
  if not skip and not st.muted then
    if engine and engine.trig then
      engine.trig(geo_freq, actual_level, geo_harm, self.modIndex, attack, amp_dec, mod_dec)
    end
  end

  local beat = (clock and clock.get_beats and clock.get_beats()) or 0
  self:emit{ type = 'fire', ch = ch, beat = beat,
             freq = geo_freq, level = actual_level, harm = geo_harm, env = st.env }
end

function Burst:_tick(ch)
  local st = self.rt[ch]
  if st.remaining ~= INF and st.remaining <= 0 then
    self:_pull_burst(ch)
  end

  self:_fire_hit(ch)
  st.hit_idx = st.hit_idx + 1
  if st.remaining ~= INF then st.remaining = st.remaining - 1 end

  -- division that governs the gap to the NEXT hit (this burst's div).
  self.sprockets[ch]:set_division(division_for(st.div, st.rate))

  if st.single_shot and st.remaining ~= INF and st.remaining <= 0 then
    self:stop(ch)
  end
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
  local t_len = c.locked and len or 1
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
