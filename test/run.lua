-- Local test harness for the pure Lua modules. Run from the project root:
--   lua test/run.lua
-- Uses faithful stubs of the norns sequins/musicutil libs (see test/norns_stub).

package.path = 'test/norns_stub/?.lua;lib/?.lua;' .. package.path
clock = require 'clock'  -- virtual cooperative clock (global, like norns)

local fail = 0
local function check(name, cond)
  if cond then
    print('  ok  ' .. name)
  else
    print('FAIL  ' .. name)
    fail = fail + 1
  end
end
local function approx(a, b) return math.abs(a - b) < 1e-4 end

-- ---- quantize ----------------------------------------------------------
local q = require 'quantize'
print('quantize:')
check('disabled at 0 returns target', q.snap_beat(3.3, 0) == 3.3)
check('on-grid value unchanged (epsilon guard)', approx(q.snap_beat(1.0, 4), 1.0))
check('snaps forward to next 1/4 (q=4 -> step 1)', approx(q.snap_beat(1.25, 4), 2.0))
check('snaps forward to next 1/16 (q=16 -> step .25)', approx(q.snap_beat(0.3, 16), 0.5))

-- ---- scales ------------------------------------------------------------
local scales = require 'scales'
print('scales:')
local major = scales.by_name.major
check('major intervals from musicutil', #major == 7 and major[1] == 0 and major[7] == 11)
check('octave (12) stripped from musicutil intervals', major[#major] ~= 12)
check('degree 0 in major = C1 = 32.7032 Hz', approx(scales.degree_to_freq(0, major), 32.7032))
check('degree 7 in major wraps to next octave root (x2 freq)',
  approx(scales.degree_to_freq(7, major), 2 * scales.degree_to_freq(0, major)))
check('degree -1 in major = previous B (floor-mod)',
  scales.degree_to_semitones(-1, major) == -1)
check('custom scale hijaz preserved literally', #scales.by_name.hijaz == 7
  and scales.by_name.hijaz[2] == 1)
check('expanded scale list, every name resolves to intervals',
  #scales.names >= 12 and scales.names[1] == 'chromatic'
  and scales.by_name[scales.names[#scales.names]] ~= nil)
check('scale list gained the extra modes', scales.by_name.lydian ~= nil
  and scales.by_name.blues ~= nil and scales.by_name.wholeTone ~= nil)
check('no grid preset list anymore (presets moved to params menu)',
  scales.picker_names == nil)
check('root transposes tonic up by semitones',
  approx(scales.degree_to_freq(0, major, 2),
    require('musicutil').note_num_to_freq(26)))
check('negative root transposes tonic DOWN (per-channel -1 octave)',
  approx(scales.degree_to_freq(0, major, -12),
    require('musicutil').note_num_to_freq(12)))
check('root defaults to 0 (no transposition)',
  approx(scales.degree_to_freq(0, major, 0), scales.degree_to_freq(0, major)))
-- JUST INTONATION: the in-between intervals are pure ratios, not 12-TET. The
-- tonic (degree 0) and octaves stay exact; degrees in between ring as rationals.
local tonic = scales.degree_to_freq(0, major)
check('JI table is one octave [1,2)', scales.JI_RATIOS[0] == 1
  and scales.JI_RATIOS[7] == 3/2 and scales.JI_RATIOS[11] == 15/8)
check('major 3rd (degree 2) = pure 5/4 above tonic',
  approx(scales.degree_to_freq(2, major), tonic * 5/4))
check('perfect 5th (degree 4) = pure 3/2 above tonic',
  approx(scales.degree_to_freq(4, major), tonic * 3/2))
check('JI fifth is sharper than the 12-TET fifth',
  scales.degree_to_freq(4, major) > tonic * 2^(7/12))
check('chromatic degree 4 = pure major third (5/4)',
  approx(scales.degree_to_freq(4, scales.by_name.chromatic), tonic * 5/4))
check('octave of any degree is exact 2:1',
  approx(scales.degree_to_freq(2 + #major, major),
         2 * scales.degree_to_freq(2, major)))

-- ---- seqx / sequins ----------------------------------------------------
local seqx = require 'seqx'
print('seqx:')
local s = seqx.new{4, 8, 15}
check('values returns underlying data', seqx.values(s)[1] == 4 and seqx.values(s)[3] == 15)
check('len = 3', seqx.len(s) == 3)
local a, b, c, d = s(), s(), s(), s()
check('cycles 4,8,15,4', a == 4 and b == 8 and c == 15 and d == 4)
check('playhead tracks just-fired step (0-based)', seqx.playhead(s) == 0) -- last call returned data[1]
s(); -- returns 8 -> ix=2
check('playhead = 1 after firing step 2', seqx.playhead(s) == 1)
s:reset()
check('after reset, next() returns first value', s() == 4)
check('as_seq wraps scalar', seqx.is_seq(seqx.as_seq(5)) and seqx.values(seqx.as_seq(5))[1] == 5)
check('as_seq passes sequins through', seqx.as_seq(s) == s)

-- ---- burst: geode math ------------------------------------------------
local Burst = require 'burst'
-- quantize is per-channel now; set every channel's grid at once (tests that want
-- deterministic timing use q=0 to disable snapping, which the curated picker set
-- never exposes but the snap math still honours).
local function set_quant(e, val) for i = 1, Burst.NUM_CHANNELS do e.channels[i].quantize = val end end
print('burst geode math:')
check('geode_mod neutral run=0.5 -> 1.0', approx(Burst.geode_mod(1, 0.5, 0, 8), 1.0))
check('geode_mod transient r=1 i=0 -> 1.0', approx(Burst.geode_mod(1, 1.0, 0, 10), 1.0))
check('geode_mod transient r=1 i=5 (cycle 10) -> 0.5', approx(Burst.geode_mod(1, 1.0, 5, 10), 0.5))
check('geode_mod cycle neutral -> 1.0', approx(Burst.geode_mod(3, 0.5, 3, 8), 1.0))
check('level_for_hit no geode passes level through', approx(Burst.burst_level_for_hit(0.5, 0, 0, 0, 8), 0.5))
check('level_for_hit geode clamps to 0.7', approx(Burst.burst_level_for_hit(1.0, 1, 0, 0, 10), 0.7))

-- reps rest encoding: positive = hits, <=0 = rest of (1-reps) div-steps
check('reps 3 is not a rest', Burst.reps_is_rest(3) == false)
check('reps 0 is a rest of 1 step', Burst.reps_is_rest(0) and Burst.reps_rest_len(0) == 1)
check('reps -1 is a rest of 2 steps', Burst.reps_is_rest(-1) and Burst.reps_rest_len(-1) == 2)
check('reps -3 is a rest of 4 steps', Burst.reps_is_rest(-3) and Burst.reps_rest_len(-3) == 4)

-- ---- burst: randomize grid-alignment ----------------------------------
print('burst randomize (grid-reachable values):')
math.randomseed(1)
local function in_set(v, set)
  for _, s in ipairs(set) do if approx(v, s) then return true end end
  return false
end
local eng = Burst.new()
local LEVEL_CONST = 16 / 31  -- the fixed init volume (default_channel), not randomized
local ok_div, ok_reps, ok_note, ok_ratio, ok_ad, ok_len, ok_level_const, ok_op1 =
  true, true, true, true, true, true, true, true
local ok_single = true  -- shapes + op2/3/4 randomize to a SINGLE held step
for _ = 1, 200 do
  eng:randomize(1)
  local c = eng.channels[1]
  for _, v in ipairs(seqx.values(c.div))  do if not in_set(v, Burst.MUSICAL_DIVS) then ok_div = false end end
  for _, v in ipairs(seqx.values(c.reps)) do if not in_set(v, {1,2,3,4}) then ok_reps = false end end
  for _, v in ipairs(seqx.values(c.note)) do if not (v >= 0 and v <= 15 and v == math.floor(v)) then ok_note = false end end
  -- op2/3/4 ratios are sequenced now: every A-layer step must land on the LOWER 32
  -- (RATIO_PICKER_COUNT) of that op's ROLE set under the channel's algo (carrier ->
  -- CARRIER_RATIOS, else MODULATOR_RATIOS) — the exact cells the A grid picker shows, so
  -- the value stays highlightable/editable (the upper 32 are B-offset reach only).
  for _, op in ipairs({2, 3, 4}) do
    local set = Burst.op_ratio_set(c.algo, op)
    local low = {} for i = 1, math.min(Burst.RATIO_PICKER_COUNT, #set) do low[i] = set[i] end
    for _, v in ipairs(seqx.values(c['opRatio' .. op])) do
      if not in_set(v, low) then ok_ratio = false end
    end
  end
  -- the four per-operator envelope shapes are sequenced as shape INDICES; randomize
  -- draws from the upper part of the short A-picker bank, so every step must be an
  -- integer in SHAPE_RANDOMIZE_MIN..SHAPE_PICKER_COUNT (a slice of the picker range).
  for _, seq in ipairs({c.opEnv1, c.opEnv2, c.opEnv3, c.opEnv4}) do
    for _, v in ipairs(seqx.values(seq)) do
      if not (v == math.floor(v) and v >= Burst.SHAPE_RANDOMIZE_MIN and v <= Burst.SHAPE_PICKER_COUNT) then ok_ad = false end
    end
  end
  -- channel level is a static scalar: randomize must leave it at the init value.
  if not approx(c.level, LEVEL_CONST) then ok_level_const = false end
  -- op1 ratio is sequenced but NOT scrambled: randomize keeps its A lane at the 1.0
  -- anchor (a single step), so a randomized channel stays pitched.
  local o1 = seqx.values(c.opRatio1)
  if #o1 ~= 1 or not approx(o1[1], 1) then ok_op1 = false end
  local dl = seqx.len(c.div)
  if not (dl >= 2 and dl <= 4) then ok_len = false end
  -- the four env shapes + op2/3/4 ratios randomize to ONE held step (stable timbre)
  for _, seq in ipairs({c.opEnv1, c.opEnv2, c.opEnv3, c.opEnv4, c.opRatio2, c.opRatio3, c.opRatio4}) do
    if seqx.len(seq) ~= 1 then ok_single = false end
  end
end
check('div values all in MUSICAL_DIVS', ok_div)
check('reps values all in {1,2,3,4}', ok_reps)
check('note values 0..15 integer', ok_note)
check('sequenced op2/3/4 ratio steps land on the lower-32 of the role set', ok_ratio)
check('randomize keeps op1 ratio at the 1.0 anchor', ok_op1)
check('carrier+mod randomize shapes land in the upper short bank (16..32)', ok_ad)
check('randomize leaves channel level at the fixed init constant', ok_level_const)
check('lengths: div/reps/note 2..4', ok_len)
check('shapes + op2/3/4 randomize to a single held step', ok_single)

-- mutate must also leave the channel level untouched (a static scalar), even with a
-- custom value, and keep per-op ratios on the curated set.
local emut = Burst.new()
emut.channels[1].level = 0.42
for _ = 1, 50 do emut:mutate(1) end
check('mutate leaves channel level unchanged', approx(emut.channels[1].level, 0.42))
check('mutate keeps sequenced ratio steps on the curated set',
  in_set(seqx.values(emut.channels[1].opRatio2)[1], Burst.RATIO_VALUES)
  and in_set(seqx.values(emut.channels[1].opRatio4)[1], Burst.RATIO_VALUES))
check('mutate keeps op1 ratio at the 1.0 anchor',
  seqx.len(emut.channels[1].opRatio1) == 1 and approx(seqx.values(emut.channels[1].opRatio1)[1], 1))

-- ---- burst: clock-coroutine scheduling --------------------------------
print('burst scheduling:')
-- single-shot: reps length-1 finite -> completes during launch, stops itself
clock._reset()
local eng2 = Burst.new()
local fires = {}
eng2:on(function(ev) if ev.type == 'fire' then fires[#fires + 1] = ev end end)
eng2.channels[1].reps = seqx.new{1}
eng2.channels[1].div  = seqx.new{4}
eng2.channels[1].note = seqx.new{0}
eng2:launch(1)
check('single-shot fired exactly one hit', #fires == 1)
check('single-shot stopped the channel', eng2:is_running(1) == false)
check('fire freq = degree_to_freq(0, major) = C1', approx(fires[1].freq, 32.7032))

-- per-channel root transposes the fired freq at fire time (root is per channel now)
clock._reset()
local engR = Burst.new()
local firesR = {}
engR:on(function(ev) if ev.type == 'fire' then firesR[#firesR + 1] = ev end end)
engR.channels[1].reps = seqx.new{1}
engR.channels[1].div  = seqx.new{4}
engR.channels[1].note = seqx.new{0}
engR.channels[1].root = 2      -- +2 semitones (per-channel tonic transpose)
engR:launch(1)
check('per-channel root transposes fired freq (degree 0, root +2)',
  #firesR == 1 and approx(firesR[1].freq, scales.degree_to_freq(0, scales.by_name.major, 2)))

-- octave scalar: applied per hit in fire, so external outputs and the ghost
-- note see the shifted freq
clock._reset()
eng2.channels[1].reps = seqx.new{1}
eng2.channels[1].octave = 1
fires = {}
eng2:launch(1)
check('octave +1 doubles fire freq', approx(fires[1].freq, 32.7032 * 2))
eng2.channels[1].octave = -2
fires = {}
clock._reset()
eng2.channels[1].reps = seqx.new{1}
eng2:launch(1)
check('octave -2 quarters fire freq', approx(fires[1].freq, 32.7032 / 4))

-- looping: default reps {2,2} keeps running across bursts
clock._reset()
local eng3 = Burst.new()
local n = 0
eng3:on(function(ev) if ev.type == 'fire' then n = n + 1 end end)
eng3:launch(2)
check('looping fired first hit on launch', n == 1)
check('looping running after launch', eng3:is_running(2) == true)
clock._run_until(8)
check('looping kept firing across bursts', n > 6)
check('looping still running', eng3:is_running(2) == true)
eng3:stop(2)
check('stop halts the channel', eng3:is_running(2) == false)

-- rest: reps <= 0 fires nothing but still consumes its slot, so the rhythm holds.
-- reps {1, 0} = hit then a one-step rest, looping (2 steps). div 4 + rate 1 =>
-- one beat per step, so fires land two beats apart (hit, rest, hit, ...).
clock._reset()
local erst = Burst.new()
set_quant(erst, 0)
erst.channels[1].div  = seqx.new{4}
erst.channels[1].reps = seqx.new{1, 0}
erst.channels[1].note = seqx.new{0}
local rbeats = {}
erst:on(function(ev) if ev.type == 'fire' then rbeats[#rbeats + 1] = clock.get_beats() end end)
erst:launch(1)
clock._run_until(8)
check('rest channel keeps looping (2-step reps)', erst:is_running(1) == true)
check('rest fired the hit steps only', #rbeats >= 4 and #rbeats <= 5)
check('rest spaces fires two beats apart', approx(rbeats[2] - rbeats[1], 2)
  and approx(rbeats[3] - rbeats[2], 2))
erst:stop(1)

-- alt-trig: 'hold' draws the B note once per burst (every hit shares it);
-- 'step' advances the B note sequins per hit so the alt layer arpeggiates.
-- A 3-hit single-shot burst with noteB {0,5,7}: hold => all three = degree 0;
-- step => degrees 0, 5, 7.
local function alt_trig_freqs(mode)
  clock._reset()
  local e = Burst.new()
  set_quant(e, 0)
  local f = {}
  e:on(function(ev) if ev.type == 'fire' then f[#f + 1] = ev.freq end end)
  e.channels[1].div   = seqx.new{4}
  e.channels[1].reps  = seqx.new{3}     -- length-1 finite -> single 3-hit burst
  e.channels[1].note  = seqx.new{0}
  e.channels[1].noteB = seqx.new{0, 5, 7}
  e.channels[1].altTrig = mode
  e:launch(1)
  clock._run_until(4)
  return f
end
local hold = alt_trig_freqs(0)
check('alt-trig hold holds one B offset across the burst',
  #hold == 3 and approx(hold[1], hold[2]) and approx(hold[2], hold[3]))
local step = alt_trig_freqs(1)
check('alt-trig step arpeggiates the B pitch per hit',
  #step == 3 and approx(step[1], scales.degree_to_freq(0, major))
  and approx(step[2], scales.degree_to_freq(5, major))
  and approx(step[3], scales.degree_to_freq(7, major)))

-- op-env trig: 'hold' draws opEnv1's shape once per burst (every hit shares its
-- contour); 'step' advances the opEnv1 B (index-offset) lane per hit, re-resolved
-- against the held A, so the envelope shape arpeggiates — exactly like the op-ratio
-- trig. A=1 + B {0,14,31} resolves to shapes 1/15/32 (tick/click/plop, distinct
-- decMul: 0.03/0.10/0.20 in the length-sorted table), observed on op1's env-decay trig
-- arg (arg 17 = decMul*gap in shape envMode): hold => three equal decays; step =>
-- three distinct decays.
local function env_step_decays(trig_mode)
  clock._reset()
  local saved = engine
  local decs = {}
  engine = { trig = function(...) local a = {...}; decs[#decs + 1] = a[17] end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].div  = seqx.new{4}
  e.channels[1].reps = seqx.new{3}          -- single 3-hit burst
  e.channels[1].note = seqx.new{0}
  e.channels[1].opEnv1  = seqx.new{1}            -- A: held shape index per burst
  e.channels[1].opEnv1B = seqx.new{0, 14, 31}    -- B: index offsets -> shapes 1/15/32
  e.channels[1].opEnvTrig = trig_mode
  e:launch(1)
  clock._run_until(4)
  engine = saved
  return decs
end
check('op-env trig defaults to hold', Burst.new().channels[1].opEnvTrig == 0)
local sh_hold = env_step_decays(0)
check('op-env hold holds one shape across the burst',
  #sh_hold == 3 and approx(sh_hold[1], sh_hold[2]) and approx(sh_hold[2], sh_hold[3]))
local sh_step = env_step_decays(1)
check('op-env step arpeggiates the shape per hit',
  #sh_step == 3 and not approx(sh_step[1], sh_step[2])
  and not approx(sh_step[2], sh_step[3]) and not approx(sh_step[1], sh_step[3]))

-- all four op ratios are sequenced (A value + B offset, drawn per burst). The drawn
-- op2/3/4 values pass straight to trig args 4/5/6 (r2/r3/r4); op1's drawn value rides
-- as r1 at arg 14; the per-channel pan rides at arg 15.
-- engine.trig(freq, amp, algo, r2, r3, r4, modIndex, feedback, ch,
--             lvl1..4, r1, pan, then per-op env {atk,dec,atkCurve,decCurve} x4 at 16..31).
local function first_trig()
  clock._reset()
  local saved = engine
  local cap
  engine = { trig = function(...) cap = cap or {...} end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].div = seqx.new{4}
  e.channels[1].reps = seqx.new{1}
  e.channels[1].opRatio1 = seqx.new{0.5}
  e.channels[1].opRatio2 = seqx.new{2}
  e.channels[1].opRatio3 = seqx.new{3}
  e.channels[1].opRatio4 = seqx.new{7}
  e.channels[1].pan = -0.5
  e:launch(1)
  clock._run_until(2)
  engine = saved
  return cap
end
local off = first_trig()
check('algo passes at trig arg 3 (default channel = 1)', off and off[3] == 1)
check('sequenced op2/3/4 ratios pass at trig args 4/5/6',
  off and approx(off[4], 2) and approx(off[5], 3) and approx(off[6], 7))
-- op1 ratio (sequenced): its drawn value rides as r1 at trig arg 14.
check('op1 ratio passes at trig arg 14', off and approx(off[14], 0.5))
check('pan passes at trig arg 15', off and approx(off[15], -0.5))

-- op ratio B lane is an INDEX OFFSET: it shifts A's position UP the op's ROLE SET
-- (never an off-grid sum), reaching the higher upper-32 ratios. Under algo 1 op2 is a
-- modulator, so B walks MODULATOR_RATIOS. A {2} + B {4} -> the 4th entry above 2.0 (arg 4).
local function ratio_b_trig()
  clock._reset()
  local saved = engine
  local cap
  engine = { trig = function(...) cap = cap or {...} end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].algo = 1                   -- op2 = modulator -> MODULATOR_RATIOS
  e.channels[1].div = seqx.new{4}
  e.channels[1].reps = seqx.new{1}
  e.channels[1].opRatio2 = seqx.new{2}    -- A: base ratio
  e.channels[1].opRatio2B = seqx.new{4}   -- B: +4 index offset (walks up the role set)
  e:launch(1)
  clock._run_until(2)
  engine = saved
  return cap
end
local rb = ratio_b_trig()
check('op2 ratio B index-offset shifts A up the role set (arg 4)',
  rb and approx(rb[4], Burst.op_ratio(2, 4, Burst.MODULATOR_RATIOS)) and rb[4] > 2)

-- op_ratio properties (generic list-walk; the 3rd arg is the list, default = union):
-- B=0 is identity; positive offsets are monotonic non-decreasing on the sorted list;
-- offsets clamp at the top rather than overflowing.
local rv = Burst.RATIO_VALUES
local sorted = true
for i = 2, #rv do if rv[i] < rv[i - 1] then sorted = false end end
check('RATIO_VALUES is sorted ascending', sorted)
check('op_ratio B=0 is identity for each value in the union', (function()
  for _, a in ipairs(Burst.RATIO_VALUES) do if not approx(Burst.op_ratio(a, 0), a) then return false end end
  return true
end)())
check('op_ratio is monotonic non-decreasing in the offset',
  Burst.op_ratio(1, 0) <= Burst.op_ratio(1, 1) and Burst.op_ratio(1, 1) <= Burst.op_ratio(1, 5)
  and Burst.op_ratio(1, 5) < rv[#rv] + 1e-9)
check('B offset walks UP WITHIN the op role set (stays in-role)', (function()
  -- B now walks the op's role set, not the union: a carrier base + offset stays a
  -- carrier ratio (never lands on a modulator-only value), and it moves up the set.
  local C = Burst.CARRIER_RATIOS
  for _, a in ipairs(C) do
    for off = 0, 6 do
      local r = Burst.op_ratio(a, off, C)
      if not in_set(r, C) then return false end       -- in-role
      if r < a - 1e-9 then return false end            -- monotonic up
    end
  end
  -- and it actually REACHES the upper 32 (e.g. low A + offset climbs past 2.0)
  return Burst.op_ratio(C[Burst.RATIO_PICKER_COUNT], 8, C) > C[Burst.RATIO_PICKER_COUNT]
end)())
check('op_ratio clamps at the top of the role set',
  approx(Burst.op_ratio(rv[#rv], 31), rv[#rv]) and approx(Burst.op_ratio(rv[#rv], 99), rv[#rv]))

-- ---- dynamic op-ratio role sets (carrier vs modulator by algorithm) ----
print('op-ratio role sets:')
check('32 algorithms across the mirrors', #Burst.ALGO_MODULATORS == 32)
check('op1 is a carrier in every algorithm (1..32)', (function()
  for a = 1, 32 do if not Burst.is_carrier(a, 1) then return false end end
  return true
end)())
check('algo 8 (additive) makes all four ops carriers',
  Burst.is_carrier(8, 2) and Burst.is_carrier(8, 3) and Burst.is_carrier(8, 4))
check('algo 1 (single stack) makes op2/3/4 modulators',
  (not Burst.is_carrier(1, 2)) and (not Burst.is_carrier(1, 3)) and (not Burst.is_carrier(1, 4)))
check('AM algo 17 makes op2 a modulator (ring source), op3/op4 carriers',
  (not Burst.is_carrier(17, 2)) and Burst.is_carrier(17, 3) and Burst.is_carrier(17, 4))
check('op_ratio_set: carrier op -> CARRIER_RATIOS, modulator op -> MODULATOR_RATIOS',
  Burst.op_ratio_set(1, 1) == Burst.CARRIER_RATIOS
  and Burst.op_ratio_set(1, 2) == Burst.MODULATOR_RATIOS)
-- randomize honors the role: under an all-carrier algo, op2/3/4 land on CARRIER_RATIOS;
-- under a single-stack algo they land on MODULATOR_RATIOS.
local rand_carrier_ok, rand_mod_ok = true, true
for _ = 1, 100 do
  local ec = Burst.new(); ec.channels[1].algo = 8; ec:randomize(1)
  local em = Burst.new(); em.channels[1].algo = 1; em:randomize(1)
  for _, op in ipairs({2, 3, 4}) do
    if not in_set(seqx.values(ec.channels[1]['opRatio' .. op])[1], Burst.CARRIER_RATIOS) then rand_carrier_ok = false end
    if not in_set(seqx.values(em.channels[1]['opRatio' .. op])[1], Burst.MODULATOR_RATIOS) then rand_mod_ok = false end
  end
end
check('randomize under all-carrier algo draws op2/3/4 from CARRIER_RATIOS', rand_carrier_ok)
check('randomize under single-stack algo draws op2/3/4 from MODULATOR_RATIOS', rand_mod_ok)

-- op-ratio trig mode (prob page): affects ONLY the B (offset) lane, mirroring the
-- note alt-trig. hold draws B once per burst (held); step advances the B index per
-- hit, re-resolved against the held A. A single 3-hit burst with A held at {2} and
-- B {0,1,2} -> hold: 2,2,2; step: walks UP the list (2, then two finer ratios).
local function op_ratio_trig_seq(trig_mode)
  clock._reset()
  local saved = engine
  local r2 = {}
  engine = { trig = function(...) local a = {...}; r2[#r2 + 1] = a[4] end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].algo = 1                   -- op2 = modulator -> MODULATOR_RATIOS
  e.channels[1].div  = seqx.new{4}
  e.channels[1].reps = seqx.new{3}        -- length-1 finite -> single 3-hit burst
  e.channels[1].opRatio2  = seqx.new{2}   -- A: held per burst
  e.channels[1].opRatio2B = seqx.new{0, 1, 2}  -- B: index offsets
  e.channels[1].opSeqTrig = trig_mode
  e:launch(1)
  clock._run_until(4)
  engine = saved
  return r2
end
local MOD = Burst.MODULATOR_RATIOS
local hold_r = op_ratio_trig_seq(0)
check('op ratio trig hold holds one B offset across the burst',
  #hold_r == 3 and approx(hold_r[1], 2) and approx(hold_r[2], 2) and approx(hold_r[3], 2))
local step_r = op_ratio_trig_seq(1)
check('op ratio trig step walks the index UP per hit (A held)',
  #step_r == 3 and approx(step_r[1], 2)
  and step_r[2] == Burst.op_ratio(2, 1, MOD) and step_r[3] == Burst.op_ratio(2, 2, MOD)
  and step_r[2] > step_r[1] and step_r[3] > step_r[2])
check('op ratio trig defaults to hold (0)', Burst.new().channels[1].opSeqTrig == 0)

-- the A lane stays held regardless of trig mode: a multi-step A under step trig must
-- NOT advance within the burst (B {0} -> all three hits use A's first value, 2).
local function op_ratio_A_held(trig_mode)
  clock._reset()
  local saved = engine
  local r2 = {}
  engine = { trig = function(...) local a = {...}; r2[#r2 + 1] = a[4] end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].div  = seqx.new{4}
  e.channels[1].reps = seqx.new{3}
  e.channels[1].opRatio2  = seqx.new{2, 3, 4}  -- A: must stay held within a burst
  e.channels[1].opSeqTrig = trig_mode
  e:launch(1)
  clock._run_until(4)
  engine = saved
  return r2
end
local a_step = op_ratio_A_held(1)
check('op ratio step leaves the A lane held within the burst',
  #a_step == 3 and approx(a_step[1], 2) and approx(a_step[2], 2) and approx(a_step[3], 2))

-- op1 is sequenced the same way (A value + B index offset + per-hit trig), and its
-- drawn value rides as r1 at trig arg 14. A {2} + B {0,1,2} under step trig walks the
-- index UP per hit, exactly like op2 above but observed on arg 14.
local function op1_ratio_trig_seq(trig_mode)
  clock._reset()
  local saved = engine
  local r1 = {}
  engine = { trig = function(...) local a = {...}; r1[#r1 + 1] = a[14] end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].div  = seqx.new{4}
  e.channels[1].reps = seqx.new{3}        -- length-1 finite -> single 3-hit burst
  e.channels[1].opRatio1  = seqx.new{2}   -- A: held per burst
  e.channels[1].opRatio1B = seqx.new{0, 1, 2}  -- B: index offsets
  e.channels[1].opSeqTrig = trig_mode
  e:launch(1)
  clock._run_until(4)
  engine = saved
  return r1
end
local hold_r1 = op1_ratio_trig_seq(0)
check('op1 ratio trig hold holds one B offset across the burst (arg 14)',
  #hold_r1 == 3 and approx(hold_r1[1], 2) and approx(hold_r1[2], 2) and approx(hold_r1[3], 2))
local step_r1 = op1_ratio_trig_seq(1)
-- op1 is a carrier in every algo, so its B walks CARRIER_RATIOS.
local CAR = Burst.CARRIER_RATIOS
check('op1 ratio trig step walks the index UP per hit on arg 14',
  #step_r1 == 3 and approx(step_r1[1], 2)
  and step_r1[2] == Burst.op_ratio(2, 1, CAR) and step_r1[3] == Burst.op_ratio(2, 2, CAR)
  and step_r1[2] > step_r1[1] and step_r1[3] > step_r1[2])
check('op1 ratio trig shares the single opSeqTrig switch (defaults hold)',
  Burst.new().channels[1].opSeqTrig == 0)

-- PER-OPERATOR envelope SHAPES: each op's sequenced shape INDEX resolves (in fire)
-- to {attack, decay, atkCurve, decCurve} scaled to the inter-hit gap, grouped per op
-- at trig args 16..31 (op1 16-19, op2 20-23, op3 24-27, op4 28-31). div 4 @ 120bpm
-- => gap 0.5s. Expectations derive from Burst.SHAPES so this survives table tuning.
local GAP = 0.5
local function exp_atk(sh) return math.max(0.001, GAP * sh[1]) end
local function shp(i) return Burst.SHAPES[i] end
-- op K's env args occupy trig 16..31 in groups of 4 (atk, dec, atkCurve, decCurve):
-- op1->16, op2->20, op3->24, op4->28.
-- pick representative shapes BY their contour, not a hard-coded index, so this
-- survives reordering the table:
--   I_INSTANT = the SHORTEST instant-attack shape (atkMul 0, min decMul)
--   I_LONGATK = the longest-attack shape (max atkMul)
--   I_LONGDEC = the longest-decay shape (max decMul)
local I_INSTANT, I_LONGATK, I_LONGDEC
do
  local bestdec, maxatk, maxdec
  for i, s in ipairs(Burst.SHAPES) do
    if s[1] == 0 and (bestdec == nil or s[2] < Burst.SHAPES[bestdec][2]) then bestdec = i end
    if maxatk == nil or s[1] >= Burst.SHAPES[maxatk][1] then maxatk = i end
    if maxdec == nil or s[2] >= Burst.SHAPES[maxdec][2] then maxdec = i end
  end
  I_INSTANT, I_LONGATK, I_LONGDEC = bestdec, maxatk, maxdec
end
-- drive an env on op K (others held at the instant shape), return the captured trig.
local function env_trig(op, idx)
  clock._reset()
  local saved = engine
  local cap
  engine = { trig = function(...) cap = cap or {...} end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].div = seqx.new{4}
  e.channels[1].reps = seqx.new{1}
  for k = 1, 4 do e.channels[1]['opEnv' .. k] = seqx.new{I_INSTANT} end
  e.channels[1]['opEnv' .. op] = seqx.new{idx}
  e:launch(1)
  clock._run_until(2)
  engine = saved
  return cap
end
-- op1's envelope rides args 16..19.
local s_inst = env_trig(1, I_INSTANT)
local s_atk  = env_trig(1, I_LONGATK)
local s_dec  = env_trig(1, I_LONGDEC)
check('instant-attack op env -> ~0.001s attack (op1 arg 16)', s_inst and approx(s_inst[16], 0.001))
check('longer-attack op env -> longer gap-relative attack (op1 arg 16)',
  s_atk and s_inst and s_atk[16] > s_inst[16] and approx(s_atk[16], exp_atk(shp(I_LONGATK))))
check('longer-decay op env -> longer decay (op1 arg 17)', s_dec and s_inst and s_dec[17] > s_inst[17])
-- op-env curves pass straight through to trig (no per-channel curve scaling).
check('op env feeds dec curve (op1 arg 19)', s_inst and approx(s_inst[19], shp(I_INSTANT)[4]))
check('op env feeds atk curve (op1 arg 18)', s_inst and approx(s_inst[18], shp(I_INSTANT)[3]))

-- each operator carries its OWN envelope: driving op3's env feeds args 24..27 and
-- must NOT disturb op1's env (args 16..19).
local o3_inst = env_trig(3, I_INSTANT)
local o3_dec  = env_trig(3, I_LONGDEC)
check('op3 env feeds its own decay (op3 arg 25)', o3_dec and o3_inst and o3_dec[25] > o3_inst[25])
check('op3 env feeds atk curve (op3 arg 26)', o3_inst and approx(o3_inst[26], shp(I_INSTANT)[3]))
check('op3 env does not disturb op1 env (args 16/17 stable)',
  o3_inst and o3_dec and approx(o3_inst[16], o3_dec[16]) and approx(o3_inst[17], o3_dec[17]))

-- op-env decay tracks the inter-hit gap: 4x faster division -> ~1/4 the decay
-- (read op1's decay at arg 17), so dense/fast channels self-shorten.
local function op1_decay_for_div(divv)
  clock._reset()
  local saved = engine
  local cap
  engine = { trig = function(...) cap = cap or {...} end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].div = seqx.new{divv}
  e.channels[1].reps = seqx.new{1}
  e:launch(1)
  clock._run_until(2)
  engine = saved
  return cap and cap[17]
end
local slow, fast = op1_decay_for_div(2), op1_decay_for_div(8)
check('op env decay scales with division (4x faster ~= 1/4 the hit)',
  slow and fast and approx(fast, slow / 4))

-- the per-channel FM algorithm reaches trig arg 3 (4-op engine routing selector).
local function algo_trig(algo)
  clock._reset()
  local saved = engine
  local cap
  engine = { trig = function(...) cap = cap or {...} end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].div = seqx.new{4}
  e.channels[1].reps = seqx.new{1}
  e.channels[1].algo = algo
  e:launch(1)
  clock._run_until(2)
  engine = saved
  return cap and cap[3]
end
check('per-channel algo feeds trig arg 3', algo_trig(5) == 5)

-- the channel index rides along as trig arg 9 so the SC engine can keep each
-- channel monophonic (a new hit releases the previous voice, no droning overlap).
local function chan_arg(ch)
  clock._reset()
  local saved = engine
  local cap
  engine = { trig = function(...) cap = cap or {...} end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[ch].div = seqx.new{4}
  e.channels[ch].reps = seqx.new{1}
  e:launch(ch)
  clock._run_until(2)
  engine = saved
  return cap and cap[9]
end
check('channel index feeds trig arg 9', chan_arg(3) == 3)

-- voice scalars/macros read straight at fire time. trig args: 7 = modIndex,
-- 8 = feedback; op1's per-segment env curves ride args 18 (atk) / 19 (dec), passed
-- through unscaled (default 'tail' decCurve -4). `setup(e)` mutates the engine before
-- launch; returns the trig.
local function macro_trig(setup)
  clock._reset()
  local saved = engine
  local cap
  engine = { trig = function(...) cap = cap or {...} end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].div = seqx.new{4}
  e.channels[1].reps = seqx.new{1}
  if setup then setup(e) end
  e:launch(1)
  clock._run_until(2)
  engine = saved
  return cap
end
local d = macro_trig()
check('voice macro defaults: modIndex=2, op1 dec curve=-4, feedback=0',
  d and approx(d[7], 2) and approx(d[19], -4) and approx(d[8], 0))
-- mod index and FM feedback are per-channel static scalars (MIX page); they feed the
-- trig args directly. op-env curves pass through unscaled, so op1's dec curve at arg 19
-- stays the shape default regardless of the other scalars.
local gv = macro_trig(function(e)
  e.channels[1].modIndex, e.channels[1].fmFeedback = 12, 1.5
end)
check('voice scalars feed trig: modIndex, feedback (curves unscaled)',
  gv and approx(gv[7], 12) and approx(gv[8], 1.5) and approx(gv[19], -4))
-- per-operator levels ride trig args 10..13; op1 default 1, op2..4 default 15/31.
check('op levels default: op1=1, op2..4=15/31 (args 10-13)',
  d and approx(d[10], 1) and approx(d[11], 15/31) and approx(d[12], 15/31) and approx(d[13], 15/31))
-- now per-channel STATIC scalars: opLevel1..4 feed trig args 10-13 directly.
local ol = macro_trig(function(e)
  e.channels[1].opLevel1 = 0.2
  e.channels[1].opLevel2 = 0.4
  e.channels[1].opLevel3 = 0.6
  e.channels[1].opLevel4 = 0.8
end)
check('per-channel op levels feed trig args 10-13',
  ol and approx(ol[10], 0.2) and approx(ol[11], 0.4) and approx(ol[12], 0.6) and approx(ol[13], 0.8))

-- quantization: an off-grid division (triplet, 4/3 beats) must snap every
-- event FORWARD to the quarter-note grid (quantize=4 -> step 1 beat). We read
-- clock.get_beats() inside the listener = the actual (snapped) firing instant.
clock._reset()
local eqn = Burst.new()
set_quant(eqn, 4)
eqn.channels[1].div  = seqx.new{3}    -- natural spacing 4/3 ≈ 1.333 beats
eqn.channels[1].reps = seqx.new{1, 1} -- loops (2+ steps): one hit per burst
eqn.channels[1].note = seqx.new{0}
local fired_at = {}
eqn:on(function(ev) if ev.type == 'fire' then fired_at[#fired_at + 1] = clock.get_beats() end end)
eqn:launch(1)
clock._run_until(10)
local on_grid = true
for _, b in ipairs(fired_at) do
  if math.abs(b - math.floor(b + 0.5)) > 1e-6 then on_grid = false end
end
check('quantize snaps off-grid events to the quarter grid', on_grid and #fired_at > 3)
eqn:stop(1)
-- and with quantize disabled, the same triplet fires at its natural 4/3 spacing
clock._reset()
local eqd = Burst.new()
set_quant(eqd, 0)
eqd.channels[1].div  = seqx.new{3}
eqd.channels[1].reps = seqx.new{1, 1}
eqd.channels[1].note = seqx.new{0}
local nat = {}
eqd:on(function(ev) if ev.type == 'fire' then nat[#nat + 1] = clock.get_beats() end end)
eqd:launch(1)
clock._run_until(6)
check('quantize=0 fires at natural 4/3 spacing', #nat >= 3 and approx(nat[2] - nat[1], 4/3))
eqd:stop(1)

-- bar_reset (the per-bar reset scheduler's per-channel action): a soft sequins
-- rewind leaves two identical channels' burst phases offset; bar_reset hard-
-- restarts a running channel so out-of-phase copies lock together — the copy/
-- paste + reset-to-1-bar use case.
clock._reset()
local erb = Burst.new()
set_quant(erb, 0)
for _, ch in ipairs({1, 2}) do
  erb.channels[ch].div  = seqx.new{3}    -- 4/3-beat spacing: won't self-align
  erb.channels[ch].reps = seqx.new{1, 1}
  erb.channels[ch].note = seqx.new{0}
end
local efb = {{}, {}}
erb:on(function(ev)
  if ev.type == 'fire' then local t = efb[ev.ch]; t[#t + 1] = clock.get_beats() end
end)
erb:launch(1)
clock._run_until(1.5)
erb:launch(2)                 -- snaps to beat 2 -> phase-offset from ch1
clock._run_until(3)
check('channels out of phase before reset',
      math.abs(efb[1][#efb[1]] - efb[2][#efb[2]]) > 1e-6)
erb:bar_reset(1); erb:bar_reset(2)   -- reset between fires (relaunch owns the bar)
clock._run_until(9)
local function after(t, b0)
  local o = {}
  for _, v in ipairs(t) do if v > b0 + 1e-9 then o[#o + 1] = v end end
  return o
end
local a1, a2 = after(efb[1], 3), after(efb[2], 3)
local aligned = (#a1 >= 3 and #a1 == #a2)
if aligned then for i = 1, #a1 do if not approx(a1[i], a2[i]) then aligned = false end end end
check('bar_reset realigns out-of-phase identical channels to lockstep', aligned)
check('bar_reset keeps running channels running', erb:is_running(1) and erb:is_running(2))
erb:stop(1); erb:stop(2)
-- on a stopped channel it rewinds sequins only, never relaunches
erb.channels[3].note = seqx.new{0}
erb:bar_reset(3)
check('bar_reset does not launch a stopped channel', erb:is_running(3) == false)

-- reset_channel must rewind EVERY sequence (hardcoded list), including the
-- per-op envelope shapes (A and B), or opEnvN drift out of phase on a bar reset.
local rzc = Burst.new()
rzc.channels[1].opEnv1 = seqx.new{1, 5, 9}
rzc.channels[1].opEnv1B = seqx.new{0, 3}
rzc.channels[1].opEnv1(); rzc.channels[1].opEnv1()  -- advance the playheads
rzc.channels[1].opEnv1B()
rzc:reset_channel(1)
check('reset_channel rewinds opEnv1 A/B to step 1',
  rzc.channels[1].opEnv1() == 1 and rzc.channels[1].opEnv1B() == 0)

-- ---- grid_ui: controller wiring ---------------------------------------
local GridUI = require 'grid_ui'
print('grid_ui controller:')
check('GridUI exposes 32 algorithm names', #GridUI.ALGO_NAMES == 32)
check('Burst and GridUI agree on carrier role for every algo/op', (function()
  for a = 1, 32 do
    for op = 1, 4 do
      if (Burst.op_ratio_set(a, op) == Burst.CARRIER_RATIOS)
         ~= (GridUI.op_ratio_set(a, op) == GridUI.CARRIER_RATIOS) then return false end
    end
  end
  return true
end)())
local function mock_grid()
  return {
    leds = {},
    strobes = {},
    set_led = function(self, x, y, b) self.leds[y * 16 + x] = b end,
    set_strobe = function(self, x, y, s) self.strobes[y * 16 + x] = (s ~= 'off') and s or nil end,
    clear = function(self) self.leds = {}; self.strobes = {} end,
    refresh = function() end,
  }
end

local function vals_eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if not approx(a[i], b[i]) then return false end end
  return true
end

clock._reset()
local geng = Burst.new()
local mg = mock_grid()
local ctl = GridUI.new(geng, mg)

-- param select — pages split across rows: row 6 cols 0..4 = note + op1..4, row 7
-- cols 0..1 = div/reps + SHP. Both A/B halves are always shown, so a re-press only
-- keeps the param selected (no double-press A/B flip)
check('default selected param = note', ctl.selectedParam == 'note')
ctl:press(0, 7)
check('row7 col0 selects div', ctl.selectedParam == 'div')
ctl:press(0, 7)
check('re-press keeps param selected (no layer flip)', ctl.selectedParam == 'div')

-- step picker edits a value
ctl:press(0, 6)  -- row 6 col 0 = note page
check('selected note again', ctl.selectedParam == 'note')
ctl:press(0, 0)  -- open picker on channel 0 step 0
check('step picker opened', ctl.picker ~= nil and ctl.picker.kind == 'step')
ctl:press(5, 6)  -- pick note value index 5 -> 5 (value grid now on rows 6-7)
check('picker set note step to 5', seqx.values(geng.channels[1].note)[1] == 5)
check('picker closed after pick', ctl.picker == nil)

-- pressing the already-selected value in the picker (rows 6-7) removes the step
geng.channels[1].note = seqx.new{5, 7, 9}
ctl:press(1, 0)  -- open picker on channel 0 step 1 (value 7)
check('picker reopened on step 1', ctl.picker ~= nil and ctl.picker.col == 1)
ctl:press(7, 6)  -- press the lit current value (note 7 -> index 7) again
check('re-pressing current value removes the step',
  seqx.len(geng.channels[1].note) == 2
  and seqx.values(geng.channels[1].note)[1] == 5
  and seqx.values(geng.channels[1].note)[2] == 9)
check('picker closed after remove', ctl.picker == nil)
-- a different value still sets (doesn't remove)
geng.channels[1].note = seqx.new{5, 7, 9}
ctl:press(1, 0); ctl:press(3, 6)  -- step 1, pick value 3
check('picker still sets a different value',
  seqx.len(geng.channels[1].note) == 3 and seqx.values(geng.channels[1].note)[2] == 3)

-- tapping another channel step hops the open picker there (rows 6-7 = values,
-- so the channel rows stay live for re-targeting)
geng.channels[1].note = seqx.new{5, 7, 9}
ctl:press(0, 0)                    -- open on ch0 step0
ctl:press(2, 0)                    -- tap ch0 step2 -> hop, picker stays open
check('tapping another step hops the picker',
  ctl.picker ~= nil and ctl.picker.col == 2)
-- re-tapping the open step cancels (closes) without removing it
ctl:press(2, 0)
check('re-tapping the open step cancels without removing',
  ctl.picker == nil and seqx.len(geng.channels[1].note) == 3)

-- B layer edits live on the right half (cols 8..15) — no double-press needed
geng.channels[1].noteB = seqx.new{0}
ctl:press(8, 0)  -- col 8 = B-layer step 0
check('right-half press opens the B-layer picker',
  ctl.picker ~= nil and ctl.picker.layer == 'B' and ctl.picker.col == 0)
ctl:press(4, 6)  -- pick note value index 4 (value 4)
check('B-layer picker edits noteB', seqx.values(geng.channels[1].noteB)[1] == 4)
-- the open B step (col 8) re-tap cancels; an A step (col 0) hops to layer A
ctl:press(0, 0)  -- open A step 0 again to verify the picker reopened on layer A
check('A-half press targets the A layer', ctl.picker.layer == 'A' and ctl.picker.col == 0)
ctl:close_picker()

-- 8-step cap: the add slot stops appearing past SEQ_LEN; commit truncates
geng.channels[1].note = seqx.new{0, 1, 2, 3, 4, 5, 6, 7}  -- exactly 8 (A half full)
ctl:press(0, 6)  -- row 6 col 0 = note page
ctl:press(7, 0)  -- step 7 (last A col) exists; opens it
check('8th A step is editable (full half)', ctl.picker ~= nil and ctl.picker.col == 7)
ctl:close_picker()
ctl:commit_step_raw(0, 'note', {0,1,2,3,4,5,6,7,8,9}, 'A')  -- 10 -> capped to 8
check('commit_step_raw caps a sequence at 8 steps',
  seqx.len(geng.channels[1].note) == 8)

-- div/reps share ONE page button (col 0): left half edits div, right half reps
geng.channels[1].div = seqx.new{4}
geng.channels[1].reps = seqx.new{2}
ctl:press(0, 7)  -- col 0 = div/reps page
check('selecting div/reps page', ctl.selectedParam == 'div')
ctl:press(0, 0)  -- left half step 0 -> div A
check('left half targets div (A)', ctl.picker.param == 'div' and ctl.picker.layer == 'A')
ctl:close_picker()
ctl:press(8, 0)  -- right half step 0 -> reps A
check('right half targets reps (A)', ctl.picker.param == 'reps' and ctl.picker.layer == 'A')
ctl:press(5, 6)  -- pick a reps value (reps layout index 6 -> 6)
check('right-half pick edits reps',
  seqx.values(geng.channels[1].reps)[1] == GridUI.STEP_PICKER_VALUES.reps[6])
ctl:close_picker()

-- rest cells (reps <= 0) strobe in the picker so they read apart from hit counts.
-- new layout: row 6 (cells 1..16) = reps 1..16 hits; row 7 (cells 17..32) = rests
-- of length 1..16 (values 0..-15), so the whole bottom row strobes.
geng.channels[1].reps = seqx.new{2}
ctl:press(8, 0)  -- open the reps A picker
ctl:render_all()
check('rest cells strobe across the whole bottom row',
  mg.strobes[7 * 16 + 0] == 'slow' and mg.strobes[7 * 16 + 15] == 'slow')
check('hit-count cells (top row) do not strobe',
  mg.strobes[6 * 16 + 0] == nil and mg.strobes[6 * 16 + 15] == nil)
ctl:close_picker()

-- per-op envelope pages (row 7 cols 1/2/3/4 = opEnv1/2/3/4, following div/reps at
-- col 0): an A|B sequence like the op ratios (left = A shape index, right = B index
-- offset). Selecting one lights only its button.
ctl:press(1, 7)  -- row 7 col 1 = opEnv1 page
check('opEnv1 page selected', ctl.selectedParam == 'opEnv1')
check('opEnv1 page shows opEnv1 A | B lanes',
  ctl:row_lanes()[1].param == 'opEnv1' and ctl:row_lanes()[1].layer == 'A'
  and ctl:row_lanes()[2].param == 'opEnv1' and ctl:row_lanes()[2].layer == 'B')
ctl:render_all()
check('row7 lights only the opEnv1 button (col1), not div/reps (col0)',
  mg.leds[7 * 16 + 1] == 15 and mg.leds[7 * 16 + 0] ~= 15)
ctl:press(0, 0)  -- left half -> opEnv1 A
check('opEnv1 left half edits the A (shape) layer',
  ctl.picker.param == 'opEnv1' and ctl.picker.layer == 'A')
ctl:press(2, 6)  -- value grid row 6 col 3 -> shape index 3
check('opEnv1 A picker writes a shape index step',
  seqx.values(geng.channels[1].opEnv1)[1] == GridUI.STEP_PICKER_VALUES.opEnv1[3])
ctl:press(8, 0)  -- right half -> opEnv1 B (offset) picker
check('opEnv1 right half edits the B (offset) layer',
  ctl.picker.param == 'opEnv1' and ctl.picker.layer == 'B')
ctl:close_picker()
ctl:press(4, 7)  -- row 7 col 4 = opEnv4 page
check('opEnv4 page selected', ctl.selectedParam == 'opEnv4')

-- sequenced op ratio pages (row 6 cols 1/2/3/4 = op1/2/3/4, following the note
-- page at col 0): an A|B sequence like note (left = A value, right = B offset).
ctl:press(1, 6)  -- row 6 col 1 = op1 ratio page
check('op1 ratio page selected', ctl.selectedParam == 'opRatio1')
check('op1 ratio page shows opRatio1 A | B lanes',
  ctl:row_lanes()[1].param == 'opRatio1' and ctl:row_lanes()[1].layer == 'A'
  and ctl:row_lanes()[2].param == 'opRatio1' and ctl:row_lanes()[2].layer == 'B')
ctl:press(0, 0)  -- left half step 0 -> opRatio1 A picker
check('op1 ratio left half edits the A layer',
  ctl.picker.param == 'opRatio1' and ctl.picker.layer == 'A')
ctl:press(11, 6) -- value grid row 6 col 11 -> op1 is a carrier, so CARRIER_RATIOS[12]
check('op1 ratio A picker writes a curated (carrier-set) ratio step',
  approx(seqx.values(geng.channels[1].opRatio1)[1], GridUI.CARRIER_RATIOS[12]))
ctl:press(8, 0)  -- right half step 0 -> opRatio1 B (offset) picker
check('op1 ratio right half edits the B (offset) layer',
  ctl.picker.param == 'opRatio1' and ctl.picker.layer == 'B')
ctl:close_picker()
ctl:press(2, 6)  -- row 6 col 2 = op2 ratio page
check('op2 ratio page selected', ctl.selectedParam == 'opRatio2')
check('op2 ratio page shows opRatio2 A | B lanes',
  ctl:row_lanes()[1].param == 'opRatio2' and ctl:row_lanes()[1].layer == 'A'
  and ctl:row_lanes()[2].param == 'opRatio2' and ctl:row_lanes()[2].layer == 'B')
ctl:press(4, 6)  -- row 6 col 4 = op4 ratio page
check('op4 ratio page selected', ctl.selectedParam == 'opRatio4')

-- dynamic picker: the op2 A picker filters to the channel's role set for op2, which
-- flips with the algorithm. Press the SAME value cell under two algos and confirm the
-- committed ratio comes from the carrier set (algo 8) vs the modulator set (algo 1).
ctl:press(2, 6)               -- op2 ratio page
geng.channels[1].algo = 8     -- additive -> op2 is a carrier
ctl:press(0, 0)               -- open op2 A picker on ch1 step 0
ctl:press(3, 6)               -- value grid row 6 col 3 -> picker index 4
check('op2 A picker (carrier algo) writes from CARRIER_RATIOS',
  approx(seqx.values(geng.channels[1].opRatio2)[1], GridUI.CARRIER_RATIOS[4]))
geng.channels[1].algo = 1     -- single stack -> op2 is a modulator
ctl:press(0, 0)               -- reopen op2 A picker
ctl:press(3, 6)               -- same cell -> picker index 4, now the modulator set
check('op2 A picker (modulator algo) writes from MODULATOR_RATIOS',
  approx(seqx.values(geng.channels[1].opRatio2)[1], GridUI.MODULATOR_RATIOS[4]))
ctl:close_picker()

-- back to the note page so later tests start from a known selection
ctl:press(0, 6)
check('back to note page', ctl.selectedParam == 'note')

-- onboarding: BEFORE the first-ever launch, idle launch buttons 'pulse' (breathing
-- cue inviting a first press)
check('fresh controller has not launched', ctl.hasLaunched == false)
ctl:render_all()
check('idle launch buttons pulse before first launch', mg.strobes[7 * 16 + 5] == 'pulse')

-- launch toggle: a contiguous 1x6 strip on row 7 at cols 5..10 (col 5+ch = channel ch+1)
ctl:press(5, 7)   -- ch0 = col 5, row 7
check('launch strip (col5,row7) launches channel 1', geng:is_running(1) == true)
check('first launch latches hasLaunched', ctl.hasLaunched == true)
ctl:press(5, 7)
check('re-press stops channel 1', geng:is_running(1) == false)
ctl:press(10, 7)  -- ch5 = col 10, row 7
check('launch strip (col10,row7) launches channel 6', geng:is_running(6) == true)
ctl:press(10, 7)
check('re-press stops channel 6', geng:is_running(6) == false)

-- first-run gate: once any channel has ever started, the onboarding pulse is gone;
-- a running channel is solid full-bright, an idle one a static dim (no strobe)
geng:launch(1)  -- ch0 = col 5, row 7
ctl:render_all()
check('idle launch button no longer pulses after first launch', mg.strobes[7 * 16 + 6] == nil)
check('idle launch button settles to a static dim', mg.leds[7 * 16 + 6] == 4)
check('running launch button is solid full-bright', mg.leds[7 * 16 + 5] == 15)
geng:stop(1)

-- ROOT/scale page (row6 col 14): mask kb rows 0-1, root kb rows 2-5 (upper 2-3,
-- lower 4-5), channel selectors on row 7 cols 5-10. root is per-channel now.
ctl.focusCh = 0
ctl:close_picker()
ctl:press(14, 6)
check('SCALE col opens ROOT page', ctl.picker ~= nil and ctl.picker.kind == 'scale')
check('root page seeds target = focused channel 0', ctl.rootTargets[0] == true)
-- global mask keyboard (rows 0-1): white row col 0 = pitch class 0 (in major -> removes)
local m0 = #geng.scale
ctl:press(0, 1)
check('mask keyboard edits the global scale', #geng.scale ~= m0)
ctl:press(0, 1)
check('mask keyboard toggles back', #geng.scale == m0)
-- root UPPER octave (rows 2-3): white row col 0 = pitch class 0 -> offset 0 (base tonic)
ctl:press(0, 3)
check('root sets targeted channel 0 to offset 0', geng.channels[1].root == 0)
check('single target auto-advances to channel 1',
  ctl.rootTargets[1] == true and ctl.rootTargets[0] == nil)
-- root LOWER octave (rows 4-5): white col 1 = pc 2 -> offset 2-12 = -10 (down an octave)
ctl:press(1, 5)
check('root lower octave sets channel 1 to -10', geng.channels[2].root == -10)
-- single applies auto-advanced twice, so the target is channel 2 now. Add ch0 (col5)
-- and ch3 (col8) via the row-7 channel selectors for a multi-target edit.
check('auto-advance reached channel 2', ctl.rootTargets[2] == true)
ctl:press(5, 7)
ctl:press(8, 7)
check('multi-select adds channels', ctl.rootTargets[2] and ctl.rootTargets[0] and ctl.rootTargets[3])
-- apply root to all selected: upper white col 2 = pc 4 -> offset 4
ctl:press(2, 3)
check('root applies to all selected channels', geng.channels[1].root == 4
  and geng.channels[3].root == 4 and geng.channels[4].root == 4)
check('multi target does NOT auto-advance',
  ctl.rootTargets[0] and ctl.rootTargets[2] and ctl.rootTargets[3])
-- selectors refuse to empty the target set
ctl:press(5, 7)   -- ch0 off -> {2,3}
ctl:press(7, 7)   -- ch2 off -> {3}
ctl:press(8, 7)   -- try ch3 off -> refused
check('selector refuses to empty the target set',
  ctl.rootTargets[3] == true)
ctl:press(14, 6)  -- close
check('ROOT page closed via SCALE col', ctl.picker == nil)

-- entering the scale page is exclusive with the other row-6 latch modes, so
-- only the active page's button stays lit (regression: a prior PERF/PROB/SND
-- page used to remain latched behind the open scale picker)
ctl:press(12, 6)  -- PERF mode on
check('PERF mode entered before scale', ctl.perfMode == true)
ctl:press(14, 6)  -- open scale picker
check('scale picker open over PERF', ctl.picker ~= nil and ctl.picker.kind == 'scale')
check('opening scale page clears PERF mode', ctl.perfMode == false)
ctl:press(13, 6)  -- PROB toggles off scale picker via mode switch path? -> close+enter PROB
check('switching to PROB clears scale picker', ctl.picker == nil)
check('PROB mode active after leaving scale', ctl.probMode == true)
ctl:press(13, 6)  -- PROB off, back to channels
check('PROB mode off', ctl.probMode == false)

-- set_mask: replace the whole mask at once (the keymask param edit path)
ctl:set_mask({7, 0, 4, 7, 13})  -- dup 7 + out-of-range 13 dropped, then sorted
check('set_mask dedups, drops out-of-range, sorts', vals_eq(geng.scale, {0, 4, 7}))
ctl:set_mask({})
check('set_mask refuses to empty the scale', vals_eq(geng.scale, {0, 4, 7}))

-- prob mode (row6 col 13)
ctl:press(13, 6)
check('PROB mode entered', ctl.probMode == true)
ctl:press(0, 0)   -- prob cell (col 0) -> opens the 32-value scalar picker
check('prob cell opens the scalar picker', ctl.picker ~= nil
  and ctl.picker.kind == 'scalar' and ctl.picker.field == 'burstProb')
ctl:press(15, 6)  -- picker row 6 col 15 -> PROB_VALUES[16] = 16/32 = 0.5
check('prob picker sets burstProb 0.5', approx(geng.channels[1].burstProb, 0.5))
check('prob picker closes after the pick', ctl.picker == nil)
check('PROB mode still latched after the pick', ctl.probMode == true)
-- note alt(B) trig toggle (col 3): single button, hold (0) <-> step (1)
ctl:press(3, 0)
check('note trig button toggles to step', geng.channels[1].altTrig == 1)
ctl:press(3, 0)
check('note trig button toggles back to hold', geng.channels[1].altTrig == 0)
-- op-ratio seq trig (col 4): ONE switch for all four B lanes
check('op seq trig defaults to hold', geng.channels[1].opSeqTrig == 0)
ctl:press(4, 0)
check('op seq trig button toggles to step', geng.channels[1].opSeqTrig == 1)
ctl:press(4, 0)
check('op seq trig button toggles back to hold', geng.channels[1].opSeqTrig == 0)
-- op-env seq trig (col 5): ONE switch for all four op-env B lanes
check('op env trig defaults to hold', geng.channels[1].opEnvTrig == 0)
ctl:press(5, 0)
check('op env trig button toggles to step', geng.channels[1].opEnvTrig == 1)
ctl:press(5, 0)
check('op env trig button toggles back to hold', geng.channels[1].opEnvTrig == 0)
ctl:press(13, 6)
check('PROB mode exited', ctl.probMode == false)

-- MIX page (row6 col 11) in signal-flow order: algo (col 0) + mod index (col 1) + per-op
-- level (cols 3-6) + FM feedback (col 8) + filter (col 13) + pan (col 14) + channel
-- level/volume (col 15). Chorus was removed; cols 2/7/9-12 are inert.
ctl:press(11, 6)
check('MIX mode entered', ctl.mixMode == true)
-- col2 is a dark separator now (chorus removed) — inert.
ctl:press(2, 0)
check('MIX col2 is inert (separator)', ctl.picker == nil)
ctl:press(0, 0)   -- col0 -> algorithm picker
check('MIX col0 opens the algorithm scalar picker',
  ctl.picker and ctl.picker.field == 'algo')
ctl:press(1, 0)   -- col1 -> mod index picker
check('MIX col1 opens the mod index scalar picker',
  ctl.picker and ctl.picker.field == 'modIndex')
ctl:press(14, 0)  -- col14 -> pan picker
check('MIX col14 opens the pan scalar picker',
  ctl.picker and ctl.picker.field == 'pan')
ctl:press(0, 6)   -- value grid row 6 col 0 -> PAN_VALUES[1] = -1 (hard left)
check('MIX pan picker sets c.pan hard left', approx(geng.channels[1].pan, -1))
ctl:press(14, 0)  -- reopen pan picker
ctl:press(0, 7)   -- value grid row 7 col 0 -> PAN_VALUES[17] = 0 (centre, grid-exact)
check('MIX pan picker can return to dead centre', approx(geng.channels[1].pan, 0))
ctl:press(15, 0)  -- col15 -> channel level/volume picker
check('MIX col15 opens the channel level scalar picker',
  ctl.picker and ctl.picker.field == 'level')
ctl:press(0, 6)   -- value grid row 6 col 0 -> OP_LEVEL_VALUES[1] = 0
check('MIX channel level picker sets c.level', approx(geng.channels[1].level, 0))
ctl:press(3, 0)   -- col3 -> op1 level picker
check('MIX op level cell opens a scalar picker',
  ctl.picker and ctl.picker.field == 'opLevel1')
ctl:press(15, 7)  -- value grid row 7 col 15 -> OP_LEVEL_VALUES[32] = 1.0
check('MIX op level picker sets opLevel1', approx(geng.channels[1].opLevel1, 1.0))
ctl:press(8, 0)   -- col8 -> FM feedback picker
check('MIX col8 opens the FM feedback scalar picker',
  ctl.picker and ctl.picker.field == 'fmFeedback')
ctl:close_picker()
-- DJ filter (col 13): one bipolar knob, centre = no filter, left = LP, right = HP.
check('filterPos defaults to 0 (no filter)', geng.channels[1].filterPos == 0)
ctl:press(13, 0)  -- col13 -> filter picker
check('MIX col13 opens the filter scalar picker',
  ctl.picker and ctl.picker.field == 'filterPos')
ctl:press(0, 6)   -- value grid row 6 col 0 -> FILTER_VALUES[1] = -1 (LP closed)
check('MIX filter picker sets filterPos to the LP extreme',
  approx(geng.channels[1].filterPos, -1))
ctl:press(13, 0)  -- reopen filter picker
ctl:press(0, 7)   -- value grid row 7 col 0 -> FILTER_VALUES[17] = 0 (off, grid-exact)
check('MIX filter picker can return to off (centre)',
  approx(geng.channels[1].filterPos, 0))
ctl:press(13, 0)
ctl:press(15, 7)  -- value grid row 7 col 15 -> FILTER_VALUES[32] = +1 (HP extreme)
check('MIX filter picker sets filterPos to the HP extreme',
  approx(geng.channels[1].filterPos, 1))
geng.channels[1].filterPos = 0  -- restore the default for later checks
ctl:press(11, 6)
check('MIX mode exited', ctl.mixMode == false)

-- the channel-strip filter pushes to the SC engine on every set_scalar (unlike
-- the other MIX scalars, which ride the next trig): Burst:push_filter forwards
-- to the global norns `engine` when present, and is silent off-hardware.
do
  local pushed = {}
  _G.engine = {
    filter = function(ch, pos) pushed.filter = {ch, pos} end,
  }
  ctl:set_scalar(1, 'filterPos', -0.5)
  check('set_scalar(filterPos) pushes engine.filter with 1-based ch',
    pushed.filter and pushed.filter[1] == 2 and approx(pushed.filter[2], -0.5))
  ctl:set_scalar(1, 'pan', 0.2)
  pushed.filter = nil
  ctl:set_scalar(1, 'level', 0.5)
  check('non-strip scalars do not push the filter', pushed.filter == nil)
  _G.engine = nil
  local c2 = geng.channels[2]
  c2.filterPos, c2.pan, c2.level = 0, 0, 16 / 31
end
check('filter labels read off/LP/HP',
  GridUI.filter_label(0) == 'off' and GridUI.filter_label(-1) == 'LP100'
  and GridUI.filter_label(1) == 'HP100')

-- env mode + geode are per-channel now, edited on the PRISM page (renamed QNT).
check('geodeMode is a per-channel field', geng.channels[1].geodeMode ~= nil)
check('envMode is a per-channel field', geng.channels[1].envMode ~= nil)
check('geode is no longer an engine-global field', geng.geodeMode == nil)
check('geode defaults to sustain (1)', Burst.new().channels[1].geodeMode == 1)
check('env mode defaults to shape (0)', Burst.new().channels[1].envMode == 0)
-- PRISM page grid: quantize on cols 0-7, env mode on 9-11, geode on 13-15.
ctl:press(15, 6)  -- enter PRISM (ROW6_PRISM_COL = 15)
check('PRISM mode entered', ctl.prismMode == true)
ctl:press(11, 0)  -- env-mode cell col 11 (3rd) -> envMode 2 (hit) on channel 1
check('PRISM env-mode press sets envMode', geng.channels[1].envMode == 2)
ctl:press(13, 0)  -- geode cell col 13 (1st) -> geodeMode 0 (transient) on channel 1
check('PRISM geode press sets geodeMode', geng.channels[1].geodeMode == 0)
ctl:press(6, 0)   -- quantize cell col 6 (7th) -> QUANTIZE_VALUES[7] = 24
check('PRISM quantize press still works', geng.channels[1].quantize == 24)
ctl:press(15, 6)  -- exit PRISM
check('PRISM mode exited', ctl.prismMode == false)
check('no SND grid mode exists', ctl.soundMode == nil)

-- PERF mode (row6 col 12): reset cols 0-3, octave cols 5-9, rate cols 11-15
ctl:press(12, 6)
check('PERF mode entered', ctl.perfMode == true)
ctl:press(3, 0)   -- reset col 3 -> 4 bars
check('PERF reset col3 sets 4-bar interval', geng.channels[1].resetInterval == 4)
ctl:press(4, 0)   -- blank gap column: no-op
check('PERF col4 is a no-op gap', geng.channels[1].resetInterval == 4)
ctl:press(5, 0)   -- octave col 5 -> -2
check('PERF octave col5 sets -2', geng.channels[1].octave == -2)
ctl:press(9, 0)   -- octave col 9 -> +2
check('PERF octave col9 sets +2', geng.channels[1].octave == 2)
ctl:press(14, 0)  -- rate col 14 -> 2x
check('PERF rate col14 sets 2x', geng.channels[1].rate == 2)
ctl:press(12, 6)
check('PERF mode exited', ctl.perfMode == false)

-- FM algorithm is a per-channel static scalar (MIX page col 15), not a global engine
-- field or a dedicated grid page/mode.
check('algo is a per-channel field, not global', geng.algo == nil and geng.channels[1].algo ~= nil)
check('no ALG grid mode exists', ctl.algoMode == nil)

-- ---- screen_ui: pages, edits, fire reactivity --------------------------
screen = require 'screen'  -- global drawing API stub, like norns
local ScreenUI = require 'screen_ui'
print('screen_ui:')

clock._reset()
local seng = Burst.new()
local sctl = GridUI.new(seng, mock_grid())
local sui = ScreenUI.new(seng, sctl)

-- page indices in the K2/K3 chain: 10 per-param sequence pages, then the 4 mode pages.
--   1 note · 2 opRatio1 · 3 opRatio2 · 4 opRatio3 · 5 opRatio4 · 6 div/reps ·
--   7 opEnv1 · 8 opEnv2 · 9 opEnv3 · 10 opEnv4 · 11 perf · 12 prob · 13 scale · 14 mix
local P_NOTE, P_OPR2, P_DIV = 1, 3, 6
local P_PERF, P_PROB, P_SCALE, P_MIX = 11, 12, 13, 14

-- smoke: redraw runs clean on every page
local pages_ok = true
for p = 1, 14 do
  sui:set_page(p)
  local ok, err = pcall(function() sui:redraw() end)
  if not ok then pages_ok = false; print('      redraw error page ' .. p .. ': ' .. tostring(err)) end
end
check('redraw runs clean on all 14 pages', pages_ok)
sui:set_page(P_PERF)
check('set_page syncs grid modes (perf -> perfMode)', sctl.perfMode == true)
sui:set_page(P_SCALE)
check('scale page opens the grid scale picker', sctl.picker and sctl.picker.kind == 'scale')

-- note page: six channel rows of one param; E3 edits land exactly on the picker grid
sui:set_page(P_NOTE)
sui.sel_ch = 0
sui.sel_lane = 1
seng.channels[1].note = seqx.new{0}
sui.sel_step = 0
sui:enc(3, 1)
check('note page E3 edit lands on the note picker grid',
  in_set(seqx.values(seng.channels[1].note)[1], GridUI.STEP_PICKER_VALUES.note))
check('note page keeps grid selectedParam = note', sctl.selectedParam == 'note')
check('note page main_param is the lane-1 (A) param', sui:main_param() == 'note' and sui:layer() == 'A')

-- prob page: prob steps the 32-value grid shared with the grid picker
sui:set_page(P_PROB)
sui.sel_line[P_PROB] = 1
seng.channels[1].burstProb = 1
sui:enc(3, -1)
check('prob E3 steps down one grid value (31/32)',
  approx(seng.channels[1].burstProb, 31 / 32))
sui.sel_line[P_PROB] = 2
sui:enc(3, 1)
check('prob mode line toggles probHit', seng.channels[1].probHit == true)
sui.sel_line[P_PROB] = 3
sui:enc(3, 1)
check('alt-trig line steps altTrig to step', seng.channels[1].altTrig == 1)
sui.sel_line[P_PROB] = 4   -- op-ratio seq trig (ONE switch, all four B lanes)
sui:enc(3, 1)
check('prob page op seq trig line steps to step', seng.channels[1].opSeqTrig == 1)
sui:enc(3, -1)
check('prob page op seq trig line steps back to hold', seng.channels[1].opSeqTrig == 0)
sui.sel_line[P_PROB] = 5   -- op-env seq trig (ONE switch, all four op envs)
sui:enc(3, 1)
check('prob page op env trig line steps to step', seng.channels[1].opEnvTrig == 1)
sui:enc(3, -1)
check('prob page op env trig line steps back to hold', seng.channels[1].opEnvTrig == 0)

-- mix page in signal-flow order: line 1 = algo, 2 = mod index, lines 3..6 = op1..op4
-- level, 7 = fm feedback, 8 = filter, 9 = pan, 10 = channel level/volume. All four
-- op ratios are sequenced (edited on the per-param seq pages), and chorus was
-- removed, so absent here.
sui:set_page(P_MIX)
check('mix page_lines is signal-flow order (alg, index, op1 l ...)',
  sui:page_lines()[1][1] == 'alg' and sui:page_lines()[2][1] == 'index'
  and sui:page_lines()[3][1] == 'op1 l')
check('mix page has 10 lines (filter added)', #sui:page_lines() == 10)
sui.sel_line[P_MIX] = 9   -- pan
seng.channels[1].pan = 0
sui:enc(3, -1)
check('mix page pan line steps pan left down the -1..1 grid',
  in_set(seng.channels[1].pan, GridUI.PAN_VALUES) and seng.channels[1].pan < 0)
sui.sel_line[P_MIX] = 10  -- channel level (volume)
seng.channels[1].level = 1.0
sui:enc(3, -1)
check('mix page level line steps channel level down the 0..1 grid',
  in_set(seng.channels[1].level, GridUI.OP_LEVEL_VALUES) and seng.channels[1].level < 1.0)
sui.sel_line[P_MIX] = 8   -- DJ filter position
seng.channels[1].filterPos = 0
sui:enc(3, -1)
check('mix page filter line steps toward the low-pass down the -1..1 grid',
  in_set(seng.channels[1].filterPos, GridUI.FILTER_VALUES) and seng.channels[1].filterPos < 0)
sui.sel_line[P_MIX] = 3   -- op1 level
seng.channels[1].opLevel1 = 1.0
sui:enc(3, -1)
check('mix page op1 line steps opLevel1 down the 0..1 grid',
  in_set(seng.channels[1].opLevel1, GridUI.OP_LEVEL_VALUES) and seng.channels[1].opLevel1 < 1.0)
sui.sel_line[P_MIX] = 2   -- mod index (line 1 is algo now)
seng.channels[1].modIndex = 4
sui:enc(3, 1)
check('mix page index line steps modIndex up its grid',
  in_set(seng.channels[1].modIndex, GridUI.MOD_INDEX_VALUES) and seng.channels[1].modIndex ~= 4)

-- op ratios are sequenced, each on its own per-param page (opRatio2 = page 3).
sui:set_page(P_OPR2)
sui.sel_ch = 0
sui.sel_lane = 1
check('opRatio2 page main_param is opRatio2', sui:main_param() == 'opRatio2')
check('opRatio2 page keeps grid selectedParam = opRatio2', sctl.selectedParam == 'opRatio2')
seng.channels[1].opRatio2 = seqx.new{1}
sui.sel_step = 0
sui:enc(3, 1)
check('opRatio2 E3 steps up the curated ratio grid (A = role set)',
  in_set(seqx.values(seng.channels[1].opRatio2)[1],
         GridUI.op_ratio_set(seng.channels[1].algo, 2))
  and seqx.values(seng.channels[1].opRatio2)[1] ~= 1)

-- perf page: line 1 = run, then reset/oct/rate/quantize come from the shared tables
sui:set_page(P_PERF)
check('perf page_lines line 1 is run, line 2 reset',
  sui:page_lines()[1][1] == 'run' and sui:page_lines()[2][1] == 'reset')
sui.sel_line[P_PERF] = 2   -- reset
sui:enc(3, 3)
check('perf E3 lands in RESET_INTERVALS', in_set(seng.channels[1].resetInterval, GridUI.RESET_INTERVALS))
sui.sel_line[P_PERF] = 3   -- oct
sui:enc(3, 1)
check('oct E3 lands in OCTAVE_VALUES', in_set(seng.channels[1].octave, GridUI.OCTAVE_VALUES))
check('oct E3 stepped up one octave', seng.channels[1].octave == 1)
sui:enc(3, -1)  -- restore octave 0: the fire tests below expect an unshifted c1
sui.sel_line[P_PERF] = 4   -- rate
sui:enc(3, 1)
check('rate E3 lands in RATE_VALUES', in_set(seng.channels[1].rate, GridUI.RATE_VALUES))

-- scale page: E2 walks root -> 12 keys; E3 edits the SELECTED channel's root
-- (per-channel now, -12..+11 signed transpose, no wrap; mask stays global)
sui:set_page(P_SCALE)
local sch = sui.sel_ch + 1
seng.channels[sch].root = 0
sui.sel_line[P_SCALE] = 1            -- root
sui:enc(3, 2)
check('scale E3 raises the selected channel root by semitones', seng.channels[sch].root == 2)
sui:enc(3, -5)                 -- goes negative (down-octave transpose), no wrap
check('scale root goes negative, clamped not wrapped', seng.channels[sch].root == -3)
seng.scale = {0, 4, 7}
sui.sel_line[P_SCALE] = 2 + 2        -- key for pitch class 2 (D)
sui:enc(3, 1)
check('scale E3 right adds a key to the mask', in_set(2, seng.scale) and #seng.scale == 4)
sui:enc(3, -1)
check('scale E3 left removes the key', not in_set(2, seng.scale) and #seng.scale == 3)

-- perf page: per-channel quantize on line 5 (after run/reset/oct/rate), curated set
sui:set_page(P_PERF)
seng.channels[1].quantize = 8
sui.sel_line[P_PERF] = 5
sui:enc(3, 1)
check('perf E3 steps quantize up the curated set', seng.channels[1].quantize == 12)
check('perf quantize lands in QUANTIZE_VALUES', in_set(seng.channels[1].quantize, GridUI.QUANTIZE_VALUES))

-- restore musical state the fire tests below assume (unshifted c1, major)
seng.channels[1].root = 0     -- root is per-channel now
seng.scale = scales.by_name.major
set_quant(seng, 32)

-- fire reactivity: ghost note recorded, dirty set, tick repaints + clears
sui:set_page(1)
sui.dirty = false
seng.channels[1].reps = seqx.new{1}
seng.channels[1].note = seqx.new{0}
seng:launch(1)  -- single-shot fires once on launch
check('fire records ghost note (degree 0 major = c1)', sui.last_note[0] == 'c1')
check('fire marks screen dirty', sui.dirty == true)
sui:tick()
check('tick repaints and clears dirty', sui.dirty == false)
screen._reset()
sui:redraw()
-- the per-channel column draws ch0's note letter ('c1') after it fired
local letter_drawn = false
for _, cl in ipairs(screen.calls) do
  if cl[1] == 'text' and cl[2] == 'c1' then letter_drawn = true end
end
check('channel column draws note letter after fire', letter_drawn)

-- grid mode buttons drive the screen tab (grid -> screen sync)
sui:set_page(P_NOTE)  -- selectedParam = 'note'
sctl:press(11, 6)  -- MIX on the grid
sui:redraw()
check('grid MIX press switches screen to mix page', sui.page == P_MIX)
sctl:press(11, 6)  -- toggle MIX off
sctl:press(13, 6)  -- PROB on the grid
sui:redraw()
check('grid PROB press switches screen to prob page', sui.page == P_PROB)
sctl:press(13, 6)  -- toggle PROB off
sui:redraw()
check('grid mode off returns screen to the selectedParam seq page', sui.page == P_NOTE)

-- channel focus follows the grid (grid -> screen sync)
sui.sel_ch = 0
sctl:press(2, 3)        -- step press on channel row 3 (0-based)
sui:redraw()
check('grid channel edit pulls screen focus to that channel', sui.sel_ch == 3)
sctl:close_picker()     -- that press opened a step picker; dismiss it
-- E1 stays free between grid touches: focus is edge-triggered, not pinned
sui:enc(1, -1)
check('E1 still moves screen channel after a grid focus', sui.sel_ch == 2)
sui:redraw()
check('redraw does not yank focus back to the grid channel', sui.sel_ch == 2)
-- re-editing the same grid channel re-pulls focus (focusSeq bumped)
sctl:press(0, 3)        -- another step press on channel row 3
sui:redraw()
check('re-touching the same grid channel re-pulls focus', sui.sel_ch == 3)
sctl:close_picker()
sui.sel_ch = 0  -- restore for the channel-1 edit tests below

-- grid mid-gesture: footer swaps step squares for the status line
sctl:press(14, 7)  -- enter randomize action mode on the grid
screen._reset()
sui:redraw()
local status_drawn = false
for _, cl in ipairs(screen.calls) do
  if cl[1] == 'text' and cl[2] == sctl.status then status_drawn = true end
end
check('grid action mode swaps footer for status', status_drawn)
sctl:press(14, 7)  -- leave action mode

-- run line now lives on the perf page (line 1): E3 right launches, left stops
sui:set_page(P_PERF)
seng.channels[1].reps = seqx.new{2, 2}  -- looping again (fire test made it single-shot)
sui.sel_line[P_PERF] = 1  -- run
sui:enc(3, 1)
check('perf run line E3 right launches the channel', seng:is_running(1) == true)
sui:enc(3, -1)
check('perf run line E3 left stops the channel', seng:is_running(1) == false)

-- E2 walks steps across channels, flowing off one channel onto the next (div page)
sui:set_page(P_DIV)
for i = 1, 6 do seng.channels[i].div = seqx.new{4, 8} end  -- 2 steps + add slot = 3 positions
sui.sel_ch = 0; sui.sel_lane = 1; sui.sel_step = 0
sui:enc(2, 1)
check('E2 advances within a channel', sui.sel_ch == 0 and sui.sel_step == 1)
sui:enc(2, 1)
check('E2 reaches the `_` add slot after the last step',
  sui.sel_ch == 0 and sui.sel_step == 2 and sui:_on_add_slot())
sui:enc(2, 1)
check('E2 flows past `_` onto the next channel', sui.sel_ch == 1 and sui.sel_step == 0)
sui:enc(2, -1)
check('E2 flows backward onto the previous channel`s add slot',
  sui.sel_ch == 0 and sui:_on_add_slot())

-- "scroll down switches to B": E2 past the last channel of lane 1 reveals lane 2
sui:set_page(P_NOTE)
for i = 1, 6 do seng.channels[i].note = seqx.new{0}; seng.channels[i].noteB = seqx.new{0} end
sui.sel_ch = 5; sui.sel_lane = 1; sui.sel_step = 1  -- ch6 add slot (1 step + add)
check('cursor on last channel add slot of lane A', sui.sel_lane == 1 and sui:_on_add_slot())
sui:enc(2, 1)
check('E2 past lane A last channel switches to lane B (scroll -> B)',
  sui.sel_lane == 2 and sui.sel_ch == 0 and sui.sel_step == 0 and sui:layer() == 'B')
sui:enc(2, -1)
check('E2 back from lane B returns to lane A last channel',
  sui.sel_lane == 1 and sui.sel_ch == 5)

-- `_` add slot: increment appends a step at the lowest picker value (div page, ch0)
sui:set_page(P_DIV)
seng.channels[1].div = seqx.new{4, 8}
sui.sel_ch = 0; sui.sel_lane = 1; sui.sel_step = 2  -- ch0 add slot (div len 2)
sui:enc(3, 1)
check('E3 on `_` appends a step (div len 3)', seqx.len(seng.channels[1].div) == 3)
check('appended step = lowest picker value',
  seqx.values(seng.channels[1].div)[3] == GridUI.STEP_PICKER_VALUES.div[1])
check('cursor now sits on the appended step', not sui:_on_add_slot())

-- decrement below the lowest value removes the step again
sui:enc(3, -1)
check('E3 decrement below bottom removes the step', seqx.len(seng.channels[1].div) == 2)
check('cursor back on the `_` add slot', sui:_on_add_slot())

-- the last remaining step clamps instead of vanishing
seng.channels[1].note = seqx.new{0}
sui:set_page(P_NOTE)
sui.sel_ch = 0; sui.sel_lane = 1; sui.sel_step = 0
sui:enc(3, -1)
check('last remaining step clamps, never removed', seqx.len(seng.channels[1].note) == 1)

-- K2/K3 page back/forward, clamped at the ends; grid selectedParam + modes follow
sui:set_page(P_NOTE)
sui:key(3, 1)
check('K3 pages forward note -> opRatio1 (grid selectedParam follows)',
  sui.page == 2 and sctl.selectedParam == 'opRatio1')
sui:set_page(10)  -- opEnv4, the last sequence page
sui:key(3, 1)
check('K3 opEnv4 -> perf (grid perfMode follows)',
  sui.page == P_PERF and sctl.perfMode == true)
sui:key(2, 1)
check('K2 perf -> opEnv4 (perfMode off, selectedParam follows)',
  sui.page == 10 and sctl.perfMode == false and sctl.selectedParam == 'opEnv4')
sui:set_page(P_NOTE)
sui:key(2, 1)
check('K2 clamps at the first page (no wrap)', sui.page == P_NOTE)
sui:set_page(P_MIX)
sui:key(3, 1)
check('K3 clamps at the last page (no wrap)', sui.page == P_MIX)

-- lane 2 = the B (offset) layer, reached directly by sel_lane = 2 (or E2 scroll). It
-- snaps to the offset set (literal 0 = no offset, prepended to the picker grid).
sui:set_page(P_NOTE)
sui.sel_ch = 0
sui.sel_lane = 2
seng.channels[1].noteB = seqx.new{0}
sui:enc(2, 0)        -- sync the grid's paramLayer to the lane
check('lane 2 on a B-capable page is the B layer',
  sui:layer() == 'B' and sctl.paramLayer == 'B' and sui:main_param() == 'note')
sui.sel_step = 0
sui:enc(3, 1)
check('lane-B E3 steps note B up from 0 onto the grid',
  approx(seqx.values(seng.channels[1].noteB)[1], GridUI.STEP_PICKER_VALUES.note[2]))
sui:enc(3, -1)
check('lane-B E3 decrement returns to 0 (no offset)',
  seqx.values(seng.channels[1].noteB)[1] == 0)
sui.sel_step = 1  -- `_` add slot
sui:enc(3, 1)
check('lane-B `_` appends 0', seqx.len(seng.channels[1].noteB) == 2
  and seqx.values(seng.channels[1].noteB)[2] == 0)

-- div/reps lane 2 is `reps` (a paired A-layer lane), not a B offset
sui:set_page(P_DIV)
sui.sel_lane = 2
check('div page lane 2 is the reps A lane', sui:main_param() == 'reps' and sui:layer() == 'A')
sui.sel_lane = 1

-- focused value token gets an underscore (rect 1px tall, token width)
sui:set_page(P_DIV)
seng.channels[1].div = seqx.new{16, 8}
sui.sel_ch = 0; sui.sel_lane = 1; sui.sel_step = 0
sui:enc(2, 0)
screen._reset()
sui:redraw()
local underlined = false
for _, cl in ipairs(screen.calls) do
  if cl[1] == 'rect' and cl[5] == 1 and cl[4] == screen.text_extents('16') then underlined = true end
end
check('focused value token is underscored', underlined)

-- system menu focus: tick must not draw while the menu is up
norns = { menu = { status = function() return true end } }
sui.dirty = true
screen._reset()
sui:tick()
check('tick never draws over the system menu', #screen.calls == 0 and sui.dirty == true)
norns = nil
sui:tick()
check('tick repaints once focus returns', sui.dirty == false)

-- ---- params_sync: bidirectional param <-> engine sync -------------------
local ParamsSync = require 'params_sync'
local Paramset = require 'paramset'
print('params_sync:')

-- every group's declared size must equal the number of params that follow it
-- (channel groups are adjacent, so counting to the next group is exact)
local function group_counts_ok(fake)
  local i = 1
  while i <= #fake.list do
    if fake.list[i].t == 'group' then
      local j = i + 1
      while j <= #fake.list and fake.list[j].t ~= 'group' do j = j + 1 end
      if (j - i - 1) ~= fake.list[i].n then return false end
      i = j
    else
      i = i + 1
    end
  end
  return true
end

clock._reset()
math.randomseed(7)
local peng = Burst.new()
for i = 1, Burst.NUM_CHANNELS do peng:randomize(i) end
peng.channels[1].noteB = seqx.new{3}
local pctl = GridUI.new(peng, mock_grid())
local pui = ScreenUI.new(peng, pctl)
local fake = Paramset.new()
local psync = ParamsSync.new{engine = peng, controller = pctl, params = fake, scales = scales}
psync:add_params()
psync:attach()

-- defaults captured from the live (randomized) engine state
check('group sizes exact by construction', group_counts_ok(fake))
check('text default reflects randomized engine values',
  vals_eq(ParamsSync.from_text('note', 'A', fake:get('ch1_note_a')),
          seqx.values(peng.channels[1].note)))
check('seeded noteB default round-trips', fake:get('ch1_note_b') == '3')
check('B-layer zero default shows as 0', fake:get('ch1_opRatio1_b') == '0')

-- bang idempotence: firing every action re-applies the same engine values
local before = {}
for i = 1, 6 do
  before[i] = {}
  for _, p in ipairs(GridUI.PARAMS) do
    local t = {}
    for _, v in ipairs(seqx.values(peng.channels[i][p])) do t[#t + 1] = v end
    before[i][p] = t
  end
end
fake:bang()
psync:enable_triggers()
local bang_same = true
for i = 1, 6 do
  for _, p in ipairs(GridUI.PARAMS) do
    if not vals_eq(before[i][p], seqx.values(peng.channels[i][p])) then bang_same = false end
  end
end
check('params:bang() leaves engine values unchanged', bang_same)

-- param -> engine: text param installs a sequence via the shared commit path
fake:set('ch1_note_a', '0 3 5')
check('text edit installs sequence', vals_eq(seqx.values(peng.channels[1].note), {0, 3, 5}))
check('text normalized after edit', fake:get('ch1_note_a') == '0 3 5')

-- cursor pair: step selects, val edits at the cursor (index-based)
fake:set('ch1_note_a_step', 2)
check('step cursor refreshes val param',
  fake:get('ch1_note_a_val') == ParamsSync.value_to_index('note', 'A', 3))
fake:set('ch1_note_a_val', 9)  -- note layout: index 9 -> value 8
check('val edit writes at cursor', seqx.values(peng.channels[1].note)[2] == 8)
check('text reflects val edit', fake:get('ch1_note_a') == '0 8 5')
fake:set('ch1_note_a_step', 99)
check('step cursor clamps to length', fake:get('ch1_note_a_step') == 3)

-- B layer: index 0 = literal 0 offset (no offset)
fake:set('ch1_note_b_val', 5)
check('B val index 5 -> note offset', approx(seqx.values(peng.channels[1].noteB)[1],
  ParamsSync.index_to_value('note', 'B', 5)))
fake:set('ch1_note_b_val', 0)
check('B val index 0 -> literal 0', seqx.values(peng.channels[1].noteB)[1] == 0)
check('B text shows 0', fake:get('ch1_note_b') == '0')

-- div/reps/harm have no B layer, so no B params exist for them
check('div has no B param', fake:lookup_param('ch1_div_b') == nil)
check('reps has no B param', fake:lookup_param('ch1_reps_b') == nil)
check('harm has no param at all', fake:lookup_param('ch1_harm_a') == nil)

-- op1 ratio is sequenced now (no static ch1_ratio1 scalar); op levels are 0..31 grid scalars.
check('no static op1-ratio scalar param', fake:lookup_param('ch1_ratio1') == nil)
check('op1 ratio has a sequenced A block', fake:lookup_param('ch1_opRatio1_a') ~= nil)
fake:set('ch1_opRatio1_a', '1.5 2 3')
check('op1 ratio text installs a curated-ratio sequence',
  vals_eq(seqx.values(peng.channels[1].opRatio1), {1.5, 2, 3}))
check('op1 ratio has a B (index-offset) block', fake:lookup_param('ch1_opRatio1_b') ~= nil)
fake:set('ch1_level3', 0)
check('op level 0 -> 0.0', approx(peng.channels[1].opLevel3, 0))
fake:set('ch1_level3', 31)
check('op level 31 -> 1.0', approx(peng.channels[1].opLevel3, 1))

-- op2/3/4 ratios are sequenced: text + cursor blocks like note/level, A value + B
-- offset, snapping every token to the curated ratio grid.
fake:set('ch1_opRatio2_a', '1.5 2 3')
check('op2 ratio text installs a curated-ratio sequence',
  vals_eq(seqx.values(peng.channels[1].opRatio2), {1.5, 2, 3}))
check('op2 ratio text normalized back (curated tokens)', fake:get('ch1_opRatio2_a') == '1.5 2 3')
fake:set('ch1_opRatio2_b', '0 4')
check('op2 ratio B index-offset parses (0 = no shift)',
  vals_eq(seqx.values(peng.channels[1].opRatio2B), {0, 4}))
check('op2 ratio has a B param (index-offset layer)', fake:lookup_param('ch1_opRatio2_b') ~= nil)

-- op-ratio seq trig mode param (hold/step option, like alt trig): ONE switch
-- for all four op-ratio B lanes (the per-op params are gone)
fake:set('ch1_op_trig', 2)  -- option 2 = step
check('op seq trig param sets step', peng.channels[1].opSeqTrig == 1)
fake:set('ch1_op_trig', 1)  -- option 1 = hold
check('op seq trig param sets hold', peng.channels[1].opSeqTrig == 0)
check('per-op ratio trig params are gone', fake:lookup_param('ch1_op1_trig') == nil)

-- op-env seq trig mode param: same single hold/step switch for all four op envs
fake:set('ch1_openv_trig', 2)  -- option 2 = step
check('op env trig param sets step', peng.channels[1].opEnvTrig == 1)
fake:set('ch1_openv_trig', 1)  -- option 1 = hold
check('op env trig param sets hold', peng.channels[1].opEnvTrig == 0)
check('per-op env trig params are gone', fake:lookup_param('ch1_opEnv1_trig') == nil)

-- reps rest tokens: rN <-> reps (1-N), so r1=0, r2=-1, r4=-3
fake:set('ch1_reps_a', '2 r1 r4')
check('reps rest tokens parse: r1->0, r4->-3',
  seqx.values(peng.channels[1].reps)[2] == 0 and seqx.values(peng.channels[1].reps)[3] == -3)
check('reps rests format back to rN', fake:get('ch1_reps_a') == '2 r1 r4')

-- channel level is a static scalar on the 0..31 grid (no longer a sequenced text param)
check('no sequenced channel-level text param', fake:lookup_param('ch1_level_a') == nil)
fake:set('ch1_level', 0)
check('channel level 0 -> 0.0', approx(peng.channels[1].level, 0))
fake:set('ch1_level', 31)
check('channel level 31 -> 1.0', approx(peng.channels[1].level, 1))

-- pan is a static scalar on a 0..31 grid mapped to -1..1 (index 16 = centre)
fake:set('ch1_pan', 1)
check('pan 1 -> hard left (-1)', approx(peng.channels[1].pan, -1))
fake:set('ch1_pan', 16)
check('pan 16 -> dead centre (0)', approx(peng.channels[1].pan, 0))
fake:set('ch1_pan', 31)
check('pan 31 -> hard right (+1)', approx(peng.channels[1].pan, 1))
peng.channels[1].pan = 0
psync:reflect_scalars(1)
check('engine pan reflects back to param index 16 (centre)', fake:get('ch1_pan') == 16)

-- filter: the strip scalar on the same bipolar 0..31 grid as pan (index 16 =
-- centre = no filter). Its param action pushes straight to the SC engine
-- (guarded on the global, absent off-hardware) as well as mutating the channel.
fake:set('ch1_filter', 1)
check('filter 1 -> LP extreme (-1)', approx(peng.channels[1].filterPos, -1))
fake:set('ch1_filter', 16)
check('filter 16 -> off (0)', approx(peng.channels[1].filterPos, 0))
fake:set('ch1_filter', 31)
check('filter 31 -> HP extreme (+1)', approx(peng.channels[1].filterPos, 1))
peng.channels[1].filterPos = 0
psync:reflect_scalars(1)
check('engine filter state reflects back silently', fake:get('ch1_filter') == 16)

-- engine/UI -> params: silent reflection only (zero action fires)
local f0 = fake.fires
pctl:press(0, 7)  -- row 7 col 0 = div/reps page
pctl:press(0, 6)  -- row 6 col 0 = note page
pctl:press(0, 0)  -- open step picker ch0 col0
pctl:press(5, 6)  -- pick note value 5 (value grid on rows 6-7)
check('grid step edit reflects into text param', fake:get('ch1_note_a') == '5 8 5')
pctl:press(13, 6)  -- PROB mode
pctl:press(0, 0)   -- prob cell -> 32-value scalar picker
pctl:press(15, 6)  -- pick value 16/32 = 0.5 -> prob option index 16
check('grid prob edit reflects into param', fake:get('ch1_prob') == 16)
pctl:press(13, 6)  -- exit PROB
check('grid edits fired zero param actions', fake.fires == f0)

-- screen edit reflects too (same set_scalar path)
pui:set_page(3)  -- perf page
pui.sel_ch = 0
pui.sel_line[3] = 2  -- octave line
pui:enc(3, peng.channels[1].octave < 2 and 1 or -1)
check('screen perf edit reflects octave param',
  fake:get('ch1_octave') == peng.channels[1].octave)
pui:set_page(1)
check('screen edits fired zero param actions', fake.fires == f0)

-- run param <-> engine transport (both directions)
peng.channels[1].reps = seqx.new{2, 2}
fake:set('ch1_run', 1)
check('run param launches channel', peng:is_running(1) == true)
fake:set('ch1_run', 0)
check('run param stops channel', peng:is_running(1) == false)
local f1 = fake.fires
peng:launch(1)
check('engine launch reflects run=1 silently', fake:get('ch1_run') == 1 and fake.fires == f1)
peng:stop(1)
check('engine stop reflects run=0 silently', fake:get('ch1_run') == 0)

-- copy/paste: snapshot ch1's MAIN (A-layer) sequins and paste into ch5
fake:set('ch1_div_a', '4 8 16')
fake:set('ch1_note_a', '1 2 3 4')
-- ...and the per-channel MIX-page static scalars travel with copy/paste too
peng.channels[1].level = 0.7
peng.channels[1].opLevel2 = 0.3
peng.channels[1].modIndex = 9
peng.channels[1].fmFeedback = 3
peng.channels[1].algo = 5
peng.channels[1].pan = -1
peng.channels[1].filterPos = -0.5
fake:set('ch1_copy', 1)
fake:set('ch5_paste', 1)
local cp_ok = true
for _, p in ipairs(GridUI.PARAMS) do
  if not vals_eq(seqx.values(peng.channels[5][p]),
                 seqx.values(peng.channels[1][p])) then cp_ok = false end
end
check('copy+paste duplicates all MAIN sequins across channels', cp_ok)
check('paste reflected into dest text param',
  vals_eq(ParamsSync.from_text('note', 'A', fake:get('ch5_note_a')), {1, 2, 3, 4}))
local mix_ok = approx(peng.channels[5].level, 0.7)
  and approx(peng.channels[5].opLevel2, 0.3)
  and peng.channels[5].modIndex == 9
  and peng.channels[5].fmFeedback == 3 and peng.channels[5].algo == 5
  and approx(peng.channels[5].pan, -1)
check('copy+paste duplicates MIX-page static scalars across channels', mix_ok)
check('copy+paste carries the filter strip scalar too',
  approx(peng.channels[5].filterPos, -0.5))
check('paste reflected filter into dest scalar param',
  fake:get('ch5_filter') == 9)  -- -0.5 -> grid index round(-0.5*15+16) = 9
check('paste reflected into dest scalar param', fake:get('ch5_algorithm') == 5)
check('paste reflected pan into dest scalar param', fake:get('ch5_pan') == 1)  -- pan -1 -> grid index 1

-- clear: resets BOTH layers (A + B where present) to defaults, so the channel is blank
fake:set('ch6_div_a', '4 8 16')
fake:set('ch6_note_b', '1 2 3')  -- B-layer offset is cleared too now
fake:set('ch6_clear', 1)
-- assert against the module's own defaults so this follows DEFAULT_VALUE edits
local cl_ok = true
for _, p in ipairs(GridUI.PARAMS) do
  local v = seqx.values(peng.channels[6][p])
  if #v ~= 1 or not approx(v[1], GridUI.DEFAULT_VALUE[p]) then cl_ok = false end
  if GridUI.has_b(p) then  -- every B-layer default is 0 (no offset)
    local vb = seqx.values(peng.channels[6][p .. 'B'])
    if #vb ~= 1 or not approx(vb[1], 0) then cl_ok = false end
  end
end
check('clear resets every sequence on both layers to defaults', cl_ok)
check('clear resets the ALT (B) layer too',
  vals_eq(seqx.values(peng.channels[6].noteB), {0}))

-- randomize trigger: result reflects exactly (grid-reachability contract)
fake:set('ch4_randomize', 1)
local rt_ok = true
for _, p in ipairs(GridUI.PARAMS) do
  if not vals_eq(ParamsSync.from_text(p, 'A', fake:get('ch4_' .. p .. '_a')),
                 seqx.values(peng.channels[4][p])) then rt_ok = false end
end
check('randomize trigger reflects all sequences exactly', rt_ok)

-- grid QNT page edit reflects into the per-channel param
pctl:press(15, 6)  -- enter the per-channel QNT page
pctl:press(5, 0)   -- ch1 row, col 5 -> QUANTIZE_VALUES[6] = 16
check('grid quantize edit sets the channel value', peng.channels[1].quantize == 16)
check('grid quantize edit reflects to chN_quantize param',
  fake:get('ch1_quantize') == GridUI.nearest_index(GridUI.QUANTIZE_VALUES, 16))
pctl:press(15, 6)  -- leave the QNT page

-- keymask: the note mask is viewed/edited/stored like a sequence string
check('mask_to_text renders pitch-class names',
  ParamsSync.mask_to_text({0, 2, 4, 5, 7, 9, 11}) == 'C D E F G A B')
check('mask_from_text parses names + numbers, dedups, keeps order',
  vals_eq(ParamsSync.mask_from_text('c e g 7 bb'), {0, 4, 7, 10}))
fake:set('keymask', 'g c e')  -- commits through controller:set_mask (sorts)
check('keymask param installs sorted mask on engine', vals_eq(peng.scale, {0, 4, 7}))
check('keymask text reflected back canonical (sorted names)', fake:get('keymask') == 'C E G')
fake:set('keymask', '')       -- refuse to empty the scale; restore the display
check('empty keymask refused, display restored',
  vals_eq(peng.scale, {0, 4, 7}) and fake:get('keymask') == 'C E G')
-- picking a scale preset keeps the keymask text in step
fake:set('scale', 2)  -- scales.names[2] = 'major'
check('scale preset updates keymask text',
  fake:get('keymask') == ParamsSync.mask_to_text(scales.by_name.major))

-- render coalescing: actions raise the flag, flush repaints once
psync.render_pending = false
fake:set('ch1_prob', 3)
check('param action requests coalesced render', psync.render_pending == true)
psync:flush()
check('flush clears the pending render', psync.render_pending == false)

-- pset-load hook: action_read re-reflects everything
peng.channels[5].burstProb = 0.5
fake.action_read()
check('action_read reflects engine state into params', fake:get('ch5_prob') == 16)

-- ---- outputs: per-channel midi / crow / i2c routing ----------------------
local Outputs = require 'outputs'
print('outputs:')

local midi_log = {}
local fake_midi = {
  connect = function(dev)
    return {
      dev = dev,
      note_on   = function(_, note, vel, ch) midi_log[#midi_log + 1] = {'on', note, vel, ch} end,
      note_off  = function(_, note, vel, ch) midi_log[#midi_log + 1] = {'off', note, vel, ch} end,
      cc        = function(_, cc, val, ch) midi_log[#midi_log + 1] = {'cc', cc, val, ch} end,
      pitchbend = function(_, val, ch) midi_log[#midi_log + 1] = {'pb', val, ch} end,
      start     = function(_) midi_log[#midi_log + 1] = {'start'} end,
      stop      = function(_) midi_log[#midi_log + 1] = {'stop'} end,
      clock     = function(_) midi_log[#midi_log + 1] = {'clock'} end,
    }
  end,
}
local crow_log = {}
local function fake_crow_out(n)
  return setmetatable({volts = 0, action = ''}, {
    __call = function(self) crow_log[#crow_log + 1] = {'exec', n, self.action} end,
  })
end
local fake_crow = {
  output = {fake_crow_out(1), fake_crow_out(2), fake_crow_out(3), fake_crow_out(4)},
  ii = {
    jf = {
      mode       = function(m) crow_log[#crow_log + 1] = {'jf_mode', m} end,
      play_voice = function(voice, v, l) crow_log[#crow_log + 1] = {'jf', voice, v, l} end,
    },
    er301 = {
      cv       = function(p, v) crow_log[#crow_log + 1] = {'301cv', p, v} end,
      tr_pulse = function(p) crow_log[#crow_log + 1] = {'301tr', p} end,
    },
  },
}

-- pure conversions
check('freq_to_note A4 = 69', approx(Outputs.freq_to_note(440), 69))
check('note_to_volts C5 = +1V', approx(Outputs.note_to_volts(72), 1))
check('velocity scales level linearly', Outputs.velocity(0.5) == 64)
check('velocity floors at 1', Outputs.velocity(0.001) == 1)
check('velocity caps at 127', Outputs.velocity(1.5) == 127)
-- ratio_ceiling: FM ratio -> the streamed CC's ceiling (0..127 over the curated span)
check('ratio_ceiling: max ratio = 127', approx(Outputs.ratio_ceiling(14), 127))
check('ratio_ceiling: min ratio = 0', approx(Outputs.ratio_ceiling(0.125), 0))
-- cv_ceiling: FM ratio -> the ER-301 CV stream's ceiling (0..OP_CV_MAX volts)
check('cv_ceiling: max ratio = OP_CV_MAX volts', approx(Outputs.cv_ceiling(14), Outputs.OP_CV_MAX))
check('cv_ceiling: min ratio = 0V', approx(Outputs.cv_ceiling(0.125), 0))
-- curve_seg: SC Env interpolation (a->b at pos, curvature)
check('curve_seg: linear midpoint', approx(Outputs.curve_seg(0, 1, 0.5, 0), 0.5))
check('curve_seg: clamps to a at pos<=0', Outputs.curve_seg(0, 1, 0, -4) == 0)
check('curve_seg: clamps to b at pos>=1', Outputs.curve_seg(0, 1, 1, -4) == 1)
check('curve_seg: negative curve is fast-start (>linear at midpoint)',
  Outputs.curve_seg(0, 1, 0.5, -4) > 0.5)
-- env_at: 0 before, rises through attack, peaks at end of attack, falls, 0 after
check('env_at: 0 at t=0', Outputs.env_at(0, 0.1, 0.2, 0, 0) == 0)
check('env_at: linear attack midpoint = 0.5', approx(Outputs.env_at(0.05, 0.1, 0.2, 0, 0), 0.5))
check('env_at: peak (=1) at end of attack', approx(Outputs.env_at(0.1, 0.1, 0.2, 0, 0), 1))
check('env_at: linear decay midpoint = 0.5', approx(Outputs.env_at(0.2, 0.1, 0.2, 0, 0), 0.5))
check('env_at: 0 after decay ends', Outputs.env_at(0.31, 0.1, 0.2, 0, 0) == 0)
check('bend_value: in-tune note is centered', Outputs.bend_value(60, 2) == 8192)
check('bend_value: +0.25 st over ±2 range = +1/8 scale', Outputs.bend_value(60.25, 2) == 8192 + 1024)
check('bend_value: -0.25 st over ±2 range = -1/8 scale', Outputs.bend_value(59.75, 2) == 8192 - 1024)
check('bend_value: narrower range bends further', Outputs.bend_value(60.25, 1) == 8192 + 2048)
check('bend_value: clamps to 14-bit ceiling', Outputs.bend_value(60.4, 0.3) == 16383)

clock._reset()
local ofake = Paramset.new()
local outs = Outputs.new{params = ofake, midi = fake_midi, crow = fake_crow}
outs:add_params()
check('outputs group size exact', group_counts_ok(ofake))
ofake:bang()
check('default destination is audio', outs:wants_audio(1) == true)
outs:note(1, {freq = 440, level = 0.5, dur = 0.5})
check('audio destination sends nothing external', #midi_log == 0 and #crow_log == 0)

-- helper: pull the value stream for one CC number out of the midi log, in order.
local function cc_values(log, ccnum)
  local out = {}
  for _, m in ipairs(log) do
    if m[1] == 'cc' and m[2] == ccnum then out[#out + 1] = m[3] end
  end
  return out
end
local function max_of(t) local m = 0 for _, v in ipairs(t) do m = math.max(m, v) end return m end

-- midi: note on with velocity/channel, note off after dur, then a per-op CC envelope
-- stream tracing each op's contour. env_stream_rate 100 Hz = 0.01s steps; a {0.01,0.02} linear
-- envelope traces 0 -> 127 (attack end) -> 64 (decay mid) -> 0.
ofake:set('ch1_output', Outputs.DEST.MIDI)
ofake:set('ch1_midi_chan', 5)
ofake:set('env_stream_rate', 100)
check('midi destination disables internal audio', outs:wants_audio(1) == false)
outs:note(1, {freq = 261.6256, level = 0.5,
  ratios = {14, 0.125, 14, 14},
  env_segs = {{0.01, 0.02, 0, 0}, {0.01, 0.02, 0, 0}, {0.01, 0.02, 0, 0}, {0.01, 0.02, 0, 0}},
  dur = 0.03})
check('midi pitch bend precedes the note, centered for an in-tune note',
  midi_log[1][1] == 'pb' and midi_log[1][2] == 8192 and midi_log[1][3] == 5)
check('midi note_on: middle C, vel 64, chan 5',
  midi_log[2][1] == 'on' and midi_log[2][2] == 60
  and midi_log[2][3] == 64 and midi_log[2][4] == 5)
check('op1 CC stream opens at 0 on the channel (cc20, attack starts from 0)',
  midi_log[3][1] == 'cc' and midi_log[3][2] == 20
  and midi_log[3][3] == 0 and midi_log[3][4] == 5)
clock._run_until(4)  -- advance well past the 0.03s stream + the note dur
local op1 = cc_values(midi_log, 20)
check('op1 CC stream peaks at the ratio ceiling (127) then returns to 0',
  max_of(op1) == 127 and op1[#op1] == 0)
check('op1 CC stream traces attack->peak->decay->0', (function()
  -- 0.01/0.02 linear @ 100Hz: values at t=0,0.01,0.02,0.03 = 0,127,64,0
  return #op1 == 4 and op1[1] == 0 and op1[2] == 127 and op1[3] == 64 and op1[4] == 0
end)())
check('op2 CC (min ratio -> ceiling 0) streams only silence',
  max_of(cc_values(midi_log, 21)) == 0)
check('midi note_off still scheduled after dur',
  (function() for _, m in ipairs(midi_log) do if m[1] == 'off' and m[2] == 60 then return true end end end)())

-- op CC number 0 = that operator's CC is disabled (no stream for it)
ofake:set('ch1_op2_cc', 0)
midi_log = {}
outs:note(1, {freq = 261.6256, level = 0.5,
  ratios = {14, 14, 14, 14},
  env_segs = {{0.01, 0.02, 0, 0}, {0.01, 0.02, 0, 0}, {0.01, 0.02, 0, 0}, {0.01, 0.02, 0, 0}},
  dur = 0.03})
clock._run_until(8)
check('op2 cc=0 suppresses op2 stream (no cc21 traffic)', #cc_values(midi_log, 21) == 0)
check('op1/op3/op4 still stream', #cc_values(midi_log, 20) > 0
  and #cc_values(midi_log, 22) > 0 and #cc_values(midi_log, 23) > 0)
ofake:set('ch1_op2_cc', 21)  -- restore default

-- retrigger: a new hit bumps the CC-stream generation so the prior stream is cancelled
-- (its next step bails). The note itself is cut + retriggered as before.
midi_log = {}
local g0 = outs.stream_gen[1]
outs:note(1, {freq = 261.6256, level = 0.5, dur = 0.5,
  ratios = {1, 1, 1, 1}, env_segs = {{0.1, 0.2, 0, 0}, {0.1, 0.2, 0, 0}, {0.1, 0.2, 0, 0}, {0.1, 0.2, 0, 0}}})
outs:note(1, {freq = 261.6256, level = 0.9, dur = 0.5,
  ratios = {1, 1, 1, 1}, env_segs = {{0.1, 0.2, 0, 0}, {0.1, 0.2, 0, 0}, {0.1, 0.2, 0, 0}, {0.1, 0.2, 0, 0}}})
check('retrigger bumps the CC-stream generation twice', outs.stream_gen[1] == g0 + 2)
check('retrigger cuts the held note (an off precedes the second on)', (function()
  local ons, off_between = 0, false
  for _, m in ipairs(midi_log) do
    if m[1] == 'on' then ons = ons + 1 end
    if m[1] == 'off' and ons == 1 then off_between = true end
  end
  return ons == 2 and off_between
end)())
clock._run_until(16)
check('retrigger settles with two offs (the cut + one surviving timer)',
  (function() local n = 0 for _, m in ipairs(midi_log) do if m[1] == 'off' then n = n + 1 end end return n == 2 end)())

-- notes_off cancels a running CC stream and zeros any non-zero CC it left
ofake:set('env_stream_rate', 20)  -- 0.05s steps: stream stays open across the cancel
midi_log = {}
outs:note(1, {freq = 261.6256, level = 0.5, dur = 1.0,
  ratios = {14, 14, 14, 14}, env_segs = {{0.2, 0.8, 0, 0}, {0.2, 0.8, 0, 0}, {0.2, 0.8, 0, 0}, {0.2, 0.8, 0, 0}}})
clock._run_until(16.5)  -- part-way up the attack: CCs are non-zero and climbing
outs:notes_off(1)
local after_cancel = #midi_log
clock._run_until(40)
check('notes_off halts the CC stream (no further messages)', #midi_log == after_cancel)
check('notes_off zeroed the streamed CCs', outs.cc_last[1][1] == 0)
ofake:set('env_stream_rate', 100)  -- restore for later fire() tests

-- zero-level hits are silent everywhere (matches the internal voice)
midi_log = {}
outs:note(1, {freq = 440, level = 0, dur = 0.5})
check('level 0 sends no midi', #midi_log == 0)

-- channel stop / cleanup flushes hanging notes
outs:note(1, {freq = 440, level = 0.5, dur = 9})
midi_log = {}
outs:notes_off(1)
check('notes_off flushes the hanging note', #midi_log == 1 and midi_log[1][1] == 'off')
clock._run_until(100)
check('flushed note\'s stale timer stays silent', #midi_log == 1)

-- crow 1+2 / 3+4: v/oct on the odd output, level-scaled envelope on the even
ofake:set('ch2_output', Outputs.DEST.CROW12)
crow_log = {}
outs:note(2, {freq = 523.2511, level = 0.5, dur = 0.5})
check('crow 1+2 sets v/oct pitch on out 1', approx(fake_crow.output[1].volts, 1))
check('crow 1+2 fires envelope on out 2', #crow_log == 1 and crow_log[1][1] == 'exec'
  and crow_log[1][2] == 2 and crow_log[1][3]:find('to%(4%.00') ~= nil)
ofake:set('ch2_output', Outputs.DEST.CROW34)
crow_log = {}
outs:note(2, {freq = 261.6256, level = 1, dur = 0.5})
check('crow 3+4 routes to outputs 3/4', approx(fake_crow.output[3].volts, 0)
  and crow_log[1][2] == 4)

-- jf: mode 1 while any channel targets it, mode 0 when the last leaves
crow_log = {}
ofake:set('ch3_output', Outputs.DEST.JF)
check('first jf channel sends jf.mode(1)', crow_log[1] and crow_log[1][1] == 'jf_mode'
  and crow_log[1][2] == 1)
ofake:set('ch4_output', Outputs.DEST.JF)
check('second jf channel does not resend mode', #crow_log == 1)
outs:note(3, {freq = 261.6256, level = 0.5, dur = 0.5})
check('jf play_voice: voice = channel, v/oct, level volts', crow_log[2][1] == 'jf'
  and crow_log[2][2] == 3 and approx(crow_log[2][3], 0) and approx(crow_log[2][4], 2.5))
ofake:set('ch3_output', Outputs.DEST.AUDIO)
check('jf mode stays while one channel remains', #crow_log == 2)
ofake:set('ch4_output', Outputs.DEST.AUDIO)
check('last jf channel leaving sends jf.mode(0)', crow_log[3][1] == 'jf_mode'
  and crow_log[3][2] == 0)

-- er301: pitch v/oct + trigger on port = channel, then four per-op CV envelope streams
-- on ports ch*10+op (ch5 -> 51..54), each tracing its op's contour up to a cv_ceiling.
local function er301_cv(log, port)
  local out = {}
  for _, m in ipairs(log) do
    if m[1] == '301cv' and m[2] == port then out[#out + 1] = m[3] end
  end
  return out
end
ofake:set('ch5_output', Outputs.DEST.ER301)
ofake:set('env_stream_rate', 100)
crow_log = {}
outs:note(5, {freq = 523.2511, level = 0.5,
  ratios = {14, 0.125, 14, 14},
  env_segs = {{0.01, 0.02, 0, 0}, {0.01, 0.02, 0, 0}, {0.01, 0.02, 0, 0}, {0.01, 0.02, 0, 0}},
  dur = 0.03})
check('er301 pitch cv + tr on port = channel', crow_log[1][1] == '301cv' and crow_log[1][2] == 5
  and approx(crow_log[1][3], 1) and crow_log[2][1] == '301tr' and crow_log[2][2] == 5)
clock._run_until(104)  -- flush the 0.03s CV streams
local cv51 = er301_cv(crow_log, 51)
check('er301 op1 CV stream on port 51 peaks at cv_ceiling (5V) then returns to 0',
  max_of(cv51) == Outputs.OP_CV_MAX and cv51[#cv51] == 0)
check('er301 op1 CV stream traces attack->peak->decay->0', (function()
  -- 0.01/0.02 linear @ 100Hz, ratio 14 -> ceiling 5V: 0, 5, 2.5, 0
  return #cv51 == 4 and cv51[1] == 0 and approx(cv51[2], 5)
    and approx(cv51[3], 2.5) and cv51[4] == 0
end)())
check('er301 op2 CV (min ratio -> ceiling 0) streams only 0V', max_of(er301_cv(crow_log, 52)) == 0)
check('er301 op3/op4 CV streams present on ports 53/54',
  #er301_cv(crow_log, 53) > 0 and #er301_cv(crow_log, 54) > 0)
check('er301 sends no legacy brightness CV on port 11', #er301_cv(crow_log, 11) == 0)

-- burst integration: fire() respects wants_audio and forwards final values
engine = { trigs = 0 }
engine.trig = function() engine.trigs = engine.trigs + 1 end
local oeng = Burst.new()
oeng.outputs = outs
midi_log = {}
-- fire(ch, beat, freq, level, env1, env2, env3, env4, div, total, hit_idx)
oeng:fire(1, 0, 440, 0.5, 4, 3, 8, 8, 4, 1, 0)  -- ch1 midi: external only (pb + note + CC stream)
check('fire on midi channel skips engine.trig',
  engine.trigs == 0 and midi_log[1][1] == 'pb' and midi_log[2][1] == 'on')
ofake:set('ch1_output', Outputs.DEST.AUDIO_MIDI)
midi_log = {}
oeng:fire(1, 0, 440, 0.5, 4, 3, 8, 8, 4, 1, 0)
check('audio+midi fires both external + engine',
  engine.trigs == 1 and midi_log[1][1] == 'pb' and midi_log[2][1] == 'on')
oeng:fire(2, 0, 440, 0.5, 4, 3, 8, 8, 4, 1, 0)  -- ch2 is on crow 3+4
check('fire on crow channel skips engine.trig', engine.trigs == 1)
engine = nil

-- midi clock out: 24 ppqn stream bracketed by Start/Stop, gated by the param.
-- Start is DEFERRED to the next beat grid (clock_grid), not sent at the call,
-- so it lands on-grid in phase with the voices + bar-aligned reset Starts.
local function count_tag(log, tag)
  local n = 0
  for _, e in ipairs(log) do if e[1] == tag then n = n + 1 end end
  return n
end
clock._reset()
midi_log = {}
outs.clock_co = nil; outs.clock_started = false
ofake:set('midi_clock_out', 1)   -- off
outs:clock_start()
clock._run_until(2)
check('clock out off: clock_start is a no-op', #midi_log == 0)
clock._reset()                   -- back to beat 0 so the deferred Start has room
midi_log = {}
ofake:set('midi_clock_out', 2)   -- on
outs:clock_start()
check('clock start defers Start off the press instant', #midi_log == 0)
clock._run_until(3)              -- Start on the beat grid, then 24 ppqn (48 pulses / 2 beats)
check('Start lands on the beat grid then streams 24 ppqn',
  #midi_log == 49 and midi_log[1][1] == 'start' and midi_log[49][1] == 'clock')
outs:clock_stop()
check('clock stop sends MIDI Stop and halts the stream', midi_log[#midi_log][1] == 'stop')
local n_stopped = #midi_log
clock._run_until(8)
check('stopped stream sends nothing further', #midi_log == n_stopped)

-- start then stop INSIDE the pre-Start grid wait must not emit an orphan Stop
clock._reset()
midi_log = {}
outs:clock_start()               -- parks; Start pending at the next beat
outs:clock_stop()                -- cancel before the grid wait elapses
check('stop during a deferred start emits no orphan Stop', #midi_log == 0)

-- disabling the param mid-stream halts + emits Stop
clock._reset()
midi_log = {}
outs:clock_start()
clock._run_until(2)              -- Start has gone out
ofake:set('midi_clock_out', 1)   -- off mid-stream
check('disabling clock out mid-stream emits Stop', midi_log[#midi_log][1] == 'stop')

-- set_transport: edge-guarded Start/Stop driven by the engine run-state. A
-- relaunch (still running) must NOT re-arm Start; only 0<->1 edges send.
clock._reset()
ofake:set('midi_clock_out', 2)   -- on
outs.transport = false; outs.clock_co = nil; outs.clock_started = false
midi_log = {}
outs:set_transport(true)         -- first channel: 0 -> 1 (Start deferred)
outs:set_transport(true)         -- relaunch while running: no edge, no new arm
clock._run_until(2)
check('set_transport sends exactly one Start across a relaunch', count_tag(midi_log, 'start') == 1)
outs:set_transport(false)        -- last channel stops: 1 -> 0
check('set_transport 1->0 sends Stop', midi_log[#midi_log][1] == 'stop')
local n_after_stop = #midi_log
outs:set_transport(false)        -- already stopped: no edge
check('set_transport redundant stop is silent', #midi_log == n_after_stop)

-- clock_reset: re-send Start to realign downstream gear, only once the stream
-- has actually started and `midi clock reset` is on (per-bar reset scheduler)
clock._reset()
ofake:set('midi_clock_out', 2)   -- on
ofake:set('midi_clock_reset', 2) -- on
outs.transport = false; outs.clock_co = nil; outs.clock_started = false
midi_log = {}
outs:clock_reset()
check('clock_reset before the stream starts is silent', #midi_log == 0)
outs:set_transport(true)         -- arm; Start emitted on the grid
clock._run_until(2)
midi_log = {}
outs:clock_reset()
check('clock_reset while streaming re-sends Start', #midi_log == 1 and midi_log[1][1] == 'start')
ofake:set('midi_clock_reset', 1) -- off
midi_log = {}
outs:clock_reset()
check('clock_reset disabled is silent', #midi_log == 0)
outs:clock_stop()

print('')
if fail == 0 then print('ALL PASS') else print(fail .. ' FAILURE(S)') os.exit(1) end
