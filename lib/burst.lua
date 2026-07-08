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
local chords   = require 'chords'
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
-- Each role set holds 64 ascending values, sorted LOW -> HIGH and biased to the low
-- end. The op-ratio A grid picker (two rows) exposes only the LOWER 32 (~the
-- sub-octave..+1-octave region); the upper 32 (higher ratios / octave-ups) are reached
-- by ADDING the B index-offset lane, which walks UP the op's ROLE SET (op_ratio below)
-- -- exactly mirroring the env-shape A/B model. So the directly-pickable range leans
-- low, and randomize draws only from the lower 32 (RATIO_PICKER_COUNT). Mirrored by
-- GridUI.CARRIER_RATIOS / MODULATOR_RATIOS / RATIO_VALUES -- keep in sync.
--
-- CARRIER set: 5-limit just ratios (every value factors into 2*3*5 num & denom). Lower
-- 32 span 0.25..2.0 (dense), upper 32 span 2.0..8.0.
local CARRIER_RATIOS = {
  -- lower 32 (A picker, 0.25 .. 2.0):
  0.25, 0.2667, 0.2778, 0.3, 0.3125, 0.3333, 0.375, 0.4,
  0.4167, 0.4444, 0.5, 0.5333, 0.5556, 0.6, 0.625, 0.6667,
  0.75, 0.8, 0.8333, 0.8889, 0.9, 1.0, 1.1111, 1.125,
  1.2, 1.25, 1.3333, 1.5, 1.6, 1.6667, 1.8, 2.0,
  -- upper 32 (B-offset reach, 2.0 .. 8.0):
  2.0833, 2.2222, 2.25, 2.4, 2.5, 2.6667, 2.7, 2.7778,
  3.0, 3.125, 3.2, 3.3333, 3.375, 3.5556, 3.6, 3.75,
  4.0, 4.1667, 4.4444, 4.5, 4.8, 5.0, 5.3333, 5.4,
  6.0, 6.25, 6.4, 6.6667, 6.75, 7.2, 7.5, 8.0,
}
Burst.CARRIER_RATIOS = CARRIER_RATIOS
-- MODULATOR set: harmonic integers (-> harmonic sidebands) + a few unit divisions
-- (subharmonic warmth) + simple fractions. Lower 32 span 0.25..6.0 and INCLUDE the
-- bright harmonic integers 1..6, so the default / randomized FM is bright rather than
-- dark; upper 32 span 6.25..16 (high & inharmonic harmonics, B-offset reach). (The
-- deep subharmonics that made the default dark were dropped.)
local MODULATOR_RATIOS = {
  -- lower 32 (A picker, 0.25 .. 6.0 -- integers 1..6 + simple fractions):
  0.25, 0.3333, 0.4, 0.5, 0.6, 0.6667, 0.75, 0.8,
  0.8333, 1.0, 1.2, 1.25, 1.3333, 1.4, 1.5, 1.6667,
  1.75, 2.0, 2.25, 2.3333, 2.5, 2.6667, 3.0, 3.3333,
  3.5, 3.6667, 4.0, 4.3333, 4.5, 5.0, 5.5, 6.0,
  -- upper 32 (B-offset reach, 6.25 .. 16 -- high / inharmonic harmonics):
  6.25, 6.3333, 6.5, 6.6667, 7.0, 7.3333, 7.5, 7.6667,
  8.0, 8.3333, 8.5, 8.6667, 9.0, 9.3333, 9.5, 9.6667,
  10.0, 10.3333, 10.5, 10.6667, 11.0, 11.3333, 11.5, 12.0,
  12.5, 13.0, 13.5, 14.0, 14.5, 15.0, 15.5, 16.0,
}
Burst.MODULATOR_RATIOS = MODULATOR_RATIOS
-- Size of the op-ratio A picker = the lower half of each role set (mirrors the
-- env-shape SHAPE_PICKER_COUNT). The A grid shows / randomize draws from set[1..32];
-- the upper 32 are B-offset reach only.
local RATIO_PICKER_COUNT = 32
Burst.RATIO_PICKER_COUNT = RATIO_PICKER_COUNT
-- The full curated set = union of both, sorted ascending + de-duplicated. This is the
-- STABLE index space that params store A values against (both role sets are subsets, so
-- every value stays addressable). NOTE: the B (index-offset) lane no longer walks this
-- union -- it walks the op's ROLE SET (see op_ratio). Mirrors GridUI.RATIO_VALUES — keep in sync.
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

-- nearest 1-based index of v in an ascending list (exact when v is a list member).
local function nearest_in(list, v)
  local best, bd = 1, math.huge
  for i, x in ipairs(list) do local d = math.abs(x - v); if d < bd then bd = d; best = i end end
  return best
