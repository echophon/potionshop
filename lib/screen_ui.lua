-- screen_ui.lua
-- Minimalist screen surface in the style of `less concepts` (vicimity/dndrks):
--   * focus-driven brightness — the focused line is level 15, everything else
--     level 2; no cursor glyphs
--   * tiny 4x4 squares as indicator rows (channels up top, steps down below),
--     with a 1px underline marking selection
--   * a big "ghost" note-name glyph (level-1 base + brighter offset echo) that
--     pulses when the selected channel fires
--   * lowercase text, font_face 1 / size 8, `a: x // b: y` formatting
--
-- Control scheme:
--   E1 = select channel (1..6)
--   E2 = scroll the cursor through every position on the main page: the run
--        line, then each step of each param line in turn. Each param line
--        ends in a temporary `_` add slot. (Other pages: select line.)
--   E3 = edit under the cursor. run: right = launch, left = stop. steps:
--        change the value (grid-reachable snapped); decrement below the
--        lowest value to remove the step; on `_`, increment to append one.
--   K2 / K3 = jump to the previous / next line (the fast lane; E2 walks)
--   K1 = untouched — left to the norns system menus
--
-- Pages: `main` edits launch + the six param sequences (via the same
-- commit_step path the grid uses); `snd` / `prob` / `rst` edit the selected
-- channel's mode fields — the same fields the grid's soundMode/probMode/
-- resetMode presses set, picking only from GridUI's shared value tables.
-- Page switching and the scale picker live on the grid (RST/PROB/SND/QNT
-- buttons); the screen tab follows.
--
-- Redraw model: state changes set `dirty`; the host calls tick() at ~15 Hz
-- (piggybacking on the strobe metro) and we repaint only when dirty — the
-- same dirty-flag clock pattern less-concepts uses for its reactive screen.

local seqx   = require 'seqx'
local GridUI = require 'grid_ui'

