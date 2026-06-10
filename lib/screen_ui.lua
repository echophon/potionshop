-- screen_ui.lua
-- Rich screen navigation: a complete secondary control surface (128x64 screen,
-- 3 encoders, 3 keys) that duplicates the grid's editing functions. Built on
-- the stock `ui` library (UI.Pages for the page indicator, UI.List for the
-- per-channel parameter list); the step-bar view and channel strip are
-- hand-drawn.
--
-- Control scheme:
--   E1 = select channel (1..6)
--   E2 = select param (div/reps/note/level/harm/env); K1 held -> select step
--   E3 = change the focused step's value (snapped through STEP_PICKER_VALUES,
--        so screen edits stay grid-reachable just like grid edits)
--   K1 = shift (hold)
--   K2 = launch / stop the selected channel
--   K3 = cycle page/mode (MAIN -> SND -> PROB -> RST); K1+K3 opens scale picker
--
-- The screen mutates state through the SAME GridUI methods the grid uses, so a
-- screen edit repaints the grid and vice-versa.

local UI     = require 'ui'
local seqx   = require 'seqx'
local scales = require 'scales'

local PARAMS = {'div', 'reps', 'note', 'level', 'harm', 'env'}
local PAGES  = {'MAIN', 'SND', 'PROB', 'RST'}

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- index of the picker value nearest `cur` (1-based).
local function nearest_index(layout, cur)
  local best, bd = 1, math.huge
  for i = 1, #layout do
    local d = math.abs(layout[i] - cur)
    if d < bd then bd = d; best = i end
  end
  return best
end

-- compact value formatting for the list (env shown on the 0..31 grid scale).
local function fmt(param, v)
  if param == 'env' then return tostring(math.floor(v * 31 + 0.5)) end
  if param == 'level' then return string.format('%.2f', v) end
  if param == 'harm' then return string.format('%.1f', v) end
  return tostring(v)
end

local Screen = {}
Screen.__index = Screen

