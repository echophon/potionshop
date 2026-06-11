-- grid_ui.lua
-- Grid controller, ported structurally 1:1 from src/grid-controller.ts.
--
-- The controller is the only consumer of grid presses and the only driver of
-- LED writes. It owns all UI state (selected param, page/picker, KB buffers,
-- the in-progress note mask, action modes) and renders via the grid wrapper's
-- set_led / set_strobe. It subscribes to engine events to repaint on
-- launch/stop and to flash playhead positions on fire.
--
-- Coordinate convention: this module stays 0-based (x = col 0..15, y = row
-- 0..7, channel index ch = 0..5) to keep the web layout math intact. The grid
-- wrapper adds the +1 for the 1-based hardware grid; engine calls convert to
-- 1-based at the call site (engine:launch(ch+1), engine.channels[ch+1], ...).
--
-- Layout reference (rows/cols, 0-based):
--   rows 0..5 = per-channel step view: cols 0..7 = A layer · cols 8..15 = B layer
--   row 6     = 0..5 launch · 6..10 dark · 11 RST · 12 KB · 13 PROB · 14 QNT · 15 SND
--   row 7     = 0..5 param (div/reps/note/level/harm/env) · 11 VOICE
--             · 12 CLR · 13 LOCK · 14 RANDOMIZE · 15 MUTATE
--   PROB:  rows 0-5 = prob slider (cols 0..14) · col 15 burst/hit toggle
--   RST:   rows 0-5 = reset interval (cols 0..8) · rate (cols 11..15)
--   SND:   rows 0-5 = env(0-2) · geode(4-7) · pitch env(8-11) · harm env(12-15)
--   scale picker: row 0 scales · rows 1-2 note-mask keyboard · rows 3-4 quantize
--   step picker:  rows 0-1 value grid
--   KB mode: see handle_kb_press / render_kb_mode

local seqx   = require 'seqx'
local scales = require 'scales'

local GRID_W = 16
local NUM_CHANNELS = 6
local PARAMS = {'div', 'reps', 'note', 'level', 'harm', 'env'}

-- row 7
local VOICE_TOGGLE_COL = 11
local CLR_BUTTON_COL = 12
local LOCK_BUTTON_COL = 13
local RANDOMIZE_BUTTON_COL = 14
local MUTATE_BUTTON_COL = 15
-- row 6 right side
local ROW6_RST_COL = 11
local ROW6_KB_COL = 12
local ROW6_PROB_COL = 13
local ROW6_QNT_COL = 14
local ROW6_SND_COL = 15
-- KB mode (row 7 cols)
local KB_EXIT_COL = 12
local KB_PAGE_BUTTON_COL = 13
local KB_CLEAR_BUTTON_COL = 14

local BLACK_KEYS = {1, 3, 6, 8, 10}
local WHITE_KEYS = {0, 2, 4, 5, 7, 9, 11}
local RESET_INTERVALS = {0, 1, 2, 3, 4, 5, 6, 7, 8}
local RESET_COLS      = {0, 1, 2, 3, 4, 5, 6, 7, 8}
local RATE_VALUES = {0.25, 0.5, 1, 2, 4}
local RATE_COLS   = {11, 12, 13, 14, 15}

local ENV_MODE_NAMES       = {'shape', 'burst', 'hit'}
local GEODE_MODE_NAMES     = {'off', 'transient', 'sustain', 'cycle'}
local PITCH_ENV_MODE_NAMES = {'off', 'fast', 'med', 'slow'}
local HARM_ENV_MODE_NAMES  = {'off', 'fast', 'med', 'slow'}

local DEFAULT_VALUE   = {div = 4, reps = 1, note = 0, level = 0.5, harm = 2, env = 0}
local DEFAULT_VALUE_B = {div = 0, reps = 0, note = 0, level = 0, harm = 0, env = 0}

-- 1-based value layouts for the step picker / KB bands. Index 1..32 maps to
-- grid cell (y*16 + x + 1). These are the grid-reachability contract.
local function range(n, f) local t = {} for i = 0, n - 1 do t[i + 1] = f(i) end return t end
local STEP_PICKER_VALUES = {
  div  = range(32, function(i) return i + 1 end),
  reps = (function() local t = range(31, function(i) return i + 1 end); t[32] = -1; return t end)(),
  note = range(32, function(i) return i end),
  level = range(32, function(i) return i / 31 end),
  harm  = range(32, function(i) return 2 + i * 0.75 end),
  env   = range(32, function(i) return i / 31 end),
}
local QUANTIZE_VALUES = range(32, function(i) return i + 1 end)

