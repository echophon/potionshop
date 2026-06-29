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
check('12 scale names in picker order', #scales.names == 12
  and scales.names[1] == 'chromatic' and scales.names[12] == 'wuSheng')
check('7 grid preset names, subset of scales.names', #scales.picker_names == 7
  and scales.picker_names[1] == 'major' and scales.by_name[scales.picker_names[7]] ~= nil)
check('root transposes tonic up by semitones',
  approx(scales.degree_to_freq(0, major, 2),
    require('musicutil').note_num_to_freq(26)))
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
  -- op2/3/4 ratios are sequenced now: every A-layer step must land on that op's ROLE
  -- set under the channel's algo (carrier -> CARRIER_RATIOS, else MODULATOR_RATIOS),
  -- the exact grid the picker shows so the value stays highlightable/editable.
  for _, op in ipairs({2, 3, 4}) do
    for _, v in ipairs(seqx.values(c['opRatio' .. op])) do
      if not in_set(v, Burst.op_ratio_set(c.algo, op)) then ok_ratio = false end
    end
  end
  -- carrier (ampShape) and modulator (modShape) envelope shapes are sequenced as
  -- shape INDICES; randomize draws only from the instant-attack family, so every
  -- step must be an integer in 1..Burst.SHAPE_PERC_COUNT (a subset of the picker).
  for _, seq in ipairs({c.ampShape, c.modShape}) do
    for _, v in ipairs(seqx.values(seq)) do
      if not (v == math.floor(v) and v >= 1 and v <= Burst.SHAPE_PERC_COUNT) then ok_ad = false end
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
  -- the two env shapes + op2/3/4 ratios randomize to ONE held step (stable timbre)
  for _, seq in ipairs({c.ampShape, c.modShape, c.opRatio2, c.opRatio3, c.opRatio4}) do
    if seqx.len(seq) ~= 1 then ok_single = false end
  end
end
check('div values all in MUSICAL_DIVS', ok_div)
check('reps values all in {1,2,3,4}', ok_reps)
check('note values 0..15 integer', ok_note)
check('sequenced op2/3/4 ratio steps land on the curated RATIO_VALUES set', ok_ratio)
check('randomize keeps op1 ratio at the 1.0 anchor', ok_op1)
check('carrier+mod randomize shapes land in the instant-attack family (1..PERC)', ok_ad)
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

