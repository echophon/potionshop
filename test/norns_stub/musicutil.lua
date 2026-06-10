-- Minimal stub of norns lib/musicutil for LOCAL TESTING ONLY.
-- note_num_to_freq uses the real formula; SCALES carries just the standard
-- entries scales.lua looks up, with a trailing-12 interval to exercise the
-- octave-stripping in mu_intervals().
local mu = {}

function mu.note_num_to_freq(n)
  return 13.75 * (2 ^ ((n - 9) / 12))
end

mu.SCALES = {
  { name = 'Chromatic',        intervals = {0,1,2,3,4,5,6,7,8,9,10,11,12} },
  { name = 'Major', alt_names = {'Ionian'}, intervals = {0,2,4,5,7,9,11,12} },
  { name = 'Natural Minor', alt_names = {'Minor','Aeolian'}, intervals = {0,2,3,5,7,8,10,12} },
  { name = 'Dorian',           intervals = {0,2,3,5,7,9,10,12} },
  { name = 'Major Pentatonic', intervals = {0,2,4,7,9,12} },
}

return mu
