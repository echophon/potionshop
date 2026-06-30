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
--   row 6     = 0 note · 1 op1 ratio · 2 op2 ratio · 3 op3 ratio · 4 op4 ratio
--             · 5..10 dark
--             · 11 MIX · 12 PERF · 13 PROB · 14 SCALE · 15 QNT
--               (SCALE opens the scale picker; QNT is the per-channel quantize
--               page. KB page disabled; FM algorithm, env mode and geode are
--               global params, not grid pages -- the old SND page was reclaimed)
--   row 7     = 0 div/reps · 1 opEnv1 · 2 opEnv2 · 3 opEnv3 · 4 opEnv4
--             · 5..10 launch ch0..5 (channels 1..6)
--             · 11 COPY · 12 PASTE · 13 CLR · 14 RANDOMIZE · 15 MUTATE
--   Page-select buttons (one per sequence page) are split across the two control
--   rows: row 6 cols 0..4 = note + the four op-ratio pages; row 7 cols 0..4 =
--   div/reps + the four per-op envelope pages (opEnv1..4). div/reps is the only
--   paired page (two A-layer lanes); the op-env pages are A/B sequenced like the op
--   ratios — A = a 1-based shape index into the curated table, B = an integer index
--   offset that walks the table. All four op ratios are likewise sequenced pages
--   (A value | B offset); channel level + op levels stay static on the MIX page.
--   Channel launch/stop is a contiguous 1x6 strip on row 7 at cols 5..10 (col 5+ch =
--   channel ch+1). A button toggles its channel's launch/stop; when an action mode
--   (CLR/COPY/PASTE/RANDOMIZE/MUTATE) is armed it instead targets that channel.
--   CLR clears BOTH layers (A + the B/alt layer where present) of the tapped
--   channel; COPY/PASTE act on the MAIN (A-layer) sequins only, leaving the B (alt)
--   layer intact so it can keep variating the copied sequins.
--   MIX:   rows 0-5 = PAN (col 6) + channel LEVEL (col 7) + per-op LEVEL (cols 8-11)
--          + voice scalars mod index (12) / amp punch (13) / FM feedback (14) / FM
--          ALGORITHM (15, per-channel). Tap a cell to open its value picker on rows
--          6-7. (All four op ratios are sequenced — edited on their row-7 pages, not
--          here, so cols 0-5 of the MIX channel rows are dark.)
--   PROB:  rows 0-5 = note alt-trig hold/step (cols 0-1)
--          · op1/2/3/4 ratio-seq trig toggles (cols 3-6, single button each:
--            off=hold, on=step)
--          · op1/2/3/4 env shape-seq trig toggles (cols 7-10, single button each)
--          · prob 25/50/75/100% (cols 11-14, right-justified)
--          · col 15 burst/hit toggle
--   PERF:  rows 0-5 = reset off/1/2/4 bars (cols 0..3) · octave -2..+2 (cols 5..9)
--          · rate (cols 11..15)
--   QNT:   rows 0-5 = per-channel quantize, one cell per curated value on cols 0-7
--          ({3,4,6,8,12,16,24,32} = 1/3..1/32 events per whole note).
--   scale picker: row 0 cols 0-6 scale presets (7)
--                 rows 1-2 cols 0-6 degree (note-mask) keyboard: black row 1 / white row 2
--                 rows 4-5 cols 0-6 root keyboard: black row 4 / white row 5
--                 (quantize is no longer here — it is per-channel on the QNT page)
--                 keyboards are a compact piano: white keys packed at cols 0-6,
--                 black keys offset above the white key they follow
--   step picker:  value grid on rows 6-7 (the control rows, borrowed while
--                 picking) so all six channel rows stay visible. Press the
--                 lit/current value to remove the step; press any other value
--                 to set it. On the channel rows: tap another step to hop the
--                 picker there, or re-tap the open step to cancel/close.
--   scalar picker: same rows-6-7 value grid, but writes a per-channel static
--                 scalar (MIX-page channel level / op level) instead of a sequence step.
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
-- ROW7_PAGES — one per page). All four op FM ratios are sequenced (A value + B index
-- offset, like note); channel level + op levels stay static on the MIX page.
local PARAMS = {'div', 'reps', 'note',
                'opEnv1', 'opEnv2', 'opEnv3', 'opEnv4',
                'opRatio1', 'opRatio2', 'opRatio3', 'opRatio4'}
-- Paired params share one page as two A-layer lanes (left|right) instead of a
-- param's own A|B layers: div|reps (an additive offset on division/repeats isn't
-- musical). div/reps is now the ONLY paired page (the per-op envelopes are A/B
-- sequenced, like the op ratios). A paired param has no B layer; every other param
-- shows its A layer left, B right.
local PAIRS = { {'div', 'reps'} }
local PAIRED, PAIR_OF = {}, {}
for _, pr in ipairs(PAIRS) do
  PAIRED[pr[1]] = true; PAIRED[pr[2]] = true
  PAIR_OF[pr[1]] = pr;  PAIR_OF[pr[2]] = pr
end
local function has_b(param) return not PAIRED[param] end
-- page-select buttons: ONE per page. A paired page is represented by its first
-- member (selecting it shows both lanes via row_lanes); singles are themselves.
-- The pages are split across the two control rows: ROW 6 (cols 0..4) = note + the
-- four op-ratio pages; ROW 7 (cols 0..4) = div/reps + the four per-op envelope
-- pages (opEnv1..4). Each list maps to cols 0..#list-1 on its row.
local ROW6_PAGES = {'note', 'opRatio1', 'opRatio2', 'opRatio3', 'opRatio4'}
local ROW7_PAGES = {'div', 'opEnv1', 'opEnv2', 'opEnv3', 'opEnv4'}

