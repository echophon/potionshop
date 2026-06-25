-- params_sync.lua
-- Exposes the whole instrument as norns params (system PARAMETERS screen,
-- PSETs, MIDI mapping) and keeps them bidirectionally in sync with the grid
-- and screen surfaces.
--
-- Layout: a global block (scale / root), a VOICE group of engine-wide
-- FM timbre macros (FM algorithm / env mode / geode / mod index / amp punch /
-- fm feedback / fm drive),
-- the OUTPUTS group (lib/outputs.lua), plus one group per
-- channel ("CHANNEL 1".."CHANNEL 6"). Each group holds the channel scalars
-- (run, rate, quantize, prob, alt trig, op2/3/4 ratio trig, reset, op1 ratio, per-op
-- levels, clear/copy/paste + action triggers) and, per sequence parameter x layer (div/reps/note/level/
-- attack/decay/modatk/moddec/opRatio2/opRatio3/opRatio4 x A/B, where div/reps,
-- attack/decay and modatk/moddec are A-only),
-- a 3-param block:
--   chN_<p>_<a|b>        text — the whole sequence as a space-separated string
--   chN_<p>_<a|b>_step   number — cursor into the sequence (1-based)
--   chN_<p>_<a|b>_val    number — value at the cursor, as an INDEX into
--                        GridUI.STEP_PICKER_VALUES (B layer adds index 0 =
--                        literal 0, the no-offset default). MIDI-mappable.
-- Per-op timbre: op2/3/4 FM ratios ARE sequenced (chN_opRatio2/3/4_a/b text+cursor
-- blocks, like note/level). op1 ratio (chN_ratio1, curated options) and chN_level1..4
-- (0..31 grid) stay plain per-channel scalars.
--
-- String tokens use the display units the grid/screen use: div/note/reps as
-- integers ('rN' for an N-step rest, reps <= 0), level/attack/decay on the 0..31 grid scale
-- (value = n/31). Parsing snaps
-- every token to the nearest picker value (the same nearest-index rule
-- screen_ui edits use), so any menu edit stays grid-reachable.
--
-- Sync invariant (this is what prevents feedback loops): params -> engine
-- only ever happens inside param ACTIONS, which mutate through the same
-- controller paths the grid uses (commit_step / set_scalar / launch), so
-- side effects (on_edit reflection, clipboard) behave identically;
-- engine/UI -> params only ever happens via SILENT params:set
-- (third arg true), which never fires actions. Reflection of off-grid engine
-- values (e.g. mutate's attack/decay jitter) snaps for display only — the engine
-- keeps its exact value until the user actually edits that param.
--
-- The module is dependency-injected (engine, controller, params table) so the
-- off-hardware tests can drive it with a fake paramset; no lib module touches
-- the `params` global.

local seqx   = require 'seqx'
local GridUI = require 'grid_ui'

local SEQ_PARAMS = GridUI.PARAMS  -- {'div','reps','note','level','attack','decay'}
local SPV        = GridUI.STEP_PICKER_VALUES
local OP_OFFSETS = GridUI.OP_RATIO_OFFSETS  -- op-ratio B index-offset layout (0..31)
local MAX_STEPS  = GridUI.SEQ_LEN  -- 8-step cap, shared with grid/screen

-- Layer-aware value layout (mirrors GridUI.picker_layout): op-ratio B is an integer
-- index offset, every other lane uses its single STEP_PICKER layout.
local function layout_of(p, layer)
  if layer == 'B' and p:match('^opRatio') then return OP_OFFSETS end
  return SPV[p]
end

local RATE_NAMES = {'0.25x', '0.5x', '1x', '2x', '4x'}
-- curated per-channel quantize labels (mirror GridUI.QUANTIZE_VALUES order),
-- shown as "1/N" since the value is events per whole note
local QUANTIZE_NAMES = {}
for i, q in ipairs(GridUI.QUANTIZE_VALUES) do QUANTIZE_NAMES[i] = '1/' .. q end
local RESET_NAMES = {}
for i, v in ipairs(GridUI.RESET_INTERVALS) do
  RESET_NAMES[i] = (v == 0) and 'off' or (v .. (v == 1 and ' bar' or ' bars'))
end
local PROB_MODE_NAMES = {'burst', 'hit'}
local PROB_PCT_NAMES = {}
for i, v in ipairs(GridUI.PROB_VALUES) do PROB_PCT_NAMES[i] = (v * 100) .. '%' end
local ALT_TRIG_NAMES = GridUI.ALT_TRIG_MODE_NAMES
-- op1 ratio option labels (the static scalar reaches only the 32-cell picker range)
local RATIO_LABELS = {}
for i, r in ipairs(GridUI.RATIO_PICKER) do
  RATIO_LABELS[i] = (r % 1 == 0) and tostring(math.floor(r)) or tostring(r)
end
local function ratio_index(v)
  for i, r in ipairs(GridUI.RATIO_PICKER) do if r == v then return i end end
  return 1
end
local NOTE_NAMES = {'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'}
-- pitch-class name -> semitone, accepting sharps, flats, case-insensitively.
local NAME_TO_PC = {}
for i, nm in ipairs(NOTE_NAMES) do NAME_TO_PC[string.lower(nm)] = i - 1 end
for nm, pc in pairs({db = 1, eb = 3, gb = 6, ab = 8, bb = 10}) do NAME_TO_PC[nm] = pc end

local function round(x) return math.floor(x + 0.5) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- sequenced params shown/parsed on the 0..31 grid scale (value = n/31): the amp
-- `level`, the carrier `attack`/`decay` axes and the modulator `modatk`/`moddec`
-- envelope axes.
local function is_level_like(p)
  return p == 'level' or p == 'attack' or p == 'decay'
      or p == 'modatk' or p == 'moddec'
end

local M = {}
M.__index = M
M.MAX_STEPS = MAX_STEPS

-- ---- pure value/text conversions (module-level so tests can pin them) ----

-- step-param index <-> engine value. B-layer index 0 = literal 0 (no offset). For
-- op-ratio B the layout is the integer index-offset set (layout_of).
function M.index_to_value(p, layer, idx)
  if layer == 'B' and idx == 0 then return 0 end
  local L = layout_of(p, layer)
  return L[clamp(idx, 1, #L)]
end

function M.value_to_index(p, layer, v)
  if layer == 'B' and v == 0 then return 0 end
  return GridUI.nearest_index(layout_of(p, layer), v)
end

-- engine value -> display token (the units the grid/screen show).
function M.fmt_value(p, v)
  if p == 'reps' and v <= 0 then return 'r' .. (1 - v) end  -- rest: r1..r16 = 1..16 steps
  if is_level_like(p) then return tostring(round(v * 31)) end
  if p:match('^opRatio') then
    -- curated ratios incl. thirds/eighths (0.125..14): 3 decimals then trim, so
    -- e.g. 0.375 -> '0.375', 1.5 -> '1.5', 2 -> '2' (round() would corrupt these).
    local s = string.format('%.3f', v)
    return (s:gsub('0+$', ''):gsub('%.$', ''))
  end
  if p == 'harm' then
    local s = string.format('%.2f', v)
    s = s:gsub('0+$', ''):gsub('%.$', '')  -- 2.00 -> 2, 3.50 -> 3.5
    return s
  end
  return tostring(round(v))
end

-- display token -> engine value, snapped to the picker grid; nil = invalid.
function M.parse_token(p, layer, tok)
  if p == 'reps' then
    local rn = tok:match('^r(%d+)$')  -- rest token r1..rN -> reps 1-N (0,-1,-2,..)
    if rn then return SPV[p][GridUI.nearest_index(SPV[p], 1 - tonumber(rn))] end
  end
  local n = tonumber(tok)
  if n == nil then return nil end
  if layer == 'B' and n == 0 then return 0 end
  if layer == 'B' and p:match('^opRatio') then
    return clamp(round(n), 0, #OP_OFFSETS - 1)  -- B = integer index offset 0..31
  end
  if is_level_like(p) then
    return clamp(round(n), 0, 31) / 31
  end
  return SPV[p][GridUI.nearest_index(SPV[p], n)]
end

-- keymask <-> text. The note mask is viewed/edited/stored like a sequence
-- string: a space-separated list of pitch-class names (c, c#, ...). Tokens
-- accept note names (sharp or flat) or bare semitone numbers; everything maps
-- to a pitch class 0..11, the same discrete set the grid's note-mask keyboard
-- reaches. mask_from_text dedups but preserves order; the controller's set_mask
-- sorts on commit (so the reflected text comes back canonical).
function M.mask_to_text(mask)
  local toks = {}
  for _, s in ipairs(mask) do toks[#toks + 1] = NOTE_NAMES[(s % 12) + 1] end
  return table.concat(toks, ' ')
end

function M.mask_from_text(str)
  local out, seen = {}, {}
  for tok in tostring(str or ''):gmatch('%S+') do
    local pc
    local n = tonumber(tok)
    if n ~= nil then pc = math.floor(n) % 12
    else pc = NAME_TO_PC[string.lower(tok)] end
    if pc ~= nil and not seen[pc] then seen[pc] = true; out[#out + 1] = pc end
  end
  return out
end

function M.to_text(p, layer, vals)
  local toks = {}
  for i = 1, #vals do
    if layer == 'B' and vals[i] == 0 then toks[i] = '0'
    else toks[i] = M.fmt_value(p, vals[i]) end
  end
  return table.concat(toks, ' ')
end

function M.from_text(p, layer, str)
  local out = {}
  for tok in tostring(str or ''):gmatch('%S+') do
    local v = M.parse_token(p, layer, tok)
    if v ~= nil then out[#out + 1] = v end
    if #out >= MAX_STEPS then break end
  end
  return out
end

local function seq_ids(n, p, layer)
  local base = 'ch' .. n .. '_' .. p .. '_' .. string.lower(layer)
  return base, base .. '_step', base .. '_val'
end

-- ---- construction --------------------------------------------------------

-- opts: {engine=Burst, controller=GridUI, params=<paramset>, scales=<scales>}
function M.new(opts)
  local self = setmetatable({}, M)
  self.engine = opts.engine
  self.controller = opts.controller
  self.params = opts.params
  self.scales = opts.scales
  self.triggers_enabled = false  -- armed after the post-init params:bang()
  self.render_pending = false
  return self
end

-- preset index whose intervals match `intervals` exactly, or nil (custom mask)
function M:_scale_index(intervals)
  for i, name in ipairs(self.scales.names) do
    local ref = self.scales.by_name[name]
    if #ref == #intervals then
      local same = true
      for k = 1, #ref do if ref[k] ~= intervals[k] then same = false; break end end
      if same then return i end
    end
  end
  return nil
end

-- ---- param definitions ----------------------------------------------------

-- Defaults are captured from the CURRENT engine state, so the params:bang()
-- after init re-applies exactly what the boot randomization seeded (and
-- params:default() restores that boot state). Split into globals/channels so
-- the host can insert other groups (lib/outputs.lua) between them.
function M:add_params()
  self:add_globals()
  self:add_channels()
end

function M:add_globals()
  local params = self.params
  local eng = self.engine

  params:add_separator('potionshop', 'POTIONSHOP')

  params:add_option('scale', 'scale', self.scales.names, self:_scale_index(eng.scale) or 2)
  params:set_action('scale', function(i)
    local name = self.scales.names[i]
    eng.scale = self.scales.by_name[name]
    local controller = self.controller
    controller.selectedScaleName = name
    controller.customMask = {}
    for _, v in ipairs(self.scales.by_name[name]) do
      controller.customMask[#controller.customMask + 1] = v
    end
    self:reflect_globals()  -- keep the keymask text in step with the chosen scale
    self:request_render()
  end)

  params:add_option('root', 'root', NOTE_NAMES, (eng.root or 0) + 1)
  params:set_action('root', function(i) eng.root = i - 1; self:request_render() end)

  -- the note mask, edited/stored as a sequence-like string of pitch-class names.
  -- Commits through the controller's set_mask (the one set-the-whole-mask path),
  -- so it behaves exactly like a grid note-mask edit; an empty/invalid string is
  -- refused (a scale needs a degree) and the display restored.
  params:add_text('keymask', 'key mask', M.mask_to_text(eng.scale))
  params:set_action('keymask', function(str)
    local mask = M.mask_from_text(str)
    if #mask > 0 then self.controller:set_mask(mask)
    else self:reflect_globals() end
    self:request_render()
  end)

  -- quantize is per-channel now (chN_quantize, added in the channel loop below) —
  -- the old global 'quantize' param is gone.

  -- VOICE: engine-wide FM timbre macros. Global (not per-channel) since the
  -- non-audio output types can't render them; these are the actual values the SC
  -- voice receives at fire time. Percent where the underlying value is fractional.
  local function pct() return function(p) return p:get() .. '%' end end
  -- (FM decay retired: the modulator-envelope decay is now per-channel sequenced
  -- via the chN_moddec_a block, not a global macro.)
  params:add_group('voice', 'VOICE', 7)
  -- FM algorithm (1..16, 1-based): engine-wide operator routing. Was per-channel
  -- (chN_algorithm + grid ALG page); now a single global timbre macro.
  params:add_option('algorithm', 'FM algorithm', GridUI.ALGO_NAMES, eng.algo)
  params:set_action('algorithm', function(i) eng.algo = i end)
  -- amp decay timing + per-hit amp geode: both were per-channel (grid/screen SND
  -- page); now engine-wide macros (the SND page was reclaimed). 0-based fields, so
  -- the option index is value + 1.
  params:add_option('env_mode', 'env mode', GridUI.ENV_MODE_NAMES, eng.envMode + 1)
  params:set_action('env_mode', function(i) eng.envMode = i - 1 end)
  params:add_option('geode', 'geode', GridUI.GEODE_MODE_NAMES, eng.geodeMode + 1)
  params:set_action('geode', function(i) eng.geodeMode = i - 1 end)
  params:add_number('mod_index', 'FM mod index', 1, 24, round(eng.modIndex))
  params:set_action('mod_index', function(v) eng.modIndex = v end)
  params:add_number('amp_punch', 'amp punch', 0, 12, round(eng.ampPunch))
  params:set_action('amp_punch', function(v) eng.ampPunch = v end)
  params:add_number('fm_feedback', 'FM feedback', 0, 200, round(eng.fmFeedback * 100), pct())
  params:set_action('fm_feedback', function(v) eng.fmFeedback = v / 100 end)
  params:add_number('fm_drive', 'FM drive', 100, 800, round(eng.drive * 100), pct())
  params:set_action('fm_drive', function(v) eng.drive = v / 100 end)
  -- op1 ratio + per-op output levels are per-channel static scalars (chN_ratio1,
  -- chN_level1..4); op2/3/4 ratios are sequenced, added in the channel groups below.
end

function M:add_channels()
  for n = 1, #self.engine.channels do self:_add_channel_params(n) end
end

function M:_add_channel_params(n)
  local params = self.params
  local eng = self.engine
  local ctl = self.controller
  local c = eng.channels[n]
  local function id(suffix) return 'ch' .. n .. '_' .. suffix end

  -- collected as closures so the group size is correct by construction;
  -- each def declares how many params (separators included) it will add
  local defs = {}
  local group_size = 0
  local function def(n_params, fn)
    defs[#defs + 1] = fn
    group_size = group_size + n_params
  end

  -- ---- scalars ----
  def(1, function()
    params:add_binary(id('run'), 'run', 'toggle', eng:is_running(n) and 1 or 0)
    params:set_action(id('run'), function(v)
      local running = eng:is_running(n)
      if v > 0 and not running then eng:launch(n)
      elseif v == 0 and running then eng:stop(n) end
      self:request_render()
    end)
  end)
  def(1, function()
    params:add_option(id('rate'), 'rate', RATE_NAMES,
      GridUI.nearest_index(GridUI.RATE_VALUES, c.rate))
    params:set_action(id('rate'), function(i)
      c.rate = GridUI.RATE_VALUES[i]
      self:request_render()
    end)
  end)
  def(1, function()
    params:add_option(id('quantize'), 'quantize', QUANTIZE_NAMES,
      GridUI.nearest_index(GridUI.QUANTIZE_VALUES, c.quantize))
    params:set_action(id('quantize'), function(i)
      c.quantize = GridUI.QUANTIZE_VALUES[i]
      self:request_render()
    end)
  end)
  def(1, function()
    params:add_option(id('prob'), 'probability', PROB_PCT_NAMES,
      GridUI.nearest_index(GridUI.PROB_VALUES, c.burstProb))
    params:set_action(id('prob'), function(i)
      c.burstProb = GridUI.PROB_VALUES[i]
      self:request_render()
    end)
  end)
  def(1, function()
    params:add_option(id('prob_mode'), 'prob mode', PROB_MODE_NAMES, c.probHit and 2 or 1)
    params:set_action(id('prob_mode'), function(i)
      c.probHit = (i == 2)
      self:request_render()
    end)
  end)
  def(1, function()
    params:add_option(id('alt_trig'), 'alt trig', ALT_TRIG_NAMES, c.altTrig + 1)
    params:set_action(id('alt_trig'), function(i)
      c.altTrig = i - 1
      self:request_render()
    end)
  end)
  -- per-op-ratio sequence trig mode (hold/step), one per sequenced op ratio
  for op = 2, 4 do
    local field = 'opRatio' .. op .. 'Trig'
    def(1, function()
      params:add_option(id('op' .. op .. '_trig'), 'op' .. op .. ' ratio trig', ALT_TRIG_NAMES, c[field] + 1)
      params:set_action(id('op' .. op .. '_trig'), function(i)
        c[field] = i - 1
        self:request_render()
      end)
    end)
  end
  -- op1 FM ratio (the static fundamental) — a curated static scalar. op2/3/4 ratios
  -- are sequenced (the chN_opRatioN_a/b blocks generated by the SEQ_PARAMS loop).
  def(1, function()
    params:add_option(id('ratio1'), 'op1 ratio', RATIO_LABELS, ratio_index(c.opRatio1))
    params:set_action(id('ratio1'), function(i)
      c.opRatio1 = GridUI.RATIO_PICKER[i]
      self:request_render()
    end)
  end)
  -- per-operator output levels (op1..4) — static scalars on the 0..1 (1/31) grid
  for op = 1, 4 do
    local field = 'opLevel' .. op
    def(1, function()
      params:add_number(id('level' .. op), 'op' .. op .. ' level', 0, 31, round(c[field] * 31))
      params:set_action(id('level' .. op), function(v)
        c[field] = v / 31
        self:request_render()
      end)
    end)
  end
  -- env mode + geode are no longer per-channel: they're engine-wide VOICE macros.
  def(1, function()
    params:add_option(id('reset'), 'reset', RESET_NAMES,
      GridUI.nearest_index(GridUI.RESET_INTERVALS, c.resetInterval))
    params:set_action(id('reset'), function(i)
      c.resetInterval = GridUI.RESET_INTERVALS[i]
      self:request_render()
    end)
  end)
  def(1, function()
    params:add_number(id('octave'), 'octave', -2, 2, c.octave,
      function(param)
        local v = param:get()
        return (v > 0 and '+' or '') .. v
      end)
    params:set_action(id('octave'), function(v)
      c.octave = v
      self:request_render()
    end)
  end)
  def(1, function()
    params:add_trigger(id('randomize'), 'randomize!')
    params:set_action(id('randomize'), function()
      if not self.triggers_enabled then return end
      eng:randomize(n)
      self:reflect_channel(n)
      self:request_render()
    end)
  end)
  def(1, function()
    params:add_trigger(id('mutate'), 'mutate!')
    params:set_action(id('mutate'), function()
      if not self.triggers_enabled then return end
      eng:mutate(n)
      self:reflect_channel(n)
      self:request_render()
    end)
  end)
  def(1, function()
    params:add_trigger(id('clear'), 'clear channel!')
    params:set_action(id('clear'), function()
      if not self.triggers_enabled then return end
      ctl:clear_channel(n - 1)  -- clears all six MAIN (A-layer) sequins, like CLR
    end)
  end)
  def(1, function()
    params:add_trigger(id('copy'), 'copy channel')
    params:set_action(id('copy'), function()
      if not self.triggers_enabled then return end
      ctl:copy_channel(n - 1)  -- snapshots the MAIN (A-layer) sequins to clipboard
    end)
  end)
  def(1, function()
    params:add_trigger(id('paste'), 'paste channel')
    params:set_action(id('paste'), function()
      if not self.triggers_enabled then return end
      ctl:paste_channel(n - 1)  -- writes the clipboard into the MAIN (A-layer) sequins
    end)
  end)

  -- ---- sequence blocks (text + cursor pair per param x layer) ----
  -- div/reps have no B layer, so they get an A block only (see GridUI.has_b).
  for _, p in ipairs(SEQ_PARAMS) do
    for _, layer in ipairs({'A', 'B'}) do
      -- div/reps have no B layer (see GridUI.has_b): skip their B block
      if layer == 'B' and not GridUI.has_b(p) then goto continue end
      local text_id, step_id, val_id = seq_ids(n, p, layer)
      local label = p .. ' ' .. string.lower(layer)
      def(4, function()  -- separator + text + step + val
        params:add_separator(text_id .. '_sep', label)

        local vals = seqx.values(ctl:seq_ref(n - 1, p, layer))
        params:add_text(text_id, label, M.to_text(p, layer, vals))
        params:set_action(text_id, function(str)
          -- commit_step handles empty (-> layer default) exactly as a grid
          -- edit does; the resulting on_edit reflection silently normalizes
          -- the string
          ctl:commit_step(n - 1, p, M.from_text(p, layer, str), layer)
          self:request_render()
        end)

        params:add_number(step_id, label .. ' step', 1, MAX_STEPS, 1)
        params:set_action(step_id, function(v)
          local cur = seqx.values(ctl:seq_ref(n - 1, p, layer))
          local k = clamp(v, 1, math.max(1, #cur))
          if k ~= v then params:set(step_id, k, true) end
          if cur[k] ~= nil then
            params:set(val_id, M.value_to_index(p, layer, cur[k]), true)
          end
        end)

        params:add_number(val_id, label .. ' value',
          (layer == 'B') and 0 or 1, #layout_of(p, layer),
          M.value_to_index(p, layer, vals[1]),
          function(param) return M.fmt_value(p, M.index_to_value(p, layer, param:get())) end)
        params:set_action(val_id, function(idx)
          local cur = seqx.values(ctl:seq_ref(n - 1, p, layer))
          local nxt = {}
          for i = 1, #cur do nxt[i] = cur[i] end
          local k = clamp(params:get(step_id), 1, math.max(1, #nxt))
          nxt[k] = M.index_to_value(p, layer, idx)
          ctl:commit_step(n - 1, p, nxt, layer)
          self:request_render()
        end)
      end)
      ::continue::
    end
  end

  params:add_group('ch' .. n, 'CHANNEL ' .. n, group_size)
  for _, fn in ipairs(defs) do fn() end
end

-- ---- wiring ---------------------------------------------------------------

function M:attach()
  self.controller.on_edit = function(ev) self:on_edit(ev) end
  self.engine:on(function(ev)
    if ev.type == 'launch' then
      self.params:set('ch' .. ev.ch .. '_run', 1, true)
    elseif ev.type == 'stop' then
      self.params:set('ch' .. ev.ch .. '_run', 0, true)
    end
  end)
  -- after a PSET load, re-reflect everything: pset read applies params in
  -- creation order and every action is idempotent, but reflection guarantees
  -- text normalization and cursor clamps regardless of saved-file contents
  local prev = self.params.action_read
  self.params.action_read = function(...)
    if prev then prev(...) end
    self:reflect_all()
    self:request_render()
  end
end

-- armed only after the post-init params:bang(), so a bang (or stray pset
-- machinery) can never fire randomize/mutate/clear
function M:enable_triggers() self.triggers_enabled = true end

-- controller mutation observer (ch arrives 0-based; params ids are 1-based)
function M:on_edit(ev)
  if ev.type == 'seq' then self:reflect_seq(ev.ch + 1, ev.param, ev.layer)
  elseif ev.type == 'scalar' then self:reflect_scalars(ev.ch + 1)
  elseif ev.type == 'channel' then self:reflect_channel(ev.ch + 1)
  elseif ev.type == 'global' then self:reflect_globals() end
end

-- ---- engine -> params reflection (all silent) ------------------------------

function M:reflect_seq(n, p, layer)
  local params = self.params
  local text_id, step_id, val_id = seq_ids(n, p, layer)
  if not params:lookup_param(text_id) then return end
  local vals = seqx.values(self.controller:seq_ref(n - 1, p, layer))
  params:set(text_id, M.to_text(p, layer, vals), true)
  local k = clamp(params:get(step_id), 1, math.max(1, #vals))
  params:set(step_id, k, true)
  if vals[k] ~= nil then
    params:set(val_id, M.value_to_index(p, layer, vals[k]), true)
  end
end

function M:reflect_scalars(n)
  local params = self.params
  local c = self.engine.channels[n]
  local function id(suffix) return 'ch' .. n .. '_' .. suffix end
  if not params:lookup_param(id('run')) then return end
  params:set(id('run'), self.engine:is_running(n) and 1 or 0, true)
  params:set(id('rate'), GridUI.nearest_index(GridUI.RATE_VALUES, c.rate), true)
  params:set(id('quantize'), GridUI.nearest_index(GridUI.QUANTIZE_VALUES, c.quantize), true)
  params:set(id('prob'), GridUI.nearest_index(GridUI.PROB_VALUES, c.burstProb), true)
  params:set(id('prob_mode'), c.probHit and 2 or 1, true)
  params:set(id('alt_trig'), c.altTrig + 1, true)
  for op = 2, 4 do params:set(id('op' .. op .. '_trig'), c['opRatio' .. op .. 'Trig'] + 1, true) end
  params:set(id('reset'), GridUI.nearest_index(GridUI.RESET_INTERVALS, c.resetInterval), true)
  params:set(id('octave'), c.octave, true)
  params:set(id('ratio1'), ratio_index(c.opRatio1), true)  -- op1 ratio static; op2/3/4 sequenced
  for op = 1, 4 do params:set(id('level' .. op), round(c['opLevel' .. op] * 31), true) end
end

function M:reflect_channel(n)
  self:reflect_scalars(n)
  for _, p in ipairs(SEQ_PARAMS) do
    self:reflect_seq(n, p, 'A')
    self:reflect_seq(n, p, 'B')
  end
end

function M:reflect_globals()
  local params = self.params
  params:set('algorithm', clamp(self.engine.algo, 1, #GridUI.ALGO_NAMES), true)
  params:set('env_mode', clamp(self.engine.envMode + 1, 1, #GridUI.ENV_MODE_NAMES), true)
  params:set('geode', clamp(self.engine.geodeMode + 1, 1, #GridUI.GEODE_MODE_NAMES), true)
  params:set('root', clamp((self.engine.root or 0) + 1, 1, 12), true)
  if params:lookup_param('keymask') then
    params:set('keymask', M.mask_to_text(self.engine.scale), true)
  end
  -- a custom note mask has no preset index; leave the option untouched then
  local si = self:_scale_index(self.engine.scale)
  if si then params:set('scale', si, true) end
end

function M:reflect_all()
  self:reflect_globals()
  for n = 1, #self.engine.channels do self:reflect_channel(n) end
end

-- ---- render coalescing -----------------------------------------------------
-- Param actions never repaint directly (params:bang() fires hundreds of
-- actions); they raise this flag and the host's 15 Hz strobe metro flushes it
-- into one controller refresh (which also marks the screen dirty).

function M:request_render() self.render_pending = true end

function M:flush()
  if self.render_pending then
    self.render_pending = false
    self.controller:refresh()
  end
end

return M
