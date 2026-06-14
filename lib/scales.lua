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
-- percussive territory. musicutil.note_num_to_freq(24) == 32.70 Hz exactly,
-- so degree_to_freq matches the browser version to floating-point precision.

local musicutil = require 'musicutil'

local scales = {}

local ROOT_NOTE = 24 -- C1

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

-- Keyed exactly like SCALE_NAMES in src/grid-controller.ts. Order matters: the
-- scale picker maps grid columns 0..11 to these in this sequence.
scales.by_name = {
  chromatic  = std('Chromatic',        {0,1,2,3,4,5,6,7,8,9,10,11}),
  major      = std('Major',            {0,2,4,5,7,9,11}),
  minor      = std('Natural Minor',    {0,2,3,5,7,8,10}),
  pentatonic = std('Major Pentatonic', {0,2,4,7,9}),
  dorian     = std('Dorian',           {0,2,3,5,7,9,10}),
  -- Custom scales (semitone approximations) — kept literal; see src/scales.ts.
  akebono    = {0,2,3,7,8},        -- Japanese pentatonic
  hijaz      = {0,1,4,5,7,8,10},   -- Arabic maqam Hijaz (b2, M3)
  kurd       = {0,1,3,5,7,8,10},   -- Maqam Kurd (Phrygian-like)
  bayati     = {0,1,3,5,7,8,10},   -- Maqam Bayati (semitone approx)
  rast       = {0,2,4,5,7,9,10},   -- Maqam Rast (semitone approx)
  zen        = {0,1,5,6,10},       -- Iwato
  wuSheng    = {0,2,4,7,9},        -- Chinese pentatonic
}

-- Display/selection order used by the grid scale picker (12 entries).
scales.names = {
  'chromatic', 'major', 'minor', 'pentatonic', 'dorian',
  'akebono', 'hijaz', 'kurd', 'bayati', 'rast', 'zen', 'wuSheng',
}

-- Curated 7-preset set shown on the scale picker's top row (grid cols 0..6).
-- A strict subset of scales.names, so picker selections still resolve to a
-- valid PARAMETERS-menu scale index.
scales.picker_names = {
  'major', 'minor', 'pentatonic', 'dorian', 'akebono', 'hijaz', 'rast',
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

-- Scale degree -> frequency in Hz, via musicutil rooted at C1 transposed by
-- `root` semitones (0..11; 0 = C1, the historical default). Root shifts the
-- whole scale's tonic up by that pitch class within the base octave.
function scales.degree_to_freq(degree, intervals, root)
  local note = ROOT_NOTE + (root or 0) + scales.degree_to_semitones(degree, intervals)
  return musicutil.note_num_to_freq(note)
end

return scales