local function round(x) return math.floor(x + 0.5) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function eq(a, b) return math.abs(a - b) < 1e-6 end

local function contains(t, v)
  for _, x in ipairs(t) do if x == v then return true end end
  return false
end
local function index_of(t, v)
  for i, x in ipairs(t) do if x == v then return i - 1 end end  -- 0-based, -1 if absent
  return -1
end

local function value_brightness(param, value)
  if param == 'div' then
    return value <= 4 and 6 or value <= 8 and 8 or value <= 16 and 11 or 14
  elseif param == 'reps' then
    return value == -1 and 15 or math.min(4 + value, 14)
  elseif param == 'note' then
    return math.min(4 + math.abs(value), 15)
  elseif param == 'level' then
    return math.max(2, round(2 + value * 13))
  elseif param == 'harm' then
    local norm = (value - 2) / 23.25
    return clamp(round(4 + norm * 10), 4, 14)
  elseif param == 'env' then
    local norm = clamp(value, 0, 1)
    return clamp(round(2 + norm * 12), 2, 14)
  end
  return 6
end

local GridUI = {}
GridUI.__index = GridUI
GridUI.STEP_PICKER_VALUES = STEP_PICKER_VALUES
GridUI.PARAMS = PARAMS
-- shared with screen_ui so both surfaces draw/edit from one source of truth
GridUI.value_brightness = value_brightness
GridUI.ENV_MODE_NAMES = ENV_MODE_NAMES
GridUI.GEODE_MODE_NAMES = GEODE_MODE_NAMES
GridUI.PITCH_ENV_MODE_NAMES = PITCH_ENV_MODE_NAMES
GridUI.HARM_ENV_MODE_NAMES = HARM_ENV_MODE_NAMES
GridUI.RESET_INTERVALS = RESET_INTERVALS
GridUI.RATE_VALUES = RATE_VALUES

