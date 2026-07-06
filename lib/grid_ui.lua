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
--             · 11 MIX · 12 PERF · 13 PROB · 14 SCALE · 15 PRISM
--               (SCALE opens the HARM harmony picker; PRISM is the per-channel
--               quantize + amp-dynamics page. KB page disabled; FM algorithm is a
--               per-channel MIX scalar, not a grid page -- the old SND page was
--               reclaimed. TUNING (just vs 12-TET) is a PARAMETERS-menu global.)
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
--   MIX:   rows 0-5 = signal-flow order: FM ALGORITHM (col 0, per-channel) + mod INDEX (col 1),
--          then op1-4 LEVEL (cols 3-6) + FM FEEDBACK (col 8), then the output stage:
--          FILTER (col 13, one bipolar DJ knob: LP left / off centre / HP right) +
--          PAN (col 14) + channel LEVEL/volume (col 15). Cols 2/7/9-12 are dark
--          separators. Tap a cell to open its value picker on rows 6-7. (All four op
--          ratios are sequenced — edited on their row-7 pages, not here.)
--   PROB:  rows 0-5 = probability (col 0, tap -> 32-value picker on rows 6-7)
--          · three hold<->step trig toggles (single button each, off=hold on=step):
--            note alt(B) layer (col 3) · op-ratio seqs (col 4, ONE switch for all
--            four B lanes) · op-env seqs (col 5, same)
--          · col 15 burst/hit toggle
--   PERF:  rows 0-5 = reset off/1/2/4 bars (cols 0..3) · octave -2..+2 (cols 5..9)
--          · rate (cols 11..15)
--   PRISM: rows 0-5 = per-channel quantize on cols 0-7 (one cell per curated value,
--          {3,4,6,8,12,16,24,32} = 1/3..1/32 events per whole note) · env mode
--          (shape/burst/hit) on cols 9-11 · geode (transient/sustain/cycle) on cols
--          13-15. Cols 8 and 12 are dark separators.
--   HARM (SCALE button): the modal harmonic context {mode, root, degree, quality,
--                 inversion, voicing} + per-channel chord-tone roles (lib/chords.lua).
--                 This REPLACES v0.3's global note-MASK / per-channel-root keyboard
--                 page — per-channel root (c.root) is now a PARAMETERS-menu scalar
--                 (chN_root), and the mode system supersedes the scale mask.
--                 row 0 cols 0-6 = ionian modes 1-7; row 1 cols 0-6 = harmonic-
--                 minor modes 8-14; row 2 cols 0-6 = chord degree I..VII (unsel-
--                 ected cells brightness-encode the diatonic quality); row 3 =
--                 DIA toggle (col 0) + 8 qualities (cols 2-9, picking one goes
--                 manual); rows 4-5 cols 0-6 GLOBAL root keyboard (compact piano:
--                 white keys packed at cols 0-6, black keys offset above); row 4
--                 cols 8-11 inversion root/1st/2nd/3rd; row 5 cols 8-11 voicing
--                 close/drop2/drop3/spread; cols 12-15 on rows 0-5 = per-channel
--                 role R/3/5/7 (re-press the lit role to free the channel)
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
local chords = require 'chords'

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
-- KB mode is disabled and the FM algorithm is now a per-channel MIX scalar (no grid
-- page), so cols 6..10 on row 6 are dark. The KB entry is commented out below; left in
-- place so the mode can be restored by un-commenting. Col 15 (the old SND page slot)
-- now hosts the PRISM page (per-channel quantize + env mode + geode).
-- local ROW6_KB_COL = 11
local ROW6_MIX_COL = 11   -- per-channel MIX page (took the old ALG slot; channel level + op level statics)
local ROW6_PERF_COL = 12
local ROW6_PROB_COL = 13
local ROW6_SCALE_COL = 14 -- opens the HARM harmony picker (mode/degree/quality/root/inv/voi/roles)
local ROW6_PRISM_COL = 15   -- per-channel PRISM page (quantize + env mode + geode)
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
-- MIX page channel-row layout follows the voice's signal flow left -> right: the FM
-- SOURCE scalars first (algorithm col 0, mod index col 1), then the OPERATOR mix (op1..4
-- LEVEL on cols 3..6, FM feedback on col 8), then the OUTPUT stage on the far right
-- (FILTER col 13, stereo PAN col 14, channel LEVEL/volume col 15). Cols 2 and 7 are
-- dark separators; cols 9..12 are dark. All four op ratios are sequenced (row-7
-- pages), not here.
local MOD_INDEX_COL = 1     -- FM mod index (PM/AM depth)
local ALGO_COL = 0          -- FM algorithm (operator routing, per-channel)
local OP_LEVEL_COL0 = 3     -- op1..op4 output levels on cols 3..6
local FM_FEEDBACK_COL = 8   -- op4 self-feedback
local FILTER_COL = 13       -- DJ filter position (LP | off | HP, output stage)
local PAN_COL = 14          -- stereo pan (output stage)
local MIX_LEVEL_COL = 15    -- channel level / volume (final output)
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
-- Harmony-picker (HARM page) row/col assignments — the modal harmonic context,
-- harmonàig-style (see lib/chords.lua and the layout reference above). This
-- REPLACES v0.3's global-mask / per-channel-root keyboard page; per-channel root
-- (c.root) is a PARAMETERS-menu scalar now, and modes supersede the scale mask.
local MODE_ROW_A, MODE_ROW_B = 0, 1  -- modes 1..7 / 8..14 on cols 0..6
local DEGREE_ROW = 2                 -- chord degree I..VII on cols 0..6
local QUALITY_ROW = 3                -- DIA toggle + the 8 chord qualities
local DIA_COL = 0                    -- diatonic auto-quality toggle
local QUALITY_COL0 = 2               -- qualities 1..8 on cols 2..9
local ROOT_BLACK_ROW, ROOT_WHITE_ROW = 4, 5  -- compact piano (global root), cols 0..6
local INV_ROW, INV_COL0 = 4, 8       -- inversion 0..3 on cols 8..11
local VOI_ROW, VOI_COL0 = 5, 8       -- voicing 1..4 on cols 8..11
local ROLE_COL0 = 12                 -- rows 0..5 = ch1..6, cols 12..15 = R/3/5/7
local RESET_INTERVALS = {0, 1, 2, 4}
local RESET_COLS      = {0, 1, 2, 3}
local OCTAVE_VALUES = {-2, -1, 0, 1, 2}
local OCTAVE_COLS   = {5, 6, 7, 8, 9}
local RATE_VALUES = {0.25, 0.5, 1, 2, 4}
local RATE_COLS   = {11, 12, 13, 14, 15}
-- PROB page: probability collapsed to ONE cell (col 0) that opens a 32-value
-- scalar picker on rows 6-7 (the same picker machinery as the MIX scalars),
-- then three single-button hold<->step trig toggles (off=hold, on=step): the
-- note alt(B) layer (col 3), the op-ratio sequences (col 4, ONE switch driving
-- all four B lanes together) and the op-env sequences (col 5, same), with the
-- burst/hit toggle at the far right (col 15).
local PROB_COL        = 0
local PROB_HIT_COL    = 1
local NOTE_TRIG_COL   = 3   -- altTrig (note alt(B) layer)
local OP_SEQ_TRIG_COL = 4   -- opSeqTrig (all four op-ratio B lanes)
local OP_ENV_TRIG_COL = 5   -- opEnvTrig (all four op-env B lanes)
-- 32 even probability steps (1/32 .. 1), so 100% (the default) and the old
-- 25/50/75% presets all stay grid-exact.
local PROB_VALUES = {}
for i = 1, 32 do PROB_VALUES[i] = i / 32 end

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
                     'spike', 'tic', 'nip', 'blip', 'nick', 'plip', 'click', 'plop',
                     'ping', 'dot', 'spit', 'rim', 'knock', 'flick', 'clave', 'dink',
                     'dab', 'clap', 'zip', 'jab', 'poke', 'snap', 'zap', 'tink',
                     'ting', 'bop', 'tap', 'pip', 'pop', 'pluck', 'drum', 'soft',
                     'round', 'puff', 'body', 'ramp', 'exp', 'log', 'lin', 'swell',
                     'arc', 'glass', 'revrs', 'tail', 'rise', 'pad', 'wedge', 'bloom',
                     'bell', 'bow', 'surge', 'long', 'fade', 'hold', 'huge', 'drone'}
