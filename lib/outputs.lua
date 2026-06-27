-- outputs.lua
-- Per-channel note routing to MIDI and crow/i2c destinations. No grid/screen
-- surface — configured entirely from the PARAMETERS menu ("OUTPUTS" group),
-- which also makes the routing PSET-persistent and MIDI-mappable for free.
--
-- Destinations (per channel): audio (internal FM engine, the default), midi
-- (one script-wide assignable device, per-channel MIDI channel), audio+midi,
-- crow 1+2 / crow 3+4 (CV pitch on
-- the odd output, AR envelope on the even one), crow ii Just Friends
-- (play_voice, JF voice = channel number), and crow ii ER-301 (sc.cv/sc.tr
-- port = channel number). JF is driven per hit — geode-'inspired' (the
-- script's local geode shaping), not JF's own geode engine.
--
-- Burst:fire calls `note()` with the FINAL per-hit values (geode-bent freq,
-- accented level, geode-shaped harmonicity, computed envelope length), so
-- external voices track the internal voice's dynamics exactly: MIDI velocity
-- follows the hit level, MIDI note length and the crow envelope follow the FM
-- amp decay. Harmonicity (with its harm-geode envelope baked in) rides out too:
-- MIDI sends it on the modwheel (CC1) per hit, and ER-301 puts it on a second
-- CV port (channel + num_channels, i.e. CV 7..12) as a plain step per hit.
--
-- MIDI *note* output goes to the single device chosen by the OUTPUTS-group
-- `midi_device` param (a name dropdown over midi.vports). MIDI *clock* out (24
-- ppqn + Start/Stop, opt-in via the `midi_clock_out` param) goes to the same
-- device, with norns as the master: potionshop.lua calls clock_start()/
-- clock_stop() off the engine's run-state (first channel start -> Start + 24
-- ppqn stream, last channel stop -> Stop). The Start is DEFERRED to the next beat
-- grid (clock_grid) rather than sent at the off-grid launch instant, so it stays
-- in phase with the voices + the bar-aligned reset Starts (no phase-jump click).
-- clock_reset() runs from the per-bar reset scheduler (re-send Start on each
-- sequins reset so slaves realign their bar, opt-out via `midi clock reset`).
-- (Leave the system CLOCK menu's "clock
-- midi out" OFF for that device to avoid double clock; this is the sender.)
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

-- Hz -> fractional MIDI note. Kept fractional so the JI / geode detuning
-- survives: the CV paths carry it as volts, and the MIDI path rounds to the
-- nearest semitone for note-on but sends the fractional remainder as pitch bend.
function M.freq_to_note(freq)
  return 69 + 12 * math.log(freq / 440) / math.log(2)
end

-- fractional MIDI note -> 14-bit pitch-bend value (8192 = centered). `range` is
-- the receiving synth's bend range in semitones, so ±range maps to 0..16383.
-- Always sent (even centered) so an in-tune note resets a prior note's bend.
function M.bend_value(note, range)
  local frac = note - round(note)          -- [-0.5, 0.5] semitone remainder
  local v = round(8192 + (frac / range) * 8192)
  return clamp(v, 0, 16383)
end

-- v/oct with 0 V = middle C (note 60), the norns/crow convention.
function M.note_to_volts(note) return (note - 60) / 12 end

-- hit level (0..1, geode-accented) -> MIDI velocity. Linear; level<=0 hits
-- never reach here (note() drops them, matching the silent internal voice).
function M.velocity(level) return clamp(round(level * 127), 1, 127) end

-- brightness proxy -> normalized 0..1 over the curated FM-ratio span
-- (RATIO_VALUES = 0.125 .. 14). The value arriving here is the channel's largest
-- active modulator ratio (Burst:fire), a per-channel stand-in for the old harm.
local HARM_MIN, HARM_MAX = 0.125, 14
function M.harm_norm(harm) return clamp((harm - HARM_MIN) / (HARM_MAX - HARM_MIN), 0, 1) end

-- ER-301 modulation CV: brightness over 0..5 V, a plain step per hit.
function M.harm_to_volts(harm) return M.harm_norm(harm) * 5 end

-- MIDI modwheel (CC1): brightness across the full 0..127 range.
function M.harm_to_cc(harm) return round(M.harm_norm(harm) * 127) end

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
  self.midi_device = 1 -- script-wide MIDI output device (vport index 1-16)
  self.midi_conn = nil -- the single connected MIDI device (shared by all chans)
  self.bend_range = 2  -- MIDI pitch-bend range in semitones (matches the synth)
  self.clock_out = false   -- send 24 ppqn MIDI clock + start/stop to the device
  self.clock_co = nil      -- the running clock-tick coroutine (nil = not streaming)
  self.clock_started = false  -- MIDI Start actually emitted (past the deferred grid wait)
  self.clock_grid = 1      -- beats to align the transport Start to (1 = quarter note)
  self.transport = false   -- script transport state (any channel running)
  self.clock_reset_on = true  -- re-send Start on each bar reset to realign slaves
  self.active = {}     -- per channel: note -> generation of the latest note_on
  self.gen = 0         -- global generation counter for note_off scheduling
  self.jf_active = false   -- mode currently sent to JF
  for n = 1, self.num_channels do self.active[n] = {} end
  return self
end

-- ---- params -----------------------------------------------------------------

-- Build the 16-entry device dropdown from the live vport names ("3: Keystep"),
-- falling back to "port N" when a port is unnamed or midi is unavailable (tests).
function M:device_names()
  local vports = self.midi and self.midi.vports
  local names = {}
  for i = 1, 16 do
    local name = vports and vports[i] and vports[i].name
    names[i] = (name and name ~= 'none') and (i .. ': ' .. name) or ('port ' .. i)
  end
  return names
end

function M:add_params()
  local params = self.params
  params:add_group('outputs', 'OUTPUTS', 4 + self.num_channels * 3)

  -- one script-wide MIDI output device; every channel routed to midi uses it
  params:add_option('midi_device', 'midi device', self:device_names(), self.midi_device)
  params:set_action('midi_device', function(v)
    self:all_notes_off()  -- pending offs still target the old device
    self.midi_device = v
    if self.midi then self.midi_conn = self.midi.connect(v) end
  end)

  -- pitch-bend range of the receiving synth; JI/geode detuning is sent as bend
  params:add_number('midi_bend_range', 'midi bend range', 1, 12, self.bend_range,
    function(p) return '+/- ' .. p.value .. ' st' end)
  params:set_action('midi_bend_range', function(v) self.bend_range = v end)

  -- send 24 ppqn MIDI clock + start/stop to the output device, bracketed by the
  -- script's transport (potionshop.lua drives clock_start/stop off run-state)
  params:add_option('midi_clock_out', 'midi clock out', {'off', 'on'}, 1)
  params:set_action('midi_clock_out', function(v)
    self.clock_out = (v == 2)
    if not self.clock_out then self:clock_stop() end  -- disabling halts the stream
  end)

  -- re-send MIDI Start on each per-bar sequins reset so downstream sequencers
  -- realign their pattern top to the script's bars (needs clock out on)
  params:add_option('midi_clock_reset', 'midi clock reset', {'off', 'on'}, 2)
  params:set_action('midi_clock_reset', function(v) self.clock_reset_on = (v == 2) end)

  for n = 1, self.num_channels do
    params:add_separator('ch' .. n .. '_out_sep', 'channel ' .. n)

    params:add_option('ch' .. n .. '_output', 'destination', M.DEST_NAMES, AUDIO)
    params:set_action('ch' .. n .. '_output', function(i) self:set_dest(n, i) end)

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
  local harm = ev.harm or HARM_MIN
  if d == MIDI or d == AUDIO_MIDI then
    self:midi_bend(ch, M.bend_value(note, self.bend_range))  -- JI/geode detune
    self:midi_note(ch, round(note), M.velocity(ev.level), ev.dur)
    self:midi_cc(ch, 1, M.harm_to_cc(harm))  -- modwheel = harmonicity
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
    self.crow.ii.er301.cv(ch + self.num_channels, M.harm_to_volts(harm))  -- harm CV on port 7..12
  end
end

function M:midi_cc(ch, cc, val)
  local conn = self.midi_conn
  if not conn then return end
  conn:cc(cc, val, self.midi_chan[ch] or 1)
end

function M:midi_bend(ch, val)
  local conn = self.midi_conn
  if not conn then return end
  conn:pitchbend(val, self.midi_chan[ch] or 1)
end

-- ---- MIDI clock out ---------------------------------------------------------

-- Transport START: DEFER MIDI Start to the next beat boundary (clock_grid), then
-- stream 24 ppqn clock pulses. Deferring matters because launch fires synchronously
-- at key-press time (off-grid) — sending Start then would land between beats and
-- fight the bar-aligned reset Start, clicking downstream. clock.sync aligns the
-- Start to the same grid the voices snap to, so the whole transport is in phase.
-- No-op unless `midi clock out` is on. The tick loop reads self.midi_conn fresh
-- each pulse, so a live device change keeps the stream flowing to the new device.
function M:clock_start()
  if not self.clock_out or not self.midi_conn then return end
  if self.clock_co then clock.cancel(self.clock_co) end
  self.clock_co = clock.run(function()
    clock.sync(self.clock_grid)       -- align Start to the beat grid, not the press
    if not self.midi_conn then return end
    self.midi_conn:start()
    self.clock_started = true
    while true do
      clock.sync(1 / 24)
      if self.midi_conn then self.midi_conn:clock() end
    end
  end)
end

-- Transport STOP: halt the (possibly still-deferred) tick stream and send MIDI
-- Stop — but only if Start actually went out (clock_started), so a start/stop
-- inside the pre-Start grid wait doesn't emit an orphan Stop.
function M:clock_stop()
  if self.clock_co then clock.cancel(self.clock_co); self.clock_co = nil end
  if self.clock_started and self.midi_conn then self.midi_conn:stop() end
  self.clock_started = false
end

-- Script transport edge: `running` = is ANY channel running (passed after each
-- launch/stop). Sends Start (+stream) on the 0->1 edge and Stop on 1->0 only, so
-- a live relaunch within a run never re-sends Start (which would snap external
-- sequencers back to bar 1). clock_start/stop themselves no-op unless enabled.
function M:set_transport(running)
  running = running and true or false
  if running == self.transport then return end
  self.transport = running
  if running then self:clock_start() else self:clock_stop() end
end

-- Bar-boundary realign: re-send MIDI Start so downstream sequencers snap their
-- pattern top to the script's per-bar sequins reset. Only once the stream has
-- actually started (clock_started, not merely a pending deferred start) and
-- `midi clock reset` is on. Driven by the per-bar reset scheduler in
-- potionshop.lua, which fires on a beat-aligned clock.sync.
function M:clock_reset()
  if not self.clock_reset_on or not self.clock_started or not self.midi_conn then return end
  self.midi_conn:start()
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
  local conn = self.midi_conn
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
  local conn = self.midi_conn
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