-- opts.on_status(string): pushed status text (for screen). opts.on_redraw():
-- called after any state change so the screen can refresh too.
function GridUI.new(engine, grid, opts)
  opts = opts or {}
  local self = setmetatable({}, GridUI)
  self.engine = engine
  self.g = grid
  self.on_status = opts.on_status or function() end
  self.on_redraw = opts.on_redraw or function() end

  self.selectedParam = 'note'
  self.paramLayer = 'A'        -- 'A' | 'B'
  self.picker = nil            -- {kind='step',ch,col,layer} | {kind='scale'} | nil
  self.probMode = false
  self.resetMode = false
  self.soundMode = false
  self.actionMode = nil        -- 'randomize'|'mutate'|'clear'|'lock'|'voice'|nil
  self.status = ''

  self.customMask = {}
  for _, v in ipairs(scales.by_name.major) do self.customMask[#self.customMask + 1] = v end
  self.selectedScaleName = 'major'

  self.kbMode = false
  self.kbPage = 1
  self.kbBLayer = false
  self.kbChannel = 0
  self.kbNoteBuffer, self.kbDivBuffer, self.kbRepBuffer = {}, {}, {}
  self.kbLevelBuffer, self.kbHarmBuffer, self.kbEnvBuffer = {}, {}, {}

  engine:on(function(ev)
    if ev.type == 'fire' then
      if self.kbMode or self.picker or self.probMode or self.resetMode or self.soundMode then return end
      self:render_channel_row(ev.ch - 1)
      self.g:refresh()
    elseif ev.type == 'launch' or ev.type == 'stop' then
      self:render_all()
    end
  end)

  self:render_all()
  return self
end

function GridUI:refresh() self:render_all() end

-- channel-state accessor (ch is 0-based)
function GridUI:chan(ch) return self.engine.channels[ch + 1] end

-- ---- press dispatch ----------------------------------------------------

function GridUI:press(x, y)
  if self.kbMode then self:handle_kb_press(x, y); return end
  if self.picker then self:handle_picker_press(x, y)
  else self:handle_normal_press(x, y) end
end

function GridUI:handle_normal_press(x, y)
  if y < 6 then
    if self.resetMode then
      local rate_idx = index_of(RATE_COLS, x)
      if rate_idx ~= -1 then
        self:chan(y).rate = RATE_VALUES[rate_idx + 1]
        self:render_channel_row(y); self.g:refresh()
        return
      end
      local idx = index_of(RESET_COLS, x)
      if idx ~= -1 then
        self:chan(y).resetInterval = RESET_INTERVALS[idx + 1]
        self:render_channel_row(y); self.g:refresh()
      end
      return
    end
    if self.probMode then
      local c = self:chan(y)
      if x == 15 then
        c.probHit = not c.probHit
      else
        c.burstProb = x / 14
      end
      self:render_channel_row(y); self.g:refresh()
      return
    end
    if self.soundMode then
      local c = self:chan(y)
      if x <= 2 then c.envMode = x
      elseif x >= 4 and x <= 7 then c.geodeMode = x - 4
      elseif x >= 8 and x <= 11 then c.pitchEnv = x - 8
      elseif x >= 12 and x <= 15 then c.harmEnv = x - 12 end
      self:render_channel_row(y); self.g:refresh()
      return
    end
    self:open_step_picker(y, x)
  elseif y == 6 then
    self:handle_row6(x)
  elseif y == 7 then
    self:handle_row7(x)
  end
end

function GridUI:handle_picker_press(x, y)
  local p = self.picker
  local picker_rows = (p.kind == 'scale') and 5 or 2
  if y < picker_rows then
    self:apply_picker_value(p, x, y)
    return
  end
  if p.kind == 'step' and y < 6 then
    if y == p.ch and x == p.col then
      self:remove_step(p.ch, p.col, p.layer)
      self:close_picker()
    else
      self:open_step_picker(y, x)
    end
    return
  end
  if y == 6 and p.kind == 'scale' and x == ROW6_QNT_COL then
    self:close_picker()
    return
  end
  self:close_picker()
  self:handle_normal_press(x, y)
end

-- ---- value application -------------------------------------------------

function GridUI:apply_picker_value(p, x, y)
  if p.kind == 'step' then
    local v = STEP_PICKER_VALUES[self.selectedParam][y * GRID_W + x + 1]
    self:set_step(p.ch, p.col, v, p.layer)
    self:close_picker()
  elseif p.kind == 'scale' then
    if y == 0 then
      local name = scales.names[x + 1]
      if not name then return end
      self.selectedScaleName = name
      self.customMask = {}
      for _, vv in ipairs(scales.by_name[name]) do self.customMask[#self.customMask + 1] = vv end
      self.engine.scale = self.customMask
    elseif y == 1 or y == 2 then
      local semitone = x
      if semitone >= 12 then return end
      local valid = (y == 1) and BLACK_KEYS or WHITE_KEYS
      if not contains(valid, semitone) then return end
      local at = nil
      for i, s in ipairs(self.customMask) do if s == semitone then at = i break end end
      if at then
        if #self.customMask > 1 then table.remove(self.customMask, at) end
      else
        self.customMask[#self.customMask + 1] = semitone
        table.sort(self.customMask)
      end
      local copy = {}
      for _, s in ipairs(self.customMask) do copy[#copy + 1] = s end
      self.engine.scale = copy
    elseif y == 3 then
      self.engine.quantize = QUANTIZE_VALUES[x + 1]
    elseif y == 4 then
      self.engine.quantize = QUANTIZE_VALUES[x + 16 + 1]
    end
    self:render_all()
  end
end

-- ---- picker enter/exit -------------------------------------------------

function GridUI:open_step_picker(ch, col)
  local param = self.selectedParam
  local layer = self.paramLayer
  local cur = seqx.values(self:seq_ref(ch, param, layer))
  local len = #cur
  if col == len then
    if len >= GRID_W then return end
    local nxt = {}
    for i = 1, len do nxt[i] = cur[i] end
    nxt[len + 1] = (layer == 'A') and DEFAULT_VALUE[param] or DEFAULT_VALUE_B[param]
    self:commit_step(ch, param, nxt, layer)
    self.picker = {kind = 'step', ch = ch, col = col, layer = layer}
  elseif col < len then
    self.picker = {kind = 'step', ch = ch, col = col, layer = layer}
  else
    return
  end
  self:render_all()
end

function GridUI:open_scale_picker()
  self.customMask = {}
  for _, v in ipairs(self.engine.scale) do self.customMask[#self.customMask + 1] = v end
  self.picker = {kind = 'scale'}
  self:render_all()
end

function GridUI:close_picker()
  self.picker = nil
  self:render_all()
end

-- ---- step mutations ----------------------------------------------------

function GridUI:seq_ref(ch, param, layer)
  local c = self:chan(ch)
  if layer == 'A' then return c[param] end
  return c[param .. 'B']
end

function GridUI:set_step(ch, col, value, layer)
  local param = self.selectedParam
  local cur = seqx.values(self:seq_ref(ch, param, layer))
  local nxt = {}
  for i = 1, #cur do nxt[i] = cur[i] end
  nxt[col + 1] = value
  self:commit_step(ch, param, nxt, layer)
end

function GridUI:remove_step(ch, col, layer)
  local param = self.selectedParam
  local cur = seqx.values(self:seq_ref(ch, param, layer))
  local nxt = {}
  for i = 1, #cur do nxt[i] = cur[i] end
  table.remove(nxt, col + 1)
  self:commit_step(ch, param, nxt, layer)
end

function GridUI:commit_step_raw(ch, param, vals, layer)
  local final = vals
  if #final == 0 then
    final = {(layer == 'A') and DEFAULT_VALUE[param] or DEFAULT_VALUE_B[param]}
  end
  local c = self:chan(ch)
  if layer == 'A' then c[param] = seqx.new(final)
  else c[param .. 'B'] = seqx.new(final) end
  -- Shared INTONE: harm on a JF channel broadcasts to all JF channels.
  if param == 'harm' and layer == 'A' and c.voiceType == 'jf' then
    for i = 0, NUM_CHANNELS - 1 do
      local oc = self:chan(i)
      if i ~= ch and oc.voiceType == 'jf' then
        local copy = {} for k = 1, #final do copy[k] = final[k] end
        oc.harm = seqx.new(copy)
      end
    end
  end
end

function GridUI:commit_step(ch, param, vals, layer)
  local old_len = #seqx.values(self:seq_ref(ch, param, layer))
  self:commit_step_raw(ch, param, vals, layer)
  local new_len = math.max(1, #vals)
  if self:chan(ch).locked and layer == 'A' and new_len ~= old_len then
    self:sync_locked_params(ch, new_len, param)
  end
end

function GridUI:sync_locked_params(ch, target_len, skip_param)
  for _, param in ipairs(PARAMS) do
    if param ~= skip_param then
      local cur = seqx.values(self:seq_ref(ch, param, 'A'))
      if #cur ~= target_len then
        local nxt = {}
        if target_len > #cur then
          for i = 1, #cur do nxt[i] = cur[i] end
          for i = #cur + 1, target_len do nxt[i] = cur[#cur] end
        else
          for i = 1, target_len do nxt[i] = cur[i] end
        end
        self:commit_step_raw(ch, param, nxt, 'A')
      end
    end
  end
end

function GridUI:enforce_lock_on_entry(ch)
  local max_len = 1
  for _, p in ipairs(PARAMS) do
    max_len = math.max(max_len, #seqx.values(self:seq_ref(ch, p, 'A')))
  end
  self:sync_locked_params(ch, max_len, nil)
end

function GridUI:clear_channel_param(ch)
  local param = self.selectedParam
  local c = self:chan(ch)
  c[param] = seqx.new{DEFAULT_VALUE[param]}
  c[param .. 'B'] = seqx.new{0}
  self:render_all()
end

-- ---- row 6 / row 7 -----------------------------------------------------

function GridUI:_exclusive_mode(field)
  -- set self[field]=true and clear the other latch modes + action mode
  self.probMode = false; self.resetMode = false; self.soundMode = false
  self.actionMode = nil
  self[field] = true
end

function GridUI:handle_row6(x)
  if x == ROW6_KB_COL then self:enter_kb_mode(); return end
  if x == ROW6_RST_COL then
    local was = self.resetMode
    self.probMode = false; self.soundMode = false; self.actionMode = nil
    self.resetMode = not was
    self:render_all(); return
  end
  if x == ROW6_PROB_COL then
    local was = self.probMode
    self.soundMode = false; self.resetMode = false; self.actionMode = nil
    self.probMode = not was
    self:render_all(); return
  end
  if x == ROW6_QNT_COL then self:open_scale_picker(); return end
  if x == ROW6_SND_COL then
    local was = self.soundMode
    self.probMode = false; self.resetMode = false; self.actionMode = nil
    self.soundMode = not was
    self:render_all(); return
  end

  if self.actionMode == 'voice' and x < 6 then
    self.engine:toggle_voice(x + 1)
    self:render_all(); return
  end
  if self.actionMode == 'lock' and x < 6 then
    local c = self:chan(x)
    c.locked = not c.locked
    if c.locked then self:enforce_lock_on_entry(x) end
    self:render_all(); return
  end
  if self.actionMode and x < 6 then
    if self.actionMode == 'randomize' then self.engine:randomize(x + 1)
    elseif self.actionMode == 'mutate' then self.engine:mutate(x + 1)
    elseif self.actionMode == 'clear' then self:clear_channel_param(x) end
    self:render_all(); return
  end

  if x < 6 then
    if self.engine:is_running(x + 1) then self.engine:stop(x + 1)
    else self.engine:launch(x + 1) end
  end
end

function GridUI:handle_row7(x)
  if x < #PARAMS then
    if PARAMS[x + 1] == self.selectedParam then
      self.paramLayer = (self.paramLayer == 'A') and 'B' or 'A'
    else
      self.selectedParam = PARAMS[x + 1]
      self.paramLayer = 'A'
    end
    self.picker = nil
    self:render_all()
  elseif x == VOICE_TOGGLE_COL then self:_toggle_action('voice')
  elseif x == CLR_BUTTON_COL then self:_toggle_action('clear')
  elseif x == LOCK_BUTTON_COL then self:_toggle_action('lock')
  elseif x == RANDOMIZE_BUTTON_COL then self:_toggle_action('randomize')
  elseif x == MUTATE_BUTTON_COL then self:_toggle_action('mutate')
  end
end

function GridUI:_toggle_action(name)
  if self.actionMode == name then self.actionMode = nil
  else
    self.actionMode = name
    self.probMode = false; self.resetMode = false; self.soundMode = false
  end
  self:render_all()
end

-- ---- rendering ---------------------------------------------------------

function GridUI:render_all()
  if self.kbMode then self:render_kb_mode(); self:_status(); self.g:refresh(); self.on_redraw(); return end
  self.g:clear()
  if self.picker then
    self:render_picker()
    if self.picker.kind ~= 'scale' then
      for ch = 2, NUM_CHANNELS - 1 do self:render_channel_row(ch) end
    end
  else
    for ch = 0, NUM_CHANNELS - 1 do self:render_channel_row(ch) end
  end
  self:render_row6()
  self:render_row7()
  self:_status()
  self.g:refresh()
  self.on_redraw()
end

function GridUI:render_picker()
  if not self.picker then return end
  if self.picker.kind == 'step' then self:render_step_picker(self.picker)
  elseif self.picker.kind == 'scale' then self:render_scale_picker() end
end

function GridUI:render_step_picker(p)
  local param = self.selectedParam
  local vals = seqx.values(self:seq_ref(p.ch, param, p.layer))
  local focused = vals[p.col + 1]
  local layout = STEP_PICKER_VALUES[param]
  for y = 0, 1 do
    for x = 0, GRID_W - 1 do
      local v = layout[y * GRID_W + x + 1]
      local b
      if eq(v, focused) then b = 15
      else
        local present = false
        for _, sv in ipairs(vals) do if eq(sv, v) then present = true break end end
        b = present and 5 or 1
      end
      self.g:set_led(x, y, b)
    end
  end
end

function GridUI:render_scale_picker()
  for x = 0, GRID_W - 1 do
    local name = scales.names[x + 1]
    local b
    if not name then b = 0
    elseif name == self.selectedScaleName then b = 15
    else b = 5 end
    self.g:set_led(x, 0, b)
  end
  for x = 0, GRID_W - 1 do
    if x >= 12 or not contains(BLACK_KEYS, x) then self.g:set_led(x, 1, 0)
    else self.g:set_led(x, 1, contains(self.customMask, x) and 12 or 3) end
  end
  for x = 0, GRID_W - 1 do
    if x >= 12 or not contains(WHITE_KEYS, x) then self.g:set_led(x, 2, 0)
    else self.g:set_led(x, 2, contains(self.customMask, x) and 12 or 3) end
  end
  local curq = self.engine.quantize
  for x = 0, GRID_W - 1 do
    self.g:set_led(x, 3, QUANTIZE_VALUES[x + 1] == curq and 15 or 3)
    self.g:set_led(x, 4, QUANTIZE_VALUES[x + 16 + 1] == curq and 15 or 3)
  end
  for x = 0, GRID_W - 1 do self.g:set_led(x, 5, 0) end
end

function GridUI:render_channel_row(ch)
  if self.probMode then self:render_prob_row(ch); return end
  if self.resetMode then self:render_reset_row(ch); return end
  if self.soundMode then self:render_sound_row(ch); return end
  local param = self.selectedParam
  local layer = self.paramLayer
  local seq = self:seq_ref(ch, param, layer)
  local vals = seqx.values(seq)
  local len = #vals
  for i = 0, GRID_W - 1 do
    if i < len then
      self.g:set_led(i, ch, value_brightness(param, vals[i + 1]))
      self.g:set_strobe(i, ch, 'off')
    elseif i == len and len < GRID_W then
      self.g:set_led(i, ch, 1); self.g:set_strobe(i, ch, 'off')
    else
      self.g:set_led(i, ch, 0); self.g:set_strobe(i, ch, 'off')
    end
  end
  if self.engine:is_running(ch + 1) and len > 0 then
    self.g:set_led(seqx.playhead(seq), ch, 15)
  end
  if self.picker and self.picker.kind == 'step' and self.picker.ch == ch and self.picker.layer == layer then
    self.g:set_led(self.picker.col, ch, 15)
  end
end

function GridUI:render_prob_row(ch)
  local c = self:chan(ch)
  local col = round(c.burstProb * 14)
  for i = 0, 14 do
    self.g:set_led(i, ch, i == col and 15 or 1)
    self.g:set_strobe(i, ch, 'off')
  end
  self.g:set_led(15, ch, c.probHit and 14 or 4)
  self.g:set_strobe(15, ch, c.probHit and 'slow' or 'off')
end

function GridUI:render_reset_row(ch)
  local c = self:chan(ch)
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  for i = 1, #RESET_INTERVALS do
    self.g:set_led(RESET_COLS[i], ch, RESET_INTERVALS[i] == c.resetInterval and 15 or 3)
  end
  for i = 1, #RATE_VALUES do
    self.g:set_led(RATE_COLS[i], ch, RATE_VALUES[i] == c.rate and 15 or 3)
  end
end

function GridUI:render_sound_row(ch)
  local c = self:chan(ch)
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  for m = 0, 2 do self.g:set_led(m, ch, c.envMode == m and 15 or 4) end
  for m = 0, 3 do self.g:set_led(m + 4, ch, c.geodeMode == m and 15 or 4) end
  for m = 0, 3 do self.g:set_led(m + 8, ch, c.pitchEnv == m and 15 or 4) end
  for m = 0, 3 do self.g:set_led(m + 12, ch, c.harmEnv == m and 15 or 4) end
end

function GridUI:render_action_mode()
  local mark_running = self.actionMode == 'randomize' or self.actionMode == 'mutate'
  for x = 0, 5 do
    local b
    if self.actionMode == 'lock' then b = self:chan(x).locked and 15 or 4
    elseif self.actionMode == 'voice' then
      local vt = self.engine:get_voice_type(x + 1)
      b = (vt == 'mg') and 15 or (vt == 'jf') and 10 or 4
    else b = 10 end
    self.g:set_led(x, 6, b)
    self.g:set_strobe(x, 6, (mark_running and self.engine:is_running(x + 1)) and 'slow' or 'off')
  end
  for x = 6, 11 do self.g:set_led(x, 6, 0) end
  self.g:set_led(ROW6_RST_COL, 6, 8)
  self.g:set_led(ROW6_KB_COL, 6, 8)
  self.g:set_led(ROW6_PROB_COL, 6, 8)
  self.g:set_led(ROW6_QNT_COL, 6, 8)
  self.g:set_led(ROW6_SND_COL, 6, 8)
end

function GridUI:render_row6()
  if self.actionMode then
    self:render_action_mode()
  else
    for x = 0, 5 do
      self.g:set_led(x, 6, self.engine:is_running(x + 1) and 15 or 4)
      self.g:set_strobe(x, 6, 'off')
    end
    for x = 6, 11 do self.g:set_led(x, 6, 0) end
  end
  self.g:set_led(ROW6_RST_COL, 6, self.resetMode and 15 or 8)
  self.g:set_strobe(ROW6_RST_COL, 6, self.resetMode and 'fast' or 'off')
  self.g:set_led(ROW6_KB_COL, 6, 8)
  self.g:set_led(ROW6_PROB_COL, 6, self.probMode and 15 or 8)
  self.g:set_strobe(ROW6_PROB_COL, 6, self.probMode and 'fast' or 'off')
  self.g:set_led(ROW6_QNT_COL, 6, 8)
  self.g:set_led(ROW6_SND_COL, 6, self.soundMode and 15 or 8)
  self.g:set_strobe(ROW6_SND_COL, 6, self.soundMode and 'fast' or 'off')
end

function GridUI:render_row7()
  for x = 0, #PARAMS - 1 do
    local sel = PARAMS[x + 1] == self.selectedParam
    self.g:set_led(x, 7, sel and 15 or 5)
    self.g:set_strobe(x, 7, (sel and self.paramLayer == 'B') and 'slow' or 'off')
  end
  for x = 6, 10 do self.g:set_led(x, 7, 0) end
  local function action_led(col, name)
    self.g:set_led(col, 7, self.actionMode == name and 15 or 4)
    self.g:set_strobe(col, 7, self.actionMode == name and 'fast' or 'off')
  end
  action_led(VOICE_TOGGLE_COL, 'voice')
  action_led(CLR_BUTTON_COL, 'clear')
  action_led(LOCK_BUTTON_COL, 'lock')
  action_led(RANDOMIZE_BUTTON_COL, 'randomize')
  action_led(MUTATE_BUTTON_COL, 'mutate')
end

-- ---- keyboard mode -----------------------------------------------------

function GridUI:enter_kb_mode()
  self.kbMode = true
  self.kbPage = 1
  self.kbBLayer = false
  self.kbChannel = 0
  self:clear_kb_buffers()
  self:render_all()
end

function GridUI:exit_kb_mode()
  self:commit_kb_buffers(self.kbChannel)
  self.kbMode = false
  self:render_all()
end

function GridUI:clear_kb_buffers()
  self.kbNoteBuffer, self.kbDivBuffer, self.kbRepBuffer = {}, {}, {}
  self.kbLevelBuffer, self.kbHarmBuffer, self.kbEnvBuffer = {}, {}, {}
end

function GridUI:commit_kb_buffers(ch)
  local layer = self.kbBLayer and 'B' or 'A'
  if #self.kbNoteBuffer > 0 then self:commit_step(ch, 'note', self.kbNoteBuffer, layer) end
  if #self.kbDivBuffer > 0 then self:commit_step(ch, 'div', self.kbDivBuffer, layer) end
  if #self.kbRepBuffer > 0 then
    -- A length-1 finite reps sequin triggers single-shot; in KB the intent is
    -- always to loop, so duplicate a solitary finite value.
    local buf = self.kbRepBuffer
    local safe = buf
    if layer == 'A' and #buf == 1 and buf[1] ~= -1 then safe = {buf[1], buf[1]} end
    self:commit_step(ch, 'reps', safe, layer)
  end
  if #self.kbLevelBuffer > 0 then self:commit_step(ch, 'level', self.kbLevelBuffer, layer) end
  if #self.kbHarmBuffer > 0 then self:commit_step(ch, 'harm', self.kbHarmBuffer, layer) end
  if #self.kbEnvBuffer > 0 then self:commit_step(ch, 'env', self.kbEnvBuffer, layer) end
end

function GridUI:switch_kb_channel(ch)
  self:commit_kb_buffers(self.kbChannel)
  self:clear_kb_buffers()
  self.kbChannel = ch
  self:render_all()
end

function GridUI:handle_kb_press(x, y)
  if y == 7 then
    if x < 6 then
      if x == self.kbChannel then
        self.kbBLayer = not self.kbBLayer
        self:clear_kb_buffers()
        self:render_all()
      else
        self:switch_kb_channel(x)
      end
      return
    end
    if x == KB_PAGE_BUTTON_COL then
      self.kbPage = (self.kbPage == 1) and 2 or 1
      self:render_all()
      return
    end
    if x == KB_CLEAR_BUTTON_COL then self:clear_kb_buffers(); self:render_all(); return end
    return
  end

  if y == 6 then
    if x == KB_EXIT_COL then self:exit_kb_mode(); return end
    local name = scales.kb_names[x + 1]
    if name then self.engine.scale = scales.by_name[name] end
    self:render_all()
    return
  end

  if y < 6 and self.kbPage == 1 then
    if y < 2 then
      self.kbNoteBuffer[#self.kbNoteBuffer + 1] = STEP_PICKER_VALUES.note[y * GRID_W + x + 1]
    elseif y < 4 then
      self.kbDivBuffer[#self.kbDivBuffer + 1] = STEP_PICKER_VALUES.div[(y - 2) * GRID_W + x + 1]
    else
      self.kbRepBuffer[#self.kbRepBuffer + 1] = STEP_PICKER_VALUES.reps[(y - 4) * GRID_W + x + 1]
    end
    self:commit_kb_buffers(self.kbChannel)
    self:render_all()
    return
  end

  if y < 6 and self.kbPage == 2 then
    if y < 2 then
      self.kbLevelBuffer[#self.kbLevelBuffer + 1] = STEP_PICKER_VALUES.level[y * GRID_W + x + 1]
    elseif y < 4 then
      self.kbHarmBuffer[#self.kbHarmBuffer + 1] = STEP_PICKER_VALUES.harm[(y - 2) * GRID_W + x + 1]
    else
      self.kbEnvBuffer[#self.kbEnvBuffer + 1] = STEP_PICKER_VALUES.env[(y - 4) * GRID_W + x + 1]
    end
    self:commit_kb_buffers(self.kbChannel)
    self:render_all()
  end
end

function GridUI:render_kb_mode()
  self.g:clear()
  if self.kbPage == 1 then self:render_kb_page1() else self:render_kb_page2() end
  self:render_kb_modifier_row()
  self:render_kb_row7()
end

function GridUI:_render_kb_band(row_offset, param, buffer, existing)
  local vals = STEP_PICKER_VALUES[param]
  for lr = 0, 1 do
    for col = 0, GRID_W - 1 do
      local v = vals[lr * GRID_W + col + 1]
      local b
      local in_buf = false
      for _, bv in ipairs(buffer) do if eq(bv, v) then in_buf = true break end end
      if in_buf then b = 15
      else
        local in_ex = false
        for _, ev in ipairs(existing) do if eq(ev, v) then in_ex = true break end end
        b = in_ex and 5 or 2
      end
      self.g:set_led(col, row_offset + lr, b)
    end
  end
end

function GridUI:render_kb_page1()
  local layer = self.kbBLayer and 'B' or 'A'
  self:_render_kb_band(0, 'note', self.kbNoteBuffer, seqx.values(self:seq_ref(self.kbChannel, 'note', layer)))
  self:_render_kb_band(2, 'div', self.kbDivBuffer, seqx.values(self:seq_ref(self.kbChannel, 'div', layer)))
  self:_render_kb_band(4, 'reps', self.kbRepBuffer, seqx.values(self:seq_ref(self.kbChannel, 'reps', layer)))
end

function GridUI:render_kb_page2()
  local layer = self.kbBLayer and 'B' or 'A'
  self:_render_kb_band(0, 'level', self.kbLevelBuffer, seqx.values(self:seq_ref(self.kbChannel, 'level', layer)))
  self:_render_kb_band(2, 'harm', self.kbHarmBuffer, seqx.values(self:seq_ref(self.kbChannel, 'harm', layer)))
  self:_render_kb_band(4, 'env', self.kbEnvBuffer, seqx.values(self:seq_ref(self.kbChannel, 'env', layer)))
end

function GridUI:render_kb_modifier_row()
  local active = self.engine.scale
  for x = 0, 7 do
    local name = scales.kb_names[x + 1]
    self.g:set_led(x, 6, scales.by_name[name] == active and 15 or 8)
  end
  for x = 8, GRID_W - 1 do self.g:set_led(x, 6, 0) end
  self.g:set_led(KB_EXIT_COL, 6, 15)
  self.g:set_strobe(KB_EXIT_COL, 6, 'fast')
end

function GridUI:render_kb_row7()
  for x = 0, 5 do
    local sel = x == self.kbChannel
    self.g:set_led(x, 7, sel and 15 or 4)
    self.g:set_strobe(x, 7, (sel and self.kbBLayer) and 'slow' or 'off')
  end
  for x = 6, GRID_W - 1 do self.g:set_led(x, 7, 0) end
  self.g:set_led(KB_PAGE_BUTTON_COL, 7, self.kbPage == 1 and 15 or 8)
  self.g:set_led(KB_CLEAR_BUTTON_COL, 7, 4)
end

-- ---- status (pushed to screen) -----------------------------------------

function GridUI:current_page()
  if self.kbMode then return 'KB' end
  if self.picker and self.picker.kind == 'scale' then return 'SCALE' end
  if self.picker and self.picker.kind == 'step' then return 'PICK' end
  if self.resetMode then return 'RST' end
  if self.probMode then return 'PROB' end
  if self.soundMode then return 'SND' end
  if self.actionMode then return string.upper(self.actionMode) end
  return 'MAIN'
end

function GridUI:_status()
  local s
  if self.kbMode then
    local page = (self.kbPage == 1) and 'pg1 note/div/reps' or 'pg2 level/harm/env'
    local layer = self.kbBLayer and 'B' or 'A'
    s = 'KB ch' .. (self.kbChannel + 1) .. ' ' .. page .. ' [' .. layer .. ']'
  elseif self.resetMode then
    s = 'RESET — col0 off, cols1-8 bars, cols11-15 rate'
  elseif self.probMode then
    s = 'PROB — slider 0-14, col15 burst/hit'
  elseif self.soundMode then
    s = 'SOUND — env/geode/pitchenv/harmenv'
  elseif self.actionMode then
    s = string.upper(self.actionMode) .. ' — tap a channel'
  elseif self.picker and self.picker.kind == 'step' then
    local raw = seqx.values(self:seq_ref(self.picker.ch, self.selectedParam, self.picker.layer))[self.picker.col + 1]
    local v = (self.selectedParam == 'env') and round(raw * 31) or raw
    s = 'edit ch' .. (self.picker.ch + 1) .. ' step ' .. self.picker.col .. ' ' ..
        self.selectedParam .. (self.picker.layer == 'B' and 'B' or '') .. '=' .. tostring(v)
  elseif self.picker and self.picker.kind == 'scale' then
    s = 'scale: row0 preset, rows1-2 keys, rows3-4 qnt (' .. self.engine.quantize .. ')'
  else
    s = 'edit ' .. self.selectedParam .. ' [' .. self.paramLayer .. ']'
  end
  self.status = s
  self.on_status(s)
end

return GridUI
