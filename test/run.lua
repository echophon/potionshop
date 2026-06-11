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

-- quantization: an off-grid division (triplet, 4/3 beats) must snap every
-- event FORWARD to the quarter-note grid (quantize=4 -> step 1 beat). We read
-- clock.get_beats() inside the listener = the actual (snapped) firing instant.
clock._reset()
local eqn = Burst.new()
eqn.quantize = 4
eqn.channels[1].div  = seqx.new{3}    -- natural spacing 4/3 ≈ 1.333 beats
eqn.channels[1].reps = seqx.new{-1}   -- infinite
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
eqd.quantize = 0
eqd.channels[1].div  = seqx.new{3}
eqd.channels[1].reps = seqx.new{-1}
eqd.channels[1].note = seqx.new{0}
local nat = {}
eqd:on(function(ev) if ev.type == 'fire' then nat[#nat + 1] = clock.get_beats() end end)
eqd:launch(1)
clock._run_until(6)
check('quantize=0 fires at natural 4/3 spacing', #nat >= 3 and approx(nat[2] - nat[1], 4/3))
eqd:stop(1)

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

clock._reset()
local geng = Burst.new()
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
for p = 1, 4 do
  sui:set_page(p)
  local ok, err = pcall(function() sui:redraw() end)
  if not ok then pages_ok = false; print('      redraw error page ' .. p .. ': ' .. tostring(err)) end
end
check('redraw runs clean on all 4 pages', pages_ok)
check('set_page syncs grid modes (rst -> resetMode)', sctl.resetMode == true)

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

-- snd page: edits cycle the shared mode tables
sui:set_page(2)
sui.sel_line[2] = 2
local g0 = seng.channels[1].geodeMode
sui:enc(3, 1)
check('snd E3 steps geodeMode within table', seng.channels[1].geodeMode == g0 + 1)
sui:enc(3, 99)
check('snd E3 clamps at table end', seng.channels[1].geodeMode == #GridUI.GEODE_MODE_NAMES - 1)

-- prob page: prob snaps to the grid slider's k/14 columns
sui:set_page(3)
sui.sel_line[3] = 1
seng.channels[1].burstProb = 1
sui:enc(3, -1)
check('prob E3 snaps to k/14', approx(seng.channels[1].burstProb, 13 / 14))
sui.sel_line[3] = 2
sui:enc(3, 1)
check('prob mode line toggles probHit', seng.channels[1].probHit == true)

-- rst page: values come from the shared interval/rate tables
sui:set_page(4)
sui.sel_line[4] = 1
sui:enc(3, 3)
check('rst E3 lands in RESET_INTERVALS', in_set(seng.channels[1].resetInterval, GridUI.RESET_INTERVALS))
sui.sel_line[4] = 2
sui:enc(3, 1)
check('rate E3 lands in RATE_VALUES', in_set(seng.channels[1].rate, GridUI.RATE_VALUES))

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
local glyph_drawn = false
for _, cl in ipairs(screen.calls) do
  if cl[1] == 'font_size' and cl[2] == 24 then glyph_drawn = true end
end
check('ghost glyph drawn after fire', glyph_drawn)

-- grid mode buttons drive the screen tab (grid -> screen sync)
sui:set_page(1)
sctl:press(15, 6)  -- SND on the grid
sui:redraw()
check('grid SND press switches screen to snd page', sui.page == 2)
sctl:press(13, 6)  -- PROB on the grid
sui:redraw()
check('grid PROB press switches screen to prob page', sui.page == 3)
sctl:press(13, 6)  -- toggle PROB off
sui:redraw()
check('grid mode off returns screen to main page', sui.page == 1)

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

-- K2/K3 jump whole lines
sui:key(3, 1)
check('K3 jumps to the next line', sui.sel_line[1] == 5 and sui.sel_step == 0)
sui:key(2, 1)
check('K2 jumps back a line', sui.sel_line[1] == 4)

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
check('B-layer zero default shows as 0', fake:get('ch1_div_b') == '0')

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

-- B layer: index 0 = literal 0 offset (off-grid for div)
fake:set('ch1_div_b_val', 4)
check('B val index 4 -> div offset 4', seqx.values(peng.channels[1].divB)[1] == 4)
fake:set('ch1_div_b_val', 0)
check('B val index 0 -> literal 0', seqx.values(peng.channels[1].divB)[1] == 0)
check('B text shows 0', fake:get('ch1_div_b') == '0')

-- reps: 'inf' token <-> -1
fake:set('ch1_reps_a', '2 inf')
check('reps inf token parses to -1', seqx.values(peng.channels[1].reps)[2] == -1)
check('reps -1 formats back to inf', fake:get('ch1_reps_a') == '2 inf')

-- level/env tokens are 0..31 grid units
fake:set('ch1_level_a', '31 0')
check('level grid units parse to i/31', approx(seqx.values(peng.channels[1].level)[1], 1)
  and approx(seqx.values(peng.channels[1].level)[2], 0))

-- engine/UI -> params: silent reflection only (zero action fires)
local f0 = fake.fires
pctl:press(0, 7)  -- select div
pctl:press(2, 7)  -- select note, layer A
pctl:press(0, 0)  -- open step picker ch0 col0
pctl:press(5, 0)  -- pick note value 5
check('grid step edit reflects into text param', fake:get('ch1_note_a') == '5 8 5')
pctl:press(13, 6)  -- PROB mode
pctl:press(7, 0)   -- burstProb = 7/14
check('grid prob slider reflects into param', fake:get('ch1_prob') == 7)
pctl:press(13, 6)  -- exit PROB
check('grid edits fired zero param actions', fake.fires == f0)

-- screen edit reflects too (same set_scalar path)
pui:set_page(2)
pui.sel_ch = 0
pui.sel_line[2] = 2
pui:enc(3, peng.channels[1].geodeMode < 3 and 1 or -1)
check('screen snd edit reflects geode option',
  fake:get('ch1_geode') == peng.channels[1].geodeMode + 1)
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

-- JF harm broadcast: param edit on one JF channel propagates + reflects
fake:set('ch1_voice', 2)  -- jf
fake:set('ch2_voice', 2)  -- jf
fake:set('ch1_harm_a', '3.5')
check('JF harm broadcast hits sibling engine channel',
  approx(seqx.values(peng.channels[2].harm)[1], 3.5))
check('JF harm broadcast reflected to sibling param', fake:get('ch2_harm_a') == '3.5')

-- locked channel: length change syncs sibling sequences and their params
fake:set('ch3_lock', 1)
check('lock param sets locked', peng.channels[3].locked == true)
fake:set('ch3_div_a', '4 8 16 2')
check('locked div edit syncs level length', seqx.len(peng.channels[3].level) == 4)
check('locked sync reflected into level text param',
  #ParamsSync.from_text('level', 'A', fake:get('ch3_level_a')) == 4)

-- randomize trigger: result reflects exactly (grid-reachability contract)
fake:set('ch4_randomize', 1)
local rt_ok = true
for _, p in ipairs(GridUI.PARAMS) do
  if not vals_eq(ParamsSync.from_text(p, 'A', fake:get('ch4_' .. p .. '_a')),
                 seqx.values(peng.channels[4][p])) then rt_ok = false end
end
check('randomize trigger reflects all sequences exactly', rt_ok)

-- grid quantize edit reflects into the global param
pctl:press(14, 6)  -- scale picker
pctl:press(7, 3)   -- quantize row -> QUANTIZE_VALUES[8] = 8
check('grid quantize edit reflects to param', fake:get('quantize') == 8)
pctl:press(14, 6)  -- close picker

-- render coalescing: actions raise the flag, flush repaints once
psync.render_pending = false
fake:set('ch1_prob', 10)
check('param action requests coalesced render', psync.render_pending == true)
psync:flush()
check('flush clears the pending render', psync.render_pending == false)

-- pset-load hook: action_read re-reflects everything
peng.channels[5].burstProb = 3 / 14
fake.action_read()
check('action_read reflects engine state into params', fake:get('ch5_prob') == 3)

print('')
if fail == 0 then print('ALL PASS') else print(fail .. ' FAILURE(S)') os.exit(1) end