local SHAPE_COUNT = #SHAPE_NAMES   -- 64 total contours
-- The A lane's picker exposes only the first 32 (two grid rows) = the shortest half;
-- the upper 32 (longer) are reachable by ADDING the B index-offset onto an A pick. The
-- A brightness gradient normalizes against this so the A row reads full-scale.
local SHAPE_PICKER_COUNT = 32
-- defaults mirror Burst.SHAPE_CARRIER_DEFAULT / SHAPE_MOD_DEFAULT ('plop' / 'chip')
local SHAPE_CARRIER_DEFAULT, SHAPE_MOD_DEFAULT = 16, 6

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
-- (two grid rows) the chN_mod_index / chN_fm_feedback params map onto
-- exactly — integer ranges so the defaults stay grid-exact.
local MOD_INDEX_VALUES  = range(32, function(i) return i + 1 end)        -- 1..32 (brightness depth)
local FM_FEEDBACK_VALUES = range(32, function(i) return i * 4 / 31 end)  -- 0..4 rad, 1/31-of-4 steps
local ALGO_VALUES = range(32, function(i) return i + 1 end)  -- 1..32 FM algorithm (per-channel; 17..32 = AM/ring & hybrid)
-- stereo pan, -1 (hard left) .. +1 (hard right) across the 32-cell grid. `range`
-- feeds i = 0..31, so i = 16 (the 17th cell) is exactly 0 (centre), the grid-exact
-- default; i = 0 clamps to -1 (a duplicate of i = 1, since 32 cells can't be
-- symmetric about a centre cell otherwise). Param/grid index = i (0-based).
local PAN_VALUES = range(32, function(i) return math.max(-1, math.min(1, (i - 16) / 15)) end)
-- DJ filter position, same bipolar 32-cell mapping as pan: cell 16 (index i = 16)
-- is exactly 0 = no filter (the grid-exact default); left of centre closes the
-- low-pass toward -1, right of centre raises the high-pass toward +1.
local FILTER_VALUES = range(32, function(i) return math.max(-1, math.min(1, (i - 16) / 15)) end)
-- Curated per-channel quantize grids (events per whole note). Mirrors
-- Burst.QUANTIZE_VALUES — keep in sync. Edited on the per-channel PRISM page.
local QUANTIZE_VALUES = {3, 4, 6, 8, 12, 16, 24, 32}
local QUANTIZE_COLS   = {0, 1, 2, 3, 4, 5, 6, 7}
-- PRISM-page amp-dynamics selectors, right of the quantize block. env mode (3 cells,
-- shape/burst/hit) and geode (3 cells, transient/sustain/cycle); cols 8 and 12 are
-- dark separators. Values are 0-based (index into ENV_MODE_NAMES / GEODE_MODE_NAMES).
local ENV_MODE_COLS   = {9, 10, 11}
local GEODE_COLS      = {13, 14, 15}