-- env-shape trig: 'hold' draws the ampShape once per burst (every hit shares its
-- contour); 'step' advances the ampShape A sequins per hit so the envelope shape
-- arpeggiates. A 3-hit burst with ampShape {1,3,6} (distinct decay muls) yields, via
-- the amp-decay trig arg (arg 9, = decMul*gap in shape envMode): hold => three equal
-- decays; step => three distinct decays. (Shapes have no B layer — step walks A.)
local function shape_step_decays(trig_mode)
  clock._reset()
  local saved = engine
  local decs = {}
  engine = { trig = function(...) local a = {...}; decs[#decs + 1] = a[9] end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].div  = seqx.new{4}
  e.channels[1].reps = seqx.new{3}          -- single 3-hit burst
  e.channels[1].note = seqx.new{0}
  e.channels[1].ampShape = seqx.new{1, 3, 6}  -- click/tap/pluck: distinct decMul
  e.channels[1].ampShapeTrig = trig_mode
  e:launch(1)
  clock._run_until(4)
  engine = saved
  return decs
end
check('env-shape trig defaults to hold', Burst.new().channels[1].ampShapeTrig == 0)
local sh_hold = shape_step_decays(0)
check('env-shape hold holds one shape across the burst',
  #sh_hold == 3 and approx(sh_hold[1], sh_hold[2]) and approx(sh_hold[2], sh_hold[3]))
local sh_step = shape_step_decays(1)
check('env-shape step arpeggiates the shape per hit',
  #sh_step == 3 and not approx(sh_step[1], sh_step[2])
  and not approx(sh_step[2], sh_step[3]) and not approx(sh_step[1], sh_step[3]))

-- all four op ratios are sequenced (A value + B offset, drawn per burst). The drawn
-- op2/3/4 values pass straight to trig args 4/5/6 (r2/r3/r4); op1's drawn value rides
-- as r1 at arg 20.
-- engine.trig(freq, amp, algo, r2, r3, r4, modIndex,
--             atk, aDec, ampDecCurve, mDec, feedback, drive, ch, op1..op4, modAtk, r1,
--             ampAtkCurve, modAtkCurve, modDecCurve).
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
  e:launch(1)
  clock._run_until(2)
  engine = saved
  return cap
end
local off = first_trig()
check('algo passes at trig arg 3 (default channel = 1)', off and off[3] == 1)
check('sequenced op2/3/4 ratios pass at trig args 4/5/6',
  off and approx(off[4], 2) and approx(off[5], 3) and approx(off[6], 7))
-- op1 ratio (sequenced): its drawn value rides as r1 at trig arg 20 (appended last).
check('op1 ratio passes at trig arg 20', off and approx(off[20], 0.5))

-- op ratio B lane is an INDEX OFFSET: it shifts A's position in the sorted
-- RATIO_VALUES list (never an off-grid sum), walking UP into the finer in-between
-- ratios. A {2} + B {4} -> the 4th entry above 2 in the list (arg 4).
local function ratio_b_trig()
  clock._reset()
  local saved = engine
  local cap
  engine = { trig = function(...) cap = cap or {...} end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].div = seqx.new{4}
  e.channels[1].reps = seqx.new{1}
  e.channels[1].opRatio2 = seqx.new{2}    -- A: base ratio
  e.channels[1].opRatio2B = seqx.new{4}   -- B: +4 index offset (walks up the list)
  e:launch(1)
  clock._run_until(2)
  engine = saved
  return cap
end
local rb = ratio_b_trig()
check('op2 ratio B index-offset shifts A up the list (arg 4)',
  rb and approx(rb[4], Burst.op_ratio(2, 4)) and rb[4] > 2)

-- op_ratio properties (robust to list content): B=0 is identity; the list is sorted
-- ascending so positive offsets are monotonic non-decreasing; offsets clamp at the
-- top rather than overflowing; every coarse picker value resolves on the full list.
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
check('B offset can walk a carrier value into a modulator-only ratio', (function()
  -- the union interleaves both role sets, so a B step from a carrier base can land on
  -- a value present only in the modulator set (proving B walks the full union).
  for _, a in ipairs(Burst.CARRIER_RATIOS) do
    for off = 1, 4 do
      local r = Burst.op_ratio(a, off)
      if r > a and not in_set(r, Burst.CARRIER_RATIOS) and in_set(r, Burst.MODULATOR_RATIOS) then
        return true
      end
    end
  end
  return false
end)())
check('op_ratio clamps at the top of the list',
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
  e.channels[1].div  = seqx.new{4}
  e.channels[1].reps = seqx.new{3}        -- length-1 finite -> single 3-hit burst
  e.channels[1].opRatio2  = seqx.new{2}   -- A: held per burst (index 12)
  e.channels[1].opRatio2B = seqx.new{0, 1, 2}  -- B: index offsets
  e.channels[1].opRatio2Trig = trig_mode
  e:launch(1)
  clock._run_until(4)
  engine = saved
  return r2
end
local hold_r = op_ratio_trig_seq(0)
check('op ratio trig hold holds one B offset across the burst',
  #hold_r == 3 and approx(hold_r[1], 2) and approx(hold_r[2], 2) and approx(hold_r[3], 2))
local step_r = op_ratio_trig_seq(1)
check('op ratio trig step walks the index UP per hit (A held)',
  #step_r == 3 and approx(step_r[1], 2)
  and step_r[2] == Burst.op_ratio(2, 1) and step_r[3] == Burst.op_ratio(2, 2)
  and step_r[2] > step_r[1] and step_r[3] > step_r[2])
check('op ratio trig defaults to hold (0)', Burst.new().channels[1].opRatio2Trig == 0)

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
  e.channels[1].opRatio2Trig = trig_mode
  e:launch(1)
  clock._run_until(4)
  engine = saved
  return r2
end
local a_step = op_ratio_A_held(1)
check('op ratio step leaves the A lane held within the burst',
  #a_step == 3 and approx(a_step[1], 2) and approx(a_step[2], 2) and approx(a_step[3], 2))

-- op1 is sequenced the same way (A value + B index offset + per-hit trig), and its
-- drawn value rides as r1 at trig arg 20. A {2} + B {0,1,2} under step trig walks the
-- index UP per hit, exactly like op2 above but observed on arg 20.
local function op1_ratio_trig_seq(trig_mode)
  clock._reset()
  local saved = engine
  local r1 = {}
  engine = { trig = function(...) local a = {...}; r1[#r1 + 1] = a[20] end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].div  = seqx.new{4}
  e.channels[1].reps = seqx.new{3}        -- length-1 finite -> single 3-hit burst
  e.channels[1].opRatio1  = seqx.new{2}   -- A: held per burst
  e.channels[1].opRatio1B = seqx.new{0, 1, 2}  -- B: index offsets
  e.channels[1].opRatio1Trig = trig_mode
  e:launch(1)
  clock._run_until(4)
  engine = saved
  return r1
end
local hold_r1 = op1_ratio_trig_seq(0)
check('op1 ratio trig hold holds one B offset across the burst (arg 20)',
  #hold_r1 == 3 and approx(hold_r1[1], 2) and approx(hold_r1[2], 2) and approx(hold_r1[3], 2))
local step_r1 = op1_ratio_trig_seq(1)
check('op1 ratio trig step walks the index UP per hit on arg 20',
  #step_r1 == 3 and approx(step_r1[1], 2)
  and step_r1[2] == Burst.op_ratio(2, 1) and step_r1[3] == Burst.op_ratio(2, 2)
  and step_r1[2] > step_r1[1] and step_r1[3] > step_r1[2])
check('op1 ratio trig defaults to hold (0)', Burst.new().channels[1].opRatio1Trig == 0)

-- envelope SHAPES: each sequenced shape INDEX resolves (in fire) to attack/decay
-- times scaled to the inter-hit gap + per-segment Env curves. The carrier shape
-- (ampShape) feeds trig args 8 (attack) / 9 (ampDecay) / 10 (ampDecCurve) /
-- 21 (ampAtkCurve); the modulator shape (modShape) feeds 19 (modAttack) /
-- 11 (modDecay) / 22 (modAtkCurve) / 23 (modDecCurve). div 4 @ 120bpm => gap 0.5s.
-- Expectations are derived from Burst.SHAPES so this survives table tuning/reordering.
local GAP = 0.5
local function exp_atk(sh) return math.max(0.001, GAP * sh[1]) end
local function shp(i) return Burst.SHAPES[i] end
-- pick representative carrier shapes BY their contour, not by a hard-coded index,
-- so this survives reordering the table:
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
local function shape_trig(amp_i, mod_i)
  clock._reset()
  local saved = engine
  local cap
  engine = { trig = function(...) cap = cap or {...} end }
  local e = Burst.new()
  set_quant(e, 0)
  e.channels[1].div = seqx.new{4}
  e.channels[1].reps = seqx.new{1}
  e.channels[1].ampShape = seqx.new{amp_i}
  e.channels[1].modShape = seqx.new{mod_i}
  e:launch(1)
  clock._run_until(2)
  engine = saved
  return cap
end
local s_inst = shape_trig(I_INSTANT, I_INSTANT)
local s_atk  = shape_trig(I_LONGATK, I_INSTANT)
local s_dec  = shape_trig(I_LONGDEC, I_INSTANT)
check('instant-attack shape -> ~0.001s attack (trig arg 8)', s_inst and approx(s_inst[8], 0.001))
check('longer-attack shape -> longer gap-relative attack (trig arg 8)',
  s_atk and s_inst and s_atk[8] > s_inst[8] and approx(s_atk[8], exp_atk(shp(I_LONGATK))))
check('longer-decay shape -> longer amp decay (trig arg 9)', s_dec and s_inst and s_dec[9] > s_inst[9])
-- ampPunch default 4 => punch scale 1.0, so the carrier curves pass through unscaled.
check('carrier shape feeds amp-decay curve (trig arg 10)', s_inst and approx(s_inst[10], shp(I_INSTANT)[4]))
check('carrier shape feeds amp-attack curve (trig arg 21)', s_inst and approx(s_inst[21], shp(I_INSTANT)[3]))

-- modulator envelope: the modShape index feeds the FM-brightness env independently
-- of the carrier (ampShape held constant). instant vs longest-decay mod shape.
local m_inst = shape_trig(I_INSTANT, I_INSTANT)
local m_dec  = shape_trig(I_INSTANT, I_LONGDEC)
check('modulator shape feeds mod attack (trig arg 19)', m_inst and approx(m_inst[19], exp_atk(shp(I_INSTANT))))
check('longer mod shape -> longer FM body (trig arg 11)', m_dec and m_inst and m_dec[11] > m_inst[11])
check('modulator shape feeds mod-attack curve (trig arg 22)', m_inst and approx(m_inst[22], shp(I_INSTANT)[3]))
check('modulator shape feeds mod-decay curve (trig arg 23)', m_inst and approx(m_inst[23], shp(I_INSTANT)[4]))
-- the modulator env is independent of the carrier env: changing modShape must not
-- move the carrier attack/decay (args 8/9).
check('mod shape does not disturb carrier env (args 8/9 stable)',
  m_inst and m_dec and approx(m_inst[8], m_dec[8]) and approx(m_inst[9], m_dec[9]))

-- shape-mode amp decay tracks the inter-hit gap: 4x faster division -> ~1/4
-- the decay, so dense/fast channels self-shorten instead of piling up.
local function amp_decay_for_div(divv)
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
  return cap and cap[9]
end
local slow, fast = amp_decay_for_div(2), amp_decay_for_div(8)
check('amp decay scales with division (4x faster ~= 1/4 the hit)',
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

-- the channel index rides along as trig arg 14 so the SC engine can keep each
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
  return cap and cap[14]
end
check('channel index feeds trig arg 14', chan_arg(3) == 3)

-- VOICE macros: engine-wide globals read straight at fire time. trig args
-- 10/12/13 = amp-decay curve, feedback, drive; arg 7 = modIndex. The amp-decay
-- curve = the carrier shape's decCurve scaled by ampPunch/4 (default shape 'tail'
-- decCurve -4 * ampPunch 4/4 = -4). (mod env args 11/19/22/23 are per-channel.)
-- `setup(e)` mutates the engine before launch; returns the first trig.
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
check('voice macro defaults: modIndex=2, amp-dec curve=-4, feedback=0, drive=1',
  d and approx(d[7], 2) and approx(d[10], -4) and approx(d[12], 0) and approx(d[13], 1))
-- mod index, amp punch and FM feedback are now per-channel static scalars (MIX page);
-- they feed the trig args directly (drive stays an engine-wide macro). The modulator
-- decay is sequenced -> arg 11, with modulator attack at arg 19.
local gv = macro_trig(function(e)
  e.channels[1].modIndex, e.channels[1].ampPunch, e.channels[1].fmFeedback = 12, 8, 1.5
  e.drive = 4
end)
check('voice scalars feed trig: modIndex, ampPunch->curve, feedback, drive',
  gv and approx(gv[7], 12) and approx(gv[10], -8) and approx(gv[12], 1.5) and approx(gv[13], 4))
-- per-operator levels ride trig args 15..18; op1 default 1, op2..4 default 15/31.
check('op levels default: op1=1, op2..4=15/31 (args 15-18)',
  d and approx(d[15], 1) and approx(d[16], 15/31) and approx(d[17], 15/31) and approx(d[18], 15/31))
-- now per-channel STATIC scalars: opLevel1..4 feed trig args 15-18 directly.
local ol = macro_trig(function(e)
  e.channels[1].opLevel1 = 0.2
  e.channels[1].opLevel2 = 0.4
  e.channels[1].opLevel3 = 0.6
  e.channels[1].opLevel4 = 0.8
end)
check('per-channel op levels feed trig args 15-18',
  ol and approx(ol[15], 0.2) and approx(ol[16], 0.4) and approx(ol[17], 0.6) and approx(ol[18], 0.8))

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
-- envelope shapes, or ampShape/modShape drift out of phase on a bar reset.
local rzc = Burst.new()
rzc.channels[1].ampShape = seqx.new{1, 5, 9}
rzc.channels[1].modShape = seqx.new{2, 6}
rzc.channels[1].ampShape(); rzc.channels[1].ampShape()  -- advance the playheads
rzc.channels[1].modShape()
rzc:reset_channel(1)
check('reset_channel rewinds ampShape/modShape to step 1',
  rzc.channels[1].ampShape() == 1 and rzc.channels[1].modShape() == 2)

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

-- SHP page on a SINGLE button (row 7 col 1, next to div/reps): the one envelope
-- page, paired ampShape | modShape lanes (replaced the old carrier attack/decay +
-- modulator modatk/moddec pages). Selecting it lights only that button.
ctl:press(1, 7)  -- row 7 col 1 = SHP page
check('SHP page selected', ctl.selectedParam == 'ampShape')
check('SHP page shows ampShape | modShape lanes',
  ctl:row_lanes()[1].param == 'ampShape' and ctl:row_lanes()[2].param == 'modShape')
ctl:render_all()
check('row7 lights only the SHP button (col1), not div/reps (col0)',
  mg.leds[7 * 16 + 1] == 15 and mg.leds[7 * 16 + 0] ~= 15)
ctl:press(8, 0)  -- right half -> modShape A
check('SHP page right half edits modShape',
  ctl.picker.param == 'modShape' and ctl.picker.layer == 'A')
ctl:press(2, 6)  -- value grid row 6 col 2 -> shape index 3
check('SHP picker writes a shape index step',
  seqx.values(geng.channels[1].modShape)[1] == GridUI.STEP_PICKER_VALUES.modShape[3])
ctl:close_picker()

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
check('idle launch buttons pulse before first launch', mg.strobes[6 * 16 + 8] == 'pulse')

-- launch toggle: 3x2 block at cols 8..10 (row 6 = ch0,1,2; row 7 = ch3,4,5)
ctl:press(8, 6)   -- ch0 = col 8, row 6
check('launch block (col8,row6) launches channel 1', geng:is_running(1) == true)
check('first launch latches hasLaunched', ctl.hasLaunched == true)
ctl:press(8, 6)
check('re-press stops channel 1', geng:is_running(1) == false)
ctl:press(10, 7)  -- ch5 = col 10, row 7
check('launch block (col10,row7) launches channel 6', geng:is_running(6) == true)
ctl:press(10, 7)
check('re-press stops channel 6', geng:is_running(6) == false)

-- first-run gate: once any channel has ever started, the onboarding pulse is gone;
-- a running channel is solid full-bright, an idle one a static dim (no strobe)
geng:launch(1)  -- ch0 = col 8, row 6
ctl:render_all()
check('idle launch button no longer pulses after first launch', mg.strobes[6 * 16 + 9] == nil)
check('idle launch button settles to a static dim', mg.leds[6 * 16 + 9] == 4)
check('running launch button is solid full-bright', mg.leds[6 * 16 + 8] == 15)
geng:stop(1)

-- scale picker (row6 QNT col 14)
ctl:press(14, 6)
check('QNT opens scale picker', ctl.picker ~= nil and ctl.picker.kind == 'scale')
ctl:press(1, 0)  -- scales.picker_names[2] = 'minor'
check('scale picker selects minor', ctl.selectedScaleName == 'minor')
check('engine.scale set to minor intervals', vals_eq(geng.scale, scales.by_name.minor))
ctl:press(0, 5)  -- root keyboard white row, col 0 = semitone 0 (C)
check('root keyboard sets engine.root to C', geng.root == 0)
ctl:press(1, 5)  -- col 1 white = semitone 2 (D)
check('root keyboard sets engine.root to D', geng.root == 2)
ctl:press(14, 6)  -- close scale picker
check('scale picker closed via QNT', ctl.picker == nil)

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
ctl:press(12, 0)  -- PROB_COLS[2] -> PROB_VALUES[2] = 0.5 on channel 0
check('prob option sets burstProb 0.5', approx(geng.channels[1].burstProb, 0.5))
ctl:press(1, 0)   -- ALT_TRIG_COLS[2] -> altTrig = 1 (step) on channel 0
check('alt-trig key sets altTrig to step', geng.channels[1].altTrig == 1)
ctl:press(0, 0)   -- ALT_TRIG_COLS[1] -> altTrig = 0 (hold)
check('alt-trig key sets altTrig to hold', geng.channels[1].altTrig == 0)
-- op1/2/3/4 ratio-seq trig toggles (cols 3-6): single button, hold (0) <-> step (1)
check('op1 ratio trig defaults to hold', geng.channels[1].opRatio1Trig == 0)
ctl:press(3, 0)   -- col3 -> toggle op1 trig
check('op1 trig button toggles to step', geng.channels[1].opRatio1Trig == 1)
ctl:press(3, 0)   -- toggle back
check('op1 trig button toggles back to hold', geng.channels[1].opRatio1Trig == 0)
ctl:press(4, 0)   -- col4 -> op2 trig toggle
check('op2 trig button (col4) sets step', geng.channels[1].opRatio2Trig == 1)
ctl:press(4, 0)
ctl:press(6, 0)   -- col6 -> op4 trig toggle
check('op4 trig button (col6) sets step', geng.channels[1].opRatio4Trig == 1)
ctl:press(6, 0)
-- amp/mod env shape-seq trig toggles (cols 8-9): single button, hold (0) <-> step (1)
check('amp env trig defaults to hold', geng.channels[1].ampShapeTrig == 0)
ctl:press(8, 0)   -- col8 -> amp env trig toggle
check('amp env trig button (col8) sets step', geng.channels[1].ampShapeTrig == 1)
ctl:press(8, 0)
check('amp env trig button toggles back to hold', geng.channels[1].ampShapeTrig == 0)
ctl:press(9, 0)   -- col9 -> mod env trig toggle
check('mod env trig button (col9) sets step', geng.channels[1].modShapeTrig == 1)
ctl:press(9, 0)
ctl:press(13, 6)
check('PROB mode exited', ctl.probMode == false)

-- MIX page (row6 col 11): channel level (col 7) + per-op level (cols 8-11). All four
-- op ratios moved to their own sequence pages, so cols 0-6 of the MIX page are inert.
ctl:press(11, 6)
check('MIX mode entered', ctl.mixMode == true)
-- col0 (the old op1 ratio slot) is now inert — op ratios are sequenced.
ctl:press(0, 0)
check('MIX col0 is inert (op1 ratio is sequenced now)', ctl.picker == nil)
ctl:press(7, 0)   -- col7 -> channel level picker
check('MIX col7 opens the channel level scalar picker',
  ctl.picker and ctl.picker.field == 'level')
ctl:press(0, 6)   -- value grid row 6 col 0 -> OP_LEVEL_VALUES[1] = 0
check('MIX channel level picker sets c.level', approx(geng.channels[1].level, 0))
ctl:press(8, 0)   -- col8 -> op1 level picker
check('MIX op level cell opens a scalar picker',
  ctl.picker and ctl.picker.field == 'opLevel1')
ctl:press(15, 7)  -- value grid row 7 col 15 -> OP_LEVEL_VALUES[32] = 1.0
check('MIX op level picker sets opLevel1', approx(geng.channels[1].opLevel1, 1.0))
ctl:press(11, 6)
check('MIX mode exited', ctl.mixMode == false)

-- env mode + geode are engine-wide VOICE macros now (no grid SND page, col 15 dark)
check('geodeMode is a global engine field, not per-channel',
  geng.geodeMode ~= nil and geng.channels[1].geodeMode == nil)
check('envMode is a global engine field, not per-channel',
  geng.envMode ~= nil and geng.channels[1].envMode == nil)
check('geode defaults to sustain (1)', Burst.new().geodeMode == 1)
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

-- smoke: redraw runs clean on every page
local pages_ok = true
for p = 1, 6 do
  sui:set_page(p)
  local ok, err = pcall(function() sui:redraw() end)
  if not ok then pages_ok = false; print('      redraw error page ' .. p .. ': ' .. tostring(err)) end
end
check('redraw runs clean on all 6 pages', pages_ok)
sui:set_page(3)
check('set_page syncs grid modes (perf -> perfMode)', sctl.perfMode == true)
sui:set_page(5)
check('scale page opens the grid scale picker', sctl.picker and sctl.picker.kind == 'scale')

-- main page: E3 edits land exactly on the step picker grid
sui:set_page(1)
sui.sel_ch = 0
sui.sel_line[1] = 4  -- note (line 1 = run)
sui:enc(2, 0)        -- sync the grid's selected param
sui.sel_step = 0
sui:enc(3, 1)
check('main E3 edit lands on note picker grid',
  in_set(seqx.values(seng.channels[1].note)[1], GridUI.STEP_PICKER_VALUES.note))
check('main E2 sync keeps grid selectedParam agreeing', sctl.selectedParam == 'note')

-- prob page: prob steps the discrete 25/50/75/100% set
sui:set_page(4)
sui.sel_line[4] = 1
seng.channels[1].burstProb = 1
sui:enc(3, -1)
check('prob E3 steps down one discrete value', approx(seng.channels[1].burstProb, 0.75))
sui.sel_line[4] = 2
sui:enc(3, 1)
check('prob mode line toggles probHit', seng.channels[1].probHit == true)
sui.sel_line[4] = 3
sui:enc(3, 1)
check('alt-trig line steps altTrig to step', seng.channels[1].altTrig == 1)
sui.sel_line[4] = 4   -- op1 ratio-seq trig
sui:enc(3, 1)
check('prob page op1 trig line steps to step', seng.channels[1].opRatio1Trig == 1)
sui:enc(3, -1)
check('prob page op1 trig line steps back to hold', seng.channels[1].opRatio1Trig == 0)
sui.sel_line[4] = 5   -- op2 ratio-seq trig
sui:enc(3, 1)
check('prob page op2 trig line steps to step', seng.channels[1].opRatio2Trig == 1)
sui:enc(3, -1)
check('prob page op2 trig line steps back to hold', seng.channels[1].opRatio2Trig == 0)
sui.sel_line[4] = 8   -- amp env shape-seq trig
sui:enc(3, 1)
check('prob page amp env trig line steps to step', seng.channels[1].ampShapeTrig == 1)
sui:enc(3, -1)
check('prob page amp env trig line steps back to hold', seng.channels[1].ampShapeTrig == 0)
sui.sel_line[4] = 9   -- mod env shape-seq trig
sui:enc(3, 1)
check('prob page mod env trig line steps to step', seng.channels[1].modShapeTrig == 1)
sui:enc(3, -1)
check('prob page mod env trig line steps back to hold', seng.channels[1].modShapeTrig == 0)

-- mix page: line 1 = channel level, lines 2..5 = op1..op4 level. All four op ratios
-- are sequenced now (edited on the main/alt seq pages), so they're absent here.
sui:set_page(6)
sui.sel_line[6] = 1   -- channel level
seng.channels[1].level = 1.0
sui:enc(3, -1)
check('mix page line 1 steps channel level down the 0..1 grid',
  in_set(seng.channels[1].level, GridUI.OP_LEVEL_VALUES) and seng.channels[1].level < 1.0)
sui.sel_line[6] = 2   -- op1 level
seng.channels[1].opLevel1 = 1.0
sui:enc(3, -1)
check('mix page line 2 steps opLevel1 down the 0..1 grid',
  in_set(seng.channels[1].opLevel1, GridUI.OP_LEVEL_VALUES) and seng.channels[1].opLevel1 < 1.0)

-- op1/2/3/4 ratios are now sequenced — editable on the main seq page like any lane.
sui:set_page(1)
sui.sel_ch = 0
sui.sel_line[1] = 1 + 7   -- run(1) + params: div..modShape(1..5) opRatio1(6) opRatio2(7) = line 8
sui:enc(2, 0)             -- sync grid selected param to the focused line
check('main page line reaches the sequenced opRatio2 lane', sui:main_param() == 'opRatio2')
seng.channels[1].opRatio2 = seqx.new{1}
sui.sel_step = 0
sui:enc(3, 1)
check('main E3 steps opRatio2 up the curated ratio grid (A = role set)',
  in_set(seqx.values(seng.channels[1].opRatio2)[1],
         GridUI.op_ratio_set(seng.channels[1].algo, 2))
  and seqx.values(seng.channels[1].opRatio2)[1] ~= 1)

-- perf page: values come from the shared interval/octave/rate tables
sui:set_page(3)
sui.sel_line[3] = 1
sui:enc(3, 3)
check('perf E3 lands in RESET_INTERVALS', in_set(seng.channels[1].resetInterval, GridUI.RESET_INTERVALS))
check('perf page_lines labels map to reset/oct/rate', sui:page_lines()[1][1] == 'reset')
sui.sel_line[3] = 2
sui:enc(3, 1)
check('oct E3 lands in OCTAVE_VALUES', in_set(seng.channels[1].octave, GridUI.OCTAVE_VALUES))
check('oct E3 stepped up one octave', seng.channels[1].octave == 1)
sui:enc(3, -1)  -- restore octave 0: the fire tests below expect an unshifted c1
sui.sel_line[3] = 3
sui:enc(3, 1)
check('rate E3 lands in RATE_VALUES', in_set(seng.channels[1].rate, GridUI.RATE_VALUES))

-- scale page: E2 walks root -> 12 keys; E3 edits each (quantize is per-channel
-- now, on the perf page below — no longer a scale-page stop)
sui:set_page(5)
seng.root = 0
sui.sel_line[5] = 1            -- root
sui:enc(3, 2)
check('scale E3 raises root by semitones', seng.root == 2)
sui:enc(3, -3)                 -- wraps below 0
check('scale root wraps mod 12', seng.root == 11)
seng.scale = {0, 4, 7}
sui.sel_line[5] = 2 + 2        -- key for pitch class 2 (D)
sui:enc(3, 1)
check('scale E3 right adds a key to the mask', in_set(2, seng.scale) and #seng.scale == 4)
sui:enc(3, -1)
check('scale E3 left removes the key', not in_set(2, seng.scale) and #seng.scale == 3)

-- perf page: per-channel quantize on line 4, stepping the curated set
sui:set_page(3)
seng.channels[1].quantize = 8
sui.sel_line[3] = 4
sui:enc(3, 1)
check('perf E3 steps quantize up the curated set', seng.channels[1].quantize == 12)
check('perf quantize lands in QUANTIZE_VALUES', in_set(seng.channels[1].quantize, GridUI.QUANTIZE_VALUES))

-- restore musical state the fire tests below assume (unshifted c1, major)
seng.root = 0
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
sui:set_page(1)
sctl:press(11, 6)  -- MIX on the grid
sui:redraw()
check('grid MIX press switches screen to mix page', sui.page == 6)
sctl:press(11, 6)  -- toggle MIX off
sctl:press(13, 6)  -- PROB on the grid
sui:redraw()
check('grid PROB press switches screen to prob page', sui.page == 4)
sctl:press(13, 6)  -- toggle PROB off
sui:redraw()
check('grid mode off returns screen to main page', sui.page == 1)

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

-- run line: E3 right launches, left stops
sui:set_page(1)
seng.channels[1].reps = seqx.new{2, 2}  -- looping again (fire test made it single-shot)
sui.sel_line[1] = 1  -- run
sui:enc(3, 1)
check('run line E3 right launches the channel', seng:is_running(1) == true)
sui:enc(3, -1)
check('run line E3 left stops the channel', seng:is_running(1) == false)

-- E2 walks every position: run -> div steps -> div `_` -> next line
sui.sel_line[1] = 1  -- run (div default seq {4, 8} -> 2 steps + add slot)
sui.sel_step = 0
sui:enc(2, 1)
check('E2 flows from run to div step 1', sui.sel_line[1] == 2 and sui.sel_step == 0)
sui:enc(2, 1); sui:enc(2, 1)
check('E2 reaches the `_` add slot after the last step',
  sui.sel_line[1] == 2 and sui.sel_step == 2 and sui:_on_add_slot())
sui:enc(2, 1)
check('E2 flows past `_` onto the next line', sui.sel_line[1] == 3 and sui.sel_step == 0)
sui:enc(2, -1)
check('E2 flows backward onto the previous line`s add slot',
  sui.sel_line[1] == 2 and sui:_on_add_slot())

-- `_` add slot: increment appends a step at the lowest picker value
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
sui.sel_line[1] = 4  -- note
sui:enc(2, 0)
sui.sel_step = 0
sui:enc(3, -1)
check('last remaining step clamps, never removed', seqx.len(seng.channels[1].note) == 1)

-- K2/K3 page back/forward, clamped at the ends; grid modes + paramLayer follow
sui:set_page(1)
sui:key(3, 1)
check('K3 pages forward to alt (grid layer follows)',
  sui.page == 2 and sctl.paramLayer == 'B')
sui:key(3, 1)
check('K3 pages to perf (grid perfMode follows)',
  sui.page == 3 and sctl.perfMode == true)
sui:key(2, 1)
check('K2 pages back to alt (perfMode off)',
  sui.page == 2 and sctl.perfMode == false)
sui:key(2, 1)
check('K2 back to main restores layer A', sui.page == 1 and sctl.paramLayer == 'A')
sui:key(2, 1)
check('K2 clamps at main (no wrap)', sui.page == 1 and sctl.perfMode == false)

-- alt page: editing the B (offset) layer — only B-capable params appear here
-- (div/reps/shapes have no B layer, so they're absent from alt)
sui:set_page(2)
sui.sel_ch = 0
seng.channels[1].noteB = seqx.new{0}
sui.sel_line[2] = 2  -- note (B_PARAMS = {note, opRatio1..4})
sui:enc(2, 0)        -- sync the grid's selected param + layer
sui.sel_step = 0
sui:enc(3, 1)
check('alt E3 steps note B up from 0 onto the grid',
  approx(seqx.values(seng.channels[1].noteB)[1], GridUI.STEP_PICKER_VALUES.note[2]))
sui:enc(3, -1)
check('alt E3 decrement returns to 0 (no offset)',
  seqx.values(seng.channels[1].noteB)[1] == 0)
sui.sel_step = 1  -- `_` add slot
sui:enc(3, 1)
check('alt `_` appends 0', seqx.len(seng.channels[1].noteB) == 2
  and seqx.values(seng.channels[1].noteB)[2] == 0)
check('div/reps/harm are absent from the alt (B) page', sui:_main_positions(1) == 1
  and (function() sui.sel_line[2] = 2; return sui:main_param() == 'note' end)())
sui:set_page(1)

-- focused value token gets an underscore (rect 1px tall, token width)
seng.channels[1].div = seqx.new{16, 8}
sui.sel_line[1] = 2  -- div
sui:enc(2, 0)
sui.sel_step = 0
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
fake:set('ch1_op1_trig', 2)  -- option 2 = step
check('op1 ratio trig param sets step', peng.channels[1].opRatio1Trig == 1)
fake:set('ch1_op1_trig', 1)  -- option 1 = hold
check('op1 ratio trig param sets hold', peng.channels[1].opRatio1Trig == 0)
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

-- op-ratio trig mode params (hold/step option, like alt trig)
fake:set('ch1_op2_trig', 2)  -- option 2 = step
check('op2 ratio trig param sets step', peng.channels[1].opRatio2Trig == 1)
fake:set('ch1_op2_trig', 1)  -- option 1 = hold
check('op2 ratio trig param sets hold', peng.channels[1].opRatio2Trig == 0)

-- amp/mod env shape trig mode params (hold/step option, like the op-ratio trigs)
fake:set('ch1_ampShape_trig', 2)  -- option 2 = step
check('amp env trig param sets step', peng.channels[1].ampShapeTrig == 1)
fake:set('ch1_ampShape_trig', 1)  -- option 1 = hold
check('amp env trig param sets hold', peng.channels[1].ampShapeTrig == 0)
fake:set('ch1_modShape_trig', 2)
check('mod env trig param sets step', peng.channels[1].modShapeTrig == 1)
fake:set('ch1_modShape_trig', 1)
check('mod env trig param sets hold', peng.channels[1].modShapeTrig == 0)

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

-- engine/UI -> params: silent reflection only (zero action fires)
local f0 = fake.fires
pctl:press(0, 7)  -- row 7 col 0 = div/reps page
pctl:press(0, 6)  -- row 6 col 0 = note page
pctl:press(0, 0)  -- open step picker ch0 col0
pctl:press(5, 6)  -- pick note value 5 (value grid on rows 6-7)
check('grid step edit reflects into text param', fake:get('ch1_note_a') == '5 8 5')
pctl:press(13, 6)  -- PROB mode
pctl:press(12, 0)  -- PROB_COLS[2] -> burstProb 0.5 -> prob option index 2
check('grid prob option reflects into param', fake:get('ch1_prob') == 2)
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
peng.channels[1].ampPunch = 7
peng.channels[1].fmFeedback = 3
peng.channels[1].algo = 5
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
  and peng.channels[5].modIndex == 9 and peng.channels[5].ampPunch == 7
  and peng.channels[5].fmFeedback == 3 and peng.channels[5].algo == 5
check('copy+paste duplicates MIX-page static scalars across channels', mix_ok)
check('paste reflected into dest scalar param', fake:get('ch5_algorithm') == 5)

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
check('action_read reflects engine state into params', fake:get('ch5_prob') == 2)

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
check('harm_to_volts: min ratio = 0V', approx(Outputs.harm_to_volts(0.125), 0))
check('harm_to_volts: max ratio = 5V', approx(Outputs.harm_to_volts(14), 5))
check('ratio_to_cc: min ratio = 0', Outputs.ratio_to_cc(0.125) == 0)
check('ratio_to_cc: max ratio = 127', Outputs.ratio_to_cc(14) == 127)
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

-- midi: note on with velocity/channel, note off after dur via clock
ofake:set('ch1_output', Outputs.DEST.MIDI)
ofake:set('ch1_midi_chan', 5)
check('midi destination disables internal audio', outs:wants_audio(1) == false)
outs:note(1, {freq = 261.6256, level = 0.5, op1 = 14, op2 = 0.125, dur = 0.5})
check('midi pitch bend precedes the note, centered for an in-tune note',
  midi_log[1][1] == 'pb' and midi_log[1][2] == 8192 and midi_log[1][3] == 5)
check('midi note_on: middle C, vel 64, chan 5',
  midi_log[2][1] == 'on' and midi_log[2][2] == 60
  and midi_log[2][3] == 64 and midi_log[2][4] == 5)
check('midi modwheel (cc1) = op1 ratio, per hit, on the channel',
  midi_log[3][1] == 'cc' and midi_log[3][2] == 1
  and midi_log[3][3] == 127 and midi_log[3][4] == 5)
check('midi breath (cc2) = op2 ratio, per hit, on the channel',
  #midi_log == 4 and midi_log[4][1] == 'cc' and midi_log[4][2] == 2
  and midi_log[4][3] == 0 and midi_log[4][4] == 5)
clock._run_until(4)  -- 0.5 s at 120 bpm = 1 beat
check('midi note_off scheduled after dur',
  #midi_log == 5 and midi_log[5][1] == 'off' and midi_log[5][2] == 60)

-- retrigger same pitch: old note cut first, stale timer's off dropped. Each hit
-- emits its pitch bend + two op CCs (cc1=op1, cc2=op2), so the sequence is
-- pb,on,cc1,cc2 / pb,off,on,cc1,cc2.
midi_log = {}
outs:note(1, {freq = 261.6256, level = 0.5, dur = 0.5})
outs:note(1, {freq = 261.6256, level = 0.9, dur = 0.5})
check('retrigger cuts the held note first',
  midi_log[2][1] == 'on' and midi_log[6][1] == 'off' and midi_log[7][1] == 'on')
clock._run_until(8)
check('exactly one note_off after retrigger settles', #midi_log == 10
  and midi_log[10][1] == 'off')

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

-- er301: cv + tr_pulse on the channel-numbered port
ofake:set('ch5_output', Outputs.DEST.ER301)
crow_log = {}
outs:note(5, {freq = 523.2511, level = 0.5, harm = 14, dur = 0.5})
check('er301 cv + tr on port = channel', crow_log[1][1] == '301cv' and crow_log[1][2] == 5
  and approx(crow_log[1][3], 1) and crow_log[2][1] == '301tr' and crow_log[2][2] == 5)
check('er301 harm CV on port channel+6 (7..12)', crow_log[3][1] == '301cv'
  and crow_log[3][2] == 11 and approx(crow_log[3][3], 5))

-- burst integration: fire() respects wants_audio and forwards final values
engine = { trigs = 0 }
engine.trig = function() engine.trigs = engine.trigs + 1 end
local oeng = Burst.new()
oeng.outputs = outs
midi_log = {}
-- fire(ch, beat, freq, level, ampShape, modShape, div, total, hit_idx)
oeng:fire(1, 0, 440, 0.5, 4, 3, 4, 1, 0)  -- ch1 is midi: external only (pitch bend + note_on + op1/op2 CCs)
check('fire on midi channel skips engine.trig', engine.trigs == 0 and #midi_log == 4)
ofake:set('ch1_output', Outputs.DEST.AUDIO_MIDI)
midi_log = {}
oeng:fire(1, 0, 440, 0.5, 4, 3, 4, 1, 0)
check('audio+midi fires both', engine.trigs == 1 and #midi_log == 4)
oeng:fire(2, 0, 440, 0.5, 4, 3, 4, 1, 0)  -- ch2 is on crow 3+4
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
