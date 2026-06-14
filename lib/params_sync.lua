-- params_sync.lua
-- Exposes the whole instrument as norns params (system PARAMETERS screen,
-- PSETs, MIDI mapping) and keeps them bidirectionally in sync with the grid
-- and screen surfaces.
--
-- Layout: a global block (scale / root / quantize / mod_index) plus one group per
-- channel ("CHANNEL 1".."CHANNEL 6"). Each group holds the channel scalars
-- (run, rate, prob, modes, reset, clear/copy/paste + action triggers) and, per
-- sequence parameter x layer (div/reps/note/level/harm/env x A/B), a
-- separator-headed block of three params:
--   chN_<p>_<a|b>        text — the whole sequence as a space-separated string
--   chN_<p>_<a|b>_step   number — cursor into the sequence (1-based)
--   chN_<p>_<a|b>_val    number — value at the cursor, as an INDEX into
--                        GridUI.STEP_PICKER_VALUES (B layer adds index 0 =
--                        literal 0, the no-offset default, which is off-grid
--                        for div/reps/harm). MIDI-mappable per-step editing.
--
-- String tokens use the display units the grid/screen use: div/note/reps as
-- integers ('inf' for infinite reps), level/env on the 0..31 grid scale
-- (value = n/31), harm as the actual ratio (2, 2.75, 3.5, ...). Parsing snaps
-- every token to the nearest picker value (the same nearest-index rule
-- screen_ui edits use), so any menu edit stays grid-reachable.
--
-- Sync invariant (this is what prevents feedback loops): params -> engine
-- only ever happens inside param ACTIONS, which mutate through the same
-- controller paths the grid uses (commit_step / set_scalar / launch), so
-- side effects (on_edit reflection, clipboard) behave identically;
-- engine/UI -> params only ever happens via SILENT params:set
-- (third arg true), which never fires actions. Reflection of off-grid engine
-- values (the boot level default, mutate jitter) snaps for display only —
-- the engine keeps its exact value until the user actually edits that param.
--
-- The module is dependency-injected (engine, controller, params table) so the
-- off-hardware tests can drive it with a fake paramset; no lib module touches
-- the `params` global.

local seqx   = require 'seqx'
local GridUI = require 'grid_ui'

local SEQ_PARAMS = GridUI.PARAMS  -- {'div','reps','note','level','harm','env'}
local SPV        = GridUI.STEP_PICKER_VALUES
local MAX_STEPS  = 16

local RATE_NAMES = {'0.25x', '0.5x', '1x', '2x', '4x'}
local RESET_NAMES = {}
for i, v in ipairs(GridUI.RESET_INTERVALS) do
  RESET_NAMES[i] = (v == 0) and 'off' or (v .. (v == 1 and ' bar' or ' bars'))
end
local PROB_MODE_NAMES = {'burst', 'hit'}
local NOTE_NAMES = {'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'}

local function round(x) return math.floor(x + 0.5) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local M = {}
M.__index = M
M.MAX_STEPS = MAX_STEPS

-- ---- pure value/text conversions (module-level so tests can pin them) ----

-- step-param index <-> engine value. B-layer index 0 = literal 0.
function M.index_to_value(p, layer, idx)
  if layer == 'B' and idx == 0 then return 0 end
  return SPV[p][clamp(idx, 1, #SPV[p])]
end

function M.value_to_index(p, layer, v)
  if layer == 'B' and v == 0 then return 0 end
  return GridUI.nearest_index(SPV[p], v)
end

-- engine value -> display token (the units the grid/screen show).
function M.fmt_value(p, v)
  if p == 'reps' and v == -1 then return 'inf' end
  if p == 'level' or p == 'env' then return tostring(round(v * 31)) end
  if p == 'harm' then
    local s = string.format('%.2f', v)
    s = s:gsub('0+$', ''):gsub('%.$', '')  -- 2.00 -> 2, 3.50 -> 3.5
    return s
  end
  return tostring(round(v))
end

-- display token -> engine value, snapped to the picker grid; nil = invalid.
function M.parse_token(p, layer, tok)
  if p == 'reps' and tok == 'inf' then return -1 end
  local n = tonumber(tok)
  if n == nil then return nil end
  if layer == 'B' and n == 0 then return 0 end
  if p == 'level' or p == 'env' then
    return clamp(round(n), 0, 31) / 31
  end
  return SPV[p][GridUI.nearest_index(SPV[p], n)]
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
    self:request_render()
  end)

  params:add_option('root', 'root', NOTE_NAMES, (eng.root or 0) + 1)
  params:set_action('root', function(i) eng.root = i - 1; self:request_render() end)

  params:add_number('quantize', 'quantize (per whole note)', 1, 32, clamp(eng.quantize, 1, 32))
  params:set_action('quantize', function(v) eng.quantize = v; self:request_render() end)

  params:add_number('mod_index', 'FM mod index', 1, 24, eng.modIndex)
  params:set_action('mod_index', function(v) eng.modIndex = v end)
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
    params:add_number(id('prob'), 'probability', 0, 14, round(c.burstProb * 14),
      function(param) return round(param:get() / 14 * 100) .. '%' end)
    params:set_action(id('prob'), function(v)
      c.burstProb = v / 14
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
  local mode_fields = {
    {'env_mode', 'env mode', 'envMode', GridUI.ENV_MODE_NAMES},
    {'geode', 'geode', 'geodeMode', GridUI.GEODE_MODE_NAMES},
    {'pitch_env', 'pitch env', 'pitchEnv', GridUI.PITCH_ENV_MODE_NAMES},
    {'harm_env', 'harm env', 'harmEnv', GridUI.HARM_ENV_MODE_NAMES},
  }
  for _, m in ipairs(mode_fields) do
    local pid, name, field, names = m[1], m[2], m[3], m[4]
    def(1, function()
      params:add_option(id(pid), name, names, c[field] + 1)
      params:set_action(id(pid), function(i)
        c[field] = i - 1
        self:request_render()
      end)
    end)
  end
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
  for _, p in ipairs(SEQ_PARAMS) do
    for _, layer in ipairs({'A', 'B'}) do
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
          (layer == 'B') and 0 or 1, #SPV[p],
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
  params:set(id('prob'), round(c.burstProb * 14), true)
  params:set(id('prob_mode'), c.probHit and 2 or 1, true)
  params:set(id('env_mode'), c.envMode + 1, true)
  params:set(id('geode'), c.geodeMode + 1, true)
  params:set(id('pitch_env'), c.pitchEnv + 1, true)
  params:set(id('harm_env'), c.harmEnv + 1, true)
  params:set(id('reset'), GridUI.nearest_index(GridUI.RESET_INTERVALS, c.resetInterval), true)
  params:set(id('octave'), c.octave, true)
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
  params:set('quantize', clamp(self.engine.quantize, 1, 32), true)
  params:set('root', clamp((self.engine.root or 0) + 1, 1, 12), true)
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
