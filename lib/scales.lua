-- scales.lua
-- Scale degree -> frequency, ported from the web app's src/scales.ts.
--
-- Uses the stock `musicutil` library for pitch conversion and for the standard
-- scale interval arrays; the custom Eastern/percussion scales that musicutil
-- does not carry are kept as literal semitone arrays so the exact 12-name set
-- the grid UI depends on (SCALE_NAMES) is preserved.
--
-- Frequency is rooted at C1 = MIDI note 24 (32.70 Hz). The web app chose this
-- sub-bass register so the picker's full degree range stays in usable
-- percussive territory. musicutil.note_num_to_freq(24) == 32.70 Hz exactly.
--
-- TUNING IS JUST INTONATION, not 12-TET. The scale mask still selects pitch
-- classes from the 12 semitone slots (the grid keyboard is unchanged), but each
-- pitch class resolves through JI_RATIOS — a curated 5-limit table of real
-- rational ratios against the tonic — exactly mirroring how the op-ratio
-- system resolves a coarse index into a real RATIO_VALUES entry (burst.lua).
-- This makes the played notes ring in pure ratios, phase-coherent with the FM
-- voice (whose operators are already locked to rational ratios). The web app
-- (12-TET) is no longer the tuning reference; degree 0 (1/1) and every octave
-- (2:1) still match it exactly, the in-between intervals are now pure.

local musicutil = require 'musicutil'

local scales = {}

local ROOT_NOTE = 24 -- C1

-- 5-limit just-intonation ratios for the 12 pitch classes against the tonic.
-- Indexed by semitone-from-root (0..11). The diatonic 5-limit scale extended to
-- all 12 chromatic steps; the two ambiguous slots use the textbook symmetric
-- 5-limit choices (tritone 45/32, minor seventh 16/9 — alts noted). Octaves are
-- handled separately (exact 2:1), so this table only spans one octave [1, 2).
-- This is the note-lane analogue of Burst.RATIO_VALUES: a discrete grid index
-- (here the pitch class) -> a real curated ratio. Eastern/maqam scales that were
-- already semitone APPROXIMATIONS stay approximations, now JI-flavored.
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

-- Find a scale's semitone interval array in musicutil.SCALES by (alt-)name.
-- Returns a fresh copy, or nil if musicutil doesn't define it.
local function mu_intervals(name)
  local target = string.lower(name)
  for _, s in ipairs(musicutil.SCALES) do
    local names = { s.name }
    if s.alt_names then
      for _, a in ipairs(s.alt_names) do names[#names + 1] = a end
    end
    for _, n in ipairs(names) do
      if string.lower(n) == target then
        local out = {}
        -- musicutil intervals include the octave (12) as the last entry; the
        -- web model uses bare 0..11 offsets, so drop a trailing 12.
        for _, v in ipairs(s.intervals) do
          if v < 12 then out[#out + 1] = v end
        end
        return out
      end
    end
  end
  return nil
end

-- Prefer musicutil's intervals; fall back to the literal from src/scales.ts so
-- the contract holds even if a musicutil name differs across norns versions.
local function std(mu_name, fallback)
  return mu_intervals(mu_name) or fallback
end

-- The shared scale mask is chosen from this set (PARAMETERS menu `scale` option;
-- the grid no longer has a preset row — presets moved to the menu, so the list is
-- free to grow). Diatonic modes prefer musicutil intervals; the Eastern/maqam and
-- pentatonic customs stay literal semitone approximations. bare 0..11 offsets.
scales.by_name = {
  chromatic     = std('Chromatic',        {0,1,2,3,4,5,6,7,8,9,10,11}),
  major         = std('Major',            {0,2,4,5,7,9,11}),
  minor         = std('Natural Minor',    {0,2,3,5,7,8,10}),
  harmonicMinor = std('Harmonic Minor',   {0,2,3,5,7,8,11}),
  melodicMinor  = std('Melodic Minor',    {0,2,3,5,7,9,11}),
  dorian        = std('Dorian',           {0,2,3,5,7,9,10}),
  phrygian      = std('Phrygian',         {0,1,3,5,7,8,10}),
  lydian        = std('Lydian',           {0,2,4,6,7,9,11}),
  mixolydian    = std('Mixolydian',       {0,2,4,5,7,9,10}),
  locrian       = std('Locrian',          {0,1,3,5,6,8,10}),
  pentatonic    = std('Major Pentatonic', {0,2,4,7,9}),
  minPentatonic = std('Minor Pentatonic', {0,3,5,7,10}),
  blues         = std('Blues Minor',      {0,3,5,6,7,10}),
  wholeTone     = std('Whole Tone',       {0,2,4,6,8,10}),
  -- Custom scales (semitone approximations) — kept literal; see src/scales.ts.
  akebono    = {0,2,3,7,8},        -- Japanese pentatonic
  hijaz      = {0,1,4,5,7,8,10},   -- Arabic maqam Hijaz (b2, M3)
  kurd       = {0,1,3,5,7,8,10},   -- Maqam Kurd (Phrygian-like)
  bayati     = {0,1,3,5,7,8,10},   -- Maqam Bayati (semitone approx)
  rast       = {0,2,4,5,7,9,10},   -- Maqam Rast (semitone approx)
  zen        = {0,1,5,6,10},       -- Iwato
  wuSheng    = {0,2,4,7,9},        -- Chinese pentatonic
}

-- Display/selection order used by the PARAMETERS-menu `scale` option.
scales.names = {
  'chromatic', 'major', 'minor', 'harmonicMinor', 'melodicMinor',
  'dorian', 'phrygian', 'lydian', 'mixolydian', 'locrian',
  'pentatonic', 'minPentatonic', 'blues', 'wholeTone',
  'akebono', 'hijaz', 'kurd', 'bayati', 'rast', 'zen', 'wuSheng',
}

-- Octave-aware degree lookup. Degree 7 in major wraps to the next octave's
-- degree 0 (root + 12 semitones). Lua % is floor-mod for these operands, so
-- negative degrees resolve correctly too. `intervals` is a 1-based Lua array.
function scales.degree_to_semitones(degree, intervals)
  local len = #intervals
  local oct = math.floor(degree / len)
  local idx = (degree % len) + 1 -- +1: Lua arrays are 1-based
  return oct * 12 + intervals[idx]
end

-- Scale degree -> frequency in Hz, in JUST INTONATION. The mask resolves the
-- degree to a semitone-from-tonic (octave-aware) exactly as before; we then split
-- that into a pitch class (0..11) and an octave, multiply the tonic frequency by
-- the pitch class's JI ratio (JI_RATIOS) and the exact 2^octave. The tonic itself
-- sits at a 12-TET position (C1 transposed by `root` semitones), so the whole pure
-- structure simply shifts with the root — every key is identically tuned (no wolf
-- intervals), at the cost of the classic JI "modulation drift" (a deliberate trade
-- for a rooted-percussive instrument). Root 0 = C1; degree 0 = the tonic (1/1).
function scales.degree_to_freq(degree, intervals, root)
  local semis = scales.degree_to_semitones(degree, intervals)
  local pc  = semis % 12              -- floor-mod -> 0..11, correct for negatives
  local oct = math.floor(semis / 12)  -- octaves above/below the tonic
  local tonic = musicutil.note_num_to_freq(ROOT_NOTE + (root or 0))
  return tonic * JI_RATIOS[pc] * (2 ^ oct)
end

return scales
