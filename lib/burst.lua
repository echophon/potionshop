-- burst.lua
-- Six-channel FM burst sequencer core, ported from src/burst.ts (which in turn
-- ports er301_geode.lua). Scheduling is a 1:1 port of the web app's
-- runChannel/runBurst coroutines onto norns `clock`: each launched channel runs
-- a `clock.run` coroutine that pulls the next value from each sequins per burst,
-- waits until the (quantized) target beat, fires, and advances.
--
-- Quantization: every event's target beat is snapped FORWARD to that channel's
-- own quantize grid (`quantize.snap_beat`, channels[ch].quantize from
-- QUANTIZE_VALUES), so each channel locks to its chosen sub-beat grid regardless
-- of its division. (This was a single global grid in the web app; it is now
-- per-channel.) quantize = 0 would disable snapping, but the curated set has no
-- 0 — every channel always snaps.
--
-- The wait itself (`wait_until_beat`) uses `clock.sync` to walk that quantize grid
-- to the snapped beat, NOT a one-shot `clock.sleep(seconds)`. clock.sync locks each
-- wakeup to the clock thread's absolute beat grid, so individual hits don't inherit
-- the scheduler jitter a latency-relative sleep target carries — the difference
-- becomes audible as the inter-hit slot shrinks at high tempo/density. (The web app
-- uses a sleep-style waitUntilBeat because the browser's AudioContext has its own
-- sample-accurate lookahead; norns Lua does not, so clock.sync is the tighter port.)
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

-- Curated per-channel quantize grids (events per whole note): the firing instant
-- snaps forward to the next 1/N point before each hit (see wait_until_beat). A
-- small musical set rather than the old continuous 1..32, so it fits a per-channel
-- grid page and reads cleanly. Mirrors GridUI.QUANTIZE_VALUES — keep in sync.
local QUANTIZE_VALUES = {3, 4, 6, 8, 12, 16, 24, 32}
Burst.QUANTIZE_VALUES = QUANTIZE_VALUES

