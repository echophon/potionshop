-- chords.lua
-- Modal harmony math, modeled on the Instruō harmonàig (see
-- Harmoniag-Manual-A5.pdf): a harmonic context {mode, root, degree, quality,
-- inversion, voicing} resolves to a four-tone seventh chord (Root/3rd/5th/7th).
--
-- Pure Lua — requires only `scales` (for degree_to_semitones), no musicutil or
-- norns globals, so it runs under the off-hardware test harness.
--
-- Pitch domain: absolute semitone offsets above the scales base note (C1).
-- Chord tones are indexed BY MEMBER — tones[1] is always the chord Root,
-- [2] the 3rd, [3] the 5th, [4] the 7th — and keep that identity through
-- inversion and voicing (like the harmonàig's four labeled CV outputs, which
-- stay R/3/5/7 while inversion/voicing re-octave them). A channel assigned the
-- "5th" role therefore always tracks the fifth, wherever the voicing puts it.

local scales = require 'scales'

local chords = {}

-- Register lift for voiced chords. `chord_tones` stays pure (semitones above C1,
-- as the tests pin it), but the harmonàig outputs sit an octave floor that low
-- lands chord (role) channels in sub-bass. Consumers that actually SOUND a chord
-- (Burst:chord_freq for audio, the screen note-name readout) add this whole-octave
-- lift so role channels sit in the same mid register the free note-lane reaches.
-- 0 = raw C1 base (old behavior), 1 = low-mid, 2 = mid. Tune to taste.
chords.CHORD_OCTAVE = 2

-- ---- modal scales --------------------------------------------------------
-- 14 modes: the 7 rotations of the major (Ionian) scale plus the 7 rotations
-- of the harmonic minor scale, in harmonàig order. Rotation r starts the base
-- scale on its r-th degree and renormalizes to 0.

local IONIAN_BASE   = {0, 2, 4, 5, 7, 9, 11}
local HARMONIC_BASE = {0, 2, 3, 5, 7, 8, 11}

local function rotation(base, r)
  local out = {}
  for i = 1, 7 do
    local v = base[((r - 1 + i - 1) % 7) + 1] - base[r]
    if v < 0 then v = v + 12 end
    out[i] = v
  end
  return out
end

local MODE_DEFS = {
  {'ionian',       'ion',  IONIAN_BASE,   1},
  {'dorian',       'dor',  IONIAN_BASE,   2},
  {'phrygian',     'phr',  IONIAN_BASE,   3},
  {'lydian',       'lyd',  IONIAN_BASE,   4},
  {'mixolydian',   'mix',  IONIAN_BASE,   5},
  {'aeolian',      'aeo',  IONIAN_BASE,   6},
  {'locrian',      'loc',  IONIAN_BASE,   7},
  {'aeolian #7',   'aeo7', HARMONIC_BASE, 1}, -- = harmonic minor
  {'locrian #6',   'loc6', HARMONIC_BASE, 2},
  {'ionian #5',    'ion5', HARMONIC_BASE, 3},
  {'dorian #4',    'dor4', HARMONIC_BASE, 4},
  {'phrygian #3',  'phr3', HARMONIC_BASE, 5},
  {'lydian #2',    'lyd2', HARMONIC_BASE, 6},
  {'super locrian','sloc', HARMONIC_BASE, 7},
}

chords.MODES = {}
chords.MODE_NAMES = {}
chords.MODE_ABBRS = {}
for i, d in ipairs(MODE_DEFS) do
  chords.MODES[i] = { name = d[1], abbr = d[2], intervals = rotation(d[3], d[4]) }
  chords.MODE_NAMES[i] = d[1]
  chords.MODE_ABBRS[i] = d[2]
end

-- ---- seventh-chord qualities ----------------------------------------------
-- The harmonàig's 8 four-part chords, in its knob order (most-flattened to
-- most-sharpened chord tones). third/fifth/seventh are semitones above the
-- chord root. ASCII `short` symbols (the norns screen font has no Δ/°/ø).

chords.QUALITIES = {
  { sym = 'min maj7', short = 'mM7',  third = 3, fifth = 7, seventh = 11 },
  { sym = 'dim7',     short = 'o7',   third = 3, fifth = 6, seventh = 9  },
  { sym = 'min7b5',   short = 'm7b5', third = 3, fifth = 6, seventh = 10 },
  { sym = 'min7',     short = 'm7',   third = 3, fifth = 7, seventh = 10 },
  { sym = 'dom7',     short = '7',    third = 4, fifth = 7, seventh = 10 },
  { sym = 'maj7',     short = 'M7',   third = 4, fifth = 7, seventh = 11 },
  { sym = 'aug maj7', short = '+M7',  third = 4, fifth = 8, seventh = 11 },
  { sym = 'aug7',     short = '+7',   third = 4, fifth = 8, seventh = 10 },
}

