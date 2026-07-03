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
-- pitch + trigger on port = channel number, PLUS four per-operator CV envelope
-- streams on ports ch*10+op — ch1 -> 11..14, ch2 -> 21..24, ...). JF is driven per
-- hit — geode-'inspired' (the script's local geode shaping), not JF's own geode engine.
--
-- Burst:fire calls `note()` with the FINAL per-hit values (geode-bent freq,
-- accented level, geode-shaped harmonicity, computed envelope length), so
-- external voices track the internal voice's dynamics exactly: MIDI velocity
-- follows the hit level, MIDI note length and the crow envelope follow the FM
-- amp decay. The MIDI path also STREAMS four per-operator CC envelopes each hit — one
-- per operator, on a SELECTABLE CC number (per-channel `chN_opK_cc` param, 0 = off).
-- Each stream traces that op's envelope CONTOUR over the note (env_at, the same
-- attack/decay shape the FM op plays) up to a ceiling set by its FM ratio, so the CC
-- carries the COMBINATION of the op's ratio sequence (how high) and its env sequence
-- (the shape in time). The ER-301 destination streams the SAME four contours as CV
-- (stream_op_cvs) on ports ch*10+op, ceilinged in volts (cv_ceiling). Both share one
-- coroutine engine (stream_env) updating at `env_stream_rate` Hz, sending only when a
-- value changes; a new hit / stop cancels the stream via a per-channel generation.
-- (This replaced the old fixed op1-modwheel / op2-breath CC pair + the ER-301 single
-- brightness CV on ports 7..12; there is no aggregate brightness proxy anymore.)
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

-- FM op ratio -> normalized 0..1 over the curated FM-ratio span (RATIO_VALUES =
-- 0.125 .. 14). Used to set each op stream's ceiling (ratio_ceiling / cv_ceiling).
local HARM_MIN, HARM_MAX = 0.125, 14
function M.harm_norm(ratio) return clamp((ratio - HARM_MIN) / (HARM_MAX - HARM_MIN), 0, 1) end

-- FM op ratio -> the CEILING of that op's streamed CC (0..127): its position over the
-- curated ratio span. The per-hit CC stream traces the op's envelope contour up to
-- this ceiling, so the CC carries BOTH the op ratio (how high) and the op env (the
-- shape over time). Kept separate from the contour so it's pinnable by tests.
function M.ratio_ceiling(ratio) return M.harm_norm(ratio) * 127 end

-- Peak volts of a per-operator ER-301 CV stream at max ratio (the CV analog of the
-- MIDI 127 ceiling). Matches the 0..5 V convention of the other er301/jf CV here.
M.OP_CV_MAX = 5
-- CV ceiling of an op's ER-301 envelope stream: its ratio position (0..1) x OP_CV_MAX.
function M.cv_ceiling(ratio) return M.harm_norm(ratio) * M.OP_CV_MAX end

-- SC-style `Env` segment interpolation from level a to b at fractional position pos
-- (0..1) with curvature `curve` (0 = linear, <0 = fast-start 'exp', >0 = slow-start
-- 'log'). Mirrors SuperCollider's Env curve math so the streamed MIDI CC follows the
-- same contour the FM operator's envelope plays.
function M.curve_seg(a, b, pos, curve)
  if pos <= 0 then return a end
  if pos >= 1 then return b end
  if math.abs(curve) < 0.0001 then return a + (b - a) * pos end
  return a + (b - a) * (1 - math.exp(pos * curve)) / (1 - math.exp(curve))
end

-- Operator envelope value (0..1) at time `t` seconds: rise 0->1 over `atk` (curve
-- `atkC`), then fall 1->0 over `dec` (curve `decC`), 0 before and after. This is the
-- contour streamed as CC per hit, scaled by the op's ratio ceiling.
function M.env_at(t, atk, dec, atkC, decC)
  if t <= 0 then return 0 end
  if t < atk then return M.curve_seg(0, 1, t / atk, atkC) end
  local dt = t - atk
  if dt < dec then return M.curve_seg(1, 0, dt / dec, decC) end
  return 0
