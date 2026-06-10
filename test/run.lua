-- Local test harness for the pure Lua modules. Run from the project root:
--   lua test/run.lua
-- Uses faithful stubs of the norns sequins/musicutil libs (see test/norns_stub).

package.path = 'test/norns_stub/?.lua;lib/?.lua;' .. package.path

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
print('burst geode math:')
check('geode_mod neutral run=0.5 -> 1.0', approx(Burst.geode_mod(1, 0.5, 0, 8), 1.0))
check('geode_mod transient r=1 i=0 -> 1.0', approx(Burst.geode_mod(1, 1.0, 0, 10), 1.0))
check('geode_mod transient r=1 i=5 (cycle 10) -> 0.5', approx(Burst.geode_mod(1, 1.0, 5, 10), 0.5))
check('geode_mod cycle neutral -> 1.0', approx(Burst.geode_mod(3, 0.5, 3, 8), 1.0))
check('level_for_hit no geode passes level through', approx(Burst.burst_level_for_hit(0.5, 0, 0, 0, 8), 0.5))
check('level_for_hit geode clamps to 0.7', approx(Burst.burst_level_for_hit(1.0, 1, 0, 0, 10), 0.7))

-- ---- burst: randomize grid-alignment ----------------------------------
print('burst randomize (grid-reachable values):')
math.randomseed(1)
local function in_set(v, set)
  for _, s in ipairs(set) do if approx(v, s) then return true end end
  return false
end
local eng = Burst.new()
local ok_div, ok_reps, ok_note, ok_level, ok_harm, ok_env, ok_len = true, true, true, true, true, true, true
for _ = 1, 200 do
  eng:randomize(1)
  local c = eng.channels[1]
  for _, v in ipairs(seqx.values(c.div))  do if not in_set(v, Burst.MUSICAL_DIVS) then ok_div = false end end
  for _, v in ipairs(seqx.values(c.reps)) do if not in_set(v, {1,2,3,4}) then ok_reps = false end end
  for _, v in ipairs(seqx.values(c.note)) do if not (v >= 0 and v <= 15 and v == math.floor(v)) then ok_note = false end end
  for _, v in ipairs(seqx.values(c.level)) do local k = v * 31 if not (approx(k, math.floor(k+0.5)) and k >= 1 and k <= 16) then ok_level = false end end
  for _, v in ipairs(seqx.values(c.harm)) do local k = (v - 2) / 0.75 if not (approx(k, math.floor(k+0.5)) and k >= 0 and k <= 15) then ok_harm = false end end
  for _, v in ipairs(seqx.values(c.env)) do local k = v * 31 if not (approx(k, math.floor(k+0.5)) and k >= 0 and k <= 15) then ok_env = false end end
  local dl = seqx.len(c.div)
  if not (dl >= 2 and dl <= 4) then ok_len = false end
  if seqx.len(c.level) ~= 1 then ok_len = false end  -- unlocked -> length 1
end
check('div values all in MUSICAL_DIVS', ok_div)
check('reps values all in {1,2,3,4}', ok_reps)
check('note values 0..15 integer', ok_note)
check('level values land on picker grid (i/31, i=1..16)', ok_level)
check('harm values land on picker grid (2+i*0.75)', ok_harm)
check('env values land on picker grid (i/31)', ok_env)
check('lengths: div/reps/note 2..4, level len 1 unlocked', ok_len)

-- ---- burst: tick-level scheduling smoke test --------------------------
print('burst scheduling:')
local eng2 = Burst.new()
eng2:setup_lattice()
local fires = {}
eng2:on(function(ev) if ev.type == 'fire' then fires[#fires + 1] = ev end end)
-- single-shot: reps length-1 finite -> stops after the burst completes
eng2.channels[1].reps = seqx.new{1}
eng2.channels[1].div  = seqx.new{4}
eng2.channels[1].note = seqx.new{0}
eng2:launch(1)
local sp1 = eng2.sprockets[1]
sp1.action()  -- one hit
check('single-shot fired exactly one hit', #fires == 1)
check('single-shot stopped the channel', eng2:is_running(1) == false)
check('fire freq = degree_to_freq(0, major) = C1', approx(fires[1].freq, 32.7032))
-- looping: default reps {2,2} keeps running across bursts
local eng3 = Burst.new(); eng3:setup_lattice()
local n = 0
eng3:on(function(ev) if ev.type == 'fire' then n = n + 1 end end)
eng3:launch(2)
local sp2 = eng3.sprockets[2]
for _ = 1, 6 do sp2.action() end
check('looping channel still running after 6 ticks', eng3:is_running(2) == true)
check('looping channel fired 6 hits', n == 6)

-- ---- grid_ui: controller wiring ---------------------------------------
local GridUI = require 'grid_ui'
print('grid_ui controller:')
local function mock_grid()
  return {
    leds = {},
    set_led = function(self, x, y, b) self.leds[y * 16 + x] = b end,
    set_strobe = function() end,
    clear = function(self) self.leds = {} end,
    refresh = function() end,
  }
end

local function vals_eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if not approx(a[i], b[i]) then return false end end
  return true
end

local geng = Burst.new(); geng:setup_lattice()
local mg = mock_grid()
local ctl = GridUI.new(geng, mg)

-- param select + A/B layer toggle (row 7)
check('default selected param = note', ctl.selectedParam == 'note')
ctl:press(0, 7)
check('row7 col0 selects div', ctl.selectedParam == 'div' and ctl.paramLayer == 'A')
ctl:press(0, 7)
check('re-press toggles to B layer', ctl.paramLayer == 'B')

-- step picker edits a value
ctl:press(2, 7)  -- select note
check('selected note again', ctl.selectedParam == 'note' and ctl.paramLayer == 'A')
ctl:press(0, 0)  -- open picker on channel 0 step 0
check('step picker opened', ctl.picker ~= nil and ctl.picker.kind == 'step')
ctl:press(5, 0)  -- pick note value index 5 -> 5
check('picker set note step to 5', seqx.values(geng.channels[1].note)[1] == 5)
check('picker closed after pick', ctl.picker == nil)

-- launch toggle (row 6)
ctl:press(0, 6)
check('row6 col0 launches channel 1', geng:is_running(1) == true)
ctl:press(0, 6)
check('re-press stops channel 1', geng:is_running(1) == false)

-- scale picker (row6 QNT col 14)
ctl:press(14, 6)
check('QNT opens scale picker', ctl.picker ~= nil and ctl.picker.kind == 'scale')
ctl:press(2, 0)  -- scales.names[3] = 'minor'
check('scale picker selects minor', ctl.selectedScaleName == 'minor')
check('engine.scale set to minor intervals', vals_eq(geng.scale, scales.by_name.minor))
ctl:press(14, 6)  -- close scale picker
check('scale picker closed via QNT', ctl.picker == nil)

-- prob mode (row6 col 13)
ctl:press(13, 6)
check('PROB mode entered', ctl.probMode == true)
ctl:press(7, 0)  -- burstProb = 7/14 = 0.5 on channel 0
check('prob slider sets burstProb ~0.5', approx(geng.channels[1].burstProb, 0.5))
ctl:press(13, 6)
check('PROB mode exited', ctl.probMode == false)

-- SND mode geode set
ctl:press(15, 6)
check('SND mode entered', ctl.soundMode == true)
ctl:press(5, 0)  -- col5 -> geode index 1 (transient) on channel 0
check('SND sets geodeMode to 1', geng.channels[1].geodeMode == 1)

print('')
if fail == 0 then print('ALL PASS') else print(fail .. ' FAILURE(S)') os.exit(1) end