local PARAMS = {'div', 'reps', 'note', 'level', 'harm', 'env'}
local PAGES  = {'main', 'snd', 'prob', 'rst'}
local LINES_PER_PAGE = {1 + #PARAMS, 4, 2, 2}  -- main line 1 = run

local NOTE_NAMES = {'c','c#','d','d#','e','f','f#','g','g#','a','a#','b'}

local FIRE_FLASH_SECS = 0.12

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function round(x) return math.floor(x + 0.5) end

local function now()
  if util and util.time then return util.time() end
  return os.clock()
end

-- frequency -> lowercase note name ('c3'); MIDI-rounded, A4 = 440.
local function freq_to_name(f)
  if not f or f <= 0 then return nil end
  local n = round(12 * math.log(f / 440) / math.log(2) + 69)
  return NOTE_NAMES[(n % 12) + 1] .. (math.floor(n / 12) - 1)
end

-- index of the picker value nearest `cur` (1-based).
local function nearest_index(layout, cur)
  local best, bd = 1, math.huge
  for i = 1, #layout do
    local d = math.abs(layout[i] - cur)
    if d < bd then bd = d; best = i end
  end
  return best
end

-- compact value formatting for the lines (env shown on the 0..31 grid scale).
local function fmt(param, v)
  if param == 'env' then return tostring(math.floor(v * 31 + 0.5)) end
  if param == 'level' then return string.format('%.2f', v) end
  if param == 'harm' then return string.format('%.1f', v) end
  return tostring(v)
end

local function fmt_rate(v)
  if v % 1 == 0 then return string.format('%dx', v) end
  return tostring(v) .. 'x'
end

local Screen = {}
Screen.__index = Screen

function Screen.new(engine, controller)
  local self = setmetatable({}, Screen)
  self.engine = engine
  self.ctl = controller
  self.SPV = controller.STEP_PICKER_VALUES
  self.sel_ch = 0
  self.sel_line = {4, 1, 1, 1}  -- per-page focused line (main defaults to note)
  self.sel_step = 0
  self.page = 1
  self.dirty = true
  self.last_note = {}  -- ch (0-based) -> note name of last fire
  self.fire_time = {}  -- ch (0-based) -> time of last fire
  engine:on(function(ev)
    if ev.type == 'fire' then
      local ch = ev.ch - 1
      self.last_note[ch] = freq_to_name(ev.freq) or self.last_note[ch]
      self.fire_time[ch] = now()
      self.dirty = true
    elseif ev.type == 'launch' or ev.type == 'stop' then
      self.dirty = true
    end
  end)
  return self
end

function Screen:tick()
  -- never draw over the system menu: metros keep running when the script
  -- loses focus (K1), and an unguarded redraw stomps the menu screen
  if norns and norns.menu and norns.menu.status and norns.menu.status() then return end
  -- keep repainting while a fire flash / glyph pulse is decaying
  local ft = self.fire_time[self.sel_ch]
  if ft and (now() - ft) < 1.5 then self.dirty = true end
  for ch = 0, 5 do
    local t = self.fire_time[ch]
    if t and (now() - t) < FIRE_FLASH_SECS then self.dirty = true end
  end
  if self.dirty then self:redraw() end
end

-- main page line 1 is `run`; lines 2..7 are the six params.
function Screen:main_param()
  if self.sel_line[1] >= 2 then return PARAMS[self.sel_line[1] - 1] end
  return nil
end

-- cursor positions on a main-page line: `run` has one; a param line has one
-- per step plus a trailing `_` add slot (unless at the 16-step grid cap).
function Screen:_main_positions(line)
  if line == 1 then return 1 end
  local param = PARAMS[line - 1]
  local len = seqx.len(self.ctl:seq_ref(self.sel_ch, param, 'A'))
  return (len < 16) and (len + 1) or len
end

-- true when the cursor sits on the focused param's `_` add slot.
function Screen:_on_add_slot()
  local param = self:main_param()
  if not param then return false end
  return self.sel_step >= seqx.len(self.ctl:seq_ref(self.sel_ch, param, 'A'))
end

function Screen:_clamp_step()
  local param = self:main_param()
  if not param then self.sel_step = 0; return end
  self.sel_step = clamp(self.sel_step, 0, self:_main_positions(self.sel_line[1]) - 1)
end

-- move the main-page cursor one position, flowing across lines: run, then
-- every step (+ add slot) of each param line in turn.
function Screen:_move_cursor(dir)
  local line, pos = self.sel_line[1], self.sel_step + dir
  if pos < 0 then
    if line > 1 then
      line = line - 1
      pos = self:_main_positions(line) - 1
    else
      pos = 0
    end
  elseif pos >= self:_main_positions(line) then
    if line < LINES_PER_PAGE[1] then
      line = line + 1
      pos = 0
    else
      pos = self:_main_positions(line) - 1
    end
  end
  self.sel_line[1], self.sel_step = line, pos
end

-- keep the grid's selected param agreeing with the focused line.
function Screen:_sync_selected_param()
  local param = self:main_param()
  if param and self.ctl.selectedParam ~= param then
    self.ctl.selectedParam = param
    self.ctl.paramLayer = 'A'
    self.ctl:render_all()
  end
end

function Screen:set_page(p)
  self.page = ((p - 1) % #PAGES) + 1
  local c = self.ctl
  c.picker = nil; c.kbMode = false; c.actionMode = nil
  c.soundMode = (self.page == 2)
  c.probMode  = (self.page == 3)
  c.resetMode = (self.page == 4)
  c:render_all()
  self.dirty = true
end

-- The grid's RST/PROB/SND buttons toggle the same modes set_page sets; follow
-- them so the screen tab always matches what the grid is showing.
function Screen:_sync_page_from_grid()
  local c = self.ctl
  self.page = c.soundMode and 2 or c.probMode and 3 or c.resetMode and 4 or 1
end

-- ---- input ---------------------------------------------------------------

function Screen:enc(n, d)
  self:_sync_page_from_grid()
  if n == 1 then
    self.sel_ch = clamp(self.sel_ch + d, 0, 5)
    self:_clamp_step()
  elseif n == 2 then
    if self.page == 1 then
      local dir = (d >= 0) and 1 or -1
      for _ = 1, math.abs(d) do self:_move_cursor(dir) end
      self:_sync_selected_param()
    else
      local p = self.page
      self.sel_line[p] = clamp(self.sel_line[p] + d, 1, LINES_PER_PAGE[p])
    end
  elseif n == 3 then
    self:_edit_value(d)
  end
  self.dirty = true
end

function Screen:_edit_value(d)
  if self.page == 1 then self:_edit_main(d)
  elseif self.page == 2 then self:_edit_snd(d)
  elseif self.page == 3 then self:_edit_prob(d)
  elseif self.page == 4 then self:_edit_rst(d) end
  self.ctl:render_all()
end

function Screen:_edit_main(d)
  local param = self:main_param()
  if not param then
    -- `run` line: turn right to launch, left to stop
    local ch1 = self.sel_ch + 1
    if d > 0 and not self.engine:is_running(ch1) then self.engine:launch(ch1)
    elseif d < 0 and self.engine:is_running(ch1) then self.engine:stop(ch1) end
    return
  end
  local seq = self.ctl:seq_ref(self.sel_ch, param, 'A')
  local src = seqx.values(seq)
  if #src == 0 then return end
  self:_clamp_step()
  local vals = {}
  for i = 1, #src do vals[i] = src[i] end
  local layout = self.SPV[param]

  -- the `_` add slot: a value below the bottom of the picker. Turning right
  -- appends a step starting from the lowest picker value.
  if self.sel_step >= #vals then
    if d > 0 and #vals < 16 then
      vals[#vals + 1] = layout[clamp(d, 1, #layout)]
      self.ctl:commit_step(self.sel_ch, param, vals, 'A')
    end
    return
  end

  local idx = nearest_index(layout, vals[self.sel_step + 1]) + d
  if idx < 1 then
    -- decrementing below the lowest value removes the step (it becomes `_`);
    -- the last remaining step just clamps instead
    if #vals > 1 then
      table.remove(vals, self.sel_step + 1)
      self.ctl:commit_step(self.sel_ch, param, vals, 'A')
      self:_clamp_step()
    end
    return
  end
  vals[self.sel_step + 1] = layout[clamp(idx, 1, #layout)]
  self.ctl:commit_step(self.sel_ch, param, vals, 'A')
end

-- step an indexed mode/value field through a shared GridUI table.
local function step_table(cur, tbl, d)
  local idx = 1
  for i, v in ipairs(tbl) do if v == cur then idx = i break end end
  return tbl[clamp(idx + d, 1, #tbl)]
end

function Screen:_edit_snd(d)
  local c = self.engine.channels[self.sel_ch + 1]
  local line = self.sel_line[2]
  if line == 1 then c.envMode  = clamp(c.envMode + d, 0, #GridUI.ENV_MODE_NAMES - 1)
  elseif line == 2 then c.geodeMode = clamp(c.geodeMode + d, 0, #GridUI.GEODE_MODE_NAMES - 1)
  elseif line == 3 then c.pitchEnv = clamp(c.pitchEnv + d, 0, #GridUI.PITCH_ENV_MODE_NAMES - 1)
  elseif line == 4 then c.harmEnv = clamp(c.harmEnv + d, 0, #GridUI.HARM_ENV_MODE_NAMES - 1)
  end
end

function Screen:_edit_prob(d)
  local c = self.engine.channels[self.sel_ch + 1]
  if self.sel_line[3] == 1 then
    -- snap to the grid slider's 0..14 columns so edits stay grid-reachable
    local k = clamp(round(c.burstProb * 14) + d, 0, 14)
    c.burstProb = k / 14
  else
    c.probHit = not c.probHit
  end
end

function Screen:_edit_rst(d)
  local c = self.engine.channels[self.sel_ch + 1]
  if self.sel_line[4] == 1 then
    c.resetInterval = step_table(c.resetInterval, GridUI.RESET_INTERVALS, d)
  else
    c.rate = step_table(c.rate, GridUI.RATE_VALUES, d)
  end
end

-- K1 is left untouched for the norns system. K2/K3 jump a whole line at a
-- time (E2 walks every step position, so this is the fast lane between lines).
function Screen:key(n, z)
  if z ~= 1 then return end
  self:_sync_page_from_grid()
  if n == 2 or n == 3 then
    local p = self.page
    self.sel_line[p] = clamp(self.sel_line[p] + (n == 3 and 1 or -1), 1, LINES_PER_PAGE[p])
    if p == 1 then
      self.sel_step = 0
      self:_sync_selected_param()
    end
    self.dirty = true
  end
end

-- ---- drawing -------------------------------------------------------------

-- Ghost glyph brightness as the last fire on the selected channel ages.
-- Returns base, echo levels. The aesthetic knob of the whole screen: a bright
-- pulse at fire that settles into a faint persistent watermark.
function Screen:glyph_levels(age)
  local echo = 2 + 8 * math.max(0, 1 - age / 1.2)
  return 1, round(echo)
end

function Screen:draw_header()
  -- six channel squares: fire flash 15 > running 10 > stopped 2
  local t = now()
  for ch = 0, 5 do
    local x = 2 + ch * 6
    local lvl = self.engine:is_running(ch + 1) and 10 or 2
    local ft = self.fire_time[ch]
    if ft and (t - ft) < FIRE_FLASH_SECS then lvl = 15 end
    screen.level(lvl)
    screen.rect(x, 1, 4, 4)
    screen.fill()
  end
  -- selected channel underline
  screen.level(8)
  screen.rect(2 + self.sel_ch * 6, 6, 4, 1)
  screen.fill()

  -- page // bpm (page slightly brighter; reflects grid reality)
  local page_name = string.lower(self.ctl:current_page())
  if page_name == 'main' then page_name = PAGES[self.page] end
  local bpm
  if clock then
    if clock.get_tempo then bpm = clock.get_tempo()
    elseif type(clock.tempo) == 'number' then bpm = clock.tempo end
  end
  screen.move(44, 6)
  screen.level(4)
  screen.text(page_name)
  if type(bpm) == 'number' then
    screen.move(44 + screen.text_extents(page_name), 6)
    screen.level(2)
    screen.text(' // ' .. math.floor(bpm))
  end
end

function Screen:draw_glyph()
  local note = self.last_note[self.sel_ch]
  if not note then return end
  local age = now() - (self.fire_time[self.sel_ch] or 0)
  local base, echo = self:glyph_levels(age)
  screen.font_size(24)
  screen.level(base)
  screen.move(2, 38)
  screen.text(note)
  screen.level(echo)
  screen.move(3, 36)
  screen.text(note)
  screen.font_size(8)
end

-- the right column: one table of {label, value, pre, tok} per page; the
-- focused line draws at 15 with an underscore under `tok` (`pre` is the text
-- between the ': ' and the focused token, for measuring where it starts).
function Screen:page_lines()
  local c = self.engine.channels[self.sel_ch + 1]
  if self.page == 1 then
    local run_val = self.engine:is_running(self.sel_ch + 1) and 'on' or 'off'
    local lines = {
      {'run', run_val, '', run_val},
    }
    for i, p in ipairs(PARAMS) do
      local vals = seqx.values(self.ctl:seq_ref(self.sel_ch, p, 'A'))
      local focused = (self.sel_line[1] == i + 1)
      -- slide a 4-value window so the cursor's step is always visible
      local first = focused and math.max(1, self.sel_step + 1 - 3) or 1
      local last = math.min(#vals, first + 3)
      local shown = {}
      for j = first, last do shown[#shown + 1] = fmt(p, vals[j]) end
      -- the temporary `_` add slot, shown while the cursor sits on it
      local on_add = focused and self.sel_step >= #vals
      if on_add then shown[#shown + 1] = '_' end
      local prefix = (first > 1) and '.. ' or ''
      local suffix = (last < #vals) and ' ..' or ''
      local pre, tok = '', nil
      if focused then
        local ti = on_add and #shown or (self.sel_step + 1 - first + 1)
        tok = shown[ti]
        pre = prefix .. table.concat(shown, ' ', 1, ti - 1) .. (ti > 1 and ' ' or '')
      end
      lines[i + 1] = {p, prefix .. table.concat(shown, ' ') .. suffix, pre, tok}
    end
    return lines
  end
  local lines
  if self.page == 2 then
    lines = {
      {'env',   GridUI.ENV_MODE_NAMES[c.envMode + 1]},
      {'geode', GridUI.GEODE_MODE_NAMES[c.geodeMode + 1]},
      {'pitch', GridUI.PITCH_ENV_MODE_NAMES[c.pitchEnv + 1]},
      {'harm',  GridUI.HARM_ENV_MODE_NAMES[c.harmEnv + 1]},
    }
  elseif self.page == 3 then
    lines = {
      {'prob', round(c.burstProb * 100) .. '%'},
      {'mode', c.probHit and 'hit' or 'burst'},
    }
  else
    local iv = c.resetInterval
    lines = {
      {'reset', iv == 0 and 'off' or (iv .. (iv == 1 and ' bar' or ' bars'))},
      {'rate',  fmt_rate(c.rate)},
    }
  end
  -- single-value lines: the whole value is the focused token
  for _, l in ipairs(lines) do l[3] = ''; l[4] = l[2] end
  return lines
end

function Screen:draw_lines()
  local lines = self:page_lines()
  local focus = self.sel_line[self.page]
  for i, l in ipairs(lines) do
    -- lines below the focused one shift 2px down, opening a gap for the
    -- underscore beneath the focused value token
    local y = 13 + (i - 1) * 6 + (i > focus and 2 or 0)
    screen.level(i == focus and 15 or 2)
    screen.move(46, y)
    screen.text(l[1] .. ': ' .. l[2])
    if i == focus and l[4] then
      local x = 46 + screen.text_extents(l[1] .. ': ' .. l[3])
      screen.level(8)
      screen.rect(x, y + 2, screen.text_extents(l[4]), 1)
      screen.fill()
    end
  end
end

-- footer: A + B step squares for the grid's selected param, brightness from
-- the same value_brightness mapping the grid LEDs use.
function Screen:draw_steps()
  local param = self.ctl.selectedParam
  local t = now()
  for li, layer in ipairs({'A', 'B'}) do
    local y = (li == 1) and 52 or 58
    local seq = self.ctl:seq_ref(self.sel_ch, param, layer)
    local vals = seqx.values(seq)
    local ph = seqx.playhead(seq)
    local running = self.engine:is_running(self.sel_ch + 1)
    for i = 1, math.min(#vals, 16) do
      local lvl = GridUI.value_brightness(param, vals[i])
      if running and (i - 1) == ph then lvl = 15 end
      screen.level(math.max(1, lvl))
      screen.rect(2 + (i - 1) * 5, y, 4, 4)
      screen.fill()
    end
  end
  -- cursor underline, between the rows (main page edits the A layer); on the
  -- add slot it sits past the last square, reading as the `_` itself
  if self.page == 1 and self:main_param() then
    screen.level(8)
    screen.rect(2 + self.sel_step * 5, 57, 4, 1)
    screen.fill()
  end
end

function Screen:draw_status()
  screen.level(2)
  screen.move(2, 60)
  local s = self.ctl.status or ''
  if #s > 42 then s = string.sub(s, 1, 42) end
  screen.text(s)
end

function Screen:redraw()
  self:_sync_page_from_grid()
  self.dirty = false
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  self:draw_header()
  self:draw_glyph()
  self:draw_lines()
  -- when the grid is mid-gesture (picker / kb / action), it owns interaction:
  -- swap the step rows for the dim status line
  local c = self.ctl
  if c.kbMode or c.picker or c.actionMode then
    self:draw_status()
  else
    self:draw_steps()
  end
  screen.update()
end

return Screen
