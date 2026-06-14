# potionshop (norns)

A six-channel FM burst sequencer for **monome norns** + **grid**. Native port of
the browser app `potionshop`, which itself descends from the `er301_geode` Lua
patch. The grid is the primary instrument; the screen + encoders/keys are a full
secondary control surface.

This is the **FM-first** pass: the FM voice is fully ported. The Just-Friends
(additive) and Mangrove (formant) voices from the web app are stubbed — selecting
them routes to the FM synth for now (see *Extending* below).

## Install

Copy the whole folder to norns so the script lands at `~/dust/code/potionshop`:

```
# from a computer on the same network as norns
rsync -av potionshop-norns/ we@norns.local:~/dust/code/potionshop/
```

(The folder name on norns must be `potionshop` so `engine.name = "Potionshop"`
resolves `lib/Engine_Potionshop.sc`.) Then **SELECT > potionshop** on norns, or
load it from maiden. A grid auto-connects via `grid.connect()`.

## Controls

### Grid (primary)
Read the layout comment at the top of `lib/grid_ui.lua` — it documents every row
and column across every page. In brief:

- **rows 0–5**: per-channel step view of the selected param, up to 16 steps of
  the active layer (A, or B = additive offset; re-press the row-7 param button
  to flip). Tap a step to open the value picker (rows 0–1); tap the step again
  to remove it; tap the dim slot past the last step to append one.
- **row 6**: cols 0–5 launch/stop each channel · col 11 KB · col 12 PERF · col 13
  PROB · col 14 QNT (scale + quantize picker) · col 15 SND.
- **row 7**: cols 0–5 select param (div/reps/note/level/harm/env; re-press to flip
  A/B layer) · col 11 VOICE · col 12 CLR · col 13 LOCK · col 14 RANDOMIZE · col 15
  MUTATE.
- **PROB / PERF / SND** pages re-skin rows 0–5 for per-channel probability;
  reset interval (off/1/2/4 bars, cols 0–3) + octave (−2..+2, cols 5–9) +
  playback rate (cols 11–15); and envelope/geode modes respectively.
- **KB mode** (row 6 col 11): gestural sequence entry across two pages.

### Screen / encoders / keys (secondary)
Five pages: **main · alt · snd · prob · perf**.

- **E1** select channel (1–6).
- **E2** on main/alt: walk the cursor through every position — the `run` line,
  then each step of each sequence line in turn, each ending in a `_` add slot.
  On snd/prob/perf: select line.
- **E3** edit under the cursor. On `run`: right = launch, left = stop. On a
  step: change its value (snapped to the grid picker's values); decrement below
  the lowest value to remove the step; on `_`, increment to append one.
- **K2 / K3** page back / forward (clamped at main and perf).
- **K1** untouched — left to the norns system menus.

**main** edits the six A-layer sequences (div/reps/note/level/harm/env); **alt**
is its clone for the B layer (additive offsets — `0` = no offset). Paging between
them also flips the grid's A/B layer view. **snd / prob / perf** edit the same
per-channel mode fields as the grid's SND/PROB/PERF pages, and the grid's mode
buttons switch the screen tab to match.

Screen edits go through the same code path as grid edits, so both surfaces stay in
sync and screen-entered values remain grid-reachable.

### PARAMS menu
The entire instrument is exposed as norns params (`lib/params_sync.lua`), so
everything saves to PSETs and is MIDI-mappable:

- **globals** — `scale`, `quantize` (events per whole note), `FM mod index`.
- **OUTPUTS** — per-channel destination: audio / MIDI (assignable device +
  channel) / crow 1+2 / crow 3+4 / crow ii JF / crow ii ER-301.
- **ch1–ch6 groups** — run, voice, rate, prob, modes, reset, octave, lock,
  randomize/mutate/clear triggers, and every sequence × layer as a text param
  (the whole sequence as a string) plus step/value cursor params.

Param edits, grid presses, and screen edits all stay bidirectionally in sync.
Tempo/clock source live in the system **CLOCK** menu (`clock.tempo`); the script
starts at 55 bpm.

## Architecture

| file | role |
|------|------|
| `potionshop.lua` | init/cleanup, grid wrapper + strobe metro, enc/key routing, reset scheduler, params wiring |
| `lib/burst.lua` | sequencing core: channel state, geode math, clock-coroutine scheduling, randomize/mutate |
| `lib/params_sync.lua` | the whole instrument as norns params (PSETs / MIDI map), bidirectionally synced with grid + screen |
| `lib/outputs.lua` | per-channel output routing (audio / MIDI / crow CV / crow ii JF + ER-301), params-only |
| `lib/grid_ui.lua` | the grid controller / UI state machine (pages, pickers, KB, action modes) |
| `lib/screen_ui.lua` | hand-drawn minimalist screen: focus-brightness lines, ghost note glyph, A/B step squares |
| `lib/scales.lua` | scales (via `musicutil`) + degree→frequency |
| `lib/quantize.lua` | division/beat snapping |
| `lib/seqx.lua` | glue over the stock `sequins` library |
| `lib/Engine_Potionshop.sc` | SuperCollider FM engine + master limiter |

**Stock libraries used:** `sequins` (pattern cycling), `musicutil` (pitch/scales).

**Scheduling:** each launched channel runs a `clock.run` coroutine that draws the
next value from each sequins per burst, waits until the target beat, fires, and
advances — a 1:1 port of the browser app's runChannel/runBurst (and of the
original `er301_geode.lua`). The global `quantize` knob snaps every event's target
beat forward to a shared grid via `quantize.snap_beat` (events per whole note;
0 = off), so all channels lock together regardless of their individual divisions.
(An earlier draft used `lattice`, but its fixed per-sprocket division grid can't
express forward-snap quantization cleanly, so the engine uses clock coroutines.)

## Testing

Pure modules are unit-tested off-hardware (the test harness ships faithful stubs of
the norns `clock`/`sequins`/`musicutil`/`screen`/`params` libs in `test/norns_stub/`):

```
lua test/run.lua          # ~165 checks: quantize math + snap-forward behaviour,
                          # scales, sequins glue, geode math, randomize grid-alignment,
                          # clock-coroutine scheduling, grid_ui wiring, screen pages
                          # + edits, params <-> engine sync, output routing
```

SynthDef graphs can be build-checked with stock SuperCollider:

```
sclang /tmp/potion_synthdef_check.scd   # (extract of the two SynthDefs) -> "SYNTHDEFS_OK"
```

Full audio + grid behavior must be verified on norns hardware.

## Extending (out of scope this pass)

- **JF / Mangrove voices** — add `PotionJF` / `PotionMG` SynthDefs to
  `Engine_Potionshop.sc` and branch in the `trig` command on a voice-type arg; the
  channel data model already carries `voiceType` and the VOICE button cycles it.
- **3-band master compressor** — the web master bus; currently a single `Limiter`.

**MIDI output** (the web app's note-out path) *is* ported — see `lib/outputs.lua`
and the OUTPUTS params group, which also add crow CV and crow ii (Just Friends /
ER-301) destinations the web app never had.
