-- outputs.lua
-- Per-channel note routing to MIDI and crow/i2c destinations. No grid/screen
-- surface — configured entirely from the PARAMETERS menu ("OUTPUTS" group),
-- which also makes the routing PSET-persistent and MIDI-mappable for free.
--
-- Destinations (per channel): audio (internal FM engine, the default), midi
-- (+ assignable device/channel), audio+midi, crow 1+2 / crow 3+4 (CV pitch on
-- the odd output, AR envelope on the even one), crow ii Just Friends
-- (play_voice, JF voice = channel number), and crow ii ER-301 (sc.cv/sc.tr
-- port = channel number). JF is driven per hit — geode-'inspired' (the
-- script's local geode shaping), not JF's own geode engine.
--
-- Burst:fire calls `note()` with the FINAL per-hit values (geode-bent freq,
-- accented level, computed envelope length), so external voices track the
-- internal voice's dynamics exactly: MIDI velocity follows the hit level,
-- MIDI note length and the crow envelope follow the FM amp decay.
--
-- The module is dependency-injected ({params, midi, crow}) like params_sync,
-- so the off-hardware tests drive it with fakes; nothing here touches norns
-- globals except `clock` (stubbed in test/norns_stub).

local M = {}
M.__index = M

M.DEST_NAMES = {'audio', 'midi', 'audio + midi',
                'crow 1+2', 'crow 3+4', 'crow ii jf', 'crow ii er301'}
local AUDIO, MIDI, AUDIO_MIDI, CROW12, CROW34, JF, ER301 = 1, 2, 3, 4, 5, 6, 7
M.DEST = {AUDIO = AUDIO, MIDI = MIDI, AUDIO_MIDI = AUDIO_MIDI,
          CROW12 = CROW12, CROW34 = CROW34, JF = JF, ER301 = ER301}

local function round(x) return math.floor(x + 0.5) end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- ---- pure conversions (module-level so tests can pin them) ---------------

-- Hz -> fractional MIDI note. Kept fractional so geode pitch bends survive on
-- the CV paths; the MIDI path rounds to the nearest semitone at send time.
function M.freq_to_note(freq)
  return 69 + 12 * math.log(freq / 440) / math.log(2)
end

-- v/oct with 0 V = middle C (note 60), the norns/crow convention.
function M.note_to_volts(note) return (note - 60) / 12 end

-- hit level (0..1, geode-accented) -> MIDI velocity. Linear; level<=0 hits
-- never reach here (note() drops them, matching the silent internal voice).
function M.velocity(level) return clamp(round(level * 127), 1, 127) end

-- ---- construction ---------------------------------------------------------

-- opts: {params=<paramset>, midi=<norns midi lib>, crow=<norns crow>,
--        num_channels=6}
function M.new(opts)
  local self = setmetatable({}, M)
  self.params = opts.params
  self.midi = opts.midi
  self.crow = opts.crow
  self.num_channels = opts.num_channels or 6
  self.dest = {}       -- per channel destination index (nil = audio)
  self.midi_chan = {}  -- per channel MIDI channel (1-16)
  self.midi_conn = {}  -- per channel connected MIDI device
  self.active = {}     -- per channel: note -> generation of the latest note_on
  self.gen = 0         -- global generation counter for note_off scheduling
  self.jf_active = false   -- mode currently sent to JF
  for n = 1, self.num_channels do self.active[n] = {} end
  return self
end

-- ---- params -----------------------------------------------------------------

function M:add_params()
  local params = self.params
  params:add_group('outputs', 'OUTPUTS', self.num_channels * 4)
  for n = 1, self.num_channels do
    params:add_separator('ch' .. n .. '_out_sep', 'channel ' .. n)

    params:add_option('ch' .. n .. '_output', 'destination', M.DEST_NAMES, AUDIO)
    params:set_action('ch' .. n .. '_output', function(i) self:set_dest(n, i) end)

    params:add_number('ch' .. n .. '_midi_dev', 'midi device', 1, 16, 1)
    params:set_action('ch' .. n .. '_midi_dev', function(v)
      self:notes_off(n)  -- pending offs still target the old device
      if self.midi then self.midi_conn[n] = self.midi.connect(v) end
    end)

    params:add_number('ch' .. n .. '_midi_chan', 'midi channel', 1, 16, 1)
    params:set_action('ch' .. n .. '_midi_chan', function(v)
      self.midi_chan[n] = v
    end)
  end
end

function M:set_dest(n, i)
  if self.dest[n] == i then return end
  self:notes_off(n)  -- leaving midi mid-note must not strand a note_on
  self.dest[n] = i
  self:_update_jf()
end

-- JF synth mode tracks whether ANY channel targets it (mode 1 retunes JF for
-- ii note control; release it when the last channel leaves).
function M:_update_jf()
  local want = false
  for ch = 1, self.num_channels do
    if self.dest[ch] == JF then want = true; break end
  end
  if want ~= self.jf_active then
    self.jf_active = want
    if self.crow then self.crow.ii.jf.mode(want and 1 or 0) end
  end
end

-- ---- routing ----------------------------------------------------------------

-- Burst:fire consults this before engine.trig, so non-audio destinations
-- replace (not double) the internal voice.
function M:wants_audio(ch)
  local d = self.dest[ch] or AUDIO
  return d == AUDIO or d == AUDIO_MIDI
end

-- ev: {freq=Hz, level=final hit level, dur=attack+decay seconds}
function M:note(ch, ev)
  local d = self.dest[ch] or AUDIO
  if d == AUDIO or ev.level <= 0 then return end
  local note = M.freq_to_note(ev.freq)
  local volts = M.note_to_volts(note)
  if d == MIDI or d == AUDIO_MIDI then
    self:midi_note(ch, round(note), M.velocity(ev.level), ev.dur)
  elseif d == CROW12 then
    self:crow_pair(1, 2, volts, ev)
  elseif d == CROW34 then
    self:crow_pair(3, 4, volts, ev)
  elseif d == JF and self.crow then
    -- six channels onto JF's six voices 1:1 (no round-robin allocation), so a
    -- channel always retriggers its own voice instead of stealing a sibling's
    self.crow.ii.jf.play_voice(ch, volts, clamp(ev.level, 0, 1) * 5)
  elseif d == ER301 and self.crow then
    self.crow.ii.er301.cv(ch, volts)
    self.crow.ii.er301.tr_pulse(ch)
  end
end

-- CV pitch on `cv_out`, one-shot AR envelope on `env_out` whose peak follows
-- the hit level (accents get taller envelopes) and whose fall time follows
-- the FM amp decay (envMode burst/hit lengths carry through to CV).
function M:crow_pair(cv_out, env_out, volts, ev)
  if not self.crow then return end
  self.crow.output[cv_out].volts = volts
  self.crow.output[env_out].action = string.format(
    '{to(%.2f,0.002),to(0,%.3f)}',
    clamp(ev.level, 0, 1) * 8, math.max(0.01, ev.dur))
  self.crow.output[env_out]()
end

-- note_on now, note_off after `dur` via a clock coroutine. A retrigger of the
-- same pitch cuts the old note first, and bumps the generation so the stale
-- timer's note_off is dropped (otherwise it would clip the new note short).
function M:midi_note(ch, note, vel, dur)
  local conn = self.midi_conn[ch]
  if not conn then return end
  local mc = self.midi_chan[ch] or 1
  local act = self.active[ch]
  if act[note] then conn:note_off(note, 0, mc) end
  self.gen = self.gen + 1
  local gen = self.gen
  act[note] = gen
  conn:note_on(note, vel, mc)
  clock.run(function()
    clock.sleep(math.max(0.02, dur))
    if act[note] == gen then
      act[note] = nil
      conn:note_off(note, 0, mc)
    end
  end)
end

-- flush hanging MIDI notes for one channel (engine stop, dest/device change)
function M:notes_off(ch)
  local conn = self.midi_conn[ch]
  local mc = self.midi_chan[ch] or 1
  for note, _ in pairs(self.active[ch]) do
    if conn then conn:note_off(note, 0, mc) end
    self.active[ch][note] = nil
  end
end

function M:all_notes_off()
  for n = 1, self.num_channels do self:notes_off(n) end
end

return M