function Screen.new(engine, controller)
  local self = setmetatable({}, Screen)
  self.engine = engine
  self.ctl = controller
  self.SPV = controller.STEP_PICKER_VALUES
  self.sel_ch = 0
  self.sel_param = 3  -- note
  self.sel_step = 0
  self.k1 = false
  self.page = 1
  self.pages = UI.Pages.new(1, #PAGES)
  self.list = UI.List.new(0, 12, self.sel_param, {})
  return self
end

function Screen:_clamp_step()
  local seq = self.ctl:seq_ref(self.sel_ch, PARAMS[self.sel_param], 'A')
  local len = seqx.len(seq)
  self.sel_step = clamp(self.sel_step, 0, math.max(0, len - 1))
end

function Screen:set_page(p)
  self.page = ((p - 1) % #PAGES) + 1
  self.pages:set_index(self.page)
  local c = self.ctl
  c.picker = nil; c.kbMode = false; c.actionMode = nil
  c.soundMode = (self.page == 2)
  c.probMode  = (self.page == 3)
  c.resetMode = (self.page == 4)
  c:render_all()
end

function Screen:enc(n, d)
  if n == 1 then
    self.sel_ch = clamp(self.sel_ch + d, 0, 5)
    self:_clamp_step()
  elseif n == 2 then
    if self.k1 then
      self.sel_step = self.sel_step + d
      self:_clamp_step()
    else
      self.sel_param = clamp(self.sel_param + d, 1, #PARAMS)
      -- keep the grid's selected param in sync so both surfaces agree
      self.ctl.selectedParam = PARAMS[self.sel_param]
      self.ctl.paramLayer = 'A'
      self.ctl:render_all()
      self:_clamp_step()
    end
  elseif n == 3 then
    self:_edit_value(d)
  end
end

function Screen:_edit_value(d)
  local param = PARAMS[self.sel_param]
  local seq = self.ctl:seq_ref(self.sel_ch, param, 'A')
  local src = seqx.values(seq)
  if #src == 0 then return end
  self:_clamp_step()
  local vals = {}
  for i = 1, #src do vals[i] = src[i] end
  local layout = self.SPV[param]
  local idx = nearest_index(layout, vals[self.sel_step + 1])
  idx = clamp(idx + d, 1, #layout)
  vals[self.sel_step + 1] = layout[idx]
  self.ctl:commit_step(self.sel_ch, param, vals, 'A')
  self.ctl:render_all()
end

function Screen:key(n, z)
  if n == 1 then
    self.k1 = (z == 1)
  elseif n == 2 and z == 1 then
    local ch1 = self.sel_ch + 1
    if self.engine:is_running(ch1) then self.engine:stop(ch1) else self.engine:launch(ch1) end
  elseif n == 3 and z == 1 then
    if self.k1 then
      self.ctl:open_scale_picker()
    else
      self:set_page(self.page + 1)
    end
  end
end

function Screen:redraw()
  screen.clear()

  -- top: page name + bpm + scale
  screen.level(15); screen.move(0, 7)
  screen.text(self.ctl:current_page())
  screen.level(3); screen.move(128, 7); screen.text_right(self.ctl.selectedScaleName)
  local bpm
  if clock then
    if clock.get_tempo then bpm = clock.get_tempo()
    elseif type(clock.tempo) == 'number' then bpm = clock.tempo end
  end
  if type(bpm) == 'number' then
    screen.level(3); screen.move(64, 7); screen.text(math.floor(bpm) .. ' bpm')
  end
  self.pages:redraw()

  -- channel strip (row of 6): filled = running, outlined = selected
  for ch = 0, 5 do
    local x = ch * 11 + 2
    local running = self.engine:is_running(ch + 1)
    screen.level(running and 15 or 3)
    screen.rect(x + 0.5, 11.5, 8, 5)
    if ch == self.sel_ch then
      screen.stroke()
      screen.level(running and 15 or 6)
      screen.move(x + 4, 16); screen.text_center(tostring(ch + 1))
    elseif running then
      screen.fill()
    else
      screen.stroke()
    end
  end

  -- param list for the selected channel (UI.List)
  local entries = {}
  for i, p in ipairs(PARAMS) do
    local seq = self.ctl:seq_ref(self.sel_ch, p, 'A')
    local vals = seqx.values(seq)
    local shown = {}
    for j = 1, math.min(#vals, 4) do shown[j] = fmt(p, vals[j]) end
    local suffix = (#vals > 4) and '..' or ''
    entries[i] = p .. ' ' .. table.concat(shown, ',') .. suffix
  end
  self.list.entries = entries
  self.list.x = 0
  self.list.y = 22
  self.list:set_index(self.sel_param)
  self.list:redraw()

  -- step bars for the selected param at the bottom
  local param = PARAMS[self.sel_param]
  local seq = self.ctl:seq_ref(self.sel_ch, param, 'A')
  local vals = seqx.values(seq)
  local layout = self.SPV[param]
  local maxidx = #layout
  local ph = seqx.playhead(seq)
  local running = self.engine:is_running(self.sel_ch + 1)
  for i = 1, #vals do
    local x = 66 + (i - 1) * 8
    if x <= 122 then
      local idx = nearest_index(layout, vals[i])
      local h = clamp(math.floor((idx / maxidx) * 24 + 0.5), 1, 24)
      local cursor = (i - 1) == self.sel_step
      screen.level(cursor and 15 or 5)
      screen.rect(x, 56 - h, 6, h)
      screen.fill()
      if running and (i - 1) == ph then
        screen.level(15); screen.rect(x, 58, 6, 1); screen.fill()
      end
    end
  end

  -- status line
  screen.level(2); screen.move(0, 63)
  local s = self.ctl.status or ''
  if #s > 42 then s = string.sub(s, 1, 42) end
  screen.text(s)

  screen.update()
end

return Screen