end

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
  self.op_cc = {}      -- per channel: {op1..op4 CC number}, 0 = that op's CC off
  self.stream_gen = {} -- per channel: env-stream generation (bumped per hit / stop to cancel)
  self.cc_last = {}    -- per channel: {op -> last MIDI CC value sent}, dedup across the stream
  self.cv_last = {}    -- per channel: {op -> last ER-301 CV value sent (0.01 V units)}, dedup
  self.stream_rate = 60  -- env stream update rate (Hz), shared by the CC + CV streams
  for n = 1, self.num_channels do
    self.op_cc[n] = {20, 21, 22, 23}
    self.stream_gen[n] = 0
    self.cc_last[n] = {}
    self.cv_last[n] = {}
  end
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
  -- per channel: separator + destination + midi channel + four op CC numbers = 7
  params:add_group('outputs', 'OUTPUTS', 5 + self.num_channels * 7)

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

  -- update rate (Hz) of the per-operator envelope streams (MIDI CC + ER-301 CV alike).
  -- Higher = smoother contours but more MIDI/i2c traffic (4 ops x this x active
  -- channels); the streams dedup unchanged values so flat tails stay cheap. Lower it
  -- on DIN MIDI / a busy i2c bus if it floods.
  params:add_number('env_stream_rate', 'env stream rate', 10, 250, self.stream_rate,
    function(p) return p.value .. ' hz' end)
  params:set_action('env_stream_rate', function(v) self.stream_rate = v end)

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

    -- Four selectable MIDI CCs, one per operator: each hit STREAMS that op's envelope
    -- contour (ceilinged by its FM ratio) on the chosen CC (see stream_op_ccs), so the
    -- op ratio + op env sequences show up on the receiving synth as a control envelope.
    -- 0 = off (that op streams no CC). Default to the general-purpose controllers 20..23
    -- (undefined in the MIDI spec, so unlikely to collide with modwheel/breath).
    for op = 1, 4 do
      local default_cc = 19 + op  -- 20, 21, 22, 23
      params:add_number('ch' .. n .. '_op' .. op .. '_cc', 'op ' .. op .. ' cc', 0, 127, default_cc,
        function(p) return p.value == 0 and 'off' or ('cc ' .. p.value) end)
      params:set_action('ch' .. n .. '_op' .. op .. '_cc', function(v)
        self.op_cc[n][op] = v
      end)
    end
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
    self:midi_bend(ch, M.bend_value(note, self.bend_range))  -- JI/geode detune
    self:midi_note(ch, round(note), M.velocity(ev.level), ev.dur)
    -- four per-operator CC ENVELOPE streams: each op traces its envelope contour as
    -- CC over the note, up to a ceiling set by its FM ratio, on its selectable CC
    -- (0 = off). ev.ratios/ev.env_segs come from Burst:fire; skip if a caller omits them.
    local ccs = self.op_cc[ch]
    local ops, total = self:build_stream_ops(ev, M.ratio_ceiling, function(op) return ccs[op] end)
    if ops and total > 0 then self:stream_op_ccs(ch, ops, total) end
  elseif d == CROW12 then
    self:crow_pair(1, 2, volts, ev)
  elseif d == CROW34 then
    self:crow_pair(3, 4, volts, ev)
  elseif d == JF and self.crow then
    -- six channels onto JF's six voices 1:1 (no round-robin allocation), so a
    -- channel always retriggers its own voice instead of stealing a sibling's
    self.crow.ii.jf.play_voice(ch, volts, clamp(ev.level, 0, 1) * 5)
  elseif d == ER301 and self.crow then
    -- pitch v/oct + trigger on CV(ch)/TR(ch), then FOUR per-operator CV ENVELOPE
    -- streams on ports ch*10+op (ch1 -> 11..14, ch2 -> 21..24, ...): the CV analog of
    -- the MIDI CC streams, each op's ratio-ceilinged envelope contour as CV.
    self.crow.ii.er301.cv(ch, volts)
    self.crow.ii.er301.tr_pulse(ch)
    local ops, total = self:build_stream_ops(ev, M.cv_ceiling, function(op) return ch * 10 + op end)
    if ops and total > 0 then self:stream_op_cvs(ch, ops, total) end
  end
end

-- Build the per-op stream descriptors from an event's ratios + env segments.
-- `ceiling_fn(ratio)` -> the op's peak value (127 for CC, OP_CV_MAX volts for CV);
-- `dest_fn(op)` -> the op's CC number / CV port, skipped when nil or <= 0. Returns
-- {ops, total_seconds}; ops[op] = {dest, ceiling, atk, dec, atkC, decC}.
function M:build_stream_ops(ev, ceiling_fn, dest_fn)
  local ratios, segs = ev.ratios, ev.env_segs
  if not (ratios and segs) then return nil, 0 end
  local ops, total = {}, 0
  for op = 1, 4 do
    local seg, dest = segs[op], dest_fn(op)
    if seg and dest and dest > 0 then
      ops[op] = { dest = dest, ceiling = ceiling_fn(ratios[op]),
                  atk = seg[1], dec = seg[2], atkC = seg[3], decC = seg[4] }
      total = math.max(total, seg[1] + seg[2])
    end
  end
  return ops, total
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