-- row 7 action buttons: COPY | PASTE | CLR | RANDOMIZE | MUTATE (copy/paste sit to
-- the left, clear immediately right of them).
local COPY_BUTTON_COL = 11
local PASTE_BUTTON_COL = 12
local CLR_BUTTON_COL = 13
local RANDOMIZE_BUTTON_COL = 14
local MUTATE_BUTTON_COL = 15
-- row 6 right side
-- KB mode is disabled and the FM algorithm is now a global param (no grid page),
-- so cols 6..10 on row 6 are dark. The KB entry is commented out below; left in
-- place so the mode can be restored by un-commenting. Col 15 (the old SND page) is
-- likewise dark now that env mode + geode are global VOICE params.
-- local ROW6_KB_COL = 11
local ROW6_MIX_COL = 11   -- per-channel MIX page (took the old ALG slot; channel level + op level statics)
local ROW6_PERF_COL = 12
local ROW6_PROB_COL = 13
local ROW6_SCALE_COL = 14 -- opens the scale picker (scale preset / degrees / root)
local ROW6_QNT_COL = 15   -- per-channel QNT page (event snap grid, curated set)
-- Channel launch/stop (and action-target) buttons: a single contiguous 1x6 strip on
-- ROW 7 at cols 5..10 (channel ch -> col 5 + ch, so ch0..5 = channels 1..6). Sits
-- between the row-7 page buttons (cols 0..4) and the action buttons (cols 11..15),
-- filling the row. (Was a 3x2 block at cols 8..10 across rows 6 & 7.)
local LAUNCH_COL0 = 5
local LAUNCH_ROW  = 7
-- (x, y) -> channel 0..5 if it falls in the launch strip, else nil.
local function launch_channel_at(x, y)
  if y == LAUNCH_ROW and x >= LAUNCH_COL0 and x < LAUNCH_COL0 + NUM_CHANNELS then
    return x - LAUNCH_COL0
  end
  return nil
end
-- MIX page channel-row layout: stereo PAN on col 6, channel LEVEL on col 7, op1..4
-- LEVEL on cols 8..11 (one contiguous strip), then the per-channel voice scalars —
-- FM mod index (col 12), amp punch (col 13), FM feedback (col 14), algorithm (col 15).
-- All four op ratios are sequenced (row-7 pages), not here, so cols 0..5 are dark.
local PAN_COL = 6          -- per-channel stereo pan, just left of the level strip
local MIX_LEVEL_COL = 7
local OP_LEVEL_COL0 = 8
local MOD_INDEX_COL = 12
local AMP_PUNCH_COL = 13
local FM_FEEDBACK_COL = 14
local ALGO_COL = 15
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
-- (the scale picker no longer hosts a quantize block — quantize is per-channel on
-- its own QNT page; the right side of the scale picker is now unused.)
local RESET_INTERVALS = {0, 1, 2, 4}
local RESET_COLS      = {0, 1, 2, 3}
local OCTAVE_VALUES = {-2, -1, 0, 1, 2}
local OCTAVE_COLS   = {5, 6, 7, 8, 9}
local RATE_VALUES = {0.25, 0.5, 1, 2, 4}
local RATE_COLS   = {11, 12, 13, 14, 15}
-- PROB page: note alt-trig mode packed left (cols 0-1), the four op-ratio sequence
-- trig toggles next to it (cols 3-6), the two envelope-shape trig toggles after them
-- (cols 8-9), prob options right-justified (cols 11-14), hit toggle at the far right
-- (col 15). burstProb is a discrete 4-value set.
local ALT_TRIG_COLS  = {0, 1}                -- note alt(B) layer: hold / step
-- op1/2/3/4 ratio-sequence trig: ONE button each (off=hold, on=step), to save grid
-- space (vs the note pair). Cols 3/4/5/6 -> opRatio1/2/3/4 trig.
local OP_TRIG_COLS   = {3, 4, 5, 6}
local OP_TRIG_FIELDS = {'opRatio1Trig', 'opRatio2Trig', 'opRatio3Trig', 'opRatio4Trig'}
-- per-op envelope sequence trig: ONE button each (off=hold, on=step), same as the
-- op-ratio toggles. Cols 7/8/9/10 -> opEnv1/2/3/4 trig (step walks that op env's B
-- index-offset lane, like the op ratios).
local OP_ENV_TRIG_COLS   = {7, 8, 9, 10}
local OP_ENV_TRIG_FIELDS = {'opEnv1Trig', 'opEnv2Trig', 'opEnv3Trig', 'opEnv4Trig'}
local PROB_VALUES   = {0.25, 0.5, 0.75, 1.0}
local PROB_COLS     = {11, 12, 13, 14}
local PROB_HIT_COL  = 15

local ENV_MODE_NAMES       = {'shape', 'burst', 'hit'}
local GEODE_MODE_NAMES     = {'transient', 'sustain', 'cycle'}  -- amp geode, always on
-- FM algorithm (1..32): operator routings, labelled by their shape. 1..8 are the
-- canonical Yamaha 4-op DX set; 9..16 are extended PM routings; 17..32 are AM/ring &
-- hybrid AM+FM routings (x = ring, ~ = AM shimmer, > = PM — see Engine_Potionshop
-- algorithms table, keep ordering in sync). The algo scalar picker spans two grid rows.
local ALGO_NAMES = {'4>3>2>1', '(4,3)>2>1', '4>3>1 2>1', '4>2>1 3>1',
                    '2>1 4>3', '4>1,2,3', '4>3 +1,2', 'additive',
                    '(4,3,2)>1', '3>2>1 +4', '4>2>1 +3', '4>3>2 +1',
                    '4>3>1 +2', '(4,3)>1 +2', '4>1,2 +3', '4>2 3>1',
                    '2x1 +3,4', '2x1 4x3', '4>3x1 +2', '4~1,2,3',
                    '4x3x2x1', '(4,3)>1 2~1',
                    '2~1 4~3', '4x1,2,3', '2>1 4~3', '4~3~2~1',
                    '4>1 3x 2~', '3>2>1 4~1', '(4,3)>2x1', '4x2 3x1',
                    '4~2 3~1', '4>3 3~2~1'}
