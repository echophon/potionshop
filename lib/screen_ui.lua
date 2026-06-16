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
--   E2 = scroll the cursor through every position on a sequence page
--        (main/alt): the run line, then each step of each param line in
--        turn. Each param line ends in a temporary `_` add slot.
--        (Other pages: select line.)
--   E3 = edit under the cursor. run: right = launch, left = stop. steps:
--        change the value (grid-reachable snapped); decrement below the
--        lowest value to remove the step; on `_`, increment to append one.
--   K2 / K3 = page back / forward (main · alt · perf · prob · scale · snd,
--        clamped; order mirrors the grid's row-6 button layout)
--   K1 = untouched — left to the norns system menus
--
-- Pages: `main` edits launch + the six A-layer param sequences (via the same
-- commit_step path the grid uses); `alt` is its clone for the B (additive
-- offset) layer, snapping to the same extended value set params_sync uses
-- (literal 0 = no offset, plus the picker grid); `perf` / `prob` / `snd` edit
-- the selected channel's mode fields — the same fields the grid's perfMode/
-- probMode/soundMode presses set, picking only from GridUI's shared value
-- tables; `scale` edits the global musical state (root, key mask, quantize)
-- the grid's scale picker drives — its E2 cursor walks root, the twelve
-- chromatic keys, then quantize, and E3 sets/toggles via the controller's
-- set_root / set_mask / set_quantize. The grid's PERF/PROB/QNT/SND buttons
-- still switch the matching pages (QNT opens the shared scale picker); the
-- screen tab follows, and main/alt drive the grid's paramLayer.
--
-- Redraw model: state changes set `dirty`; the host calls tick() at ~15 Hz
-- (piggybacking on the strobe metro) and we repaint only when dirty — the
-- same dirty-flag clock pattern less-concepts uses for its reactive screen.

local seqx   = require 'seqx'
local GridUI = require 'grid_ui'

local PARAMS = {'div', 'reps', 'note', 'level', 'harm', 'env'}
-- Page order mirrors the grid's row-6 button layout (perf · prob · scale · snd),
-- after the two sequence pages. K2/K3 walk this list; the grid mode buttons map
-- onto the same pages (see _sync_page_from_grid).
local PAGES  = {'main', 'alt', 'perf', 'prob', 'scale', 'snd'}
-- main/alt line 1 = run. scale = root + 12 chromatic keys + quantize = 14 stops.
local LINES_PER_PAGE = {1 + #PARAMS, 1 + #PARAMS, 3, 4, 14, 4}
local PAGE_PERF, PAGE_PROB, PAGE_SCALE, PAGE_SND = 3, 4, 5, 6

local NOTE_NAMES = {'c','c#','d','d#','e','f','f#','g','g#','a','a#','b'}

local FIRE_FLASH_SECS = 0.12
local ENV_GLYPH_SECS  = 1.0   -- how long the focused-row letter pulse fades over
local HIST_SECS       = 2.5   -- time window the scrolling amplitude trail spans
local HIST_CAP        = 96    -- max retained fires per channel

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

-- index of the picker value nearest `cur` (1-based); one snapping rule shared
-- with the grid + params surfaces.
local nearest_index = GridUI.nearest_index

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
  self._focus_seen = 0  -- last grid focusSeq adopted (edge-trigger; see _sync_focus_from_grid)
  self.sel_line = {4, 4, 1, 1, 1, 1}  -- per-page focused line (main/alt default to note)
  self.sel_step = 0
  self.page = 1
  self.dirty = true
  self.last_note = {}   -- ch (0-based) -> note name of last fire
  self.fire_time = {}   -- ch (0-based) -> time of last fire
  self.hist = {}        -- ch (0-based) -> ring of {t, a} fires (scrolling sparkline)
  for ch = 0, 5 do self.hist[ch] = {} end
  engine:on(function(ev)
    if ev.type == 'fire' then
      -- every 'fire' counts, including a per-hit-skip (no voice) — consistent
      -- with the header flash; it feeds the channel's scrolling amplitude trail
      local ch = ev.ch - 1
      self.last_note[ch] = freq_to_name(ev.freq) or self.last_note[ch]
      self.fire_time[ch] = now()
      local h = self.hist[ch]
      h[#h + 1] = { t = now(), a = ev.level or 0 }
      if #h > HIST_CAP then table.remove(h, 1) end
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
  -- keep repainting while any channel's amplitude trail is still scrolling
  for ch = 0, 5 do
    local t = self.fire_time[ch]
    if t and (now() - t) < HIST_SECS then self.dirty = true end
  end
  if self.dirty then self:redraw() end
end

-- pages 1 (main) and 2 (alt) are the two sequence pages; alt edits the
-- B (additive offset) layer through the same machinery.
function Screen:_seq_page() return self.page <= 2 end
function Screen:layer() return (self.page == 2) and 'B' or 'A' end

-- value layout for the focused param on this page. The B layer's value set
-- is params_sync's: literal 0 (the no-offset default) plus the picker grid —
-- prepended only where the A layout doesn't already start at 0.
function Screen:_layout(param)
  local layout = self.SPV[param]
  if self:layer() == 'B' and layout[1] ~= 0 then
    local t = {0}
    for i = 1, #layout do t[i + 1] = layout[i] end
    return t
  end
  return layout
end

-- sequence page line 1 is `run`; lines 2..7 are the six params.
function Screen:main_param()
  if not self:_seq_page() then return nil end
  local line = self.sel_line[self.page]
  if line >= 2 then return PARAMS[line - 1] end
  return nil
end

-- cursor positions on a sequence-page line: `run` has one; a param line has
-- one per step plus a trailing `_` add slot (unless at the 16-step grid cap).
function Screen:_main_positions(line)
  if line == 1 then return 1 end
  local param = PARAMS[line - 1]
  local len = seqx.len(self.ctl:seq_ref(self.sel_ch, param, self:layer()))
  return (len < 16) and (len + 1) or len
end

-- true when the cursor sits on the focused param's `_` add slot.
function Screen:_on_add_slot()
  local param = self:main_param()
  if not param then return false end
  return self.sel_step >= seqx.len(self.ctl:seq_ref(self.sel_ch, param, self:layer()))
end

function Screen:_clamp_step()
  local param = self:main_param()
  if not param then self.sel_step = 0; return end
  self.sel_step = clamp(self.sel_step, 0, self:_main_positions(self.sel_line[self.page]) - 1)
end

-- move the sequence-page cursor one position, flowing across lines: run,
-- then every step (+ add slot) of each param line in turn.
function Screen:_move_cursor(dir)
  local pg = self.page
  local line, pos = self.sel_line[pg], self.sel_step + dir
  if pos < 0 then
    if line > 1 then
      line = line - 1
      pos = self:_main_positions(line) - 1
    else
      pos = 0
    end
  elseif pos >= self:_main_positions(line) then
    if line < LINES_PER_PAGE[pg] then
      line = line + 1
      pos = 0
    else
      pos = self:_main_positions(line) - 1
    end
  end
  self.sel_line[pg], self.sel_step = line, pos
end

-- keep the grid's selected param + layer agreeing with the focused line/page.
function Screen:_sync_selected_param()
  local param = self:main_param()
  if param and (self.ctl.selectedParam ~= param or self.ctl.paramLayer ~= self:layer()) then
    self.ctl.selectedParam = param
    self.ctl.paramLayer = self:layer()
    self.ctl:render_all()
  end
end

function Screen:set_page(p)
  self.page = ((p - 1) % #PAGES) + 1
  local c = self.ctl
  c.kbMode = false; c.actionMode = nil
  c.perfMode  = (self.page == PAGE_PERF)
  c.probMode  = (self.page == PAGE_PROB)
  c.soundMode = (self.page == PAGE_SND)
  -- the scale page shares the grid's scale picker, so the grid follows the
  -- screen onto it (and the keymask/root/quantize stay one source of truth)
  if self.page == PAGE_SCALE then
    if not (c.picker and c.picker.kind == 'scale') then c:open_scale_picker() end
  else
    c.picker = nil
  end
  if self:_seq_page() then
    c.paramLayer = self:layer()
    self:_clamp_step()
  end
  c:render_all()
  self.dirty = true
end

-- The grid's PERF/PROB/SND buttons toggle the same modes set_page sets; follow
-- them so the screen tab always matches what the grid is showing. With no mode
-- active we're on a sequence page: follow the grid's paramLayer so re-pressing a
-- row-7 param (the double-press that flips A↔B) swaps the screen to main/alt.
function Screen:_sync_page_from_grid()
  local c = self.ctl
  self.page = (c.picker and c.picker.kind == 'scale') and PAGE_SCALE
    or c.perfMode and PAGE_PERF or c.probMode and PAGE_PROB or c.soundMode and PAGE_SND
    or ((c.paramLayer == 'B') and 2 or 1)
end

-- Channel focus follows the grid: the grid bumps focusSeq each time a press
-- targets a channel. We adopt its focusCh once per bump (edge-triggered, so E1
-- stays free to scroll channels between grid touches, and a repeat edit of the
-- same channel still pulls focus back).
function Screen:_sync_focus_from_grid()
  local c = self.ctl
  if c.focusSeq ~= self._focus_seen then
    self._focus_seen = c.focusSeq
    if self.sel_ch ~= c.focusCh then
      self.sel_ch = c.focusCh
      self:_clamp_step()
      self.dirty = true
    end
  end
end

-- ---- input ---------------------------------------------------------------

function Screen:enc(n, d)
  self:_sync_page_from_grid()
  self:_sync_focus_from_grid()
  if n == 1 then
    self.sel_ch = clamp(self.sel_ch + d, 0, 5)
    self:_clamp_step()
  elseif n == 2 then
    if self:_seq_page() then
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
  if self:_seq_page() then self:_edit_main(d)
  elseif self.page == PAGE_PERF then self:_edit_perf(d)
  elseif self.page == PAGE_PROB then self:_edit_prob(d)
  elseif self.page == PAGE_SCALE then self:_edit_scale(d)
  elseif self.page == PAGE_SND then self:_edit_snd(d) end
  self.ctl:render_all()
end

-- Scale page cursor: line 1 = root, lines 2..13 = the twelve chromatic keys
-- (pitch class = line - 2), line 14 = quantize. E3 turns right/left to raise or
-- lower root/quantize; on a key, right adds it to the mask, left removes it
-- (mirroring the run line's right=on / left=off feel). All edits route through
-- the controller's global setters so on_edit reflects them into the params.
function Screen:_edit_scale(d)
  local c = self.ctl
  local line = self.sel_line[PAGE_SCALE]
  if line == 1 then
    c:set_root(((self.engine.root or 0) + d) % 12)
  elseif line == LINES_PER_PAGE[PAGE_SCALE] then
    c:set_quantize(self.engine.quantize + d)
  else
    local pc = line - 2
    local cur, has = {}, false
    for _, s in ipairs(self.engine.scale) do
      cur[#cur + 1] = s % 12
      if s % 12 == pc then has = true end
    end
    if d > 0 and not has then
      cur[#cur + 1] = pc
      c:set_mask(cur)
    elseif d < 0 and has then
      local nxt = {}
      for _, s in ipairs(cur) do if s ~= pc then nxt[#nxt + 1] = s end end
      c:set_mask(nxt)  -- set_mask refuses to empty the scale (keeps the last degree)
    end
  end
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
  local layer = self:layer()
  local seq = self.ctl:seq_ref(self.sel_ch, param, layer)
  local src = seqx.values(seq)
  if #src == 0 then return end
  self:_clamp_step()
  local vals = {}
  for i = 1, #src do vals[i] = src[i] end
  local layout = self:_layout(param)

  -- the `_` add slot: a value below the bottom of the picker. Turning right
  -- appends a step starting from the lowest value (0 = no offset on alt).
  if self.sel_step >= #vals then
    if d > 0 and #vals < 16 then
      vals[#vals + 1] = layout[clamp(d, 1, #layout)]
      self.ctl:commit_step(self.sel_ch, param, vals, layer)
    end
    return
  end

  local idx = nearest_index(layout, vals[self.sel_step + 1]) + d
  if idx < 1 then
    -- decrementing below the lowest value removes the step (it becomes `_`);
    -- the last remaining step just clamps instead
    if #vals > 1 then
      table.remove(vals, self.sel_step + 1)
      self.ctl:commit_step(self.sel_ch, param, vals, layer)
      self:_clamp_step()
    end
    return
  end
  vals[self.sel_step + 1] = layout[clamp(idx, 1, #layout)]
  self.ctl:commit_step(self.sel_ch, param, vals, layer)
end

-- step an indexed mode/value field through a shared GridUI table.
local function step_table(cur, tbl, d)
  local idx = 1
  for i, v in ipairs(tbl) do if v == cur then idx = i break end end
  return tbl[clamp(idx + d, 1, #tbl)]
end

function Screen:_edit_snd(d)
  local ch = self.sel_ch
  local c = self.engine.channels[ch + 1]
  local line = self.sel_line[PAGE_SND]
  if line == 1 then self.ctl:set_scalar(ch, 'envMode', clamp(c.envMode + d, 0, #GridUI.ENV_MODE_NAMES - 1))
  elseif line == 2 then self.ctl:set_scalar(ch, 'geodeMode', clamp(c.geodeMode + d, 0, #GridUI.GEODE_MODE_NAMES - 1))
  elseif line == 3 then self.ctl:set_scalar(ch, 'harmEnvMode', clamp(c.harmEnvMode + d, 0, #GridUI.HARM_ENV_MODE_NAMES - 1))
  elseif line == 4 then self.ctl:set_scalar(ch, 'harmEnv', clamp(c.harmEnv + d, 0, #GridUI.HARM_GEODE_NAMES - 1))
  end
end

function Screen:_edit_prob(d)
  local ch = self.sel_ch
  local c = self.engine.channels[ch + 1]
  local line = self.sel_line[PAGE_PROB]
  if line == 1 then
    -- step the discrete 25/50/75/100% set shared with the grid prob page
    self.ctl:set_scalar(ch, 'burstProb', step_table(c.burstProb, GridUI.PROB_VALUES, d))
  elseif line == 2 then
    self.ctl:set_scalar(ch, 'probHit', not c.probHit)
  elseif line == 3 then
    self.ctl:set_scalar(ch, 'altTrig', clamp(c.altTrig + d, 0, #GridUI.ALT_TRIG_MODE_NAMES - 1))
  else
    self.ctl:set_scalar(ch, 'harmTrig', clamp(c.harmTrig + d, 0, #GridUI.ALT_TRIG_MODE_NAMES - 1))
  end
end

function Screen:_edit_perf(d)
  local ch = self.sel_ch
  local c = self.engine.channels[ch + 1]
  local line = self.sel_line[PAGE_PERF]
  if line == 1 then
    self.ctl:set_scalar(ch, 'resetInterval', step_table(c.resetInterval, GridUI.RESET_INTERVALS, d))
  elseif line == 2 then
    self.ctl:set_scalar(ch, 'octave', step_table(c.octave, GridUI.OCTAVE_VALUES, d))
  else
    self.ctl:set_scalar(ch, 'rate', step_table(c.rate, GridUI.RATE_VALUES, d))
  end
end

-- K1 is left untouched for the norns system. K2/K3 page back/forward,
-- clamping at the ends; E2's walking cursor covers travel within a page.
function Screen:key(n, z)
  if z ~= 1 then return end
  self:_sync_page_from_grid()
  self:_sync_focus_from_grid()
  if n == 2 or n == 3 then
    self:set_page(clamp(self.page + (n == 3 and 1 or -1), 1, #PAGES))
    if self:_seq_page() then self:_sync_selected_param() end
  end
end

-- ---- drawing -------------------------------------------------------------

-- Left-column layout: six rows (one per channel), each a small note letter plus
-- a scrolling amplitude trail of that channel's recent fires. Lives above the
-- A/B step footer (y>=52), so rows run y~13..48.
local COL_LETTER_X  = 2    -- note-name x
local COL_GLYPH_X   = 16   -- sparkline x
local COL_GLYPH_W   = 28   -- sparkline width (== HIST_SECS time span)
local COL_ROW_TOP   = 13   -- first row baseline
local COL_ROW_PITCH = 7    -- baseline-to-baseline
local COL_ENV_H     = 6    -- full-height bar (normalized loudest hit) in px

-- Letter brightness as the channel's last fire ages: the focused row pulses
-- 15 -> 5; the rest sit at a dim 2 with a brief flash. Same focus-brightness
-- spirit as the rest of the screen.
function Screen:row_level(sel, age)
  if sel then return round(5 + 10 * math.max(0, 1 - age / ENV_GLYPH_SECS)) end
  return round(2 + 6 * math.max(0, 1 - age / 0.4))
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

-- One channel's scrolling amplitude trail: each recent fire is a vertical bar,
-- positioned by age (newest at the right "playhead" edge, drifting left and out
-- of the window). Heights are normalized to the loudest hit in *this* channel's
-- window, so soft channels still use the full row height and adjacent hits read
-- as more than a 1px difference. Older bars fade so the motion is legible.
function Screen:draw_sparkline(ch, x0, yb, sel)
  local h = self.hist[ch]
  if #h == 0 then return end
  local t = now()
  -- per-channel normalization: find the loudest visible hit
  local maxa = 0
  for i = #h, 1, -1 do
    local age = t - h[i].t
    if age > HIST_SECS then break end
    if h[i].a > maxa then maxa = h[i].a end
  end
  if maxa <= 0 then return end
  local base = sel and 13 or 5
  for i = #h, 1, -1 do
    local age = t - h[i].t
    if age > HIST_SECS then break end
    local x = round(x0 + COL_GLYPH_W * (1 - age / HIST_SECS))
    local bar = math.max(1, round((h[i].a / maxa) * COL_ENV_H))
    screen.level(math.max(2, round(base * math.max(0.3, 1 - age / HIST_SECS))))
    screen.move(x, yb)
    screen.line(x, yb - bar)
    screen.stroke()
  end
end

-- Six-row channel column: note letter + scrolling amplitude trail per channel,
-- focused row brightest. Replaces the single big ghost glyph.
function Screen:draw_channel_column()
  local t = now()
  for ch = 0, 5 do
    local sel = (ch == self.sel_ch)
    local yb = COL_ROW_TOP + ch * COL_ROW_PITCH
    local age = t - (self.fire_time[ch] or -1e9)
    screen.level(self:row_level(sel, age))
    screen.move(COL_LETTER_X, yb)
    screen.text(self.last_note[ch] or '-')
    self:draw_sparkline(ch, COL_GLYPH_X, yb, sel)
  end
end

-- the right column: one table of {label, value, pre, tok} per page; the
-- focused line draws at 15 with an underscore under `tok` (`pre` is the text
-- between the ': ' and the focused token, for measuring where it starts).
function Screen:page_lines()
  local c = self.engine.channels[self.sel_ch + 1]
  if self:_seq_page() then
    local run_val = self.engine:is_running(self.sel_ch + 1) and 'on' or 'off'
    local lines = {
      {'run', run_val, '', run_val},
    }
    for i, p in ipairs(PARAMS) do
      local vals = seqx.values(self.ctl:seq_ref(self.sel_ch, p, self:layer()))
      local focused = (self.sel_line[self.page] == i + 1)
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
  if self.page == PAGE_SND then
    lines = {
      {'env',   GridUI.ENV_MODE_NAMES[c.envMode + 1]},
      {'geode', GridUI.GEODE_MODE_NAMES[c.geodeMode + 1]},
      {'h.env', GridUI.HARM_ENV_MODE_NAMES[c.harmEnvMode + 1]},
      {'harm',  GridUI.HARM_GEODE_NAMES[c.harmEnv + 1]},
    }
  elseif self.page == PAGE_PROB then
    lines = {
      {'prob', round(c.burstProb * 100) .. '%'},
      {'mode', c.probHit and 'hit' or 'burst'},
      {'note', GridUI.ALT_TRIG_MODE_NAMES[c.altTrig + 1]},
      {'harm', GridUI.ALT_TRIG_MODE_NAMES[c.harmTrig + 1]},
    }
  else  -- PAGE_PERF
    local iv = c.resetInterval
    lines = {
      {'reset', iv == 0 and 'off' or (iv .. (iv == 1 and ' bar' or ' bars'))},
      {'oct',   (c.octave > 0 and '+' or '') .. c.octave},
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
  -- cursor underline: between the rows when editing A (main), below the B
  -- row on alt; on the add slot it sits past the last square, reading as
  -- the `_` itself
  if self:_seq_page() and self:main_param() then
    screen.level(8)
    screen.rect(2 + self.sel_step * 5, self.page == 1 and 57 or 63, 4, 1)
    screen.fill()
  end
end

-- One-octave piano geometry for the scale page's key mask. White keys tile the
-- row; black keys are half-width / shorter and straddle the gap *above and
-- between* two white keys — with no black key between E-F or B-C, exactly like a
-- real keyboard.
local KB_X0, KB_Y = 3, 26
local KB_WW, KB_WH = 11, 24      -- white key pitch / height
local KB_BW, KB_BH = 7, 14       -- black key width / height
local WHITE_PCS = {0, 2, 4, 5, 7, 9, 11}
local BLACK_AFTER = {[1] = 0, [3] = 1, [6] = 3, [8] = 4, [10] = 5}  -- pc -> white index it follows

local function white_index(pc)
  for i, w in ipairs(WHITE_PCS) do if w == pc then return i - 1 end end
  return nil
end

-- screen rect + black/white flag for a pitch class's key
local function key_rect(pc)
  local wi = white_index(pc)
  if wi then
    return { x = KB_X0 + wi * KB_WW, y = KB_Y, w = KB_WW - 1, h = KB_WH, black = false }
  end
  local cx = KB_X0 + (BLACK_AFTER[pc] + 1) * KB_WW
  return { x = cx - math.floor(KB_BW / 2), y = KB_Y, w = KB_BW, h = KB_BH, black = true }
end

-- Scale page: shown while the grid's scale picker is open. Displays — and, via
-- E2/E3, edits — the three global musical params the picker drives: root, key
-- mask (a real piano keyboard; in-mask keys lit, root footed), and quantize.
-- The E2 cursor underlines root/quantize or caps the focused key.
function Screen:draw_scale_lines()
  local root = (self.engine.root or 0) % 12
  local cursor = self.sel_line[PAGE_SCALE]
  local on = {}
  for _, s in ipairs(self.engine.scale) do on[s % 12] = true end

  -- root + quantize text (cursor lines 1 and 14), underlined when focused
  local function label(x, focus, str)
    screen.level(focus and 15 or 4)
    screen.move(x, 14)
    screen.text(str)
    if focus then
      screen.rect(x, 16, screen.text_extents(str), 1); screen.fill()
    end
  end
  label(3, cursor == 1, 'root ' .. NOTE_NAMES[root + 1])
  local qnt = 'qnt ' .. tostring(self.engine.quantize)
  label(126 - screen.text_extents(qnt), cursor == LINES_PER_PAGE[PAGE_SCALE], qnt)

  -- white keys, then black keys on top (so they overlap the white edges)
  for _, pc in ipairs(WHITE_PCS) do
    local r = key_rect(pc)
    screen.level(on[pc] and 13 or 4)
    screen.rect(r.x, r.y, r.w, r.h); screen.fill()
    if pc == root then screen.level(15); screen.rect(r.x, r.y + r.h - 3, r.w, 2); screen.fill() end
  end
  for pc in pairs(BLACK_AFTER) do
    local r = key_rect(pc)
    screen.level(0); screen.rect(r.x - 1, r.y - 1, r.w + 2, r.h + 1); screen.fill()  -- gap so it reads as a key
    screen.level(on[pc] and 9 or 2)
    screen.rect(r.x, r.y, r.w, r.h); screen.fill()
    if pc == root then screen.level(15); screen.rect(r.x, r.y + r.h - 3, r.w, 2); screen.fill() end
  end

  -- cursor cap above the focused key (lines 2..13)
  if cursor >= 2 and cursor <= 13 then
    local r = key_rect(cursor - 2)
    screen.level(15); screen.rect(r.x, KB_Y - 4, r.w, 2); screen.fill()
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
  self:_sync_focus_from_grid()
  self.dirty = false
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  self:draw_header()
  local c = self.ctl
  if c.picker and c.picker.kind == 'scale' then
    -- scale picker open: the grid owns a global-musical gesture, so the screen
    -- shows the scale page (root/keymask/quantize) instead of the stale seq page
    self:draw_scale_lines()
    self:draw_status()
  else
    self:draw_channel_column()
    self:draw_lines()
    -- when the grid is mid-gesture (picker / kb / action), it owns interaction:
    -- swap the step rows for the dim status line
    if c.kbMode or c.picker or c.actionMode then
      self:draw_status()
    else
      self:draw_steps()
    end
  end
  screen.update()
end

return Screen