chords.QUALITY_NAMES = {}
for i, q in ipairs(chords.QUALITIES) do chords.QUALITY_NAMES[i] = q.sym end

-- ---- shared name tables ----------------------------------------------------

chords.DEGREE_NAMES    = {'I', 'II', 'III', 'IV', 'V', 'VI', 'VII'}
chords.INVERSION_NAMES = {'root', '1st', '2nd', '3rd'}          -- values 0..3
chords.VOICING_NAMES   = {'close', 'drop2', 'drop3', 'spread'}  -- values 1..4
chords.ROLE_NAMES      = {'free', 'root', '3rd', '5th', '7th'}  -- c.role 0..4

-- ---- chord math -------------------------------------------------------------

-- Member index of the n-th highest tone (1 = highest). No two tones ever share
-- a pitch (a close stack spans < 12, so each inversion strictly re-orders), so
-- the ranking is unambiguous.
local function nth_highest(tones, n)
  local idx = {1, 2, 3, 4}
  table.sort(idx, function(a, b) return tones[a] > tones[b] end)
  return idx[n]
end

-- ctx = { intervals = <7-entry mode interval table>, root = 0..11,
--         degree = 1..7, diatonic = bool, quality = 1..8 (used when not
--         diatonic), inversion = 0..3, voicing = 1..4 }
-- Returns {root, third, fifth, seventh} — absolute semitones above C1,
-- indexed by chord member (see header).
function chords.chord_tones(ctx)
  local tones
  if ctx.diatonic then
    -- stack alternate mode degrees: deg, deg+2, deg+4, deg+6.
    -- degree_to_semitones is octave-aware, so wraps past the 7th are free.
    tones = {}
    for k = 1, 4 do
      tones[k] = ctx.root + scales.degree_to_semitones(ctx.degree - 1 + 2 * (k - 1), ctx.intervals)
    end
  else
    local q = chords.QUALITIES[ctx.quality]
    local cr = ctx.root + scales.degree_to_semitones(ctx.degree - 1, ctx.intervals)
    tones = { cr, cr + q.third, cr + q.fifth, cr + q.seventh }
  end

  -- inversion: move the currently-lowest member up an octave, N times.
  for _ = 1, ctx.inversion or 0 do
    local lo = 1
    for k = 2, 4 do if tones[k] < tones[lo] then lo = k end end
    tones[lo] = tones[lo] + 12
  end

  -- voicing. drop2/drop3 lower the 2nd-/3rd-highest tone of the (inverted)
  -- close voicing by an octave. spread is our concrete reading of the manual's
  -- "drop 2 with one other chord tone shifted by a further octave": drop2,
  -- then raise the highest tone an octave — widening upward, since the C1
  -- base register leaves no room below.
  local v = ctx.voicing or 1
  if v == 2 or v == 4 then
    local m = nth_highest(tones, 2)
    tones[m] = tones[m] - 12
    if v == 4 then
      -- the old highest is still the highest after dropping the 2nd-highest
      local h = nth_highest(tones, 1)
      tones[h] = tones[h] + 12
    end
  elseif v == 3 then
    local m = nth_highest(tones, 3)
    tones[m] = tones[m] - 12
  end

  return tones
end

-- {third, fifth, seventh} semitones above the chord root (any octave; folded
-- mod 12) -> quality index 1..8, or nil if outside the harmonàig set.
function chords.classify(third, fifth, seventh)
  local t, f, s = third % 12, fifth % 12, seventh % 12
  for i, q in ipairs(chords.QUALITIES) do
    if q.third == t and q.fifth == f and q.seventh == s then return i end
  end
  return nil
end

-- Diatonic quality at a degree of a mode: classify the raw (pre-inversion)
-- stack. Every stacked seventh of both scale families lands in the 8-quality
-- set, so this never returns nil for the shipped modes.
function chords.diatonic_quality(intervals, degree)
  local r = scales.degree_to_semitones(degree - 1, intervals)
  return chords.classify(
    scales.degree_to_semitones(degree + 1, intervals) - r,
    scales.degree_to_semitones(degree + 3, intervals) - r,
    scales.degree_to_semitones(degree + 5, intervals) - r)
end

-- Display symbol for the context's chord, e.g. 'V7', 'IIm7', 'VIIm7b5'.
function chords.chord_symbol(ctx)
  local qi = ctx.diatonic and chords.diatonic_quality(ctx.intervals, ctx.degree)
    or ctx.quality
  local short = qi and chords.QUALITIES[qi].short or '?'
  return chords.DEGREE_NAMES[ctx.degree] .. short
end

return chords