-- alt(B)-layer trigger mode for the note layer (altTrig):
--   hold = add&hold (B drawn once per burst, summed onto A for every hit)
--   step = advance the B sequins per hit (arpeggiates the alt layer)
local ALT_TRIG_MODE_NAMES  = {'hold', 'step'}
-- Curated per-operator FM ratios, in two role sets. Mirrors Burst.CARRIER_RATIOS /
-- MODULATOR_RATIOS / RATIO_VALUES — keep in sync. The op-ratio A lane shows the set
-- for that op's ROLE under the channel's algo (carrier -> CARRIER_RATIOS 5-limit just
-- intervals; modulator -> MODULATOR_RATIOS integers + divisions + fractions). Each set
-- is 64 ascending values, biased LOW: the A grid picker (rows 6-7, two rows) exposes
-- only the LOWER 32 (cols 0..15 = 1..16, second row = 17..32); the upper 32 (higher
-- ratios) are B-offset reach only (op_ratio walks the role set). See Burst for the model.
local CARRIER_RATIOS = {
  -- lower 32 (A picker, 0.25 .. 2.0):
  0.25, 0.2667, 0.2778, 0.3, 0.3125, 0.3333, 0.375, 0.4,
  0.4167, 0.4444, 0.5, 0.5333, 0.5556, 0.6, 0.625, 0.6667,
  0.75, 0.8, 0.8333, 0.8889, 0.9, 1.0, 1.1111, 1.125,
  1.2, 1.25, 1.3333, 1.5, 1.6, 1.6667, 1.8, 2.0,
  -- upper 32 (B-offset reach, 2.0 .. 8.0):
  2.0833, 2.2222, 2.25, 2.4, 2.5, 2.6667, 2.7, 2.7778,
  3.0, 3.125, 3.2, 3.3333, 3.375, 3.5556, 3.6, 3.75,
  4.0, 4.1667, 4.4444, 4.5, 4.8, 5.0, 5.3333, 5.4,
  6.0, 6.25, 6.4, 6.6667, 6.75, 7.2, 7.5, 8.0,
}
local MODULATOR_RATIOS = {
  -- lower 32 (A picker, 0.25 .. 6.0 -- bright: integers 1..6 + simple fractions):
  0.25, 0.3333, 0.4, 0.5, 0.6, 0.6667, 0.75, 0.8,
  0.8333, 1.0, 1.2, 1.25, 1.3333, 1.4, 1.5, 1.6667,
  1.75, 2.0, 2.25, 2.3333, 2.5, 2.6667, 3.0, 3.3333,
  3.5, 3.6667, 4.0, 4.3333, 4.5, 5.0, 5.5, 6.0,
  -- upper 32 (B-offset reach, 6.25 .. 16 -- high / inharmonic harmonics):
  6.25, 6.3333, 6.5, 6.6667, 7.0, 7.3333, 7.5, 7.6667,
  8.0, 8.3333, 8.5, 8.6667, 9.0, 9.3333, 9.5, 9.6667,
  10.0, 10.3333, 10.5, 10.6667, 11.0, 11.3333, 11.5, 12.0,
  12.5, 13.0, 13.5, 14.0, 14.5, 15.0, 15.5, 16.0,
}
-- full set = union of both, sorted ascending + de-duplicated. This is the STABLE index
-- space params store A values against (both role sets are subsets). The B (index-offset)
-- lane no longer walks this union — it walks the op's ROLE SET (see Burst.op_ratio). The
-- grid step picker filters to the role set's lower 32. Mirrors Burst.RATIO_VALUES — keep in sync.
local RATIO_VALUES = {}
do
  local seen = {}
  local function add(v) if not seen[v] then seen[v] = true; RATIO_VALUES[#RATIO_VALUES + 1] = v end end
  for _, v in ipairs(CARRIER_RATIOS)   do add(v) end
  for _, v in ipairs(MODULATOR_RATIOS) do add(v) end
  table.sort(RATIO_VALUES)
end
-- Carrier role per algo 1..22 = complement of the modulator list. Mirrors
-- Burst.ALGO_MODULATORS / Engine_Potionshop.algorithms — keep in sync. Used to pick
-- which role set the op-ratio A grid picker shows for a given channel.
local ALGO_MODULATORS = {
  {2,3,4},{2,3,4},{2,3,4},{2,3,4},{2,4},{4},{4},{},
  {2,3,4},{2,3},{2,4},{3,4},{3,4},{3,4},{4},{3,4},
  {2},{2,4},{3,4},{4},{2,3,4},{2,3,4},
  {2,4},{4},{2,4},{2,3,4},{2,3,4},{2,3,4},{2,3,4},{3,4},{3,4},{2,3,4},
}
local function is_carrier(algo, op)
  for _, m in ipairs(ALGO_MODULATORS[algo] or {}) do if m == op then return false end end
  return true
end
local function op_ratio_set(algo, op)
  return is_carrier(algo, op) and CARRIER_RATIOS or MODULATOR_RATIOS
end
-- op-ratio / op-env B lane: integer INDEX offsets 0..31 (0 = no shift, the default).
-- For op ratios this walks UP the op's ROLE SET (the lower-32 A pick into the upper 32);
-- for op envelopes it walks UP the SHAPES table to neighbouring contours.
local OP_RATIO_OFFSETS = {}
for i = 0, 31 do OP_RATIO_OFFSETS[i + 1] = i end

-- Envelope shape names, mirroring Burst.SHAPES order/count (keep in sync). The
-- opEnv1..4 sequences index 1..#SHAPE_NAMES; the actual contour data (attack/decay
-- muls + per-segment curves) lives only in lib/burst.lua (the SC engine never sees a
-- shape -- fire() resolves it). The grid needs just count + labels.
-- The table is SORTED SHORTEST -> LONGEST by total length (atkMul+decMul). Shapes
-- 1..32 are the A-PICKER bank = the 32 SHORTEST contours. Shapes 33..64 are the longer
-- half, reached ONLY by the B index-offset lane added onto an A pick (see Burst.SHAPES
-- / op_env), so B EXTENDS a short A pick toward longer tails.
local SHAPE_NAMES = {'tick', 'dust', 'tock', 'clip', 'prick', 'chip', 'grain', 'dit',
                     'spike', 'tic', 'nip', 'blip', 'nick', 'plip', 'click', 'ping',
                     'dot', 'spit', 'rim', 'knock', 'flick', 'clave', 'dink', 'dab',
                     'clap', 'zip', 'jab', 'poke', 'snap', 'zap', 'tink', 'plop',
                     'ting', 'bop', 'tap', 'pip', 'pop', 'pluck', 'drum', 'soft',
                     'round', 'puff', 'body', 'ramp', 'exp', 'log', 'lin', 'swell',
                     'arc', 'glass', 'revrs', 'tail', 'rise', 'pad', 'wedge', 'bloom',
                     'bell', 'bow', 'surge', 'long', 'fade', 'hold', 'huge', 'drone'}
local SHAPE_COUNT = #SHAPE_NAMES   -- 64 total contours
-- The A lane's picker exposes only the first 32 (two grid rows) = the shortest half;
-- the upper 32 (longer) are reachable by ADDING the B index-offset onto an A pick. The
-- A brightness gradient normalizes against this so the A row reads full-scale.
local SHAPE_PICKER_COUNT = 32
-- defaults mirror Burst.SHAPE_CARRIER_DEFAULT / SHAPE_MOD_DEFAULT ('plop' / 'knock')
local SHAPE_CARRIER_DEFAULT, SHAPE_MOD_DEFAULT = 32, 20