end
-- Resolve a sequenced op ratio: A is a curated ratio value, `off` is the B integer
-- index offset that walks UP a sorted ratio `list` (clamped to its ends). `list`
-- defaults to the full union (RATIO_VALUES) but run_burst passes the op's ROLE SET
-- (CARRIER_RATIOS / MODULATOR_RATIOS), so B walks WITHIN the op's role -- this is the
-- only route from the low A-picker range into the upper-32 (higher) ratios, mirroring
-- op_env. The result is always a real list entry, never an off-grid sum.
local function op_ratio(a, off, list)
  list = list or RATIO_VALUES
  local pos = (list == RATIO_VALUES) and ratio_pos(a) or nearest_in(list, a)
  local idx = pos + math.floor((off or 0) + 0.5)
  return list[math.max(1, math.min(#list, idx))]
end
Burst.op_ratio = op_ratio

-- Resolve a sequenced per-operator envelope shape: A is a 1-based shape index, `off`
-- is the B integer index offset that walks UP the SHAPES table (clamped to its ends).
-- Mirrors op_ratio, but A is already an index (shapes have no value/index split), so
-- this is a plain clamped add. Defined after SHAPES below via the forward upvalue.
local op_env  -- forward-declared; body assigned once #SHAPES is known (see below)

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
-- DEFAULTS: carrier = SHAPE_CARRIER_DEFAULT ('plop', a round mid contour sitting at
-- the MIDPOINT (#16) of the short A picker so there is equal shorter/longer headroom),
-- modulator = SHAPE_MOD_DEFAULT ('chip', ~0.65x the carrier so the FM brightness env
-- reads as a tighter bright attack). Mirrored by
-- name + count in lib/grid_ui.lua (GridUI.SHAPE_NAMES) -- keep the two in sync. (The
-- SC engine never sees a shape: fire() resolves the index to times + curves.)
--
-- SORTED SHORTEST -> LONGEST by TOTAL length (atkMul + decMul), spanning L 0.10 .. 0.85
-- (a deliberately focused range -- no sub-0.10 micro-clicks, no multi-second drones;
-- the long 49..64 contours keep their swell/tail SHAPE but are length-capped at 0.85).
-- The A lane's grid/screen picker exposes ONLY the first 32 (GridUI.SHAPE_PICKER_COUNT;
-- the picker is two grid rows), the shorter half, so the default palette leans short.
-- The upper 32 (the longer half) are reachable ONLY by ADDING the B index-offset lane
-- onto an A pick (op_env clamps a+off into 1..#SHAPES) -- so B EXTENDS a short A pick
-- toward longer tails. Because the table is length-ordered the LED/screen brightness
-- ramp now reads as a short -> long gradient. Every entry is a single attack-decay
-- contour -- deliberately NO ratchets / LFO-style cycling, which would fight the
-- engine's own rhythm; the variety is in length + the per-segment curve family
-- (exp / linear / log).
local SHAPES = {
  -- {atkMul, decMul, atkCurve, decCurve, name}   -- sorted by total length; L 0.10 .. 0.85
  -- A-PICKER bank (1..32): the shorter half (carrier default 'plop' at #16, the midpoint):
  {0.00, 0.10, -8, -8, 'tick'},  -- 1
  {0.00, 0.11, -6, -8, 'dust'},  -- 2
  {0.00, 0.11, -8, -6, 'tock'},  -- 3
  {0.00, 0.12, -4, -4, 'clip'},  -- 4
  {0.00, 0.13, -8, -4, 'prick'},  -- 5
  {0.00, 0.13, -6, -8, 'chip'},  -- 6
  {0.00, 0.14, -4, -6, 'grain'},  -- 7
  {0.00, 0.15, -8, 0, 'dit'},  -- 8
  {0.02, 0.13, -8, -6, 'spike'},  -- 9
  {0.00, 0.16, -6, -4, 'tic'},  -- 10
  {0.00, 0.17, -8, -6, 'nip'},  -- 11
  {0.00, 0.17, -8, -8, 'blip'},  -- 12
  {0.00, 0.18, -8, -2, 'nick'},  -- 13
  {0.00, 0.19, -6, -8, 'plip'},  -- 14
  {0.00, 0.19, -8, -8, 'click'},  -- 15
  {0.00, 0.20, -4, -4, 'plop'},  -- 16
  {0.00, 0.21, -2, -8, 'ping'},  -- 17
  {0.00, 0.23, 0, -8, 'dot'},  -- 18
  {0.05, 0.19, -6, -8, 'spit'},  -- 19
  {0.00, 0.25, -4, -8, 'rim'},  -- 20
  {0.00, 0.27, -8, -8, 'knock'},  -- 21
  {0.05, 0.23, -8, -8, 'flick'},  -- 22
  {0.00, 0.29, -2, -6, 'clave'},  -- 23
  {0.00, 0.31, -4, -6, 'dink'},  -- 24
  {0.09, 0.23, -8, -8, 'dab'},  -- 25
  {0.00, 0.34, -6, -4, 'clap'},  -- 26
  {0.07, 0.28, -6, -6, 'zip'},  -- 27
  {0.00, 0.36, -6, -6, 'jab'},  -- 28
  {0.05, 0.33, -4, -4, 'poke'},  -- 29
  {0.00, 0.39, -8, -8, 'snap'},  -- 30
  {0.00, 0.40, -4, -8, 'zap'},  -- 31
  {0.00, 0.42, -2, -6, 'tink'},  -- 32
  -- B-REACH bank (33..64): the longer half (reached by the B index-offset lane):
  {0.00, 0.43, -2, -8, 'ting'},  -- 33
  {0.00, 0.44, -6, -6, 'bop'},  -- 34
  {0.00, 0.46, -4, -4, 'tap'},  -- 35
  {0.00, 0.47, -2, -2, 'pip'},  -- 36
  {0.00, 0.48, -2, -8, 'pop'},  -- 37
  {0.00, 0.50, -4, -4, 'pluck'},  -- 38
  {0.00, 0.51, -6, -6, 'drum'},  -- 39
  {0.08, 0.44, -2, -2, 'soft'},  -- 40
  {0.12, 0.41, -1, -2, 'round'},  -- 41
  {0.17, 0.38, 2, -3, 'puff'},  -- 42
  {0.00, 0.57, -4, -4, 'body'},  -- 43
  {0.33, 0.25, -4, -4, 'ramp'},  -- 44
  {0.00, 0.59, -4, -8, 'exp'},  -- 45
  {0.00, 0.61, -4, 4, 'log'},  -- 46
  {0.04, 0.58, 0, 0, 'lin'},  -- 47
  {0.22, 0.41, 4, -4, 'swell'},  -- 48
  {0.25, 0.40, 4, 4, 'arc'},  -- 49
  {0.00, 0.66, -1, 8, 'glass'},  -- 50
  {0.64, 0.03, 0, -8, 'revrs'},  -- 51
  {0.00, 0.69, -4, -4, 'tail'},  -- 52
  {0.64, 0.06, 3, -2, 'rise'},  -- 53
  {0.37, 0.34, -2, -2, 'pad'},  -- 54
  {0.49, 0.23, -3, -3, 'wedge'},  -- 55
  {0.25, 0.49, 6, -4, 'bloom'},  -- 56
  {0.00, 0.76, -2, -6, 'bell'},  -- 57
  {0.36, 0.41, 2, -2, 'bow'},  -- 58
  {0.13, 0.66, 3, -5, 'surge'},  -- 59
  {0.00, 0.80, -4, -3, 'long'},  -- 60
  {0.07, 0.74, 0, -2, 'fade'},  -- 61
  {0.00, 0.82, 0, -8, 'hold'},  -- 62
  {0.21, 0.63, 5, -4, 'huge'},  -- 63
  {0.00, 0.85, -1, -2, 'drone'},  -- 64
}
Burst.SHAPES = SHAPES
Burst.SHAPE_CARRIER_DEFAULT = 16  -- 'plop'  (round mid contour at the midpoint of the A picker)
Burst.SHAPE_MOD_DEFAULT     = 6   -- 'chip'  (~0.65x the carrier: tighter bright attack)
-- Size of the A-PICKER bank = the first (shortest) half of the length-sorted table
-- (mirrors GridUI.SHAPE_PICKER_COUNT, the picker's two grid rows). init + randomize
-- draw env shapes from this range (1..SHAPE_PICKER_COUNT), so a scrambled channel
-- stays short/tight -- the whole upper half (the longer swells/pads/tails) stays a
-- deliberate, hand-picked B-offset reach. Indices here are inherently grid-reachable.
local SHAPE_PICKER_COUNT = math.min(32, #SHAPES)
Burst.SHAPE_PICKER_COUNT = SHAPE_PICKER_COUNT
-- randomize draws env shapes from SHAPE_RANDOMIZE_MIN..SHAPE_PICKER_COUNT (the upper
-- part of the short bank) -- skips the tiniest clicks for a bit more body.
local SHAPE_RANDOMIZE_MIN = 16
Burst.SHAPE_RANDOMIZE_MIN = SHAPE_RANDOMIZE_MIN

-- Resolve a 1-based shape index to its contour entry (clamped to the table).
function Burst.shape(i)
  i = math.floor((i or 1) + 0.5)
  if i < 1 then i = 1 elseif i > #SHAPES then i = #SHAPES end
  return SHAPES[i]
end

-- op_env body (forward-declared above): A shape index + B index offset, clamped to
-- the SHAPES table. The mirror of op_ratio for per-operator envelope sequences.
op_env = function(a, off)
  local idx = math.floor((a or 1) + 0.5) + math.floor((off or 0) + 0.5)
  return math.max(1, math.min(#SHAPES, idx))
end
Burst.op_env = op_env

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
    -- PER-OPERATOR envelope SHAPES, sequenced like the op ratios. opEnv1..4 each
    -- give operator K its own EG (DX-style): a carrier's env shapes its amplitude,
    -- a modulator's env shapes the FM depth/brightness it imparts (SC multiplies oK
    -- by its env). Each is a 1-based index into Burst.SHAPES with an A value lane +
    -- a B index-offset lane (opEnvKB) that walks UP the table, exactly like
    -- opRatioK. Resolved per hit in fire() to attack/decay times (scaled to the
    -- inter-hit gap) + per-segment curves. Replaced the old ampShape|modShape pair.
    -- op1 defaults to the carrier contour, op2..4 to the modulator contour (their
    -- usual roles), but every op env is fully editable + A/B sequenced.
    opEnv1 = seqx.new{Burst.SHAPE_CARRIER_DEFAULT},
    opEnv2 = seqx.new{Burst.SHAPE_MOD_DEFAULT},
    opEnv3 = seqx.new{Burst.SHAPE_MOD_DEFAULT},
    opEnv4 = seqx.new{Burst.SHAPE_MOD_DEFAULT},
    opEnv1B = seqx.new{0}, opEnv2B = seqx.new{0}, opEnv3B = seqx.new{0}, opEnv4B = seqx.new{0},
    -- div/reps have no B layer; note + the op ratios + the op envelopes each keep one.
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
    -- grid page / sequence): FM mod index (1..32, brightness depth), FM feedback
    -- (0..4 rad, modulator self-feedback) and FM algo (1..32, DX-style operator routing,
    -- MIX col 15). Like level/opLevel they're exempt from randomize/mutate and survive
    -- clear/copy/paste. Drawn straight at fire time.
    modIndex = 2, fmFeedback = 0, algo = 1,
    -- per-channel STATIC stereo pan (MIX page): -1 = hard left, 0 = centre,
    -- +1 = hard right. Like the other MIX scalars it's exempt from randomize/mutate
    -- and survives clear/copy/paste. Drawn straight at fire time (SC Pan2).
    pan = 0,
    -- per-channel DJ-style multimode filter (MIX page, col 13): one bipolar knob,
    -- -1 = low-pass closed, 0 = no filter (both sections open), +1 = high-pass
    -- fully up. Unlike the other MIX scalars it lives on a PERSISTENT SC strip
    -- synth (PotionChannel), so edits are PUSHED via Burst:push_filter instead of
    -- riding each trig. Travels with copy/paste and is exempt from
    -- randomize/mutate, like the rest of the MIX scalars. (A follower
    -- subscription — followSrc/followDepth sidechaining another channel's
    -- envelope onto this knob — lived here briefly; it never sounded right and
    -- was removed.)
    filterPos = 0,
    burstProb = 1,
    probHit = false,
    resetInterval = 0,
    rate = 1,
    quantize = 16,  -- per-channel event snap grid (events per whole note), from QUANTIZE_VALUES
    -- per-channel amp dynamics (PRISM page): envMode = amp-decay timing (0=shape
    -- 1=burst 2=hit), geodeMode = per-hit amp geode contour (0=transient 1=sustain
    -- 2=cycle, default sustain; the geode is always on). Both were engine-wide VOICE
    -- macros; now per channel, edited on the PRISM page alongside quantize.
    envMode = 0,
    geodeMode = 1,
    -- per-channel tonic transposition (ROOT page), signed semitones -12..+11
    -- (0 = base tonic C1, no transpose). Spans the two-octave root keyboard; sums with
    -- `octave` below at fire time and composes with the GLOBAL harmonic root
    -- (self.root) as a tonic shift. The mode/harmonic context is global.
    root = 0,
    octave = 0,     -- -2..2, whole-octave pitch shift (perf page)
    altTrig = 0,    -- alt(B) note layering: 0=hold (add&hold) 1=step (per-hit)
    -- op-ratio sequence trig mode (prob page): ONE switch for all four ops.
    -- 0=hold (each ratio is drawn once per burst, held for every hit) 1=step
    -- (advance every opRatioN B index lane per hit, so the ratios arpeggiate
    -- within a burst). Mirrors altTrig for the note B. (Was four per-op fields
    -- opRatio1..4Trig; collapsed — they were always flipped together.)
    opSeqTrig = 0,
    -- op-envelope sequence trig mode (prob page): ONE switch for all four op
    -- envs. 0=hold (each env shape is drawn once per burst) 1=step (advance
    -- every opEnvN B index-offset lane per hit, re-resolved against the held A,
    -- so the envelope shapes arpeggiate within a burst). Identical mechanism to
    -- opSeqTrig (walks B). (Was four per-op fields opEnv1..4Trig; collapsed.)
    opEnvTrig = 0,
    -- chord-tone role: 0 = free (pitch from the note lane, today's behavior);
    -- 1..4 = Root/3rd/5th/7th of the global harmonic context (chords.ROLE_NAMES).
    -- While a role is active the note lane is unused but keeps advancing, so
    -- flipping back to free resumes the melody where it would be. The per-channel
    -- `root` above still applies as an additional tonic transpose either way.
    role = 0,
  }
end

function Burst.new()
  local self = setmetatable({}, Burst)
  self.launchGrid = 4   -- launches snap to the next quarter-note boundary
  -- (event snap grid is per-channel now: channels[ch].quantize, from QUANTIZE_VALUES)
  -- Harmonic context (harmonàig model, lib/chords.lua): mode + root place the
  -- scale; degree/quality/inversion/voicing resolve the four-tone chord that
  -- role channels (channels[ch].role > 0) draw their pitch from. Free channels
  -- only use mode + root (their note lanes index mode degrees). The modal system
  -- REPLACES the old global scale mask (scales.by_name) — modes live in chords.lua.
  -- self.root is the GLOBAL harmonic root; each channel's c.root adds on top.
  self.mode = 1         -- index into chords.MODES (1 = ionian)
  self.root = 0         -- global tonic transposition in semitones (0..11; 0 = C)
  self.degree = 1       -- chord degree I..VII
  self.diatonic = true  -- quality derived from mode+degree (vs manual pick)
  self.quality = 6      -- manual quality index (maj7), used when diatonic = false
  self.inversion = 0    -- 0..3 = root/1st/2nd/3rd
  self.voicing = 1      -- 1..4 = close/drop2/drop3/spread
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
  -- (env mode + geode were engine-wide VOICE macros; they are now per-channel PRISM
  -- scalars — see default_channel. FM algorithm, mod index and FM feedback likewise
  -- moved to per-channel static MIX-page scalars. FM
  -- body length
  -- is no longer a macro either: the per-channel per-op envelope sequences (opEnv1..4)
  -- own each operator's contour; the old self.fmDecay was retired.)
  -- per-operator output levels are NOT global anymore: each channel sequences its
  -- own op1..op4 (A/B) sequins (see default_channel), drawn per burst in run_burst.
  self.outputs = nil    -- optional lib/outputs.lua router (set by the host)
  return self
end

-- Kept for call-site compatibility; the clock model needs no setup.
function Burst:setup() end

-- ---- harmonic context ----------------------------------------------------

function Burst:mode_intervals()
  return chords.MODES[self.mode].intervals
end

function Burst:chord_ctx()
  return { intervals = self:mode_intervals(), root = self.root,
           degree = self.degree, diatonic = self.diatonic,
           quality = self.quality, inversion = self.inversion,
           voicing = self.voicing }
end

-- Chord-tone role (1..4 = R/3/5/7) -> Hz, pre-octave (fire applies 2^c.octave).
-- `root` is the channel's additional tonic transpose (c.root), layered on the
-- global harmonic root already baked into the chord tones (self.root, via ctx).
function Burst:chord_freq(role, root)
  -- chords.CHORD_OCTAVE lifts the C1-anchored chord tones into a mid register
  -- (see chords.lua). Kept out of chord_tones so the pure-math contract holds.
  local tone = chords.chord_tones(self:chord_ctx())[role] + 12 * chords.CHORD_OCTAVE
  return scales.semitone_to_freq(tone, root)
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

-- ---- channel-strip push (filter) ----------------------------------------

-- Push a channel's filter position to the SC engine's persistent PotionChannel
-- strip. It's the one scalar that can't ride trig (the strip outlives every
-- voice), so every edit path lands here: GridUI:set_scalar forwards the filter
-- field, and the param action calls it directly — which also replays boot/PSET
-- state onto the synths at params:bang. Guarded on the global norns `engine`
-- exactly like fire(), so the off-hardware tests (no engine global) pass
-- through silently. ch is 1-based.
function Burst:push_filter(ch)
  local c = self.channels[ch]
  if not c then return end
  if engine and engine.filter then
    engine.filter(ch, c.filterPos or 0)
  end
end

-- ---- sequins reset -----------------------------------------------------

function Burst:reset_channel(ch)
  local c = self.channels[ch]
  for _, k in ipairs{'div','reps','note',                          -- timing + pitch (A)
                     'opEnv1','opEnv2','opEnv3','opEnv4',          -- per-op envelope shapes (A)
                     'opRatio1','opRatio2','opRatio3','opRatio4',  -- sequenced op ratios (A)
                     'noteB',                                      -- note keeps a B layer
                     'opEnv1B','opEnv2B','opEnv3B','opEnv4B',      -- op envelopes keep a B layer
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
    -- sequenced op1/2/3/4 FM ratios: A = base ratio (lower-32 grid range), B = integer
    -- index offset that walks UP the op's ROLE SET (the only route into the upper-32
    -- higher ratios). A is the per-burst value (drawn once, held for every hit, like the
    -- note A degree); B is its offset. Kept separate so the step trig mode below can
    -- advance B per hit while A stays held. Drawn above the rest/skip checks so the
    -- sequins advance on every burst step. op1 is the fundamental (A defaults to 1.0).
    -- A live edit applies at the next burst (not identity-checked, like level).
    -- Role set per op (carrier vs modulator under this channel's algo) = the list B walks.
    local rset1 = op_ratio_set(c.algo, 1)
    local rset2 = op_ratio_set(c.algo, 2)
    local rset3 = op_ratio_set(c.algo, 3)
    local rset4 = op_ratio_set(c.algo, 4)
    local ratio1A, ratio1B = c.opRatio1(), c.opRatio1B()
    local ratio2A, ratio2B = c.opRatio2(), c.opRatio2B()
    local ratio3A, ratio3B = c.opRatio3(), c.opRatio3B()
    local ratio4A, ratio4B = c.opRatio4(), c.opRatio4B()
    local ratio1 = op_ratio(ratio1A, ratio1B, rset1)
    local ratio2 = op_ratio(ratio2A, ratio2B, rset2)
    local ratio3 = op_ratio(ratio3A, ratio3B, rset3)
    local ratio4 = op_ratio(ratio4A, ratio4B, rset4)
    -- per-operator envelope shapes: A = shape index, B = integer index offset that
    -- walks UP the SHAPES table (mirrors the op ratios). Drawn once per burst (held
    -- for every hit) unless the per-op env trig mode is 'step', which advances that
    -- op's B lane per hit in the loop below so the shape arpeggiates within the burst.
    local env1A, env1B = c.opEnv1(), c.opEnv1B()
    local env2A, env2B = c.opEnv2(), c.opEnv2B()
    local env3A, env3B = c.opEnv3(), c.opEnv3B()
    local env4A, env4B = c.opEnv4(), c.opEnv4B()
    local env1 = op_env(env1A, env1B)
    local env2 = op_env(env2A, env2B)
    local env3 = op_env(env3A, env3B)
    local env4 = op_env(env4A, env4B)
    -- Role channels take their pitch from the harmonic context's chord tone; the
    -- note lane was still drawn above so it keeps advancing. Free channels index
    -- mode degrees. self.root (global harmonic root) + c.root (per-channel
    -- transpose) compose as tonic shifts under the active tuning.
    local freq
    if c.role > 0 then
      freq = self:chord_freq(c.role, c.root)
    else
      freq = scales.degree_to_freq(degreeA + degreeB, self:mode_intervals(), self.root + c.root)
    end

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

      -- ROLE CHANNELS re-resolve the chord tone EVERY hit: a degree/quality/
      -- mode/inversion/voicing edit re-harmonizes on the very next hit even
      -- mid-burst (harmonàig behavior), with no extra plumbing. Deliberately
      -- an elseif: a role channel does not advance noteB per hit — its lane
      -- data stays untouched-and-unused while the role is active.
      --
      -- ALT-TRIG STEP MODE (free channels): when c.altTrig == 1 the alt (B)
      -- pitch layer arpeggiates — advance the captured B note sequins per hit
      -- and re-sum with the held degreeA. i == 0 already consumed the
      -- burst-start draw. Advancing here (above the probHit skip) keeps the
      -- arpeggio locked to the beat grid: a skipped hit still consumes a B value.
      if c.role > 0 then
        freq = self:chord_freq(c.role, c.root)
      elseif c.altTrig == 1 and i > 0 then
        degreeB = note_seqB()
        freq = scales.degree_to_freq(degreeA + degreeB, self:mode_intervals(), self.root + c.root)
      end

      -- OP-RATIO STEP MODE: when opSeqTrig == 1 every op's B (offset) lane
      -- advances per hit and re-resolves against its held A, so the indices walk
      -- through neighbouring ratios within the burst (A stays the per-burst base —
      -- exactly like the note alt-trig above). Same placement/rationale: above the
      -- probHit skip and i > 0, so a skipped hit still consumes a B value.
      if i > 0 and c.opSeqTrig == 1 then
        ratio1 = op_ratio(ratio1A, c.opRatio1B(), rset1)
        ratio2 = op_ratio(ratio2A, c.opRatio2B(), rset2)
        ratio3 = op_ratio(ratio3A, c.opRatio3B(), rset3)
        ratio4 = op_ratio(ratio4A, c.opRatio4B(), rset4)
      end

      -- OP-ENV STEP MODE: when opEnvTrig == 1 every op env's B (offset) lane
      -- advances per hit and re-resolves against its held A, so the envelope
      -- shapes walk through neighbouring contours within the burst (A stays the
      -- per-burst base). Identical to the op-ratio step above; same i > 0 /
      -- skip-still-advances rule.
      if i > 0 and c.opEnvTrig == 1 then
        env1 = op_env(env1A, c.opEnv1B())
        env2 = op_env(env2A, c.opEnv2B())
        env3 = op_env(env3A, c.opEnv3B())
        env4 = op_env(env4A, c.opEnv4B())
      end

      if c.probHit and math.random() > c.burstProb then
        -- per-hit skip: advance the playhead but don't trigger a voice.
        self:emit{ type = 'fire', ch = ch, beat = target,
                   freq = freq, level = level }
      else
        self:fire(ch, target, freq, level, env1, env2, env3, env4, div, total, i,
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

function Burst:fire(ch, beat, freq, level, env1, env2, env3, env4, div, total, hit_idx,
                    ratio1, ratio2, ratio3, ratio4)
  local c = self.channels[ch]
  -- per-operator envelope contours, resolved from their sequenced shape indices
  -- (drawn per burst in run_burst). Default to the channel defaults when called
  -- directly (tests / external callers): op1 = carrier contour, op2..4 = modulator.
  local sh1 = Burst.shape(env1 or Burst.SHAPE_CARRIER_DEFAULT)
  local sh2 = Burst.shape(env2 or Burst.SHAPE_MOD_DEFAULT)
  local sh3 = Burst.shape(env3 or Burst.SHAPE_MOD_DEFAULT)
  local sh4 = Burst.shape(env4 or Burst.SHAPE_MOD_DEFAULT)
  -- all four op ratios are sequenced and passed in (drawn per burst in run_burst).
  -- Default to unison when called directly (tests).
  ratio1 = ratio1 or 1; ratio2 = ratio2 or 1; ratio3 = ratio3 or 1; ratio4 = ratio4 or 1
  -- octave shift is applied per hit, not per burst: a single long burst never
  -- redraws freq mid-burst, so a burst-start shift would be inaudible across its
  -- hits. Shifting here also feeds the final freq to external outputs.
  freq = freq * (2 ^ c.octave)
  -- geodeMode is per-channel (PRISM page), 0-based {transient,sustain,cycle};
  -- geode_mod wants 1/2/3, so +1 at the call site. The amp geode is always on (no
  -- 'off'). op1's env decay length (decMul) gates the geode's 0.7 build-up clamp
  -- (op1 is the anchor carrier; a longer decay overlaps more, like the old amp env).
  local actual_level = Burst.burst_level_for_hit(level, c.geodeMode + 1, sh1[2], hit_idx, total)

  -- geo_freq stays at the target pitch (this voice has no pitch envelope).
  local geo_freq = freq

  -- FM ratios: all four are the sequenced (A+B) values drawn for this burst (op1 is the
  -- fundamental). They are handed to external outputs per op (MIDI CC / ER-301 CV
  -- ceilings); there is no longer an aggregate brightness proxy.

  -- per-hit timing, drives the amp-envelope decay maths below.
  local sec_per_beat = 60 / get_tempo()
  local interval_sec = (4 / div) * sec_per_beat

  -- amp decaySec from envMode (per-channel; 1=burst-length, 2=per-hit).
  local decay_sec = nil
  if c.envMode ~= 0 then
    if c.envMode == 1 then
      decay_sec = total * interval_sec
    else
      decay_sec = interval_sec
    end
  end

  -- envelope contours from the FOUR sequenced per-op SHAPE indices, scaled to this
  -- hit's inter-hit slot. Each op K gets its own EG from shape {atkMul, decMul,
  -- atkCurve, decCurve}:
  --   attack -> gap-RELATIVE (atkMul * gap), floored at 0.001 s so an 'instant'
  --             shape stays snappy; a swell/ramp shape fills more of the slot. This
  --             is the deliberate trade vs the old absolute attack: every shape now
  --             tracks the schedule (gap shrinks with tempo/density).
  --   decay  -> gap-RELATIVE (decMul * gap); dense/fast channels self-shorten so a
  --             6-voice mix stays legible. burst/hit envMode (per channel) still override the
  --             decay timing to lock it to the grid -- applied to every op env.
  local gap_sec = interval_sec / math.max(0.01, c.rate)
  local function attack_time(mul) return math.max(0.001, gap_sec * mul) end
  local function decay_time(mul)
    if decay_sec ~= nil then return math.max(0.01, decay_sec) end
    return clamp(gap_sec * mul, 0.02, 3.0)
  end
  -- {atk, dec, atkCurve, decCurve} per op, in op order, for the trig call.
  local function env_args(sh)
    return attack_time(sh[1]), decay_time(sh[2]), sh[3], sh[4]
  end
  local atk1, dec1, atkC1, decC1 = env_args(sh1)
  local atk2, dec2, atkC2, decC2 = env_args(sh2)
  local atk3, dec3, atkC3, decC3 = env_args(sh3)
  local atk4, dec4, atkC4, decC4 = env_args(sh4)

  -- output routing (lib/outputs.lua): non-audio destinations replace the
  -- internal voice; midi/crow get the same final freq/level/length it would
  -- have played. Hook lives here (not on emit) because the per-hit prob skip
  -- emits a 'fire' event for the playhead without sounding anything.
  -- per-channel static voice macros (MIX page).
  local mod_index = c.modIndex
  local feedback  = c.fmFeedback
  local pan       = c.pan or 0
  -- per-channel static operator levels, passed straight to the voice.
  local ol = {c.opLevel1, c.opLevel2, c.opLevel3, c.opLevel4}
  local out = self.outputs
  if engine and engine.trig and ((not out) or out:wants_audio(ch)) then
    -- 4-op FM (lib/Engine_Potionshop.sc): the per-channel algorithm selects the
    -- operator routing; r2/r3/r4 are the per-burst sequenced op2/3/4 ratios, r1 (op1)
    -- rides at arg 14. Each operator now carries its OWN envelope (per-op EG, DX-style)
    -- from its sequenced SHAPE index, resolved above to {atk, dec, atkCurve, decCurve}
    -- and grouped per op at args 16..31 (op1 16-19, op2 20-23, op3 24-27, op4 28-31).
    -- ol[1..4] are this channel's static operator levels, geode-shaped per hit above.
    -- See the trig command header in Engine_Potionshop.sc for the full arg order.
    engine.trig(geo_freq, actual_level, c.algo,
                ratio2, ratio3, ratio4, mod_index,
                feedback, ch,
                ol[1], ol[2], ol[3], ol[4], ratio1, pan,
                atk1, dec1, atkC1, decC1,
                atk2, dec2, atkC2, decC2,
                atk3, dec3, atkC3, decC3,
                atk4, dec4, atkC4, decC4)
  end
  if out then
    -- external voices can't render FM timbre; hand them the four sequenced op ratios.
    -- The MIDI + ER-301 paths send each op's ratio as one CC / CV per hit (the operator
    -- ratio sequence, no envelope). The note length (for MIDI / crow) follows op1's
    -- (carrier) envelope.
    out:note(ch, { freq = geo_freq, level = actual_level,
                   ratios = {ratio1, ratio2, ratio3, ratio4},
                   dur = atk1 + dec1 })
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
  -- Drawn from the UPPER part of the short A-picker bank (SHAPE_RANDOMIZE_MIN..
  -- SHAPE_PICKER_COUNT) so a randomized channel sits in the mid-short range (not the
  -- tiniest clicks, not the long swells/pads which are B-offset reach). Indices are
  -- inherently grid-reachable (within the picker range).
  c.opEnv1 = seqx.new{math.random(SHAPE_RANDOMIZE_MIN, SHAPE_PICKER_COUNT)}
  c.opEnv2 = seqx.new{math.random(SHAPE_RANDOMIZE_MIN, SHAPE_PICKER_COUNT)}
  c.opEnv3 = seqx.new{math.random(SHAPE_RANDOMIZE_MIN, SHAPE_PICKER_COUNT)}
  c.opEnv4 = seqx.new{math.random(SHAPE_RANDOMIZE_MIN, SHAPE_PICKER_COUNT)}
  -- op2/3/4 FM ratios ARE scrambled (timbral variety): each gets a SINGLE random A
  -- value drawn from the LOWER 32 (RATIO_PICKER_COUNT) of its ROLE set under this
  -- channel's algo — CARRIER_RATIOS if the op is a carrier, else MODULATOR_RATIOS (held,
  -- not stepped, like the shapes above). The lower-32 restriction keeps the value inside
  -- the A grid picker so it stays highlightable/editable (the reachability test asserts
  -- it). The B (offset) layer is left intact, like noteB. op1 is ALSO sequenced now, but
  -- randomize leaves it alone (A stays at the 1.0 anchor) so a randomized channel keeps a
  -- fundamental and stays pitched — op1 is a carrier in every algo (mutate likewise).
  local function pick_low(set) return set[math.random(1, math.min(RATIO_PICKER_COUNT, #set))] end
  c.opRatio2 = seqx.new{pick_low(op_ratio_set(c.algo, 2))}
  c.opRatio3 = seqx.new{pick_low(op_ratio_set(c.algo, 3))}
  c.opRatio4 = seqx.new{pick_low(op_ratio_set(c.algo, 4))}
  -- The per-channel amp-dynamics modes (envMode/geodeMode) and per-op LEVELS are
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
  -- nudge each op env's shape index to a neighbouring shape (grid-exact in 1..#SHAPES);
  -- the B offset lane is left untouched, like the op ratios below.
  local function nudge_shape(v) return clamp(round(v + jitter(amount * 4)), 1, #SHAPES) end
  c.opEnv1 = map(c.opEnv1, nudge_shape)
  c.opEnv2 = map(c.opEnv2, nudge_shape)
  c.opEnv3 = map(c.opEnv3, nudge_shape)
  c.opEnv4 = map(c.opEnv4, nudge_shape)
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
