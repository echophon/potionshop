-- scales.lua
-- Pitch math: scale degree / semitone -> frequency.
--
-- The scale *content* no longer lives here: the modal system (14 modes,
-- rotations of major and harmonic minor) is defined in lib/chords.lua, and the
-- engine passes a mode's interval table into these functions. This module owns
-- the degree arithmetic, the Hz conversion, and the TUNING switch.
--
-- Frequency is rooted at C1 = MIDI note 24 (32.70 Hz). This sub-bass register
-- keeps the picker's full degree range in usable percussive territory.
-- musicutil.note_num_to_freq(24) == 32.70 Hz exactly.
--
-- TWO TUNINGS, selectable at runtime via `scales.tuning` (driven by the global
-- `tuning` param):
--   1 = 'just'   (default) -- 5-limit just intonation via JI_RATIOS: each pitch
--        class resolves through a real rational ratio against the tonic,
--        phase-coherent with the FM voice (whose operators are already locked to
--        rational ratios). Octaves are exact 2:1; degree 0 (1/1) and every
--        octave match 12-TET exactly, the in-between intervals are pure.
--   2 = '12-tet' (equal)   -- musicutil.note_num_to_freq, standard equal temp.
--
-- In BOTH tunings `root` is a whole-semitone TONIC SHIFT (C1 transposed by
-- `root`), so under just intonation the pure structure simply shifts with the
-- root — every key is identically tuned (no wolf intervals), at the cost of the
-- classic JI "modulation drift" (a deliberate trade for a rooted-percussive
-- instrument). Root selects the ratio SET's anchor, not which ratios play.

local musicutil = require 'musicutil'

local scales = {}

scales.ROOT_NOTE = 24 -- C1

-- Tuning selection: 1 = just intonation (default), 2 = 12-TET.
scales.TUNING_NAMES = { 'just', '12-tet' }
scales.tuning = 1

-- 5-limit just-intonation ratios for the 12 pitch classes against the tonic.
-- Indexed by semitone-from-root (0..11). The diatonic 5-limit scale extended to
-- all 12 chromatic steps; the two ambiguous slots use the textbook symmetric
-- 5-limit choices (tritone 45/32, minor seventh 16/9 — alts noted). Octaves are
-- handled separately (exact 2:1), so this table only spans one octave [1, 2).
-- This is the note-lane analogue of Burst.RATIO_VALUES: a discrete grid index
-- (here the pitch class) -> a real curated ratio.
local JI_RATIOS = {
  [0]  = 1 / 1,    -- unison
  [1]  = 16 / 15,  -- just minor second
  [2]  = 9 / 8,    -- just major second
  [3]  = 6 / 5,    -- just minor third
  [4]  = 5 / 4,    -- just major third
  [5]  = 4 / 3,    -- just perfect fourth
  [6]  = 45 / 32,  -- just augmented fourth (alt 5-limit tritone: 64/45, or 7/5)
  [7]  = 3 / 2,    -- just perfect fifth
  [8]  = 8 / 5,    -- just minor sixth
  [9]  = 5 / 3,    -- just major sixth
  [10] = 16 / 9,   -- just minor seventh (alt: 9/5, the greater just m7)
  [11] = 15 / 8,   -- just major seventh
}
scales.JI_RATIOS = JI_RATIOS

-- Absolute semitone offset above C1 -> Hz, honoring the tuning switch. `root` is
-- an additional whole-semitone tonic shift (see the module header). This is the
-- single conversion both the note-lane and chord-tone paths funnel through.
function scales.semitone_to_freq(semitones, root)
  local r = root or 0
  if scales.tuning == 2 then
    return musicutil.note_num_to_freq(scales.ROOT_NOTE + r + semitones)
  end
  -- just intonation: pitch class picks the ratio, octave is exact 2:1, tonic is
  -- C1 transposed by `root` in 12-TET.
  local pc  = semitones % 12              -- floor-mod -> 0..11, correct for negatives
  local oct = math.floor(semitones / 12)  -- octaves above/below the tonic
  local tonic = musicutil.note_num_to_freq(scales.ROOT_NOTE + r)
  return tonic * JI_RATIOS[pc] * (2 ^ oct)
end

-- Octave-aware degree lookup. Degree 7 in a 7-note mode wraps to the next
-- octave's degree 0 (root + 12 semitones). Lua % is floor-mod for these
-- operands, so negative degrees resolve correctly too. `intervals` is a
-- 1-based Lua array of semitone offsets (0..11).
function scales.degree_to_semitones(degree, intervals)
  local len = #intervals
  local oct = math.floor(degree / len)
  local idx = (degree % len) + 1 -- +1: Lua arrays are 1-based
  return oct * 12 + intervals[idx]
end

-- Scale degree -> frequency in Hz, honoring the tuning switch. The mode's
-- interval table resolves the degree to a semitone-from-tonic (octave-aware);
-- semitone_to_freq then places it under the active tuning, transposed by `root`.
function scales.degree_to_freq(degree, intervals, root)
  return scales.semitone_to_freq(scales.degree_to_semitones(degree, intervals), root)
end

return scales