-- Generic per-hit envelope streamer, shared by the MIDI CC + ER-301 CV streams. Walks
-- a shared time grid at stream_rate Hz over `total` seconds; each step calls
-- on_step(op, o, env01) for every present op (o = its descriptor, env01 = its 0..1
-- contour value now). Bumps the per-channel generation so a new hit / notes_off cancels
-- this stream at its next step; runs on_close() (the zero-out) once the note ends,
-- unless a newer hit already superseded it (monophonic per channel, like the note).
function M:stream_env(ch, ops, total, on_step, on_close)
  self.stream_gen[ch] = (self.stream_gen[ch] or 0) + 1
  local token = self.stream_gen[ch]
  local step = 1 / self.stream_rate
  clock.run(function()
    local t = 0
    while t <= total and self.stream_gen[ch] == token do
      for op = 1, 4 do
        local o = ops[op]
        if o then on_step(op, o, M.env_at(t, o.atk, o.dec, o.atkC, o.decC)) end
      end
      clock.sleep(step)
      t = t + step
    end
    if self.stream_gen[ch] == token then on_close() end
  end)
end

-- MIDI CC stream: each op's ratio-ceilinged envelope contour as CC on o.dest, sent only
-- when the rounded 0..127 value CHANGES (flat tails stay cheap). cc_last persists per
-- channel so a value equal to the previous hit's tail isn't resent; a final 0 closes it.
function M:stream_op_ccs(ch, ops, total)
  local last = self.cc_last[ch]
  local mc = self.midi_chan[ch] or 1
  self:stream_env(ch, ops, total,
    function(op, o, env01)
      local v = round(o.ceiling * env01)
      if v ~= last[op] and self.midi_conn then
        self.midi_conn:cc(o.dest, v, mc); last[op] = v
      end
    end,
    function()
      for op = 1, 4 do
        local o = ops[op]
        if o and last[op] ~= 0 and self.midi_conn then
          self.midi_conn:cc(o.dest, 0, mc); last[op] = 0
        end
      end
    end)
end

-- ER-301 CV stream: each op's ratio-ceilinged envelope contour as CV (volts) on its
-- port o.dest, sent only when the value CHANGES at 0.01 V resolution (dedup keeps i2c
-- traffic down). cv_last persists per channel; a final 0 V closes each op's CV.
function M:stream_op_cvs(ch, ops, total)
  local last = self.cv_last[ch]
  self:stream_env(ch, ops, total,
    function(op, o, env01)
      local q = round(o.ceiling * env01 * 100)  -- quantize to 0.01 V (dedup + clean 0)
      if q ~= last[op] and self.crow then
        self.crow.ii.er301.cv(o.dest, q / 100); last[op] = q
      end
    end,
    function()
      for op = 1, 4 do
        local o = ops[op]
        if o and last[op] and last[op] ~= 0 and self.crow then
          self.crow.ii.er301.cv(o.dest, 0); last[op] = 0
        end
      end
    end)
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

-- flush hanging MIDI notes for one channel (engine stop, dest/device change), and
-- cancel any running envelope stream (bump the gen so it bails), zeroing whatever it
-- left non-zero so a control value doesn't hang mid-contour — on both the MIDI CC and
-- ER-301 CV surfaces (only the channel's active destination has non-zero state).
function M:notes_off(ch)
  local conn = self.midi_conn
  local mc = self.midi_chan[ch] or 1
  for note, _ in pairs(self.active[ch]) do
    if conn then conn:note_off(note, 0, mc) end
    self.active[ch][note] = nil
  end
  self.stream_gen[ch] = (self.stream_gen[ch] or 0) + 1  -- invalidate the in-flight stream
  local cclast, ccs = self.cc_last[ch], self.op_cc[ch]
  for op = 1, 4 do
    local cc = ccs[op]
    if cclast[op] and cclast[op] ~= 0 and cc and cc > 0 then
      if conn then conn:cc(cc, 0, mc) end
      cclast[op] = 0
    end
  end
  local cvlast = self.cv_last[ch]
  for op = 1, 4 do
    if cvlast[op] and cvlast[op] ~= 0 then
      if self.crow then self.crow.ii.er301.cv(ch * 10 + op, 0) end
      cvlast[op] = 0
    end
  end
end

function M:all_notes_off()
  for n = 1, self.num_channels do self:notes_off(n) end
end

return M
