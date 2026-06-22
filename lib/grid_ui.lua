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
--   rows 0..5 = per-channel step view: two lanes side by side — the left half
--               (cols 0..7) and the right half (cols 8..15), each capped at 8
--               steps. For most params the halves are the A and B layers; for
--               div/reps the halves are div (left) and reps (right), both A
--               (div/reps have no B layer). The lane you edit is the half you
--               press; there is no A/B flip (no double-press). See row_lanes.
--   row 6     = 0..5 launch · 6..9 dark · 10 OP · 11 ALG · 12 PERF · 13 PROB · 14 QNT · 15 SND
--               (KB page disabled)
--   row 7     = 0 div/reps · 1 note · 2 level · 3 attack/decay · 4 modatk/moddec
--             · 5..10 dark · 11 CLR · 12 COPY · 13 PASTE · 14 RANDOMIZE · 15 MUTATE
--             (one page-select button each; div/reps, attack/decay and
--             modatk/moddec are paired pages showing two A-layer lanes. The two
--             envelope pages are the carrier amp env and the modulator/FM-bright
--             env. timbre — per-op ratio/level — lives
--             on the OP page as static scalars)
--   CLR/COPY/PASTE act on the MAIN (A-layer) sequins of the tapped channel only;
--   the B (alt) layer is left intact so it can keep variating the copied sequins.
--   OP:    rows 0-5 = per-op RATIO (cols 0-3, op1..op4 all editable) · per-op LEVEL
--          (cols 8-11). Tap a cell to open its value picker on rows 6-7.
--   PROB:  rows 0-5 = note alt-trig hold/step (cols 0-1)
--          · prob 25/50/75/100% (cols 11-14, right-justified)
--          · col 15 burst/hit toggle
--   PERF:  rows 0-5 = reset off/1/2/4 bars (cols 0..3) · octave -2..+2 (cols 5..9)
--          · rate (cols 11..15)
--   SND:   rows 0-5 = env(0-2) · geode(4-6)
--   ALG:   rows 0-5 = FM algorithm 1-16 (cols 0-15), the channel's selection bright
--   scale picker: row 0 cols 0-6 scale presets (7)
--                 rows 1-2 cols 0-6 degree (note-mask) keyboard: black row 1 / white row 2
--                 rows 4-5 cols 0-6 root keyboard: black row 4 / white row 5
--                 rows 1-4 cols 8-15 quantize (8x4 = 32 values, right side)
--                 keyboards are a compact piano: white keys packed at cols 0-6,
--                 black keys offset above the white key they follow
--   step picker:  value grid on rows 6-7 (the control rows, borrowed while
--                 picking) so all six channel rows stay visible. Press the
--                 lit/current value to remove the step; press any other value
--                 to set it. On the channel rows: tap another step to hop the
--                 picker there, or re-tap the open step to cancel/close.
--   scalar picker: same rows-6-7 value grid, but writes a per-channel static
--                 scalar (OP-page op ratio / op level) instead of a sequence step.
--   KB mode: DISABLED — entry (row6 col 11) is commented out, so the mode is
--            unreachable; its handle_kb_press / render_kb_mode code remains in
--            place and can be restored by un-commenting the entry points.

local seqx   = require 'seqx'
local scales = require 'scales'

local GRID_W = 16
-- Each channel row shows both A/B layers side by side: A on cols 0..SEQ_LEN-1,
-- B on cols B_COL0..15. Each layer is capped at SEQ_LEN steps (half the row).
local SEQ_LEN = 8
local B_COL0 = 8
local NUM_CHANNELS = 6
-- All sequenced params (the row-7 page buttons are a separate, smaller list —
-- ROW7_PAGES — one per page). Timbre (per-op ratios + levels) is no longer
-- sequenced — it lives on the per-channel OP page as static scalars.
local PARAMS = {'div', 'reps', 'note', 'level', 'attack', 'decay', 'modatk', 'moddec'}
-- Paired params share one page as two A-layer lanes (left|right) instead of a
-- param's own A|B layers: div|reps (an additive offset on division/repeats isn't
-- musical), attack|decay (the carrier envelope shape) and modatk|moddec (the
-- modulator/FM-brightness envelope shape). A paired param therefore has no B
-- layer; every other param shows its A layer left, B right.
local PAIRS = { {'div', 'reps'}, {'attack', 'decay'}, {'modatk', 'moddec'} }
local PAIRED, PAIR_OF = {}, {}
for _, pr in ipairs(PAIRS) do
  PAIRED[pr[1]] = true; PAIRED[pr[2]] = true
  PAIR_OF[pr[1]] = pr;  PAIR_OF[pr[2]] = pr
end
local function has_b(param) return not PAIRED[param] end
-- row-7 page-select buttons: ONE per page. A paired page is represented by its
-- first member (selecting it shows both lanes via row_lanes); singles are
-- themselves. Cols 0..#ROW7_PAGES-1.
local ROW7_PAGES = {'div', 'note', 'level', 'attack', 'modatk'}