local DEFAULT_VALUE   = {div = 8, reps = 3, note = 0,
                         opEnv1 = SHAPE_CARRIER_DEFAULT, opEnv2 = SHAPE_MOD_DEFAULT,
                         opEnv3 = SHAPE_MOD_DEFAULT, opEnv4 = SHAPE_MOD_DEFAULT,
                         opRatio1 = 1, opRatio2 = 1, opRatio3 = 1, opRatio4 = 1}  -- op ratio default = unison
local DEFAULT_VALUE_B = {div = 0, reps = 0, note = 0,
                         opEnv1 = 0, opEnv2 = 0, opEnv3 = 0, opEnv4 = 0,           -- op env offset default = 0 (none)
                         opRatio1 = 0, opRatio2 = 0, opRatio3 = 0, opRatio4 = 0}  -- op ratio offset default = 0 (none)

-- 1-based value layouts for the step picker / KB bands. Index 1..32 maps to
-- grid cell (y*16 + x + 1). These are the grid-reachability contract.
local function range(n, f) local t = {} for i = 0, n - 1 do t[i + 1] = f(i) end return t end
local STEP_PICKER_VALUES = {
  div  = range(32, function(i) return i + 1 end),
  -- Two aligned rows of 16: the TOP row (cells 1..16) is reps 1..16 (hit counts);
  -- the BOTTOM row (cells 17..32) is rests of length 1..16 (values 0,-1,..,-15 ->
  -- rest length 1-reps). Column N pairs N hits (top) with an N-step rest (bottom).
  -- No infinite sentinel: 2+ steps loop.
  reps = (function()
    local t = {}
    for i = 1, 16 do t[i] = i end          -- top row: 1..16 hits
    for i = 1, 16 do t[16 + i] = 1 - i end -- bottom row: rest of length i (reps 0..-15)
    return t
  end)(),
  note = range(32, function(i) return i end),
  -- (channel level is no longer a sequenced param — it's a MIX-page scalar using
  -- OP_LEVEL_VALUES, the same 0..1 in 1/31 layout the op levels use.)
  -- per-op envelope shapes: a flat 1..#SHAPES index list (the curated shape table).
  -- The A lane picks a shape index; the B lane is an integer index offset
  -- (OP_RATIO_OFFSETS, via picker_layout) that walks UP the table, like the op ratios.
  opEnv1 = range(SHAPE_PICKER_COUNT, function(i) return i + 1 end),
  opEnv2 = range(SHAPE_PICKER_COUNT, function(i) return i + 1 end),
  opEnv3 = range(SHAPE_PICKER_COUNT, function(i) return i + 1 end),
  opEnv4 = range(SHAPE_PICKER_COUNT, function(i) return i + 1 end),
  -- sequenced op1/2/3/4 FM ratios: A indexes the STABLE union (RATIO_VALUES) for
  -- params storage + off-grid snapping; the grid step picker filters this to the op's
  -- role set (op_picker_layout). The B lane (an index offset) uses OP_RATIO_OFFSETS —
  -- see picker_layout, which is layer-aware for op ratios.
  opRatio1 = RATIO_VALUES,
  opRatio2 = RATIO_VALUES,
  opRatio3 = RATIO_VALUES,
  opRatio4 = RATIO_VALUES,
}
-- Layer-aware picker layout. Op-ratio B is the one lane whose value set differs from
-- its A lane (integer index offsets vs ratios); every other lane uses one layout for
-- both A and B (B's "no offset" literal-0 is handled where it's drawn/parsed).
local function picker_layout(param, layer)
  -- op ratios and op envelopes share the integer index-offset B lane.
  if layer == 'B' and (param:match('^opRatio') or param:match('^opEnv')) then
    return OP_RATIO_OFFSETS
  end
  return STEP_PICKER_VALUES[param]
end
-- Role-aware variant for the op-ratio A lane: the grid step picker shows only the
-- channel's role set for that op (carrier vs modulator under its algo), filtering the
-- stable union that params/brightness use. Every other param/layer falls through to
-- picker_layout. ch is the 0-based channel.
local function op_picker_layout(self, ch, param, layer)
  if layer == 'A' and param:match('^opRatio') then
    local op = tonumber(param:sub(-1))
    local algo = (self:chan(ch) or {}).algo or 1
    return op_ratio_set(algo, op)
  end
  return picker_layout(param, layer)
end
-- OP-page op-level picker: 0..1 in 1/31 steps (same layout the old op sequins
-- used), so every operator level stays grid-reachable.
local OP_LEVEL_VALUES = range(32, function(i) return i / 31 end)
-- MIX-page voice-scalar pickers (after the op levels). Each is a full 32-value grid
-- (two grid rows) the chN_mod_index / chN_amp_punch / chN_fm_feedback params map onto
-- exactly — integer ranges so the 2/4 defaults stay grid-exact.
local MOD_INDEX_VALUES  = range(32, function(i) return i end)            -- 1..32 (brightness depth)
local AMP_PUNCH_VALUES  = range(32, function(i) return i - 1 end)        -- 0..31 (curve exaggeration)
local FM_FEEDBACK_VALUES = range(32, function(i) return (i - 1) * 4 / 31 end) -- 0..4 rad, 1/31-of-4 steps
local ALGO_VALUES = range(32, function(i) return i end)  -- 1..32 FM algorithm (per-channel; 17..32 = AM/ring & hybrid)
-- stereo pan, -1 (hard left) .. +1 (hard right) across the 32-cell grid. `range`
-- feeds i = 0..31, so i = 16 (the 17th cell) is exactly 0 (centre), the grid-exact
-- default; i = 0 clamps to -1 (a duplicate of i = 1, since 32 cells can't be
-- symmetric about a centre cell otherwise). Param/grid index = i (0-based).
local PAN_VALUES = range(32, function(i) return math.max(-1, math.min(1, (i - 16) / 15)) end)
-- Curated per-channel quantize grids (events per whole note). Mirrors
-- Burst.QUANTIZE_VALUES — keep in sync. Edited on the per-channel QNT page.
local QUANTIZE_VALUES = {3, 4, 6, 8, 12, 16, 24, 32}
local QUANTIZE_COLS   = {0, 1, 2, 3, 4, 5, 6, 7}