local function round(x) return math.floor(x + 0.5) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Human-readable pan: 'C' centre, 'L<n>'/'R<n>' as a 0..100 distance from centre.
local function pan_label(p)
  p = p or 0
  if math.abs(p) < 1e-6 then return 'C' end
  return (p < 0 and 'L' or 'R') .. round(math.abs(p) * 100)
end
-- Human-readable filter position: 'off' at centre, 'LP<n>'/'HP<n>' as a 0..100
-- distance into the low-/high-pass half of the knob.
local function filter_label(p)
  p = p or 0
  if math.abs(p) < 1e-6 then return 'off' end
  return (p < 0 and 'LP' or 'HP') .. round(math.abs(p) * 100)
end
local function eq(a, b) return math.abs(a - b) < 1e-6 end

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
GridUI.FM_FEEDBACK_VALUES = FM_FEEDBACK_VALUES
GridUI.ALGO_VALUES = ALGO_VALUES
GridUI.PAN_VALUES = PAN_VALUES
GridUI.pan_label = pan_label
GridUI.FILTER_VALUES = FILTER_VALUES  -- bipolar DJ filter-position grid
GridUI.filter_label = filter_label

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
  self.prismMode = false         -- PRISM page: per-channel quantize + env mode + geode
  self.mixMode = false          -- MIX page: per-channel channel level + op level statics
  self.actionMode = nil        -- 'randomize'|'mutate'|'clear'|'copy'|'paste'|nil
  self.clipboard = nil         -- {param = {vals...}} snapshot of a channel's A layer
  self.status = ''
  -- onboarding: idle launch buttons breathe until the FIRST channel ever starts,
  -- then settle to a static dim. Latches true on the first launch (session-scoped;
  -- resets on script reload, which is a fresh start anyway).
  self.hasLaunched = false

  self.kbMode = false
  self.kbPage = 1
  self.kbBLayer = false
  self.kbChannel = 0
  self.kbNoteBuffer, self.kbDivBuffer, self.kbRepBuffer = {}, {}, {}
  self.kbLevelBuffer, self.kbHarmBuffer, self.kbEnvBuffer = {}, {}, {}

  engine:on(function(ev)
    if ev.type == 'fire' then
      if self.kbMode or self.probMode or self.perfMode or self.prismMode or self.mixMode then return end
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

-- Channel-strip fields that live on a PERSISTENT SC synth (PotionChannel):
-- unlike the other scalars they can't ride the next trig, so a mutation must be
-- pushed to the engine immediately (Burst:push_filter).
local STRIP_FIELDS = { filterPos = true }

-- single edit path for channel scalar fields: grid and screen both write
-- through here so on_edit sees every mutation. ch is 0-based.
function GridUI:set_scalar(ch, field, value)
  self:chan(ch)[field] = value
  if STRIP_FIELDS[field] and self.engine.push_filter then
    self.engine:push_filter(ch + 1)
  end
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
    if self.prismMode then
      local qi = index_of(QUANTIZE_COLS, x)
      local ei = index_of(ENV_MODE_COLS, x)
      local gi = index_of(GEODE_COLS, x)
      if qi ~= -1 then
        self:set_scalar(y, 'quantize', QUANTIZE_VALUES[qi + 1])
        self:render_channel_row(y); self.g:refresh()
      elseif ei ~= -1 then
        self:set_scalar(y, 'envMode', ei)   -- 0-based: cell index = env-mode value
        self:render_channel_row(y); self.g:refresh()
      elseif gi ~= -1 then
        self:set_scalar(y, 'geodeMode', gi)  -- 0-based: cell index = geode value
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
      if x == PROB_COL then
        -- probability edits through the 32-value scalar picker (rows 6-7)
        self:open_scalar_picker(y, 'burstProb', PROB_VALUES, 'prob')
        return
      end
      -- single-button hold (0) <-> step (1) toggles
      if x == PROB_HIT_COL then
        self:set_scalar(y, 'probHit', not self:chan(y).probHit)
      elseif x == NOTE_TRIG_COL then
        self:set_scalar(y, 'altTrig', (self:chan(y).altTrig == 1) and 0 or 1)
      elseif x == OP_SEQ_TRIG_COL then
        self:set_scalar(y, 'opSeqTrig', (self:chan(y).opSeqTrig == 1) and 0 or 1)
      elseif x == OP_ENV_TRIG_COL then
        self:set_scalar(y, 'opEnvTrig', (self:chan(y).opEnvTrig == 1) and 0 or 1)
      end
      self:render_channel_row(y); self.g:refresh()
      return
    end
    if self.mixMode then
      -- signal-flow layout: algorithm (col 0) + mod index (col 1), op1..op4 levels
      -- (cols 3..6) + FM feedback (col 8), then filter (col 13) + pan (col 14) +
      -- channel level (col 15). Cols 2/7/9..12 are dark. All four op ratios are
      -- sequenced (their row-7 pages).
      if x == FILTER_COL then                    -- DJ filter (LP | off | HP)
        self:open_scalar_picker(y, 'filterPos', FILTER_VALUES, 'filter')
      elseif x == PAN_COL then                   -- stereo pan
        self:open_scalar_picker(y, 'pan', PAN_VALUES, 'pan')
      elseif x == MIX_LEVEL_COL then            -- channel level (volume)
        self:open_scalar_picker(y, 'level', OP_LEVEL_VALUES, 'level')
      elseif x == MOD_INDEX_COL then            -- FM mod index
        self:open_scalar_picker(y, 'modIndex', MOD_INDEX_VALUES, 'index')
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
    -- any other control-row press exits the harmony page, then acts normally
    -- (e.g. the launch strip launches/stops its channel).
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
    -- every setter below is a single mutation path that fires its own on_edit,
    -- so this branch only routes the press and repaints.
    -- role matrix first — it spans all six rows (rows 0..5 = ch1..6).
    if x >= ROLE_COL0 then
      local rk = x - ROLE_COL0 + 1
      local cur = self:chan(y).role or 0
      self:_focus(y)
      -- re-pressing the lit role releases the channel back to free (the same
      -- re-press idiom as the launch buttons), so no fifth column is needed.
      self:set_scalar(y, 'role', (cur == rk) and 0 or rk)
    elseif (y == MODE_ROW_A or y == MODE_ROW_B) and x <= 6 then
      self:set_mode((y == MODE_ROW_B and 7 or 0) + x + 1)
    elseif y == DEGREE_ROW and x <= 6 then
      self:set_degree(x + 1)
    elseif y == QUALITY_ROW and x == DIA_COL then
      self:set_diatonic(not self.engine.diatonic)
    elseif y == QUALITY_ROW and x >= QUALITY_COL0 and x < QUALITY_COL0 + 8 then
      self:set_quality(x - QUALITY_COL0 + 1)
    elseif y == ROOT_BLACK_ROW and x <= 6 and KB_BLACK_COL[x] then
      self:set_root(KB_BLACK_COL[x])
    elseif y == ROOT_WHITE_ROW and x <= 6 and KB_WHITE_COL[x] then
      self:set_root(KB_WHITE_COL[x])
    elseif y == INV_ROW and x >= INV_COL0 and x < INV_COL0 + 4 then
      self:set_inversion(x - INV_COL0)
    elseif y == VOI_ROW and x >= VOI_COL0 and x < VOI_COL0 + 4 then
      self:set_voicing(x - VOI_COL0 + 1)
    end
    self:render_all()
  end
end

-- Global harmonic-context scalars (harmonàig model, lib/chords.lua). Each is
-- THE single mutation path for its field — grid, screen, and param actions all
-- write through here so on_edit{global} fires and every surface reflects.
-- (quantize is per-channel now — edited via set_scalar on the QNT page /
-- chN_quantize param, not here.)
function GridUI:set_root(semitone)
  self.engine.root = semitone % 12
  self.on_edit{ type = 'global' }
end

function GridUI:set_mode(i)
  self.engine.mode = clamp(i, 1, #chords.MODES)
  self.on_edit{ type = 'global' }
end

function GridUI:set_degree(d)
  self.engine.degree = clamp(d, 1, 7)
  self.on_edit{ type = 'global' }
end

function GridUI:set_diatonic(on)
  self.engine.diatonic = on and true or false
  self.on_edit{ type = 'global' }
end

-- Picking a quality takes manual control (the harmonàig gesture: touching the
-- quality knob overrides the modal harmonization; the DIA button hands it back).
-- keep_diatonic skips that takeover: the chord_quality PARAM action uses it so
-- params:bang() / params:default() replay never clobbers the diatonic state
-- (params users have the explicit `diatonic` toggle instead).
function GridUI:set_quality(i, keep_diatonic)
  self.engine.quality = clamp(i, 1, #chords.QUALITIES)
  if not keep_diatonic then self.engine.diatonic = false end
  self.on_edit{ type = 'global' }
end

function GridUI:set_inversion(v)
  self.engine.inversion = clamp(v, 0, 3)
  self.on_edit{ type = 'global' }
end

function GridUI:set_voicing(v)
  self.engine.voicing = clamp(v, 1, 4)
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
  -- entering the harmony page is exclusive with the other row-6 latch modes, so
  -- only one row-6 button stays lit (see handle_row6's latch handlers)
  self:_clear_latches()
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
-- AND on the per-channel voice scalars (pan, channel level, op levels, mod index,
-- fm feedback, algorithm from the MIX page + env mode / geode from the PRISM page) so
-- a copied channel carries its whole voicing. CLR leaves the scalars alone (they are
-- not in PARAMS). quantize stays out — it's a per-channel performance grid, not voicing.
local MIX_SCALARS = {
  'pan', 'filterPos',
  'level', 'opLevel1', 'opLevel2', 'opLevel3', 'opLevel4',
  'modIndex', 'fmFeedback', 'algo', 'envMode', 'geodeMode',
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
  self.prismMode = false; self.mixMode = false; self.actionMode = nil
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
-- — no A/B flip. Pressing a sequence selector also EXITS any open latch page
-- (MIX/PERF/PROB/PRISM) or armed action mode and switches straight to the sequence,
-- so a page-select always takes you to that sequence rather than being swallowed by
-- the still-latched page.
function GridUI:select_page(page)
  self:_clear_latches()
  self.selectedParam = page
  self.picker = nil
  self:render_all()
end

function GridUI:handle_row6(x)
  -- KB mode disabled: entry commented out (its old col 11 slot is now dark; the
  -- FM algorithm is a global param, no longer a grid page).
  -- if x == ROW6_KB_COL then self:enter_kb_mode(); return end
  local LATCH = {[ROW6_PERF_COL] = 'perfMode', [ROW6_PROB_COL] = 'probMode',
                 [ROW6_PRISM_COL] = 'prismMode', [ROW6_MIX_COL] = 'mixMode'}
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
  local eng = self.engine
  -- clear the whole picker area first (rows 0..5)
  for y = 0, 5 do
    for x = 0, GRID_W - 1 do self.g:set_led(x, y, 0); self.g:set_strobe(x, y, 'off') end
  end

  -- mode rows: ionian family on row 0, harmonic-minor family on row 1
  for x = 0, 6 do
    self.g:set_led(x, MODE_ROW_A, eng.mode == x + 1 and 15 or 4)
    self.g:set_led(x, MODE_ROW_B, eng.mode == x + 8 and 15 or 4)
  end

  -- degree row: selected degree full-bright; the others brightness-encode
  -- their diatonic quality (major-type bright / minor-type mid / diminished
  -- dark), so the mode's harmonization table reads at a glance.
  local ivals = chords.MODES[eng.mode].intervals
  for d = 1, 7 do
    local b = 15
    if eng.degree ~= d then
      local q = chords.QUALITIES[chords.diatonic_quality(ivals, d)]
      if q.fifth == 6 then b = 3        -- dim7 / m7b5
      elseif q.third == 3 then b = 6    -- m7 / mM7
      else b = 8 end                    -- dom7 / M7 / +M7 / +7
    end
    self.g:set_led(d - 1, DEGREE_ROW, b)
  end

  -- quality row: with diatonic ON the derived quality glows as an indicator
  -- and the DIA cell strobes; with it OFF the manual pick is full-bright.
  if eng.diatonic then
    local qi = chords.diatonic_quality(ivals, eng.degree)
    for i = 1, 8 do
      self.g:set_led(QUALITY_COL0 + i - 1, QUALITY_ROW, i == qi and 10 or 2)
    end
    self.g:set_led(DIA_COL, QUALITY_ROW, 15)
    self.g:set_strobe(DIA_COL, QUALITY_ROW, 'slow')
  else
    for i = 1, 8 do
      self.g:set_led(QUALITY_COL0 + i - 1, QUALITY_ROW, i == eng.quality and 15 or 4)
    end
    self.g:set_led(DIA_COL, QUALITY_ROW, 4)
  end

  -- root keyboard: highlights the single selected (global) tonic
  local root = eng.root or 0
  for x, semi in pairs(KB_BLACK_COL) do
    self.g:set_led(x, ROOT_BLACK_ROW, semi == root and 15 or 3)
  end
  for x, semi in pairs(KB_WHITE_COL) do
    self.g:set_led(x, ROOT_WHITE_ROW, semi == root and 15 or 3)
  end

  -- inversion / voicing selectors
  for i = 0, 3 do
    self.g:set_led(INV_COL0 + i, INV_ROW, eng.inversion == i and 15 or 4)
    self.g:set_led(VOI_COL0 + i, VOI_ROW, eng.voicing == i + 1 and 15 or 4)
  end

  -- role matrix: rows 0..5 = ch1..6, cols 12..15 = R/3/5/7. The assigned role
  -- strobes while its channel is running (the running-channel idiom).
  for ch = 0, NUM_CHANNELS - 1 do
    local role = self:chan(ch).role or 0
    local running = eng:is_running(ch + 1)
    for rk = 1, 4 do
      self.g:set_led(ROLE_COL0 + rk - 1, ch, role == rk and 15 or 3)
      if role == rk and running then
        self.g:set_strobe(ROLE_COL0 + rk - 1, ch, 'slow')
      end
    end
  end
end

function GridUI:render_channel_row(ch)
  if self.probMode then self:render_prob_row(ch); return end
  if self.perfMode then self:render_perf_row(ch); return end
  if self.prismMode then self:render_prism_row(ch); return end
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

-- MIX page (signal-flow order): FM algorithm (col 0) + mod index (col 1), op1..4 level
-- (cols 3..6) + FM feedback (col 8), then pan (col 14) + channel level/volume (col 15).
-- Each cell's brightness encodes its value (normalised to its own range); picker opens
-- on tap. All four op ratios are sequenced (their own row-7 pages).
function GridUI:render_mix_row(ch)
  local c = self:chan(ch)
  local function bright(frac) return math.max(2, round(2 + clamp(frac, 0, 1) * 11)) end
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  self.g:set_led(MOD_INDEX_COL, ch, bright(((c.modIndex or 1) - 1) / 31))
  self.g:set_led(ALGO_COL, ch, bright(((c.algo or 1) - 1) / 31))
  for op = 1, 4 do
    self.g:set_led(OP_LEVEL_COL0 + (op - 1), ch, bright(c['opLevel' .. op] or 1))
  end
  self.g:set_led(FM_FEEDBACK_COL, ch, bright((c.fmFeedback or 0) / 4))
  -- filter brightness = distance from centre (off = dim, either extreme = bright),
  -- so the cell reads "how much filtering", not which direction.
  self.g:set_led(FILTER_COL, ch, bright(math.abs(c.filterPos or 0)))
  self.g:set_led(PAN_COL, ch, bright(((c.pan or 0) + 1) / 2))  -- -1..1 -> 0..1 brightness
  self.g:set_led(MIX_LEVEL_COL, ch, bright(c.level or 0))
  if self.picker and self.picker.kind == 'scalar' and self.picker.ch == ch then
    local f = self.picker.field
    if f == 'filterPos' then self.g:set_led(FILTER_COL, ch, 15)
    elseif f == 'pan' then self.g:set_led(PAN_COL, ch, 15)
    elseif f == 'level' then self.g:set_led(MIX_LEVEL_COL, ch, 15)
    elseif f == 'modIndex' then self.g:set_led(MOD_INDEX_COL, ch, 15)
    elseif f == 'fmFeedback' then self.g:set_led(FM_FEEDBACK_COL, ch, 15)
    elseif f == 'algo' then self.g:set_led(ALGO_COL, ch, 15)
    elseif f:match('^opLevel') then self.g:set_led(OP_LEVEL_COL0 + (tonumber(f:sub(-1)) - 1), ch, 15) end
  end
end

function GridUI:render_prob_row(ch)
  local c = self:chan(ch)
  local function bright(frac) return math.max(2, round(2 + clamp(frac, 0, 1) * 11)) end
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  -- probability (col 0): brightness encodes the value, tap opens the 32-value picker
  self.g:set_led(PROB_COL, ch, bright(c.burstProb or 1))
  if self.picker and self.picker.kind == 'scalar' and self.picker.ch == ch
     and self.picker.field == 'burstProb' then
    self.g:set_led(PROB_COL, ch, 15)
  end
  -- hold<->step trig toggles (note alt(B) / all op-ratio B lanes / all op-env B
  -- lanes): on (step) bright+strobe, off (hold) dim
  local toggles = {{NOTE_TRIG_COL, c.altTrig}, {OP_SEQ_TRIG_COL, c.opSeqTrig},
                   {OP_ENV_TRIG_COL, c.opEnvTrig}}
  for _, t in ipairs(toggles) do
    local on = t[2] == 1
    self.g:set_led(t[1], ch, on and 14 or 4)
    self.g:set_strobe(t[1], ch, on and 'slow' or 'off')
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

-- PRISM page: the channel's quantize grid as one selector across cols 0..7 (the
-- curated 1/3..1/32 set), then env mode (cols 9-11) and geode (cols 13-15) selectors.
-- Selected cell full-bright, others dim; cols 8 and 12 stay dark separators.
function GridUI:render_prism_row(ch)
  local c = self:chan(ch)
  for x = 0, GRID_W - 1 do self.g:set_led(x, ch, 0); self.g:set_strobe(x, ch, 'off') end
  local sel = nearest_index(QUANTIZE_VALUES, c.quantize)
  for i = 1, #QUANTIZE_VALUES do
    self.g:set_led(QUANTIZE_COLS[i], ch, i == sel and 15 or 3)
  end
  for i = 1, #ENV_MODE_NAMES do
    self.g:set_led(ENV_MODE_COLS[i], ch, (i - 1) == (c.envMode or 0) and 15 or 3)
  end
  for i = 1, #GEODE_MODE_NAMES do
    self.g:set_led(GEODE_COLS[i], ch, (i - 1) == (c.geodeMode or 0) and 15 or 3)
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
  mode_led(ROW6_PRISM_COL, self.prismMode)
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
  if self.picker and self.picker.kind == 'scale' then return 'HARM' end
  if self.picker and self.picker.kind == 'step' then return 'PICK' end
  if self.picker and self.picker.kind == 'scalar' then
    -- the prob picker opens from the PROB page; every other scalar is a MIX cell
    return self.picker.field == 'burstProb' and 'PROB' or 'MIX'
  end
  if self.perfMode then return 'PERF' end
  if self.probMode then return 'PROB' end
  if self.prismMode then return 'PRISM' end
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
    s = 'PROB — 0 prob, 3 note 4 opR 5 opE trig, 15 hit'
  elseif self.prismMode then
    s = 'PRISM — 0-7 quant, 9-11 env, 13-15 geode'
  elseif self.mixMode then
    s = 'MIX — 0 alg 1 idx, 3-6 op 8 fb, 13 flt 14 pan 15 vol'
  elseif self.actionMode then
    s = string.upper(self.actionMode) .. ' — tap a channel'
  elseif self.picker and self.picker.kind == 'scalar' then
    local f = self.picker.field
    local val = self:chan(self.picker.ch)[f]
    if f == 'algo' then
      s = 'edit ch' .. (self.picker.ch + 1) .. ' algo=' .. (ALGO_NAMES[val] or '?')
    elseif f == 'pan' then
      s = 'edit ch' .. (self.picker.ch + 1) .. ' pan=' .. pan_label(val)
    elseif f == 'filterPos' then
      s = 'edit ch' .. (self.picker.ch + 1) .. ' filter=' .. filter_label(val)
    elseif f == 'burstProb' then
      s = 'edit ch' .. (self.picker.ch + 1) .. ' prob=' .. round((val or 1) * 100) .. '%'
    else
      local lbl = f:match('^opLevel') and ('op' .. f:sub(-1) .. ' level')
        or ({modIndex = 'mod index', fmFeedback = 'fm fb'})[f]
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
    local sym = chords.chord_symbol(self.engine:chord_ctx())
    s = 'HARM ' .. chords.MODE_ABBRS[self.engine.mode] .. ' ' .. sym ..
        ' — r0-1 mode r2 deg r3 qual r4-5 root/inv/voi c12-15 roles'
  else
    local pr = PAIR_OF[self.selectedParam]
    s = pr and ('edit ' .. pr[1] .. ' | ' .. pr[2])
      or ('edit ' .. self.selectedParam .. ' (A | B)')
  end
  self.status = s
  self.on_status(s)
end

return GridUI