-- row 7
local CLR_BUTTON_COL = 11
local COPY_BUTTON_COL = 12
local PASTE_BUTTON_COL = 13
local RANDOMIZE_BUTTON_COL = 14
local MUTATE_BUTTON_COL = 15
-- row 6 right side
local ROW6_ALG_COL = 11   -- FM algorithm page (took KB's old slot; cols 6..10 dark)
-- KB mode is disabled — its entry button is commented out below, which makes the
-- whole mode unreachable. Left in place so it can be restored by un-commenting.
-- local ROW6_KB_COL = 11
local ROW6_OP_COL = 10    -- per-channel OP page (per-op ratio + level statics)
local ROW6_PERF_COL = 12
local ROW6_PROB_COL = 13
local ROW6_QNT_COL = 14
local ROW6_SND_COL = 15
-- OP page channel-row layout: op1..4 RATIO on cols 0..3 (op1 default 1.0, editable),
-- op1..4 LEVEL on cols 8..11 (left/right halves, like the A/B convention).
local OP_RATIO_COL0 = 0
local OP_LEVEL_COL0 = 8
-- The step picker's 32-value grid renders on the control rows (6-7) while a pick
-- is in progress, leaving all six channel rows visible so the step being edited
-- is never hidden behind the picker. (The scale picker still owns rows 0-5.)
local PICKER_ROW0 = 6
-- KB mode (exit on row 6, same col as entry; page/clear on row 7)
local KB_EXIT_COL = 11
local KB_PAGE_BUTTON_COL = 13
local KB_CLEAR_BUTTON_COL = 14

local BLACK_KEYS = {1, 3, 6, 8, 10}
local WHITE_KEYS = {0, 2, 4, 5, 7, 9, 11}

-- Compact piano keyboard (scale picker): col -> semitone. White keys pack into
-- cols 0..6; black keys sit above the white key they follow (cols 2 and 6 have
-- no black key, matching a real keyboard's E-F and B-C gaps).
local KB_WHITE_COL = {[0] = 0, [1] = 2, [2] = 4, [3] = 5, [4] = 7, [5] = 9, [6] = 11}
local KB_BLACK_COL = {[0] = 1, [1] = 3, [3] = 6, [4] = 8, [5] = 10}
-- Scale-picker row assignments.
local SCALE_PRESET_ROW = 0
local DEG_BLACK_ROW, DEG_WHITE_ROW = 1, 2
local ROOT_BLACK_ROW, ROOT_WHITE_ROW = 4, 5
-- Quantize block: 8 cols x 4 rows on the right side.
local QNT_COL0, QNT_ROW0, QNT_W, QNT_H = 8, 1, 8, 4
local RESET_INTERVALS = {0, 1, 2, 4}
local RESET_COLS      = {0, 1, 2, 3}
local OCTAVE_VALUES = {-2, -1, 0, 1, 2}
local OCTAVE_COLS   = {5, 6, 7, 8, 9}
local RATE_VALUES = {0.25, 0.5, 1, 2, 4}
local RATE_COLS   = {11, 12, 13, 14, 15}
-- PROB page: note alt-trig mode packed left, prob options right-justified, hit
-- toggle at the far right (col 15). burstProb is a discrete 4-value set. (harm/op
-- trig columns are gone — harm and op levels no longer have a B layer.)
local ALT_TRIG_COLS  = {0, 1}                -- note alt(B) layer: hold / step
local PROB_VALUES   = {0.25, 0.5, 0.75, 1.0}
local PROB_COLS     = {11, 12, 13, 14}
local PROB_HIT_COL  = 15

local ENV_MODE_NAMES       = {'shape', 'burst', 'hit'}
local GEODE_MODE_NAMES     = {'transient', 'sustain', 'cycle'}  -- amp geode, always on
-- FM algorithm (1..16): operator routings, labelled by their shape. 1..8 are the
-- canonical Yamaha 4-op DX set; 9..16 are extended routings (see Engine_Potionshop
-- algorithms table — keep ordering in sync). One ALG grid row fits all 16 (cols 0..15).
local ALGO_NAMES = {'4>3>2>1', '(4,3)>2>1', '4>3>1 2>1', '4>2>1 3>1',
                    '2>1 4>3', '4>1,2,3', '4>3 +1,2', 'additive',
                    '(4,3,2)>1', '3>2>1 +4', '4>2>1 +3', '4>3>2 +1',
                    '4>3>1 +2', '(4,3)>1 +2', '4>1,2 +3', '4>2 3>1'}
-- alt(B)-layer trigger mode for the note layer (altTrig):
--   hold = add&hold (B drawn once per burst, summed onto A for every hit)
--   step = advance the B sequins per hit (arpeggiates the alt layer)
local ALT_TRIG_MODE_NAMES  = {'hold', 'step'}
-- Curated per-operator FM ratios for the OP-page picker (32 values across the two
-- picker rows 6-7: cols 0..15 = ratios 1..16, second row = 17..32). Mirrors
-- Burst.RATIO_VALUES (randomize/mutate) — keep the two in sync. Superset of the
-- earlier 16-value set: denser sub-octave bass, a unity-detune zone (1.25/1.75),
-- and half-integer inharmonic ratios for bell/metallic timbres.
local RATIO_VALUES = {
  0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1,
  1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3,
  3.5, 4, 4.5, 5, 5.5, 6, 6.5, 7,
  7.5, 8, 9, 10, 11, 12, 13, 14,
}

local DEFAULT_VALUE   = {div = 8, reps = 3, note = 0, level = 0.5, attack = 0, decay = 16 / 31, modatk = 0, moddec = 8 / 31}
local DEFAULT_VALUE_B = {div = 0, reps = 0, note = 0, level = 0, attack = 0, decay = 0, modatk = 0, moddec = 0}

-- 1-based value layouts for the step picker / KB bands. Index 1..32 maps to
-- grid cell (y*16 + x + 1). These are the grid-reachability contract.
local function range(n, f) local t = {} for i = 0, n - 1 do t[i + 1] = f(i) end return t end
local STEP_PICKER_VALUES = {
  div  = range(32, function(i) return i + 1 end),
  -- cells 1..28 = reps 1..28 (hit counts); cells 29..32 = rests of 1..4 steps
  -- (values 0,-1,-2,-3 -> rest length 1-reps). No infinite sentinel: 2+ steps loop.
  reps = (function()
    local t = range(28, function(i) return i + 1 end)
    t[29], t[30], t[31], t[32] = 0, -1, -2, -3
    return t
  end)(),
  note = range(32, function(i) return i end),
  level = range(32, function(i) return i / 31 end),
  attack = range(32, function(i) return i / 31 end),
  decay  = range(32, function(i) return i / 31 end),
  modatk = range(32, function(i) return i / 31 end),
  moddec = range(32, function(i) return i / 31 end),
}
-- OP-page op-level picker: 0..1 in 1/31 steps (same layout the old op sequins
-- used), so every operator level stays grid-reachable.
local OP_LEVEL_VALUES = range(32, function(i) return i / 31 end)
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

-- channel-row column -> (lane index 1|2, step). Cols 0..SEQ_LEN-1 are the left
-- lane (1), cols B_COL0..15 the right lane (2); step is 0-based within the half.
-- The lane's actual param/layer comes from row_lanes (A/B, or div/reps).
local function decode_col(x)
  if x < B_COL0 then return 1, x end
  return 2, x - B_COL0
end

-- index of the picker value nearest `cur` (1-based). Shared by screen_ui and
-- params_sync so every surface snaps off-grid values identically.
local function nearest_index(layout, cur)
  local best, bd = 1, math.huge
  for i = 1, #layout do
    local d = math.abs(layout[i] - cur)
    if d < bd then bd = d; best = i end
  end
  return best
end

-- Brightness 15 is reserved for the running playhead (render_channel_row /
-- screen draw_steps), so every *value* tops out at VALUE_MAX. With the playhead
-- the only thing that can hit 15, it stays legible even over a hot step.
local VALUE_MAX = 13
local function value_brightness(param, value)
  local b
  if param == 'div' then
    b = value <= 4 and 6 or value <= 8 and 8 or value <= 16 and 11 or VALUE_MAX
  elseif param == 'reps' then
    b = value == -1 and VALUE_MAX or math.min(4 + value, VALUE_MAX)
  elseif param == 'note' then
    -- signed ramp centered on 7: a negative degree reads dimmer than zero, a
    -- positive one brighter, so +n and -n no longer collide (they did under the
    -- old abs() mapping). Reads like pitch height — higher note, brighter cell.
    b = clamp(round(7 + value), 2, VALUE_MAX)
  elseif param == 'level' or param:match('^op%d') then
    b = math.max(2, round(2 + value * 11))
  elseif param == 'harm' then
    local norm = (value - 2) / 23.25
    b = clamp(round(4 + norm * 9), 4, VALUE_MAX)
  elseif param == 'attack' or param == 'decay'
      or param == 'modatk' or param == 'moddec' then
    local norm = clamp(value, 0, 1)
    b = clamp(round(2 + norm * 11), 2, VALUE_MAX)
  else
    b = 6
  end
  return math.min(b, VALUE_MAX)
end

local GridUI = {}
GridUI.__index = GridUI
GridUI.STEP_PICKER_VALUES = STEP_PICKER_VALUES
GridUI.PARAMS = PARAMS
GridUI.SEQ_LEN = SEQ_LEN
GridUI.has_b = has_b
-- shared with screen_ui so both surfaces draw/edit from one source of truth
GridUI.value_brightness = value_brightness
GridUI.nearest_index = nearest_index
GridUI.DEFAULT_VALUE = DEFAULT_VALUE
GridUI.ENV_MODE_NAMES = ENV_MODE_NAMES
GridUI.GEODE_MODE_NAMES = GEODE_MODE_NAMES
GridUI.ALGO_NAMES = ALGO_NAMES
GridUI.RESET_INTERVALS = RESET_INTERVALS
GridUI.OCTAVE_VALUES = OCTAVE_VALUES
GridUI.RATE_VALUES = RATE_VALUES
GridUI.PROB_VALUES = PROB_VALUES
GridUI.ALT_TRIG_MODE_NAMES = ALT_TRIG_MODE_NAMES
GridUI.RATIO_VALUES = RATIO_VALUES
GridUI.OP_LEVEL_VALUES = OP_LEVEL_VALUES

-- opts.on_status(string): pushed status text (for screen). opts.on_redraw():
-- called after any state change so the screen can refresh too. opts.on_edit(ev):
-- observer for every engine-state mutation made through the controller —
-- ev = {type='seq', ch, param, layer} | {type='scalar', ch} |
-- {type='channel', ch} | {type='global'} (ch 0-based). The params layer hangs
-- off this; defaults to a no-op so tests run params-free.
function GridUI.new(engine, grid, opts)
  opts = opts or {}
  local self = setmetatable({}, GridUI)
  self.engine = engine
  self.g = grid
  self.on_status = opts.on_status or function() end
  self.on_redraw = opts.on_redraw or function() end
  self.on_edit = opts.on_edit or function() end

  self.selectedParam = 'note'
  self.paramLayer = 'A'        -- 'A' | 'B'
  -- last channel touched by a grid press + a generation counter bumped on every
  -- such touch. The screen pulls these (edge-triggered on focusSeq) so its focus
  -- follows whichever channel the grid is editing, even on a repeat edit of the
  -- same channel. ch is 0-based.
  self.focusCh = 0
  self.focusSeq = 0
  self.picker = nil            -- {kind='step'|'scalar'|'scale', ...} | nil
  self.probMode = false
  self.perfMode = false
  self.soundMode = false
  self.algoMode = false        -- FM algorithm page (per-channel routing selector)
  self.opMode = false          -- OP page: per-channel per-op ratio + level statics
  self.actionMode = nil        -- 'randomize'|'mutate'|'clear'|'copy'|'paste'|nil
  self.clipboard = nil         -- {param = {vals...}} snapshot of a channel's A layer
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
      if self.kbMode or self.probMode or self.perfMode or self.soundMode or self.algoMode or self.opMode then return end
      -- the scale picker repurposes the channel rows; a step picker does not
      -- (it lives on rows 6-7), so let its channel-row playheads keep animating
      if self.picker and self.picker.kind == 'scale' then return end
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

-- mark a channel as the grid's current focus. Bumps focusSeq so the screen
-- re-adopts even when the same channel is touched again. ch is 0-based.
function GridUI:_focus(ch)
  self.focusCh = ch
  self.focusSeq = self.focusSeq + 1
  -- nudge the screen to repaint: some channel-row paths (perf/prob/snd) only
  -- redraw their grid row and never reach render_all's on_redraw, so without
  -- this the focus jump wouldn't show until the next fire flash.
  self.on_redraw()
end

-- single edit path for channel scalar fields: grid and screen both write
-- through here so on_edit sees every mutation. ch is 0-based.
function GridUI:set_scalar(ch, field, value)
  self:chan(ch)[field] = value
  self.on_edit{ type = 'scalar', ch = ch }
end

-- The two step lanes a channel row shows, left ([1]) then right ([2]). Normally
-- a param's A and B layers; div/reps is special — div (A) left, reps (A) right.
function GridUI:row_lanes()
  local p = self.selectedParam
  local pr = PAIR_OF[p]
  if pr then
    return {{param = pr[1], layer = 'A'}, {param = pr[2], layer = 'A'}}
  end
  return {{param = p, layer = 'A'}, {param = p, layer = 'B'}}
end

-- ---- press dispatch ----------------------------------------------------

function GridUI:press(x, y)
  -- KB mode disabled (see handle_row6): kbMode never becomes true.
  -- if self.kbMode then self:handle_kb_press(x, y); return end
  if self.picker then self:handle_picker_press(x, y)
  else self:handle_normal_press(x, y) end
end

function GridUI:handle_normal_press(x, y)
  if y < 6 then
    self:_focus(y)
    if self.perfMode then
      local rate_idx = index_of(RATE_COLS, x)
      if rate_idx ~= -1 then
        self:set_scalar(y, 'rate', RATE_VALUES[rate_idx + 1])
        self:render_channel_row(y); self.g:refresh()
        return
      end
      local oct_idx = index_of(OCTAVE_COLS, x)
      if oct_idx ~= -1 then
        self:set_scalar(y, 'octave', OCTAVE_VALUES[oct_idx + 1])
        self:render_channel_row(y); self.g:refresh()
        return
      end
      local idx = index_of(RESET_COLS, x)
      if idx ~= -1 then
        self:set_scalar(y, 'resetInterval', RESET_INTERVALS[idx + 1])
        self:render_channel_row(y); self.g:refresh()
      end
      return
    end
    if self.probMode then
      local trig_idx = index_of(ALT_TRIG_COLS, x)
      local prob_idx = index_of(PROB_COLS, x)
      if x == PROB_HIT_COL then
        self:set_scalar(y, 'probHit', not self:chan(y).probHit)
      elseif trig_idx ~= -1 then
        self:set_scalar(y, 'altTrig', trig_idx)
      elseif prob_idx ~= -1 then
        self:set_scalar(y, 'burstProb', PROB_VALUES[prob_idx + 1])
      end
      self:render_channel_row(y); self.g:refresh()
      return
    end
    if self.opMode then
      -- ratios on cols 0..3 (op1..op4, all editable); levels on cols 8..11
      local ri = x - OP_RATIO_COL0
      local lvi = x - OP_LEVEL_COL0
      if ri >= 0 and ri <= 3 then            -- op1..op4 ratio
        self:open_scalar_picker(y, 'opRatio' .. (ri + 1), RATIO_VALUES, 'ratio')
      elseif lvi >= 0 and lvi <= 3 then      -- op1..op4 level
        self:open_scalar_picker(y, 'opLevel' .. (lvi + 1), OP_LEVEL_VALUES, 'level')
      end
      return
    end
    if self.soundMode then
      if x <= 2 then self:set_scalar(y, 'envMode', x)
      elseif x >= 4 and x <= 6 then self:set_scalar(y, 'geodeMode', x - 4) end
      self:render_channel_row(y); self.g:refresh()
      return
    end
    if self.algoMode then
      if x <= #ALGO_NAMES - 1 then self:set_scalar(y, 'algo', x + 1) end  -- cols 0..15 -> algo 1..16
      self:render_channel_row(y); self.g:refresh()
      return
    end
    local li, step = decode_col(x)
    local lane = self:row_lanes()[li]
    self:open_step_picker(y, step, lane.param, lane.layer)
  elseif y == 6 then
    self:handle_row6(x)
  elseif y == 7 then
    self:handle_row7(x)
  end
end

function GridUI:handle_picker_press(x, y)
  local p = self.picker
  if p.kind == 'scale' then
    if y < 6 then self:apply_picker_value(p, x, y); return end
    if y == 6 and x == ROW6_QNT_COL then self:close_picker(); return end
    self:close_picker()
    self:handle_normal_press(x, y)
    return
  end
  -- step/scalar picker: value grid on rows 6-7, every channel row live on 0-5.
  if y >= PICKER_ROW0 then
    self:apply_picker_value(p, x, y - PICKER_ROW0)
    return
  end
  if p.kind == 'scalar' then
    -- a channel-row tap closes the scalar picker (re-tap to cancel, or move on).
    self:close_picker()
    self:_focus(y)
    self:handle_normal_press(x, y)
    return
  end
  -- a channel step: re-tapping the open step cancels/closes; any other step
  -- (either half) hops the picker there. Removal lives on the value grid (tap
  -- the lit value), so it no longer needs the channel row to be reachable.
  local li, step = decode_col(x)
  local lane = self:row_lanes()[li]
  if y == p.ch and lane.param == p.param and lane.layer == p.layer and step == p.col then
    self:close_picker()
  else
    self:_focus(y)
    self:open_step_picker(y, step, lane.param, lane.layer)
  end
end

-- ---- value application -------------------------------------------------

function GridUI:apply_picker_value(p, x, y)
  if p.kind == 'step' then
    local v = STEP_PICKER_VALUES[p.param][y * GRID_W + x + 1]
    if v == nil then return end
    -- pressing the already-selected (full-bright) value toggles the step off:
    -- the value grid (rows 6-7) is the remove affordance, freeing the channel
    -- rows to stay visible and the open-step re-tap to mean cancel.
    local cur = seqx.values(self:seq_ref(p.ch, p.param, p.layer))[p.col + 1]
    if cur ~= nil and eq(cur, v) then
      self:remove_step(p.ch, p.col, p.param, p.layer)
    else
      self:set_step(p.ch, p.col, v, p.param, p.layer)
    end
    self:close_picker()
  elseif p.kind == 'scalar' then
    local v = p.layout[y * GRID_W + x + 1]
    if v == nil then return end
    self:set_scalar(p.ch, p.field, v)  -- single edit path: fires on_edit{scalar}
    self:close_picker()
  elseif p.kind == 'scale' then
    -- quantize block (right side): 8x4 grid, cols 8..15, rows 1..4
    if x >= QNT_COL0 and y >= QNT_ROW0 and y < QNT_ROW0 + QNT_H then
      local idx = (y - QNT_ROW0) * QNT_W + (x - QNT_COL0) + 1
      self.engine.quantize = QUANTIZE_VALUES[idx]
    elseif y == SCALE_PRESET_ROW then
      local name = scales.picker_names[x + 1]
      if not name then return end
      self.selectedScaleName = name
      self.customMask = {}
      for _, vv in ipairs(scales.by_name[name]) do self.customMask[#self.customMask + 1] = vv end
      self.engine.scale = self.customMask
    elseif y == DEG_BLACK_ROW or y == DEG_WHITE_ROW then
      local semitone = (y == DEG_BLACK_ROW) and KB_BLACK_COL[x] or KB_WHITE_COL[x]
      if semitone == nil then return end
      self:toggle_mask_note(semitone)
    elseif y == ROOT_BLACK_ROW or y == ROOT_WHITE_ROW then
      local semitone = (y == ROOT_BLACK_ROW) and KB_BLACK_COL[x] or KB_WHITE_COL[x]
      if semitone == nil then return end
      self.engine.root = semitone
    else
      return
    end
    self.on_edit{ type = 'global' }
    self:render_all()
  end
end

-- Toggle a semitone in the custom note mask. Refuses to empty the mask (a scale
-- needs at least one degree). Keeps customMask sorted and re-points engine.scale.
function GridUI:toggle_mask_note(semitone)
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
end

-- preset scale name whose intervals match `mask` exactly, or nil (custom mask).
-- Lets a whole-mask edit re-light the matching preset on the scale picker.
function GridUI:_mask_preset_name(mask)
  for _, name in ipairs(scales.names) do
    local ref = scales.by_name[name]
    if #ref == #mask then
      local same = true
      for k = 1, #ref do if ref[k] ~= mask[k] then same = false break end end
      if same then return name end
    end
  end
  return nil
end

-- Replace the whole custom note mask at once (the params keymask edit path).
-- Shares toggle_mask_note's invariants: dedup + sort, refuse to empty the scale,
-- re-point engine.scale, and emit on_edit{global} so params/screen reflect.
-- Semitones outside 0..11 are dropped; this is the only set-the-mask path so
-- the keymask param stays grid-reachable just like the sequence text params.
function GridUI:set_mask(semitones)
  local seen, mask = {}, {}
  for _, s in ipairs(semitones) do
    s = math.floor(s)
    if s >= 0 and s <= 11 and not seen[s] then seen[s] = true; mask[#mask + 1] = s end
  end
  if #mask == 0 then return end
  table.sort(mask)
  self.customMask = mask
  local copy = {}
  for _, s in ipairs(mask) do copy[#copy + 1] = s end
  self.engine.scale = copy
  local name = self:_mask_preset_name(mask)
  if name then self.selectedScaleName = name end
  self.on_edit{ type = 'global' }
end

-- Global musical scalars (root tonic / quantize grid). Like set_mask these are
-- the single mutation path so on_edit{global} fires and the params/screen
-- reflect; the screen scale page edits through them.
function GridUI:set_root(semitone)
  self.engine.root = semitone % 12
  self.on_edit{ type = 'global' }
end

function GridUI:set_quantize(q)
  self.engine.quantize = clamp(round(q), 1, 32)
  self.on_edit{ type = 'global' }
end

-- ---- picker enter/exit -------------------------------------------------

-- col is the 0-based step index within the lane's half (decode_col already
-- stripped the B_COL0 offset); param/layer come from the pressed lane.
function GridUI:open_step_picker(ch, col, param, layer)
  local cur = seqx.values(self:seq_ref(ch, param, layer))
  local len = #cur
  if col == len then
    if len >= SEQ_LEN then return end
    local nxt = {}
    for i = 1, len do nxt[i] = cur[i] end
    nxt[len + 1] = (layer == 'A') and DEFAULT_VALUE[param] or DEFAULT_VALUE_B[param]
    self:commit_step(ch, param, nxt, layer)
    self.picker = {kind = 'step', ch = ch, col = col, param = param, layer = layer}
  elseif col < len then
    self.picker = {kind = 'step', ch = ch, col = col, param = param, layer = layer}
  else
    return
  end
  self:render_all()
end

-- OP-page scalar picker: edits a per-channel static field (opRatioN / opLevelN)
-- by tapping a value on the rows-6-7 grid. `layout` is the value array, `valkind`
-- ('ratio'|'level') is for the status string.
function GridUI:open_scalar_picker(ch, field, layout, valkind)
  self:_focus(ch)
  self.picker = {kind = 'scalar', ch = ch, field = field, layout = layout, valkind = valkind}
  self:render_all()
end

function GridUI:open_scale_picker()
  -- entering the scale page is exclusive with the other row-6 latch modes, so
  -- only one row-6 button stays lit (see handle_row6's latch handlers)
  self:_clear_latches()
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

function GridUI:set_step(ch, col, value, param, layer)
  local cur = seqx.values(self:seq_ref(ch, param, layer))
  local nxt = {}
  for i = 1, #cur do nxt[i] = cur[i] end
  nxt[col + 1] = value
  self:commit_step(ch, param, nxt, layer)
end

function GridUI:remove_step(ch, col, param, layer)
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
  elseif #final > SEQ_LEN then
    -- single chokepoint for the 8-step cap: every surface (grid/screen/params)
    -- commits through here, so truncating drops over-long sequences everywhere.
    local capped = {}
    for i = 1, SEQ_LEN do capped[i] = final[i] end
    final = capped
  end
  local c = self:chan(ch)
  if layer == 'A' then c[param] = seqx.new(final)
  else c[param .. 'B'] = seqx.new(final) end
  self.on_edit{ type = 'seq', ch = ch, param = param, layer = layer }
end

function GridUI:commit_step(ch, param, vals, layer)
  self:commit_step_raw(ch, param, vals, layer)
end

-- CLR/COPY/PASTE all act on the MAIN (A-layer) sequins only, leaving the B (alt)
-- layer untouched so it can keep variating whatever was cleared/copied/pasted.

function GridUI:clear_channel(ch)
  for _, param in ipairs(PARAMS) do
    self:commit_step_raw(ch, param, {DEFAULT_VALUE[param]}, 'A')
  end
  self:render_all()
end

function GridUI:copy_channel(ch)
  local buf = {}
  for _, param in ipairs(PARAMS) do
    local cur = seqx.values(self:seq_ref(ch, param, 'A'))
    local vals = {}
    for i = 1, #cur do vals[i] = cur[i] end
    buf[param] = vals
  end
  self.clipboard = buf
end

function GridUI:paste_channel(ch)
  if not self.clipboard then return end
  for _, param in ipairs(PARAMS) do
    local vals = self.clipboard[param]
    if vals then
      local copy = {}
      for i = 1, #vals do copy[i] = vals[i] end
      self:commit_step_raw(ch, param, copy, 'A')
    end
  end
  self:render_all()
end

-- ---- row 6 / row 7 -----------------------------------------------------

-- clear every row-6 latch mode + action mode (so only one page is ever active).
function GridUI:_clear_latches()
  self.probMode = false; self.perfMode = false; self.soundMode = false
  self.algoMode = false; self.opMode = false; self.actionMode = nil
end

function GridUI:handle_row6(x)
  -- KB mode disabled: entry commented out (col 11 now drives the ALG page).
  -- if x == ROW6_KB_COL then self:enter_kb_mode(); return end
  local LATCH = {[ROW6_PERF_COL] = 'perfMode', [ROW6_PROB_COL] = 'probMode',
                 [ROW6_SND_COL] = 'soundMode', [ROW6_ALG_COL] = 'algoMode',
                 [ROW6_OP_COL] = 'opMode'}
  if LATCH[x] then
    local was = self[LATCH[x]]
    self:_clear_latches()
    self[LATCH[x]] = not was
    self:render_all(); return
  end
  if x == ROW6_QNT_COL then self:open_scale_picker(); return end

  if self.actionMode and x < 6 then
    self:_focus(x)
    if self.actionMode == 'randomize' then
      self.engine:randomize(x + 1)
      self.on_edit{ type = 'channel', ch = x }
    elseif self.actionMode == 'mutate' then
      self.engine:mutate(x + 1)
      self.on_edit{ type = 'channel', ch = x }
    elseif self.actionMode == 'clear' then self:clear_channel(x)
    elseif self.actionMode == 'copy' then self:copy_channel(x)
    elseif self.actionMode == 'paste' then self:paste_channel(x) end
    self:render_all(); return
  end

  if x < 6 then
    self:_focus(x)
    if self.engine:is_running(x + 1) then self.engine:stop(x + 1)
    else self.engine:launch(x + 1) end
  end
end

function GridUI:handle_row7(x)
  if x < #ROW7_PAGES then
    -- one button per page; a paired page is represented by its first member.
    -- Both A/B (or both pair) lanes are always shown — no A/B flip.
    self.selectedParam = ROW7_PAGES[x + 1]
    self.picker = nil
    self:render_all()
  elseif x == CLR_BUTTON_COL then self:_toggle_action('clear')
  elseif x == COPY_BUTTON_COL then self:_toggle_action('copy')
  elseif x == PASTE_BUTTON_COL then self:_toggle_action('paste')
  elseif x == RANDOMIZE_BUTTON_COL then self:_toggle_action('randomize')
  elseif x == MUTATE_BUTTON_COL then self:_toggle_action('mutate')
  end
end

function GridUI:_toggle_action(name)
  if self.actionMode == name then self.actionMode = nil
  else
    self:_clear_latches()
    self.actionMode = name
  end
  self:render_all()
end

-- ---- rendering ---------------------------------------------------------

function GridUI:render_all()
  -- KB mode disabled (see handle_row6): kbMode never becomes true.
  -- if self.kbMode then self:render_kb_mode(); self:_status(); self.g:refresh(); self.on_redraw(); return end
  self.g:clear()
  if self.picker and (self.picker.kind == 'step' or self.picker.kind == 'scalar') then
    -- step/scalar pick: every channel row stays drawn (the edited cell glows on
    -- its own row) and the value grid borrows the control rows (6-7).
    for ch = 0, NUM_CHANNELS - 1 do self:render_channel_row(ch) end
    if self.picker.kind == 'step' then self:render_step_picker(self.picker)
    else self:render_scalar_picker(self.picker) end
    self:_status()
    self.g:refresh()
    self.on_redraw()
    return
  end
  if self.picker then          -- scale picker owns rows 0-5
    self:render_picker()
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
  local vals = seqx.values(self:seq_ref(p.ch, p.param, p.layer))
  local focused = vals[p.col + 1]
  local layout = STEP_PICKER_VALUES[p.param]
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
      self.g:set_led(x, PICKER_ROW0 + y, b)
      -- rests (reps <= 0) pulse to set them apart from the hit-count cells.
      if p.param == 'reps' and v <= 0 then
        self.g:set_strobe(x, PICKER_ROW0 + y, 'slow')
      end
    end
  end
end

-- OP-page scalar picker: the value layout across rows 6-7, current value bright.
function GridUI:render_scalar_picker(p)
  local cur = self:chan(p.ch)[p.field]
  for i = 1, #p.layout do
    local x = (i - 1) % GRID_W
    local y = PICKER_ROW0 + math.floor((i - 1) / GRID_W)
    self.g:set_led(x, y, eq(p.layout[i], cur) and 15 or 1)
  end
end

function GridUI:render_scale_picker()
  -- clear the whole picker area first (rows 0..5)
  for y = 0, 5 do for x = 0, GRID_W - 1 do self.g:set_led(x, y, 0) end end

  -- row 0: 7 scale presets, left justified
  for x = 0, #scales.picker_names - 1 do
    local name = scales.picker_names[x + 1]
    self.g:set_led(x, SCALE_PRESET_ROW, name == self.selectedScaleName and 15 or 5)
  end

  -- degree (note-mask) keyboard: black row above white row
  for x, semi in pairs(KB_BLACK_COL) do
    self.g:set_led(x, DEG_BLACK_ROW, contains(self.customMask, semi) and 12 or 3)
  end
  for x, semi in pairs(KB_WHITE_COL) do
    self.g:set_led(x, DEG_WHITE_ROW, contains(self.customMask, semi) and 12 or 3)
  end

  -- root keyboard: highlights the single selected tonic
  local root = self.engine.root or 0
  for x, semi in pairs(KB_BLACK_COL) do
    self.g:set_led(x, ROOT_BLACK_ROW, semi == root and 15 or 3)
  end
  for x, semi in pairs(KB_WHITE_COL) do
    self.g:set_led(x, ROOT_WHITE_ROW, semi == root and 15 or 3)
  end

  -- quantize: 8x4 block on the right
  local curq = self.engine.quantize
  for r = 0, QNT_H - 1 do
    for c = 0, QNT_W - 1 do
      local idx = r * QNT_W + c + 1
      self.g:set_led(QNT_COL0 + c, QNT_ROW0 + r, QUANTIZE_VALUES[idx] == curq and 15 or 3)
    end
  end
end

function GridUI:render_channel_row(ch)
  if self.probMode then self:render_prob_row(ch); return end
  if self.perfMode then self:render_perf_row(ch); return end
  if self.soundMode then self:render_sound_row(ch); return end
  if self.algoMode then self:render_algo_row(ch); return end
  if self.opMode then self:render_op_row(ch); return end
  local running = self.engine:is_running(ch + 1)
  -- two lanes side by side: left half (cols 0..SEQ_LEN-1) then right half
  -- (cols B_COL0..15). Normally A/B of the selected param; div/reps shows
  -- div left + reps right (see row_lanes).
  local lanes = self:row_lanes()
  for li, lane in ipairs(lanes) do
    local base = (li == 2) and B_COL0 or 0
    local seq = self:seq_ref(ch, lane.param, lane.layer)
    local vals = seqx.values(seq)
    local len = #vals
    for i = 0, SEQ_LEN - 1 do
      local col = base + i
      if i < len then
        self.g:set_led(col, ch, value_brightness(lane.param, vals[i + 1]))
      elseif i == len and len < SEQ_LEN then
        self.g:set_led(col, ch, 1)  -- the add slot
      else
        self.g:set_led(col, ch, 0)
      end
      self.g:set_strobe(col, ch, 'off')
    end
    if running and len > 0 then
      self.g:set_led(base + seqx.playhead(seq), ch, 15)
    end
    if self.picker and self.picker.kind == 'step' and self.picker.ch == ch
       and self.picker.param == lane.param and self.picker.layer == lane.layer then
      self.g:set_led(base + self.picker.col, ch, 15)
    end
  end
end

-- OP page: per-op ratio (cols 0..3, op1..op4 all editable) + per-op level
-- (cols 8..11), each cell's brightness encoding its value; picker opens on tap.
function GridUI:render_op_row(ch)
  local c = self:chan(ch)
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  local ratios = {c.opRatio1, c.opRatio2, c.opRatio3, c.opRatio4}
  for op = 1, 4 do
    -- ratio brightness from its index in the curated set (low ratio = dim)
    local idx = nearest_index(RATIO_VALUES, ratios[op])
    local rb = clamp(round(2 + (idx - 1) / (#RATIO_VALUES - 1) * 11), 2, VALUE_MAX)
    self.g:set_led(OP_RATIO_COL0 + (op - 1), ch, rb)
    local lvl = c['opLevel' .. op] or 1
    self.g:set_led(OP_LEVEL_COL0 + (op - 1), ch, math.max(2, round(2 + lvl * 11)))
  end
  if self.picker and self.picker.kind == 'scalar' and self.picker.ch == ch then
    local f = self.picker.field
    local op = tonumber(f:sub(-1))
    if f:match('^opRatio') then self.g:set_led(OP_RATIO_COL0 + (op - 1), ch, 15)
    elseif f:match('^opLevel') then self.g:set_led(OP_LEVEL_COL0 + (op - 1), ch, 15) end
  end
end

function GridUI:render_prob_row(ch)
  local c = self:chan(ch)
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  -- note alt-trig mode (cols 0-1): hold / step
  for i = 1, #ALT_TRIG_MODE_NAMES do
    self.g:set_led(ALT_TRIG_COLS[i], ch, c.altTrig == (i - 1) and 15 or 4)
  end
  -- prob options (right-justified): nearest discrete value highlighted
  local sel = nearest_index(PROB_VALUES, c.burstProb)
  for i = 1, #PROB_VALUES do
    self.g:set_led(PROB_COLS[i], ch, i == sel and 15 or 4)
  end
  -- burst/hit toggle (far right)
  self.g:set_led(PROB_HIT_COL, ch, c.probHit and 14 or 4)
  self.g:set_strobe(PROB_HIT_COL, ch, c.probHit and 'slow' or 'off')
end

function GridUI:render_perf_row(ch)
  local c = self:chan(ch)
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  for i = 1, #RESET_INTERVALS do
    self.g:set_led(RESET_COLS[i], ch, RESET_INTERVALS[i] == c.resetInterval and 15 or 3)
  end
  for i = 1, #OCTAVE_VALUES do
    -- center (0) sits a touch brighter so the no-shift column reads as home
    local base = OCTAVE_VALUES[i] == 0 and 5 or 3
    self.g:set_led(OCTAVE_COLS[i], ch, OCTAVE_VALUES[i] == c.octave and 15 or base)
  end
  for i = 1, #RATE_VALUES do
    self.g:set_led(RATE_COLS[i], ch, RATE_VALUES[i] == c.rate and 15 or 3)
  end
end

function GridUI:render_sound_row(ch)
  local c = self:chan(ch)
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  for m = 0, 2 do self.g:set_led(m, ch, c.envMode == m and 15 or 4) end
  for m = 0, 2 do self.g:set_led(m + 4, ch, c.geodeMode == m and 15 or 4) end
end

-- FM algorithm page: cols 0..15 = algorithm 1..16, the channel's selection bright.
function GridUI:render_algo_row(ch)
  local c = self:chan(ch)
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  for a = 1, #ALGO_NAMES do self.g:set_led(a - 1, ch, c.algo == a and 15 or 4) end
end

function GridUI:render_action_mode()
  local mark_running = self.actionMode == 'randomize' or self.actionMode == 'mutate'
  for x = 0, 5 do
    self.g:set_led(x, 6, 10)
    self.g:set_strobe(x, 6, (mark_running and self.engine:is_running(x + 1)) and 'slow' or 'off')
  end
  for x = 6, 11 do self.g:set_led(x, 6, 0) end
  self.g:set_led(ROW6_OP_COL, 6, 8)
  self.g:set_led(ROW6_ALG_COL, 6, 8)
  self.g:set_led(ROW6_PERF_COL, 6, 8)
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
  self.g:set_led(ROW6_PERF_COL, 6, self.perfMode and 15 or 8)
  self.g:set_strobe(ROW6_PERF_COL, 6, self.perfMode and 'fast' or 'off')
  self.g:set_led(ROW6_PROB_COL, 6, self.probMode and 15 or 8)
  self.g:set_strobe(ROW6_PROB_COL, 6, self.probMode and 'fast' or 'off')
  local scale_open = self.picker and self.picker.kind == 'scale'
  self.g:set_led(ROW6_QNT_COL, 6, scale_open and 15 or 8)
  self.g:set_strobe(ROW6_QNT_COL, 6, scale_open and 'fast' or 'off')
  self.g:set_led(ROW6_SND_COL, 6, self.soundMode and 15 or 8)
  self.g:set_strobe(ROW6_SND_COL, 6, self.soundMode and 'fast' or 'off')
  self.g:set_led(ROW6_ALG_COL, 6, self.algoMode and 15 or 8)
  self.g:set_strobe(ROW6_ALG_COL, 6, self.algoMode and 'fast' or 'off')
  self.g:set_led(ROW6_OP_COL, 6, self.opMode and 15 or 8)
  self.g:set_strobe(ROW6_OP_COL, 6, self.opMode and 'fast' or 'off')
end

function GridUI:render_row7()
  for x = 0, #ROW7_PAGES - 1 do
    local bp = ROW7_PAGES[x + 1]
    -- a page button lights when the selected param belongs to its page (itself,
    -- or the same pair via PAIR_OF identity).
    local sel = bp == self.selectedParam
      or (PAIR_OF[bp] ~= nil and PAIR_OF[self.selectedParam] == PAIR_OF[bp])
    self.g:set_led(x, 7, sel and 15 or 5)
    self.g:set_strobe(x, 7, 'off')
  end
  for x = #ROW7_PAGES, 10 do self.g:set_led(x, 7, 0) end  -- dark gap before the action buttons
  local function action_led(col, name)
    self.g:set_led(col, 7, self.actionMode == name and 15 or 4)
    self.g:set_strobe(col, 7, self.actionMode == name and 'fast' or 'off')
  end
  action_led(CLR_BUTTON_COL, 'clear')
  action_led(COPY_BUTTON_COL, 'copy')
  action_led(PASTE_BUTTON_COL, 'paste')
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
  for x = 0, GRID_W - 1 do self.g:set_led(x, 6, 0) end
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
  if self.picker and self.picker.kind == 'scalar' then return 'OP' end
  if self.perfMode then return 'PERF' end
  if self.probMode then return 'PROB' end
  if self.soundMode then return 'SND' end
  if self.algoMode then return 'ALG' end
  if self.opMode then return 'OP' end
  if self.actionMode then return string.upper(self.actionMode) end
  return 'MAIN'
end

function GridUI:_status()
  local s
  if self.kbMode then
    local page = (self.kbPage == 1) and 'pg1 note/div/reps' or 'pg2 level/harm/env'
    local layer = self.kbBLayer and 'B' or 'A'
    s = 'KB ch' .. (self.kbChannel + 1) .. ' ' .. page .. ' [' .. layer .. ']'
  elseif self.perfMode then
    s = 'PERF — cols0-3 reset, cols5-9 oct, cols11-15 rate'
  elseif self.probMode then
    s = 'PROB — cols0-1 note trig, 11-14 prob%, 15 burst/hit'
  elseif self.soundMode then
    s = 'SOUND — env(0-2) / geode(4-6)'
  elseif self.algoMode then
    s = 'ALG — cols0-15 FM algorithm (1-16)'
  elseif self.opMode then
    s = 'OP — cols0-3 op ratio, cols8-11 op level'
  elseif self.actionMode then
    s = string.upper(self.actionMode) .. ' — tap a channel'
  elseif self.picker and self.picker.kind == 'scalar' then
    local op = tonumber(self.picker.field:sub(-1))
    local kind = self.picker.valkind == 'ratio' and 'ratio' or 'level'
    s = 'edit ch' .. (self.picker.ch + 1) .. ' op' .. op .. ' ' .. kind ..
        '=' .. tostring(self:chan(self.picker.ch)[self.picker.field])
  elseif self.picker and self.picker.kind == 'step' then
    local pp = self.picker.param
    local raw = seqx.values(self:seq_ref(self.picker.ch, pp, self.picker.layer))[self.picker.col + 1]
    local v = (pp == 'attack' or pp == 'decay' or pp == 'modatk' or pp == 'moddec') and round(raw * 31) or raw
    s = 'edit ch' .. (self.picker.ch + 1) .. ' step ' .. self.picker.col .. ' ' ..
        pp .. (self.picker.layer == 'B' and 'B' or '') .. '=' .. tostring(v)
  elseif self.picker and self.picker.kind == 'scale' then
    s = 'scale: row0 preset, rows1-2 keys, rows3-4 qnt (' .. self.engine.quantize .. ')'
  else
    local pr = PAIR_OF[self.selectedParam]
    s = pr and ('edit ' .. pr[1] .. ' | ' .. pr[2])
      or ('edit ' .. self.selectedParam .. ' (A | B)')
  end
  self.status = s
  self.on_status(s)
end

return GridUI