local function round(x) return math.floor(x + 0.5) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Human-readable pan: 'C' centre, 'L<n>'/'R<n>' as a 0..100 distance from centre.
local function pan_label(p)
  p = p or 0
  if math.abs(p) < 1e-6 then return 'C' end
  return (p < 0 and 'L' or 'R') .. round(math.abs(p) * 100)
end
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
local function value_brightness(param, value, layer)
  local b
  if param == 'div' then
    b = value <= 4 and 6 or value <= 8 and 8 or value <= 16 and 11 or VALUE_MAX
  elseif param == 'reps' then
    -- hits (>0) ramp brighter with the count; rests (<=0) sit in a dim 2..4 band,
    -- deeper rests dimmer, so a rest never collides with a hit count (min hit = 5).
    if value <= 0 then b = clamp(4 + value, 2, 4)
    else b = math.min(4 + value, VALUE_MAX) end
  elseif param == 'note' then
    -- signed ramp centered on 7: a negative degree reads dimmer than zero, a
    -- positive one brighter, so +n and -n no longer collide (they did under the
    -- old abs() mapping). Reads like pitch height — higher note, brighter cell.
    b = clamp(round(7 + value), 2, VALUE_MAX)
  elseif param:match('^opRatio') then
    if layer == 'B' then
      -- B is an integer index offset 0..31: brightness ramps with the shift amount.
      b = clamp(round(2 + clamp(value, 0, 31) / 31 * 11), 2, VALUE_MAX)
    else
      -- A ratio: brightness from its position in the full (union) ratio space (low
      -- ratio = dim), so the sequence row reads as a pitch-height gradient regardless
      -- of which role set the cell came from.
      local idx = nearest_index(RATIO_VALUES, value)
      b = clamp(round(2 + (idx - 1) / (#RATIO_VALUES - 1) * 11), 2, VALUE_MAX)
    end
  elseif param == 'level' or param:match('^op%d') then
    b = math.max(2, round(2 + value * 11))
  elseif param == 'harm' then
    local norm = (value - 2) / 23.25
    b = clamp(round(4 + norm * 9), 4, VALUE_MAX)
  elseif param:match('^opEnv') then
    if layer == 'B' then
      -- B is an integer index offset 0..31: brightness ramps with the shift amount.
      b = clamp(round(2 + clamp(value, 0, 31) / 31 * 11), 2, VALUE_MAX)
    else
      -- A shape index 1..SHAPE_PICKER_COUNT: brightness ramps with the index, and the
      -- table is length-sorted, so the sequence row reads as a short->long gradient
      -- (low index = short = dim, high index = longer = bright).
      local norm = clamp((value - 1) / math.max(1, SHAPE_PICKER_COUNT - 1), 0, 1)
      b = clamp(round(2 + norm * 11), 2, VALUE_MAX)
    end
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
GridUI.QUANTIZE_VALUES = QUANTIZE_VALUES
GridUI.PROB_VALUES = PROB_VALUES
GridUI.ALT_TRIG_MODE_NAMES = ALT_TRIG_MODE_NAMES
GridUI.RATIO_VALUES = RATIO_VALUES          -- stable union (params index + B-walk space)
GridUI.SHAPE_NAMES = SHAPE_NAMES            -- envelope shape labels (mirror Burst.SHAPES)
GridUI.CARRIER_RATIOS = CARRIER_RATIOS      -- 5-limit set (carrier ops); mirror Burst
GridUI.MODULATOR_RATIOS = MODULATOR_RATIOS  -- whole-number/division set (modulator ops)
GridUI.op_ratio_set = op_ratio_set          -- (algo, op) -> role set
GridUI.OP_RATIO_OFFSETS = OP_RATIO_OFFSETS  -- op ratio B index-offset layout (0..31)
GridUI.picker_layout = picker_layout        -- layer-aware step-picker layout
GridUI.OP_LEVEL_VALUES = OP_LEVEL_VALUES
GridUI.MOD_INDEX_VALUES = MOD_INDEX_VALUES
GridUI.AMP_PUNCH_VALUES = AMP_PUNCH_VALUES
GridUI.FM_FEEDBACK_VALUES = FM_FEEDBACK_VALUES
GridUI.ALGO_VALUES = ALGO_VALUES
GridUI.PAN_VALUES = PAN_VALUES
GridUI.pan_label = pan_label

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
  self.qntMode = false         -- QNT page: per-channel event snap grid (curated set)
  self.mixMode = false          -- MIX page: per-channel channel level + op level statics
  self.actionMode = nil        -- 'randomize'|'mutate'|'clear'|'copy'|'paste'|nil
  self.clipboard = nil         -- {param = {vals...}} snapshot of a channel's A layer
  self.status = ''
  -- onboarding: idle launch buttons breathe until the FIRST channel ever starts,
  -- then settle to a static dim. Latches true on the first launch (session-scoped;
  -- resets on script reload, which is a fresh start anyway).
  self.hasLaunched = false

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
      if self.kbMode or self.probMode or self.perfMode or self.qntMode or self.mixMode then return end
      -- the scale picker repurposes the channel rows; a step picker does not
      -- (it lives on rows 6-7), so let its channel-row playheads keep animating
      if self.picker and self.picker.kind == 'scale' then return end
      self:render_channel_row(ev.ch - 1)
      self.g:refresh()
    elseif ev.type == 'launch' or ev.type == 'stop' then
      if ev.type == 'launch' then self.hasLaunched = true end  -- onboarding pulse off
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
    if self.qntMode then
      local qi = index_of(QUANTIZE_COLS, x)
      if qi ~= -1 then
        self:set_scalar(y, 'quantize', QUANTIZE_VALUES[qi + 1])
        self:render_channel_row(y); self.g:refresh()
      end
      return
    end
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
      local op_trig_idx = index_of(OP_TRIG_COLS, x)
      local env_trig_idx = index_of(OP_ENV_TRIG_COLS, x)
      local prob_idx = index_of(PROB_COLS, x)
      if x == PROB_HIT_COL then
        self:set_scalar(y, 'probHit', not self:chan(y).probHit)
      elseif trig_idx ~= -1 then
        self:set_scalar(y, 'altTrig', trig_idx)
      elseif op_trig_idx ~= -1 then
        -- single-button toggle: hold (0) <-> step (1)
        local field = OP_TRIG_FIELDS[op_trig_idx + 1]
        self:set_scalar(y, field, (self:chan(y)[field] == 1) and 0 or 1)
      elseif env_trig_idx ~= -1 then
        -- per-op env shape trig, same single-button toggle
        local field = OP_ENV_TRIG_FIELDS[env_trig_idx + 1]
        self:set_scalar(y, field, (self:chan(y)[field] == 1) and 0 or 1)
      elseif prob_idx ~= -1 then
        self:set_scalar(y, 'burstProb', PROB_VALUES[prob_idx + 1])
      end
      self:render_channel_row(y); self.g:refresh()
      return
    end
    if self.mixMode then
      -- pan on col 6, channel level on col 7, op1..op4 levels on cols 8..11 (one
      -- contiguous strip), then the voice scalars (mod index 12, amp punch 13, FM
      -- feedback 14, algorithm 15). All four op ratios are sequenced now (their own
      -- row-7 pages), so cols 0..5 are dark.
      if x == PAN_COL then                      -- stereo pan
        self:open_scalar_picker(y, 'pan', PAN_VALUES, 'pan')
      elseif x == MIX_LEVEL_COL then            -- channel level
        self:open_scalar_picker(y, 'level', OP_LEVEL_VALUES, 'level')
      elseif x == MOD_INDEX_COL then            -- FM mod index
        self:open_scalar_picker(y, 'modIndex', MOD_INDEX_VALUES, 'index')
      elseif x == AMP_PUNCH_COL then            -- amp punch
        self:open_scalar_picker(y, 'ampPunch', AMP_PUNCH_VALUES, 'punch')
      elseif x == FM_FEEDBACK_COL then          -- FM feedback
        self:open_scalar_picker(y, 'fmFeedback', FM_FEEDBACK_VALUES, 'fb')
      elseif x == ALGO_COL then                 -- FM algorithm (per-channel)
        self:open_scalar_picker(y, 'algo', ALGO_VALUES, 'algo')
      else
        local lvi = x - OP_LEVEL_COL0
        if lvi >= 0 and lvi <= 3 then           -- op1..op4 level
          self:open_scalar_picker(y, 'opLevel' .. (lvi + 1), OP_LEVEL_VALUES, 'level')
        end
      end
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
    if y == 6 and x == ROW6_SCALE_COL then self:close_picker(); return end
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
    local v = op_picker_layout(self, p.ch, p.param, p.layer)[y * GRID_W + x + 1]
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
    if y == SCALE_PRESET_ROW then
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

-- Global musical scalars (root tonic). Like set_mask this is the single mutation
-- path so on_edit{global} fires and the params/screen reflect; the screen scale
-- page edits through it. (quantize is per-channel now — edited via set_scalar on
-- the QNT page / chN_quantize param, not here.)
function GridUI:set_root(semitone)
  self.engine.root = semitone % 12
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

-- MIX-page scalar picker: edits a per-channel static field (level / opLevelN)
-- by tapping a value on the rows-6-7 grid. `layout` is the value array, `valkind`
-- ('level') is for the status string.
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

-- CLR resets BOTH layers — A and (where present) the B (alt) layer — so a cleared
-- channel is fully blank. COPY/PASTE act on the MAIN (A-layer) sequins only,
-- leaving the B (alt) layer untouched so it can keep variating the pasted sequins,
-- AND on the per-channel MIX-page static scalars (pan, channel level, op levels,
-- mod index, amp punch, fm feedback, algorithm) so a copied channel carries its
-- whole voicing. CLR leaves the scalars alone (they are not in PARAMS).
local MIX_SCALARS = {
  'pan', 'level', 'opLevel1', 'opLevel2', 'opLevel3', 'opLevel4',
  'modIndex', 'ampPunch', 'fmFeedback', 'algo',
}

function GridUI:clear_channel(ch)
  for _, param in ipairs(PARAMS) do
    self:commit_step_raw(ch, param, {DEFAULT_VALUE[param]}, 'A')
    if has_b(param) then
      self:commit_step_raw(ch, param, {DEFAULT_VALUE_B[param]}, 'B')
    end
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
  local scalars = {}
  local c = self:chan(ch)
  for _, field in ipairs(MIX_SCALARS) do scalars[field] = c[field] end
  buf.scalars = scalars
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
  local scalars = self.clipboard.scalars
  if scalars then
    for _, field in ipairs(MIX_SCALARS) do
      if scalars[field] ~= nil then self:set_scalar(ch, field, scalars[field]) end
    end
  end
  self:render_all()
end

-- ---- row 6 / row 7 -----------------------------------------------------

-- clear every row-6 latch mode + action mode (so only one page is ever active).
function GridUI:_clear_latches()
  self.probMode = false; self.perfMode = false
  self.qntMode = false; self.mixMode = false; self.actionMode = nil
end

-- A channel launch-block press: apply the active action mode to the channel, or
-- (no action mode) toggle launch/stop. Shared by row 6 & row 7 since the block
-- straddles both rows.
function GridUI:handle_channel_button(ch)
  self:_focus(ch)
  if self.actionMode == 'randomize' then
    self.engine:randomize(ch + 1)
    self.on_edit{ type = 'channel', ch = ch }
    self:render_all()
  elseif self.actionMode == 'mutate' then
    self.engine:mutate(ch + 1)
    self.on_edit{ type = 'channel', ch = ch }
    self:render_all()
  elseif self.actionMode == 'clear' then self:clear_channel(ch)
  elseif self.actionMode == 'copy' then self:copy_channel(ch); self:render_all()
  elseif self.actionMode == 'paste' then self:paste_channel(ch)
  else
    if self.engine:is_running(ch + 1) then self.engine:stop(ch + 1)
    else self.engine:launch(ch + 1) end
  end
end

-- Select a sequence page (row 6 / row 7 page buttons). A paired page is
-- represented by its first member; both A/B (or both pair) lanes are always shown
-- — no A/B flip.
function GridUI:select_page(page)
  self.selectedParam = page
  self.picker = nil
  self:render_all()
end

function GridUI:handle_row6(x)
  -- KB mode disabled: entry commented out (its old col 11 slot is now dark; the
  -- FM algorithm is a global param, no longer a grid page).
  -- if x == ROW6_KB_COL then self:enter_kb_mode(); return end
  local LATCH = {[ROW6_PERF_COL] = 'perfMode', [ROW6_PROB_COL] = 'probMode',
                 [ROW6_QNT_COL] = 'qntMode', [ROW6_MIX_COL] = 'mixMode'}
  if LATCH[x] then
    local was = self[LATCH[x]]
    self:_clear_latches()
    self[LATCH[x]] = not was
    self:render_all(); return
  end
  if x == ROW6_SCALE_COL then self:open_scale_picker(); return end

  if x < #ROW6_PAGES then self:select_page(ROW6_PAGES[x + 1]) end
end

function GridUI:handle_row7(x)
  if x < #ROW7_PAGES then
    self:select_page(ROW7_PAGES[x + 1])
  elseif launch_channel_at(x, 7) then
    self:handle_channel_button(launch_channel_at(x, 7))
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
  self:render_launch_block()
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
  local layout = op_picker_layout(self, p.ch, p.param, p.layer)
  for y = 0, 1 do
    for x = 0, GRID_W - 1 do
      local v = layout[y * GRID_W + x + 1]
      local b
      -- a layout shorter than the 32-cell grid (e.g. the shape picker = 16 values)
      -- leaves the trailing cells empty: draw them dark and skip the value logic.
      if v == nil then b = 0
      elseif eq(v, focused) then b = 15
      else
        local present = false
        for _, sv in ipairs(vals) do if eq(sv, v) then present = true break end end
        b = present and 5 or 1
      end
      self.g:set_led(x, PICKER_ROW0 + y, b)
      -- rests (reps <= 0) pulse to set them apart from the hit-count cells.
      if p.param == 'reps' and v ~= nil and v <= 0 then
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
end

function GridUI:render_channel_row(ch)
  if self.probMode then self:render_prob_row(ch); return end
  if self.perfMode then self:render_perf_row(ch); return end
  if self.qntMode then self:render_qnt_row(ch); return end
  if self.mixMode then self:render_mix_row(ch); return end
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
        self.g:set_led(col, ch, value_brightness(lane.param, vals[i + 1], lane.layer))
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

-- MIX page: channel level (col 7) + per-op level (cols 8..11) + the voice scalars
-- mod index/amp punch/FM feedback (cols 12..14) + per-channel FM algorithm (col 15),
-- each cell's brightness encoding its value (normalised to its own range); picker
-- opens on tap. All four op ratios are sequenced (their own row-7 pages), so cols
-- 0..6 stay dark here.
function GridUI:render_mix_row(ch)
  local c = self:chan(ch)
  local function bright(frac) return math.max(2, round(2 + clamp(frac, 0, 1) * 11)) end
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  self.g:set_led(PAN_COL, ch, bright(((c.pan or 0) + 1) / 2))  -- -1..1 -> 0..1 brightness
  self.g:set_led(MIX_LEVEL_COL, ch, bright(c.level or 0))
  for op = 1, 4 do
    self.g:set_led(OP_LEVEL_COL0 + (op - 1), ch, bright(c['opLevel' .. op] or 1))
  end
  self.g:set_led(MOD_INDEX_COL, ch, bright(((c.modIndex or 1) - 1) / 31))
  self.g:set_led(AMP_PUNCH_COL, ch, bright((c.ampPunch or 0) / 31))
  self.g:set_led(FM_FEEDBACK_COL, ch, bright((c.fmFeedback or 0) / 4))
  self.g:set_led(ALGO_COL, ch, bright(((c.algo or 1) - 1) / 31))
  if self.picker and self.picker.kind == 'scalar' and self.picker.ch == ch then
    local f = self.picker.field
    if f == 'pan' then self.g:set_led(PAN_COL, ch, 15)
    elseif f == 'level' then self.g:set_led(MIX_LEVEL_COL, ch, 15)
    elseif f == 'modIndex' then self.g:set_led(MOD_INDEX_COL, ch, 15)
    elseif f == 'ampPunch' then self.g:set_led(AMP_PUNCH_COL, ch, 15)
    elseif f == 'fmFeedback' then self.g:set_led(FM_FEEDBACK_COL, ch, 15)
    elseif f == 'algo' then self.g:set_led(ALGO_COL, ch, 15)
    elseif f:match('^opLevel') then self.g:set_led(OP_LEVEL_COL0 + (tonumber(f:sub(-1)) - 1), ch, 15) end
  end
end

function GridUI:render_prob_row(ch)
  local c = self:chan(ch)
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  -- note alt-trig mode (cols 0-1): hold / step
  for i = 1, #ALT_TRIG_MODE_NAMES do
    self.g:set_led(ALT_TRIG_COLS[i], ch, c.altTrig == (i - 1) and 15 or 4)
  end
  -- op1/2/3/4 ratio-seq trig toggles (cols 3-6): on (step) bright+strobe, off (hold) dim
  for i = 1, #OP_TRIG_COLS do
    local on = c[OP_TRIG_FIELDS[i]] == 1
    self.g:set_led(OP_TRIG_COLS[i], ch, on and 14 or 4)
    self.g:set_strobe(OP_TRIG_COLS[i], ch, on and 'slow' or 'off')
  end
  -- op1/2/3/4 env shape-seq trig toggles (cols 7-10): same on/off treatment
  for i = 1, #OP_ENV_TRIG_COLS do
    local on = c[OP_ENV_TRIG_FIELDS[i]] == 1
    self.g:set_led(OP_ENV_TRIG_COLS[i], ch, on and 14 or 4)
    self.g:set_strobe(OP_ENV_TRIG_COLS[i], ch, on and 'slow' or 'off')
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
  self:render_scaled_row(ch, OCTAVE_VALUES, OCTAVE_COLS, c.octave)
  self:render_scaled_row(ch, RATE_VALUES, RATE_COLS, c.rate)
end

-- QNT page: the channel's quantize grid as one selector across cols 0..7
-- (the curated 1/3..1/32 set). Brightness scales with the value's index so the
-- coarse-to-fine ordering reads at a glance; selected cell is full-bright.
function GridUI:render_qnt_row(ch)
  local c = self:chan(ch)
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  local sel = nearest_index(QUANTIZE_VALUES, c.quantize)
  for i = 1, #QUANTIZE_VALUES do
    self.g:set_led(QUANTIZE_COLS[i], ch, i == sel and 15 or 3)
  end
end

-- Light a 5-cell selector where the lit cell's brightness scales with its
-- distance from the centre (default) value: the home column reads dim and the
-- selection brightens as it moves toward either extreme, so the offset amount
-- shows at a glance. Unselected cells stay at a low base.
function GridUI:render_scaled_row(ch, values, cols, cur)
  local center = math.ceil(#values / 2)
  for i = 1, #values do
    local b = 3
    if values[i] == cur then b = clamp(4 + math.abs(i - center) * 5, 4, 14) end
    self.g:set_led(cols[i], ch, b)
  end
end

-- The channel launch/stop strip (cols 5..10 on row 7). Drawn after row 6/7 so it
-- owns those cells. In an action mode the buttons dim to 10 (the channel-target
-- affordance); randomize/mutate also slow-
-- strobe the running channels so you can see what you're about to scramble.
-- Outside an action mode a RUNNING channel is solid full-bright; an IDLE channel
-- is a static dim, except on first run (before any channel has ever started) when
-- it gently 'pulse'-oscillates (smooth sine fade, driven by the strobe metro) as
-- an onboarding cue inviting a first press.
function GridUI:render_launch_block()
  local action = self.actionMode
  local mark_running = action == 'randomize' or action == 'mutate'
  local onboarding = not self.hasLaunched
  for ch = 0, NUM_CHANNELS - 1 do
    local x = LAUNCH_COL0 + ch
    local y = LAUNCH_ROW
    local running = self.engine:is_running(ch + 1)
    if action then
      self.g:set_led(x, y, 10)
      self.g:set_strobe(x, y, (mark_running and running) and 'slow' or 'off')
    elseif running then
      self.g:set_led(x, y, 15)
      self.g:set_strobe(x, y, 'off')
    elseif onboarding then
      self.g:set_led(x, y, 8)
      self.g:set_strobe(x, y, 'pulse')
    else
      self.g:set_led(x, y, 4)
      self.g:set_strobe(x, y, 'off')
    end
  end
end

-- A page-select button lights when the selected param belongs to its page
-- (itself, or the same pair via PAIR_OF identity).
function GridUI:render_page_button(x, y, page)
  local sel = page == self.selectedParam
    or (PAIR_OF[page] ~= nil and PAIR_OF[self.selectedParam] == PAIR_OF[page])
  self.g:set_led(x, y, sel and 15 or 5)
  self.g:set_strobe(x, y, 'off')
end

function GridUI:render_row6()
  for i, page in ipairs(ROW6_PAGES) do self:render_page_button(i - 1, 6, page) end
  for x = #ROW6_PAGES, 10 do self.g:set_led(x, 6, 0) end  -- cols 5..10 dark (launch is on row 7 now)
  -- In an action mode the page/mode buttons dim to a flat 8 (no strobe) so the
  -- launch strip reads as the active target surface.
  local dim = self.actionMode ~= nil
  local function mode_led(col, active)
    if dim then
      self.g:set_led(col, 6, 8); self.g:set_strobe(col, 6, 'off')
    else
      self.g:set_led(col, 6, active and 15 or 8)
      self.g:set_strobe(col, 6, active and 'fast' or 'off')
    end
  end
  mode_led(ROW6_PERF_COL, self.perfMode)
  mode_led(ROW6_PROB_COL, self.probMode)
  mode_led(ROW6_SCALE_COL, self.picker and self.picker.kind == 'scale')
  mode_led(ROW6_QNT_COL, self.qntMode)
  mode_led(ROW6_MIX_COL, self.mixMode)
end

function GridUI:render_row7()
  for i, page in ipairs(ROW7_PAGES) do self:render_page_button(i - 1, 7, page) end
  -- no gap: pages (0..4) sit directly left of the launch strip (5..10, drawn
  -- separately by render_launch_block); this loop is a no-op while they're adjacent.
  for x = #ROW7_PAGES, LAUNCH_COL0 - 1 do self.g:set_led(x, 7, 0) end
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
  if self.picker and self.picker.kind == 'scalar' then return 'MIX' end
  if self.perfMode then return 'PERF' end
  if self.probMode then return 'PROB' end
  if self.qntMode then return 'QNT' end
  if self.mixMode then return 'MIX' end
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
    s = 'PROB — 0-1 note 3-6 opR 7-10 opE trig, 11-14 prob, 15 hit'
  elseif self.qntMode then
    s = 'QNT — cols0-7 per-channel quantize (1/3..1/32)'
  elseif self.mixMode then
    s = 'MIX — 6 pan 7 lvl, 8-11 op, 12 idx 13 punch 14 fb 15 alg'
  elseif self.actionMode then
    s = string.upper(self.actionMode) .. ' — tap a channel'
  elseif self.picker and self.picker.kind == 'scalar' then
    local f = self.picker.field
    local val = self:chan(self.picker.ch)[f]
    if f == 'algo' then
      s = 'edit ch' .. (self.picker.ch + 1) .. ' algo=' .. (ALGO_NAMES[val] or '?')
    elseif f == 'pan' then
      s = 'edit ch' .. (self.picker.ch + 1) .. ' pan=' .. pan_label(val)
    else
      local lbl = f:match('^opLevel') and ('op' .. f:sub(-1) .. ' level')
        or ({modIndex = 'mod index', ampPunch = 'amp punch', fmFeedback = 'fm fb'})[f]
        or 'level'
      s = 'edit ch' .. (self.picker.ch + 1) .. ' ' .. lbl .. '=' .. tostring(val)
    end
  elseif self.picker and self.picker.kind == 'step' then
    local pp = self.picker.param
    local raw = seqx.values(self:seq_ref(self.picker.ch, pp, self.picker.layer))[self.picker.col + 1]
    -- op-env A shows the shape name (B is an integer offset); else the raw value
    local v = raw
    if pp:match('^opEnv') and self.picker.layer ~= 'B' and raw then v = SHAPE_NAMES[raw] or raw end
    s = 'edit ch' .. (self.picker.ch + 1) .. ' step ' .. self.picker.col .. ' ' ..
        pp .. (self.picker.layer == 'B' and 'B' or '') .. '=' .. tostring(v)
  elseif self.picker and self.picker.kind == 'scale' then
    s = 'scale: row0 preset, rows1-2 keys, rows4-5 root'
  else
    local pr = PAIR_OF[self.selectedParam]
    s = pr and ('edit ' .. pr[1] .. ' | ' .. pr[2])
      or ('edit ' .. self.selectedParam .. ' (A | B)')
  end
  self.status = s
  self.on_status(s)
end

return GridUI