-- Per-operator FM ratios, split into TWO curated sets that complement the 5-limit
-- key layout (lib/scales.lua JI_RATIOS). Which set an op draws from is chosen
-- DYNAMICALLY per channel by the algorithm: an op that is a CARRIER under the
-- channel's algo uses CARRIER_RATIOS (5-limit just intervals, so each carrier sounds
-- a pure interval and reinforces the key); an op that is a MODULATOR uses
-- MODULATOR_RATIOS (whole numbers + simple divisions, so the FM/ring sidebands land
-- on 5-limit-consonant partials). Burst.is_carrier(algo, op) = the complement of
-- ALGO_MODULATORS. Mirrored by GridUI.CARRIER_RATIOS / MODULATOR_RATIOS — keep in sync.
--
-- CARRIER set: 5-limit just ratios across ~4 octaves (every value factors into
-- 2*3*5 in both numerator & denominator). 32 ascending values = one full grid picker.
local CARRIER_RATIOS = {
  -- sub-octave: 1/2 3/5 5/8 2/3 3/4 4/5 5/6 15/16
  0.5, 0.6, 0.625, 0.667, 0.75, 0.8, 0.833, 0.9375,
  -- octave 1-2: 1/1 9/8 6/5 5/4 4/3 3/2 8/5 5/3
  1.0, 1.125, 1.2, 1.25, 1.333, 1.5, 1.6, 1.667,
  -- octave 2-4: 15/8 2/1 12/5 5/2 8/3 3/1 16/5 10/3
  1.875, 2.0, 2.4, 2.5, 2.667, 3.0, 3.2, 3.333,
  -- octave 4-8: 15/4 4/1 24/5 5/1 16/3 6/1 15/2 8/1
  3.75, 4.0, 4.8, 5.0, 5.333, 6.0, 7.5, 8.0,
}
Burst.CARRIER_RATIOS = CARRIER_RATIOS
-- MODULATOR set: whole numbers (integer modulator -> harmonic sidebands) + unit
-- divisions (subharmonic, keeps the spectrum periodic) + 5-limit-biased fractions
-- (5/4, 5/3, 5/2, ... tilt the brightest sidebands onto the just thirds/fifths the
-- key is tuned to). 32 ascending values.
local MODULATOR_RATIOS = {
  -- unit divisions + small 5-limit fractions below 1:
  -- 1/8 1/6 1/5 1/4 1/3 2/5 1/2 3/5 2/3 3/4 4/5
  0.125, 0.167, 0.2, 0.25, 0.333, 0.4, 0.5, 0.6, 0.667, 0.75, 0.8,
  -- 5-limit fractions 1-2 + harmonic integers + 5-rich highs:
  -- 1 5/4 4/3 3/2 5/3 2 5/2 3 10/3 15/4 4 5 6 7 8 9 10 11 12 14 16
  1.0, 1.25, 1.333, 1.5, 1.667, 2.0, 2.5, 3.0, 3.333, 3.75, 4.0,
  5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 14.0, 16.0,
}
Burst.MODULATOR_RATIOS = MODULATOR_RATIOS
-- The full curated set = union of both, sorted ascending + de-duplicated. This is the
-- STABLE index space the op-ratio B (index-offset) lane walks and that params store
-- indices against; both role sets are subsets, so every value stays grid-reachable.
-- Mirrors GridUI.RATIO_VALUES — keep in sync.
local RATIO_VALUES = {}
do
  local seen = {}
  local function add(v) if not seen[v] then seen[v] = true; RATIO_VALUES[#RATIO_VALUES + 1] = v end end
  for _, v in ipairs(CARRIER_RATIOS)   do add(v) end
  for _, v in ipairs(MODULATOR_RATIOS) do add(v) end
  table.sort(RATIO_VALUES)
end
Burst.RATIO_VALUES = RATIO_VALUES

-- value -> 1-based index in RATIO_VALUES (exact for picked values; nearest otherwise).
local RATIO_INDEX = {}
for i, r in ipairs(RATIO_VALUES) do RATIO_INDEX[r] = i end
local function ratio_pos(v)
  if RATIO_INDEX[v] then return RATIO_INDEX[v] end
  local best, bd = 1, math.huge
  for i, r in ipairs(RATIO_VALUES) do
    local d = math.abs(r - v); if d < bd then bd = d; best = i end
  end
  return best
end

-- Resolve a sequenced op ratio: A is a curated ratio value (first-32 grid range),
-- `off` is the B integer index offset that walks UP the list (clamped to its end).
-- The result is always a real RATIO_VALUES entry — never an off-grid sum.
local function op_ratio(a, off)
  local idx = ratio_pos(a) + math.floor((off or 0) + 0.5)
  return RATIO_VALUES[math.max(1, math.min(#RATIO_VALUES, idx))]
end
Burst.op_ratio = op_ratio

-- Which operators are modulators (appear as a 'from' in some edge) per algorithm
-- 1..16. Mirrors Engine_Potionshop.algorithms (SC) — keep in sync; used only to
-- pick the brightness proxy (largest active modulator ratio) for MIDI/crow out.
-- Non-carrier (modulator) ops per algo 1..22. For 17..22 these include the AM/ring
-- source ops too (they appear as a 'from' in an amEdge). op1 is a carrier in every
-- algorithm. Mirrors Engine_Potionshop.algorithms (pmEdges + amEdges) — keep in sync.
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
  {2},                   -- 17: op2 ring-mods op1 (two bare carriers)
  {2, 4},                -- 18: twin ring pairs (2->1, 4->3)
  {3, 4},                -- 19: 4->3 PM stack ring-mods op1 (pure op2)
  {4},                   -- 20: op4 AM-shimmers three carriers
  {2, 3, 4},             -- 21: ring chain 4(x)3(x)2(x)1
  {2, 3, 4},             -- 22: (4,3)->1 PM + op2 AM-shimmers op1
  {2, 4},                -- 23: twin AM pairs (2~1, 4~3)
  {4},                   -- 24: op4 ring-mods three carriers
  {2, 4},                -- 25: 2->1 PM stack + 4~3 AM pair
  {2, 3, 4},             -- 26: AM chain 4~3~2~1
  {2, 3, 4},             -- 27: op1 hit by PM(4) + ring(3) + AM(2)
  {2, 3, 4},             -- 28: 3->2->1 PM stack + op4 AM-shimmer
  {2, 3, 4},             -- 29: (4,3)->2 PM carrier ring-mods op1
  {3, 4},                -- 30: twin ring pairs (4x2, 3x1)
  {3, 4},                -- 31: twin AM pairs (4~2, 3~1)
  {2, 3, 4},             -- 32: 4->3 PM then AM chain 3~2~1
}
Burst.ALGO_MODULATORS = ALGO_MODULATORS

-- An op is a carrier under `algo` iff it is NOT in that algo's modulator list. Drives
-- the dynamic op-ratio set selection (carriers -> CARRIER_RATIOS, else MODULATOR_RATIOS)
-- in randomize/mutate and the grid op-ratio pickers (mirrored in lib/grid_ui.lua).
local function is_carrier(algo, op)
  local mods = ALGO_MODULATORS[algo] or {}
  for _, m in ipairs(mods) do if m == op then return false end end
  return true
end
Burst.is_carrier = is_carrier
-- The op-ratio set for op `op` under `algo`: 5-limit carriers, else harmonic modulators.
local function op_ratio_set(algo, op)
  return is_carrier(algo, op) and CARRIER_RATIOS or MODULATOR_RATIOS
end
Burst.op_ratio_set = op_ratio_set

-- Envelope SHAPES. Each is a normalized contour scaled at fire time to the channel's
-- *known* inter-hit slot (gap_sec), so every shape "fits the schedule" automatically.
-- A single shape index replaces the old attack|decay (and modatk|moddec) pairs: one
-- value picks the whole contour. Fields:
--   atkMul/decMul = attack / decay length as a fraction of the inter-hit gap. The
--                   amp decay is still grid-locked by env_mode (burst/hit) just like
--                   the old `decay` was; in shape mode it is decMul*gap.
--   atkCurve/decCurve = SC `Env` curve per segment (0 = linear, negative = fast-start
--                   exp 'pluck', positive = slow-start 'log'). Independent per segment,
--                   which the old single Env.perc curve couldn't express.
-- DEFAULTS: carrier = SHAPE_CARRIER_DEFAULT ('tail', ~the old decay 16/31 contour),
-- modulator = SHAPE_MOD_DEFAULT ('body', ~the old moddec 8/31). Mirrored by name +
-- count in lib/grid_ui.lua (GridUI.SHAPE_NAMES) -- keep the two in sync. (The SC
-- engine never sees a shape: fire() resolves the index to times + curves.)
--
-- ORDERED BY ATTACK LENGTH (atkMul ascending) so the picker reads left-to-right /
-- top-to-bottom as a short -> long attack gradient (and the LED/screen brightness
-- ramp tracks it). row 1 (1..16) is the INSTANT-attack family (atkMul 0, percussive),
-- ordered by decay length within it; row 2 (17..32) is the GROWING-attack family
-- (atkMul 0.05 -> 1.00), swells through ramps. Every entry is a single attack-decay
-- contour -- deliberately NO ratchets / LFO-style cycling, which would fight the
-- engine's own rhythm; the variety is in decay length + the per-segment curve family
-- (exp / linear / log).
local SHAPES = {
  -- {atkMul, decMul, atkCurve, decCurve, name}
  -- row 1: instant attack (atkMul 0), ordered by decay length, curve variety:
  {0.00, 0.10, -8, -8, 'click'},  -- 1  tiniest transient
  {0.00, 0.18, -8, -8, 'snap'},   -- 2  very short, steep
  {0.00, 0.25, -4, -4, 'tap'},    -- 3  short pluck
  {0.00, 0.30, -2, -2, 'pip'},    -- 4  gentle short
  {0.00, 0.38, -2, -8, 'pop'},    -- 5  soft-ish in, steep out
  {0.00, 0.45, -4, -4, 'pluck'},  -- 6
  {0.00, 0.55, -6, -6, 'drum'},   -- 7  punchy mid
  {0.00, 0.70, -4, -4, 'body'},   -- 8  (modulator default; ~old moddec 8/31)
  {0.00, 0.80, -4, -8, 'exp'},    -- 9  steep exponential decay
  {0.00, 0.85, -4,  4, 'log'},    -- 10 logarithmic decay (slow then fast)
  {0.00, 1.00, -1,  8, 'glass'},  -- 11 hold then a log (slow-start) drop
  {0.00, 1.10, -4, -4, 'tail'},   -- 12 (carrier default; ~old decay 16/31)
  {0.00, 1.40, -2, -6, 'bell'},   -- 13 long bell-like ring
  {0.00, 1.70, -4, -3, 'long'},   -- 14 nearly fills the slot
  {0.00, 2.00,  0, -8, 'hold'},   -- 15 flat sustain then a fast drop
  {0.00, 2.40, -1, -2, 'drone'},  -- 16 very long tail (cut by next hit; clamped 3s)
  -- row 2: growing attack (atkMul 0.05 -> 1.00), swells through ramps:
  {0.05, 0.80,  0,  0, 'lin'},    -- 17 linear attack + decay
  {0.10, 0.55, -2, -2, 'soft'},   -- 18 gentle pluck w/ a touch of attack
  {0.15, 0.50, -1, -2, 'round'},  -- 19
  {0.15, 1.60,  0, -2, 'fade'},   -- 20 soft in, long near-linear fade
  {0.20, 0.45,  2, -3, 'puff'},   -- 21 gentle log blip
  {0.25, 1.30,  3, -5, 'surge'},  -- 22 log attack + long tail
  {0.30, 0.55,  4, -4, 'swell'},  -- 23 soft (log) attack
  {0.35, 0.55,  4,  4, 'arc'},    -- 24 soft symmetric (log in + out)
  {0.40, 0.30, -4, -4, 'ramp'},   -- 25 exp attack, short
  {0.45, 0.90,  6, -4, 'bloom'},  -- 26 slow swell + medium tail
  {0.50, 1.50,  5, -4, 'huge'},   -- 27 big swell pad
  {0.60, 0.55, -2, -2, 'pad'},    -- 28 slow symmetric
  {0.70, 0.80,  2, -2, 'bow'},    -- 29 bowed: slow in, medium out
  {0.85, 0.40, -3, -3, 'wedge'},  -- 30 attack nearly fills the slot
  {1.00, 0.10,  3, -2, 'rise'},   -- 31 reverse: rises into the next hit
  {1.00, 0.05,  0, -8, 'revrs'},  -- 32 pure ramp into the next hit, click off
}
Burst.SHAPES = SHAPES
Burst.SHAPE_CARRIER_DEFAULT = 12  -- 'tail'
Burst.SHAPE_MOD_DEFAULT     = 8   -- 'body'
-- Count of the leading INSTANT-attack shapes (atkMul 0). Because the table is
-- attack-ordered they're contiguous at the front (the row-1 / first-16 percussive
-- family). randomize draws env shapes only from this range, so a scrambled channel
-- stays punchy rather than getting a slow swell/pad that smears the rhythm.
local SHAPE_PERC_COUNT = 0
for _, s in ipairs(SHAPES) do
  if s[1] == 0 then SHAPE_PERC_COUNT = SHAPE_PERC_COUNT + 1 else break end
end
Burst.SHAPE_PERC_COUNT = SHAPE_PERC_COUNT

-- Resolve a 1-based shape index to its contour entry (clamped to the table).
function Burst.shape(i)
  i = math.floor((i or 1) + 0.5)
  if i < 1 then i = 1 elseif i > #SHAPES then i = #SHAPES end
  return SHAPES[i]
end

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
    -- channel level is a per-channel STATIC scalar (no longer sequenced) edited on
    -- the MIX page alongside the four op levels — it never varied (randomize/mutate
    -- left it alone), so it sequenced nothing. 16/31 ≈ 0.52 is the grid-exact form
    -- of the old 0.5 neutral, kept reachable on the 1/31 MIX picker.
    level = 16 / 31,
    -- envelope SHAPE is sequenced. ampShape (carrier amp env) and modShape
    -- (modulator/FM-brightness env) are a single PAIR sharing one page (like
    -- div/reps): each is a 1-based index into Burst.SHAPES, resolved per hit in
    -- fire() to attack/decay times (scaled to the inter-hit gap) + per-segment
    -- curves. One index replaces the old attack|decay and modatk|moddec pairs.
    ampShape = seqx.new{Burst.SHAPE_CARRIER_DEFAULT},
    modShape = seqx.new{Burst.SHAPE_MOD_DEFAULT},
    -- div/reps/ampShape/modShape have no B layer; only note keeps one now (level
    -- became a static MIX-page scalar, so its old additive B layer is gone too).
    noteB  = seqx.new{0},
    -- per-operator FM ratios. ALL four are SEQUENCED (their own grid pages, A value
    -- + B index offset, like note/level) so every operator's voicing can morph per
    -- step. op1 is the fundamental — its A defaults to 1.0 (a pitch anchor that
    -- randomize/mutate leave alone), but it sequences exactly like op2/3/4 now.
    -- ratios 1,1,1,1 = unison (cleanest, ~2-op).
    opRatio1 = seqx.new{1}, opRatio2 = seqx.new{1}, opRatio3 = seqx.new{1}, opRatio4 = seqx.new{1},
    opRatio1B = seqx.new{0}, opRatio2B = seqx.new{0}, opRatio3B = seqx.new{0}, opRatio4B = seqx.new{0},
    -- per-operator output levels (0..1) stay per-channel STATIC timbre, edited on the
    -- OP page — not sequenced. levels: FM depth when the op is a modulator, mix gain
    -- when it's a carrier.
    opLevel1 = 1, opLevel2 = 15/31, opLevel3 = 15/31, opLevel4 = 15/31,  -- ~0.48, grid-exact on the i/31 OP page
    -- per-channel STATIC voice macros, edited on the MIX page after the op levels (no
    -- grid page / sequence): FM mod index (1..32, brightness depth), amp punch (0..31,
    -- carrier env-curve exaggeration, /4 = 1.0 neutral), FM feedback (0..4 rad,
    -- modulator self-feedback) and FM algo (1..16, DX-style operator routing, MIX col
    -- 15). Like level/opLevel they're exempt from randomize/mutate and survive
    -- clear/copy/paste. Drawn straight at fire time.
    modIndex = 2, ampPunch = 4, fmFeedback = 0, algo = 1,
    -- per-channel STATIC stereo pan (MIX page): -1 = hard left, 0 = centre,
    -- +1 = hard right. Like the other MIX scalars it's exempt from randomize/mutate
    -- and survives clear/copy/paste. Drawn straight at fire time (SC Pan2).
    pan = 0,
    burstProb = 1,
    probHit = false,
    resetInterval = 0,
    rate = 1,
    quantize = 16,  -- per-channel event snap grid (events per whole note), from QUANTIZE_VALUES
    octave = 0,     -- -2..2, whole-octave pitch shift (perf page)
    altTrig = 0,    -- alt(B) note layering: 0=hold (add&hold) 1=step (per-hit)
    -- per-op-ratio sequence trig mode (prob page): 0=hold (the ratio is drawn once
    -- per burst, held for every hit) 1=step (advance the opRatioN B index lane per
    -- hit, so the ratio arpeggiates within a burst). Mirrors altTrig for the note B.
    opRatio1Trig = 0, opRatio2Trig = 0, opRatio3Trig = 0, opRatio4Trig = 0,
    -- per-envelope-shape sequence trig mode (prob page): 0=hold (the shape is drawn
    -- once per burst) 1=step (advance the ampShape/modShape A sequins per hit, so the
    -- envelope shape arpeggiates within a burst). Same hold/step mechanism, but since
    -- shapes have no B layer it walks the A lane itself (op-ratio step walks B).
    ampShapeTrig = 0, modShapeTrig = 0,
  }
end

function Burst.new()
  local self = setmetatable({}, Burst)
  self.launchGrid = 4   -- launches snap to the next quarter-note boundary
  -- (event snap grid is per-channel now: channels[ch].quantize, from QUANTIZE_VALUES)
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
  self.envMode = 0      -- amp decay timing (0=shape 1=burst 2=hit): engine-wide
  self.geodeMode = 1    -- amp per-hit geode (0=transient 1=sustain 2=cycle): engine-wide, default sustain
  -- (FM algorithm, mod index, amp punch and FM feedback used to be engine-wide globals
  -- too; they are now per-channel static MIX-page scalars — see default_channel. FM
  -- body length
  -- is no longer a macro either: the per-channel modShape sequence owns the modulator
  -- envelope; the old self.fmDecay was retired.)
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
  for _, k in ipairs{'div','reps','note','ampShape','modShape',  -- envelope shapes (paired, A-only)
                     'opRatio1','opRatio2','opRatio3','opRatio4',  -- sequenced op ratios (A)
                     'noteB',                                     -- only note keeps a B layer
                     'opRatio1B','opRatio2B','opRatio3B','opRatio4B'} do  -- op ratios keep a B layer
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
-- grid point. `q` is the firing channel's per-channel quantize (events per whole
-- note); tempo is preserved — target progresses at the natural rate, the snap
-- only nudges the firing instant. (Direct port of clock.ts waitUntilBeat.)
function Burst:wait_until_beat(target, q)
  -- q <= 0 disables snapping (not reachable from the curated picker, but the math
  -- honours it): there's no grid to lock to, so fall back to a direct sleep to the
  -- absolute target.
  if q <= 0 then
    local wait_secs = (target - get_beats()) * (60 / get_tempo())
    if wait_secs > 0 then clock.sleep(wait_secs) end
    return
  end
  -- Grid-locked wait: walk the quantize grid up to the snapped `fire` beat with
  -- clock.sync, which schedules each wakeup against the clock thread's ABSOLUTE
  -- beat grid rather than `now + computed_seconds`. A clock.sleep target inherits
  -- the scheduler/CPU jitter present at the instant it's called (worse as the
  -- inter-hit slot shrinks at high tempo/density); clock.sync's target is the same
  -- phase-locked grid point every time, so wakeups don't accumulate that jitter.
  -- When we're already at/past `fire` (hit density finer than q, so successive
  -- targets snap to the same point) the loop body never runs and we fire
  -- immediately — identical catch-up semantics to the old `wait_secs > 0` guard.
  local fire = quantize.snap_beat(target, q)
  local step = 4 / q
  while get_beats() < fire - 1e-9 do
    clock.sync(step)
  end
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
    local level = c.level  -- per-channel static MIX scalar (no longer sequenced)
    -- sequenced op1/2/3/4 FM ratios: A = base ratio (first-32 grid range), B = integer
    -- index offset that walks UP RATIO_VALUES (the only route into the 33..63 extended
    -- range). A is the per-burst value (drawn once, held for every hit, like the note
    -- A degree); B is its offset. Kept separate so the step trig mode below can
    -- advance B per hit while A stays held. Drawn above the rest/skip checks so the
    -- sequins advance on every burst step. op1 is the fundamental (A defaults to 1.0).
    -- A live edit applies at the next burst (not identity-checked, like level).
    local ratio1A, ratio1B = c.opRatio1(), c.opRatio1B()
    local ratio2A, ratio2B = c.opRatio2(), c.opRatio2B()
    local ratio3A, ratio3B = c.opRatio3(), c.opRatio3B()
    local ratio4A, ratio4B = c.opRatio4(), c.opRatio4B()
    local ratio1 = op_ratio(ratio1A, ratio1B)
    local ratio2 = op_ratio(ratio2A, ratio2B)
    local ratio3 = op_ratio(ratio3A, ratio3B)
    local ratio4 = op_ratio(ratio4A, ratio4B)
    -- carrier/modulator envelope shape indices (paired, A-only). Drawn once per burst
    -- (held for every hit) unless the per-shape trig mode is 'step', which advances the
    -- A sequins per hit in the loop below so the shape arpeggiates through its sequence.
    local amp_shape = c.ampShape()
    local mod_shape = c.modShape()
    local freq = scales.degree_to_freq(degreeA + degreeB, self.scale, self.root)

    -- REST: reps <= 0 fires nothing but still consumes (1 - reps) div-steps of
    -- time so the rhythm holds. We drew all the sequins above (so they advance
    -- like any burst step), then just wait out the slot and advance. Deterministic
    -- silence, distinct from level=0 (a triggered-but-silent voice) and from
    -- probability (random). Not subject to the probability gate below.
    if Burst.reps_is_rest(reps) then
      target = target + Burst.reps_rest_len(reps) * (4 / div) / c.rate
      self:wait_until_beat(target, c.quantize)
      if self.tokens[ch] ~= token then return nil end
      return { reps = reps, div = div, target = target }
    end

    local total = math.max(1, reps)

    -- burst-mode probability gate: skip the whole burst, advance time once.
    if (not c.probHit) and math.random() > c.burstProb then
      target = target + total * (4 / div) / c.rate
      self:wait_until_beat(target, c.quantize)
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
      self:wait_until_beat(target, c.quantize)
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

      -- OP-RATIO STEP MODE: per sequence, when opRatioNTrig == 1 the B (offset) lane
      -- advances per hit and re-resolves against the held A, so the index walks
      -- through neighbouring ratios within the burst (A stays the per-burst base —
      -- exactly like the note alt-trig above). Same placement/rationale: above the
      -- probHit skip and i > 0, so a skipped hit still consumes a B value.
      if i > 0 then
        if c.opRatio1Trig == 1 then ratio1 = op_ratio(ratio1A, c.opRatio1B()) end
        if c.opRatio2Trig == 1 then ratio2 = op_ratio(ratio2A, c.opRatio2B()) end
        if c.opRatio3Trig == 1 then ratio3 = op_ratio(ratio3A, c.opRatio3B()) end
        if c.opRatio4Trig == 1 then ratio4 = op_ratio(ratio4A, c.opRatio4B()) end
      end

      -- SHAPE STEP MODE: ampShape/modShape have no B layer, so 'step' advances their
      -- A sequins per hit (the envelope shape arpeggiates through its sequence within
      -- the burst); 'hold' keeps the per-burst draw. Same placement/rationale as the
      -- op-ratio step above — past the i > 0 guard so a skipped hit still advances.
      if i > 0 then
        if c.ampShapeTrig == 1 then amp_shape = c.ampShape() end
        if c.modShapeTrig == 1 then mod_shape = c.modShape() end
      end

      if c.probHit and math.random() > c.burstProb then
        -- per-hit skip: advance the playhead but don't trigger a voice.
        self:emit{ type = 'fire', ch = ch, beat = target,
                   freq = freq, level = level }
      else
        self:fire(ch, target, freq, level, amp_shape, mod_shape, div, total, i,
                  ratio1, ratio2, ratio3, ratio4)
      end
      target = target + (4 / div) / c.rate
      i = i + 1
    end

    if self.tokens[ch] ~= token then return nil end
    if not restarted then return { reps = reps, div = div, target = target } end
  end
  return nil
