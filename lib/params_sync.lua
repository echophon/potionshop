-- params_sync.lua
-- Exposes the whole instrument as norns params (system PARAMETERS screen,
-- PSETs, MIDI mapping) and keeps them bidirectionally in sync with the grid
-- and screen surfaces.
--
-- Layout: a global block (tuning + the harmonic context — mode / root / chord
-- degree / chord quality / diatonic / inversion / voicing, see lib/chords.lua),
-- the OUTPUTS group (lib/outputs.lua), plus one group per
-- channel ("CHANNEL 1".."CHANNEL 6"). Each group holds the channel scalars
-- (run, rate, quantize, root, env mode, geode, prob, alt trig, op seq trig, op env trig,
-- chord role, reset, channel level + per-op levels, clear/copy/paste + action triggers) and,
-- per sequence parameter x layer (div/reps/note/opEnv1..4/opRatio1..4 x A/B, where div/reps is
-- A-only and the op envelopes + op ratios carry an A value + B index-offset layer),
-- a 3-param block:
--   chN_<p>_<a|b>        text — the whole sequence as a space-separated string
--   chN_<p>_<a|b>_step   number — cursor into the sequence (1-based)
--   chN_<p>_<a|b>_val    number — value at the cursor, as an INDEX into
--                        GridUI.STEP_PICKER_VALUES (B layer adds index 0 =
--                        literal 0, the no-offset default). MIDI-mappable.
-- Per-op timbre: all four op FM ratios ARE sequenced (chN_opRatio1/2/3/4_a/b
-- text+cursor blocks, like note). Channel level (chN_level) and the per-op levels
-- (chN_level1..4) are plain per-channel scalars on the 0..31 grid (MIX page).
--
-- String tokens use the display units the grid/screen use: div/note/reps as
-- integers ('rN' for an N-step rest, reps <= 0), opEnv1..4 A as shape names
-- (or a bare index), their B as an integer index offset. Parsing snaps
-- every token to the nearest picker value (the same nearest-index rule
-- screen_ui edits use), so any menu edit stays grid-reachable.
--
-- Sync invariant (this is what prevents feedback loops): params -> engine
-- only ever happens inside param ACTIONS, which mutate through the same
-- controller paths the grid uses (commit_step / set_scalar / launch), so
-- side effects (on_edit reflection, clipboard) behave identically;
-- engine/UI -> params only ever happens via SILENT params:set
-- (third arg true), which never fires actions. Reflection of off-grid engine
-- values (e.g. mutate's shape-index nudge) snaps for display only — the engine
-- keeps its exact value until the user actually edits that param.
--
-- The module is dependency-injected (engine, controller, params table) so the
-- off-hardware tests can drive it with a fake paramset; no lib module touches
-- the `params` global.

local seqx   = require 'seqx'
local GridUI = require 'grid_ui'
local chords = require 'chords'
local scales = require 'scales'  -- for the global tuning switch (scales.tuning)

local SEQ_PARAMS = GridUI.PARAMS  -- div/reps/note/opEnv1..4/opRatio1..4
local SPV        = GridUI.STEP_PICKER_VALUES
local OP_OFFSETS = GridUI.OP_RATIO_OFFSETS  -- op-ratio B index-offset layout (0..31)
local MAX_STEPS  = GridUI.SEQ_LEN  -- 8-step cap, shared with grid/screen

-- Layer-aware value layout (mirrors GridUI.picker_layout): op-ratio B is an integer
-- index offset, every other lane uses its single STEP_PICKER layout.
local function layout_of(p, layer)
  -- op ratios and op envelopes share the integer index-offset B lane.
  if layer == 'B' and (p:match('^opRatio') or p:match('^opEnv')) then return OP_OFFSETS end
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
-- 32 even steps (1/32 .. 1); non-integer percents round for display (3%, 6%, ...)
local PROB_PCT_NAMES = {}
for i, v in ipairs(GridUI.PROB_VALUES) do
  PROB_PCT_NAMES[i] = math.floor(v * 100 + 0.5) .. '%'
end
local ALT_TRIG_NAMES = GridUI.ALT_TRIG_MODE_NAMES
local NOTE_NAMES = {'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'}

local function round(x) return math.floor(x + 0.5) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- (no sequenced param uses the 0..31 grid scale anymore: the envelope axes became
-- shape indices — see is_shape — and `level` became a static per-channel MIX scalar
-- (chN_level), edited like the op levels rather than as a sequence.)

-- per-op envelope SHAPE params (opEnv1..4): the A lane is a 1-based index into the
-- curated shape table, shown/parsed as a shape NAME (GridUI.SHAPE_NAMES) for
-- readability, falling back to the bare index. The B lane is an integer index
-- offset (handled like the op-ratio B lane), NOT a shape name.
local SHAPE_NAMES = GridUI.SHAPE_NAMES
local SHAPE_INDEX = {}
for i, nm in ipairs(SHAPE_NAMES) do SHAPE_INDEX[string.lower(nm)] = i end
local function is_shape(p) return p:match('^opEnv') ~= nil end

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
  if is_shape(p) then return SHAPE_NAMES[round(v)] or tostring(round(v)) end
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
  if is_shape(p) and layer ~= 'B' then
    -- A lane: accept a shape name (case-insensitive) or a bare index, snapped to 1..#shapes
    local byname = SHAPE_INDEX[string.lower(tok)]
    if byname then return byname end
    local n = tonumber(tok)
    if n == nil then return nil end
    return SPV[p][GridUI.nearest_index(SPV[p], round(n))]
  end
  local n = tonumber(tok)
  if n == nil then return nil end
  if layer == 'B' and n == 0 then return 0 end
  if layer == 'B' and (p:match('^opRatio') or p:match('^opEnv')) then
    return clamp(round(n), 0, #OP_OFFSETS - 1)  -- B = integer index offset 0..31
  end
  return SPV[p][GridUI.nearest_index(SPV[p], n)]
end

function M.to_text(p, layer, vals)
  local toks = {}
  for i = 1, #vals do
    if layer == 'B' and vals[i] == 0 then toks[i] = '0'
    elseif layer == 'B' and is_shape(p) then toks[i] = tostring(round(vals[i]))  -- index offset, not a shape name
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

-- opts: {engine=Burst, controller=GridUI, params=<paramset>}
function M.new(opts)
  local self = setmetatable({}, M)
  self.engine = opts.engine
  self.controller = opts.controller
  self.params = opts.params
  self.triggers_enabled = false  -- armed after the post-init params:bang()
  self.render_pending = false
  return self
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

  -- Tuning: just intonation (default) vs 12-TET. Drives scales.tuning, which the
  -- note-lane and chord-tone frequency paths both funnel through (lib/scales.lua).
  params:add_option('tuning', 'tuning', scales.TUNING_NAMES, scales.tuning)
  params:set_action('tuning', function(i) scales.tuning = i; self:request_render() end)

  -- The global harmonic context (harmonàig model, lib/chords.lua): mode + root
  -- place the scale; degree/quality/inversion/voicing resolve the chord that
  -- role channels play. Every action routes through the controller's global
  -- setters — the same single mutation paths the grid/screen use — so on_edit
  -- reflection keeps all surfaces in step. All are MIDI-mappable, so a chord
  -- progression can be driven externally (chord_degree especially).
  local ctl = self.controller

  params:add_option('mode', 'mode', chords.MODE_NAMES, eng.mode)
  params:set_action('mode', function(i) ctl:set_mode(i); self:request_render() end)

  -- Global harmonic root (harmonàig context). Per-channel tonic transpose is a
  -- separate chN_root added in the channel groups below; the two compose.
  params:add_option('root', 'root', NOTE_NAMES, (eng.root or 0) + 1)
  params:set_action('root', function(i) ctl:set_root(i - 1); self:request_render() end)

  params:add_option('chord_degree', 'chord degree', chords.DEGREE_NAMES, eng.degree)
  params:set_action('chord_degree', function(i) ctl:set_degree(i); self:request_render() end)

  -- keep_diatonic = true: unlike the grid/screen quality gesture, the param
  -- action must not flip `diatonic` — params:bang()/params:default() replay
  -- every action, and a side effect on another param's state would clobber it
  -- (the `diatonic` toggle below is the params-surface way to go manual).
  params:add_option('chord_quality', 'chord quality', chords.QUALITY_NAMES, eng.quality)
  params:set_action('chord_quality', function(i) ctl:set_quality(i, true); self:request_render() end)

  params:add_binary('diatonic', 'diatonic', 'toggle', eng.diatonic and 1 or 0)
  params:set_action('diatonic', function(v) ctl:set_diatonic(v > 0); self:request_render() end)

  params:add_option('inversion', 'inversion', chords.INVERSION_NAMES, eng.inversion + 1)
  params:set_action('inversion', function(i) ctl:set_inversion(i - 1); self:request_render() end)

  params:add_option('voicing', 'voicing', chords.VOICING_NAMES, eng.voicing)
  params:set_action('voicing', function(i) ctl:set_voicing(i); self:request_render() end)

  -- quantize is per-channel now (chN_quantize, added in the channel loop below) —
  -- the old global 'quantize' param is gone.

  -- No VOICE group anymore: env mode + geode were its last two members and are now
  -- per-channel PRISM-page scalars (chN_env_mode / chN_geode). Every other voice
  -- control (env mode, geode, per-op levels, FM mod index / feedback / algorithm, all
  -- four op ratios) is per-channel too — added in the channel groups below.
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
  -- per-channel tonic transpose (ROOT/scale page): signed semitones -12..+11.
  def(1, function()
    params:add_number(id('root'), 'root', -12, 11, c.root or 0)
    params:set_action(id('root'), function(v) c.root = v; self:request_render() end)
  end)
  -- per-channel amp dynamics (PRISM page), 0-based fields so the option index = value+1.
  def(1, function()
    params:add_option(id('env_mode'), 'env mode', GridUI.ENV_MODE_NAMES, c.envMode + 1)
    params:set_action(id('env_mode'), function(i) c.envMode = i - 1; self:request_render() end)
  end)
  def(1, function()
    params:add_option(id('geode'), 'geode', GridUI.GEODE_MODE_NAMES, c.geodeMode + 1)
    params:set_action(id('geode'), function(i) c.geodeMode = i - 1; self:request_render() end)
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
  -- op-ratio sequence trig mode (hold/step): ONE switch driving all four op-ratio
  -- B lanes together (was four per-op params, collapsed)
  def(1, function()
    params:add_option(id('op_trig'), 'op seq trig', ALT_TRIG_NAMES, c.opSeqTrig + 1)
    params:set_action(id('op_trig'), function(i)
      c.opSeqTrig = i - 1
      self:request_render()
    end)
  end)
  -- chord-tone role: free = pitch from the note lanes (mode degrees);
  -- root/3rd/5th/7th = pitch from the global harmonic context's resolved chord,
  -- walked by the channel's SEPARATE stack lanes (chN_stack_a/b, signed offsets
  -- from that tone; see lib/chords.lua stack_tone / Burst:chord_freq). Flipping
  -- the role swaps materials — both lane sets persist.
  def(1, function()
    params:add_option(id('role'), 'chord role', chords.ROLE_NAMES, (c.role or 0) + 1)
    params:set_action(id('role'), function(i)
      ctl:set_scalar(n - 1, 'role', i - 1)
      self:request_render()
    end)
  end)
  -- op-env sequence trig mode (hold/step): ONE switch for all four op-env B lanes.
  -- 'step' walks every op env's B index-offset lane per hit (see Burst:run_burst).
  def(1, function()
    params:add_option(id('openv_trig'), 'op env trig', ALT_TRIG_NAMES, c.opEnvTrig + 1)
    params:set_action(id('openv_trig'), function(i)
      c.opEnvTrig = i - 1
      self:request_render()
    end)
  end)
  -- op1..4 FM ratios are all sequenced now (the chN_opRatioN_a/b blocks generated by
  -- the SEQ_PARAMS loop below) — there is no static op1-ratio scalar.
  -- channel level — a static per-channel scalar on the 0..31 (1/31) grid (MIX page),
  -- demoted from a sequenced lane (it never varied: randomize/mutate left it alone).
  def(1, function()
    params:add_number(id('level'), 'level', 0, 31, round(c.level * 31))
    params:set_action(id('level'), function(v)
      c.level = v / 31
      self:request_render()
    end)
  end)
  -- stereo pan — static per-channel scalar on a 0..31 grid mapped to -1..1 (index 16
  -- = centre, the grid-exact default), the same discrete set (PAN_VALUES, index = i)
  -- the MIX picker uses so a grid/menu edit reflects exactly. Displays as L<n>/C/R<n>.
  def(1, function()
    params:add_number(id('pan'), 'pan', 0, 31, round(c.pan * 15 + 16),
      function(p) return GridUI.pan_label(clamp((p:get() - 16) / 15, -1, 1)) end)
    params:set_action(id('pan'), function(v)
      c.pan = clamp((v - 16) / 15, -1, 1)
      self:request_render()
    end)
  end)
  -- DJ filter position — the channel-strip scalar. Same bipolar 0..31 grid as
  -- pan (index 16 = centre = no filter). It lives on a persistent SC synth, so
  -- the action PUSHES to the engine (Burst:push_filter) — which also replays
  -- boot/PSET state at params:bang.
  def(1, function()
    params:add_number(id('filter'), 'filter', 0, 31, round(c.filterPos * 15 + 16),
      function(p) return GridUI.filter_label(clamp((p:get() - 16) / 15, -1, 1)) end)
    params:set_action(id('filter'), function(v)
      c.filterPos = clamp((v - 16) / 15, -1, 1)
      eng:push_filter(n)
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
  -- per-channel voice scalars (MIX page, after the op levels): FM mod index (1..32),
  -- FM feedback rides a 0..31 grid mapped to 0..4 rad (1/31-of-4 steps), the
  -- grid-exact form the MIX picker uses.
  def(1, function()
    params:add_number(id('mod_index'), 'mod index', 1, 32, round(c.modIndex))
    params:set_action(id('mod_index'), function(v) c.modIndex = v; self:request_render() end)
  end)
  def(1, function()
    params:add_number(id('fm_feedback'), 'fm feedback', 0, 31, round(c.fmFeedback / 4 * 31),
      function(p) return string.format('%.2f', p:get() / 31 * 4) end)
    params:set_action(id('fm_feedback'), function(v) c.fmFeedback = v / 31 * 4; self:request_render() end)
  end)
  -- per-channel FM algorithm (1..22, DX-style operator routing) — an option on the
  -- MIX page's last column. Was an engine-wide VOICE macro until it moved here.
  def(1, function()
    params:add_option(id('algorithm'), 'algorithm', GridUI.ALGO_NAMES, c.algo)
    params:set_action(id('algorithm'), function(i) c.algo = i; self:request_render() end)
  end)
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
      ctl:clear_channel(n - 1)  -- clears every sequence on both layers, like CLR
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
  params:set(id('root'), clamp(c.root or 0, -12, 11), true)
  params:set(id('env_mode'), clamp(c.envMode + 1, 1, #GridUI.ENV_MODE_NAMES), true)
  params:set(id('geode'), clamp(c.geodeMode + 1, 1, #GridUI.GEODE_MODE_NAMES), true)
  params:set(id('prob'), GridUI.nearest_index(GridUI.PROB_VALUES, c.burstProb), true)
  params:set(id('prob_mode'), c.probHit and 2 or 1, true)
  params:set(id('alt_trig'), c.altTrig + 1, true)
  params:set(id('op_trig'), c.opSeqTrig + 1, true)
  params:set(id('openv_trig'), c.opEnvTrig + 1, true)
  params:set(id('role'), (c.role or 0) + 1, true)
  params:set(id('reset'), GridUI.nearest_index(GridUI.RESET_INTERVALS, c.resetInterval), true)
  params:set(id('octave'), c.octave, true)
  params:set(id('level'), round(c.level * 31), true)
  params:set(id('pan'), round(c.pan * 15 + 16), true)
  params:set(id('filter'), round((c.filterPos or 0) * 15 + 16), true)
  for op = 1, 4 do params:set(id('level' .. op), round(c['opLevel' .. op] * 31), true) end
  params:set(id('mod_index'), round(c.modIndex), true)
  params:set(id('fm_feedback'), round(c.fmFeedback / 4 * 31), true)
  params:set(id('algorithm'), clamp(c.algo, 1, #GridUI.ALGO_NAMES), true)
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
  local eng = self.engine
  -- global harmonic root + tuning (guarded: tests build partial param sets).
  -- algo/env_mode/geode are per-channel now — reflected in reflect_scalars.
  if params:lookup_param('root') then
    params:set('root', clamp((eng.root or 0) + 1, 1, 12), true)
  end
  if params:lookup_param('tuning') then
    params:set('tuning', scales.tuning, true)
  end
  -- the harmonic context (harmonàig model, lib/chords.lua)
  if params:lookup_param('mode') then
    params:set('mode', clamp(eng.mode, 1, #chords.MODE_NAMES), true)
    params:set('chord_degree', clamp(eng.degree, 1, 7), true)
    params:set('chord_quality', clamp(eng.quality, 1, #chords.QUALITY_NAMES), true)
    params:set('diatonic', eng.diatonic and 1 or 0, true)
    params:set('inversion', clamp(eng.inversion + 1, 1, 4), true)
    params:set('voicing', clamp(eng.voicing, 1, 4), true)
  end
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