end

function Burst:fire(ch, beat, freq, level, amp_shape, mod_shape, div, total, hit_idx,
                    ratio1, ratio2, ratio3, ratio4)
  local c = self.channels[ch]
  -- carrier + modulator envelope contours, resolved from their sequenced shape
  -- indices (drawn per burst in run_burst). Default to the channel defaults when
  -- called directly (tests / external callers).
  local amp_sh = Burst.shape(amp_shape or Burst.SHAPE_CARRIER_DEFAULT)
  local mod_sh = Burst.shape(mod_shape or Burst.SHAPE_MOD_DEFAULT)
  -- all four op ratios are sequenced and passed in (drawn per burst in run_burst).
  -- Default to unison when called directly (tests).
  ratio1 = ratio1 or 1; ratio2 = ratio2 or 1; ratio3 = ratio3 or 1; ratio4 = ratio4 or 1
  -- octave shift is applied per hit, not per burst: a single long burst never
  -- redraws freq mid-burst, so a burst-start shift would be inaudible across its
  -- hits. Shifting here also feeds the final freq to external outputs.
  freq = freq * (2 ^ c.octave)
  -- geodeMode is engine-wide (VOICE group), 0-based {transient,sustain,cycle};
  -- geode_mod wants 1/2/3, so +1 at the call site. The amp geode is always on (no
  -- 'off'). The amp shape's decay length (decMul) gates the geode's 0.7 build-up
  -- clamp (a longer decay overlaps more, like the old env decay_n did).
  local actual_level = Burst.burst_level_for_hit(level, self.geodeMode + 1, amp_sh[2], hit_idx, total)

  -- geo_freq stays at the target pitch (this voice has no pitch envelope).
  local geo_freq = freq

  -- FM ratios: all four are the sequenced (A+B) values drawn for this burst (op1 is
  -- the fundamental). The brightness proxy handed to external outputs is the largest
  -- ratio among this algo's active modulators (or op1's ratio for additive) — a
  -- stand-in for the old harm.
  local ratios = {ratio1, ratio2, ratio3, ratio4}
  local bright_ratio = 0
  for _, op in ipairs(ALGO_MODULATORS[c.algo] or {}) do
    if ratios[op] > bright_ratio then bright_ratio = ratios[op] end
  end
  if bright_ratio == 0 then bright_ratio = ratios[1] end  -- additive: no modulators

  -- per-hit timing, drives the amp-envelope decay maths below.
  local sec_per_beat = 60 / get_tempo()
  local interval_sec = (4 / div) * sec_per_beat

  -- amp decaySec from envMode (engine-wide; 1=burst-length, 2=per-hit).
  local decay_sec = nil
  if self.envMode ~= 0 then
    if self.envMode == 1 then
      decay_sec = total * interval_sec
    else
      decay_sec = interval_sec
    end
  end

  -- envelope contours from the two sequenced SHAPE indices, scaled to this hit's
  -- inter-hit slot. Two independent envelopes share this mapping: the CARRIER amp
  -- env (amp_sh) and the MODULATOR brightness env (mod_sh). Each shape is
  -- {atkMul, decMul, atkCurve, decCurve}:
  --   attack -> gap-RELATIVE (atkMul * gap), floored at 0.001 s so an 'instant'
  --             shape stays snappy; a swell/ramp shape fills more of the slot. This
  --             is the deliberate trade vs the old absolute attack: every shape now
  --             tracks the schedule (gap shrinks with tempo/density).
  --   decay  -> gap-RELATIVE (decMul * gap); dense/fast channels self-shorten so a
  --             6-voice mix stays legible. burst/hit envMode still override the
  --             decay timing to lock it to the grid -- applied to both envelopes.
  local gap_sec = interval_sec / math.max(0.01, c.rate)
  local function attack_time(mul) return math.max(0.001, gap_sec * mul) end
  local function decay_time(mul)
    if decay_sec ~= nil then return math.max(0.01, decay_sec) end
    return clamp(gap_sec * mul, 0.02, 3.0)
  end
  local attack  = attack_time(amp_sh[1])
  local amp_dec = decay_time(amp_sh[2])
  local mod_attack = attack_time(mod_sh[1])
  local mod_dec    = decay_time(mod_sh[2])
  -- per-segment Env curves. The carrier curves are scaled by the per-channel `ampPunch`
  -- MIX scalar (ampPunch/4 = 1.0 neutral, so the boot 'tail' shape's -4 stays -4),
  -- which reads as a per-channel "flatten <-> exaggerate the contour" control rather
  -- than a fixed perc curve. The modulator keeps the shape's own curves.
  local punch = c.ampPunch / 4
  local amp_atk_curve = amp_sh[3] * punch
  local amp_dec_curve = amp_sh[4] * punch
  local mod_atk_curve = mod_sh[3]
  local mod_dec_curve = mod_sh[4]

  -- output routing (lib/outputs.lua): non-audio destinations replace the
  -- internal voice; midi/crow get the same final freq/level/length it would
  -- have played. Hook lives here (not on emit) because the per-hit prob skip
  -- emits a 'fire' event for the playhead without sounding anything.
  -- per-channel static voice macros (MIX page) + the engine-wide drive macro.
  local mod_index = c.modIndex
  local feedback  = c.fmFeedback
  local pan       = c.pan or 0
  local drive     = self.drive
  -- per-channel static operator levels, passed straight to the voice.
  local ol = {c.opLevel1, c.opLevel2, c.opLevel3, c.opLevel4}
  local out = self.outputs
  if engine and engine.trig and ((not out) or out:wants_audio(ch)) then
    -- 4-op FM (lib/Engine_Potionshop.sc): the per-channel algorithm selects the
    -- operator routing; r2/r3/r4 are the per-burst sequenced op2/3/4 ratios; the
    -- carrier/modulator envelopes come from the two sequenced SHAPE indices,
    -- resolved above to times (args 8/9 carrier, 11/19 modulator) + per-segment
    -- curves (arg 10 amp-decay, 21 amp-attack, 22 mod-attack, 23 mod-decay).
    -- ol[1..4] are this channel's static operator levels, geode-shaped per hit
    -- above. ratio1 (op1's per-burst sequenced fundamental) rides as r1 (arg 20).
    -- New curve args are appended (21..23) so the older positional args keep theirs;
    -- pan (24) is appended for the same reason.
    engine.trig(geo_freq, actual_level, c.algo,
                ratio2, ratio3, ratio4, mod_index,
                attack, amp_dec, amp_dec_curve, mod_dec, feedback, drive, ch,
                ol[1], ol[2], ol[3], ol[4], mod_attack, ratio1,
                amp_atk_curve, mod_atk_curve, mod_dec_curve, pan)
  end
  if out then
    -- external voices can't render FM timbre; hand them the channel's brightness
    -- proxy (largest active modulator ratio, used by the ER-301 brightness CV) plus
    -- the raw op1/op2 ratios, which the MIDI path sends as modwheel/breath CCs.
    out:note(ch, { freq = geo_freq, level = actual_level, harm = bright_ratio,
                   op1 = ratio1, op2 = ratio2, dur = attack + amp_dec })
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
  -- envelope shapes: a SINGLE random shape index per envelope (held for the whole
  -- pattern, not stepped) -- a stable per-channel timbre rather than a morphing one.
  -- Drawn only from the instant-attack family (1..SHAPE_PERC_COUNT) so a randomized
  -- channel stays punchy; the slow-attack swells/pads stay deliberate, hand-picked
  -- choices. Indices are inherently grid-reachable (a subset of the picker range).
  c.ampShape = seqx.new{math.random(1, SHAPE_PERC_COUNT)}
  c.modShape = seqx.new{math.random(1, SHAPE_PERC_COUNT)}
  -- op2/3/4 FM ratios ARE scrambled (timbral variety): each gets a SINGLE random A
  -- value drawn from its ROLE set under this channel's algo — CARRIER_RATIOS if the op
  -- is a carrier, else MODULATOR_RATIOS (held, not stepped, like the shapes above; the
  -- picker can still highlight/edit it; the reachability test asserts it). The B
  -- (offset) layer is left intact, like noteB. op1 is ALSO sequenced now, but randomize
  -- leaves it alone (A stays at the 1.0 anchor) so a randomized channel keeps a
  -- fundamental and stays pitched — op1 is a carrier in every algo (mutate likewise).
  c.opRatio2 = seqx.new{pick(op_ratio_set(c.algo, 2))}
  c.opRatio3 = seqx.new{pick(op_ratio_set(c.algo, 3))}
  c.opRatio4 = seqx.new{pick(op_ratio_set(c.algo, 4))}
  -- The engine-wide modes (envMode/geodeMode) and per-op LEVELS are
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
  -- nudge each shape index to a neighbouring shape (stays grid-exact in 1..#SHAPES).
  local function nudge_shape(v) return clamp(round(v + jitter(amount * 4)), 1, #SHAPES) end
  c.ampShape = map(c.ampShape, nudge_shape)
  c.modShape = map(c.modShape, nudge_shape)
  -- nudge each sequenced op ratio A step to a neighbouring value within its ROLE set
  -- (carrier vs modulator, per the channel's algo) so it stays grid-exact and in
  -- family; the B offset lane is left untouched. op2/3/4 are nudged; op1 stays at its
  -- anchor (see randomize). If a value is orphaned (algo changed its role), we snap
  -- from the nearest entry in the new set first.
  local function nearest_idx(set, v)
    local bi, bd = 1, math.huge
    for i, r in ipairs(set) do local d = math.abs(r - v); if d < bd then bd = d; bi = i end end
    return bi
  end
  local function nudge_ratio_in(set)
    return function(v)
      local idx = nearest_idx(set, v)
      return set[clamp(idx + (jitter(amount) > 0 and 1 or -1), 1, #set)]
    end
  end
  c.opRatio2 = map(c.opRatio2, nudge_ratio_in(op_ratio_set(c.algo, 2)))
  c.opRatio3 = map(c.opRatio3, nudge_ratio_in(op_ratio_set(c.algo, 3)))
  c.opRatio4 = map(c.opRatio4, nudge_ratio_in(op_ratio_set(c.algo, 4)))
end

return Burst
