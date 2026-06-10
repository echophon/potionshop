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

- **rows 0–5**: per-channel step view. Cols 0–7 = A layer, cols 8–15 = B layer
  (additive offset). Tap a step to open the value picker (rows 0–1); tap the step
  again to remove it.
- **row 6**: cols 0–5 launch/stop each channel · col 11 RST · col 12 KB · col 13
  PROB · col 14 QNT (scale + quantize picker) · col 15 SND.
- **row 7**: cols 0–5 select param (div/reps/note/level/harm/env; re-press to flip
  A/B layer) · col 11 VOICE · col 12 CLR · col 13 LOCK · col 14 RANDOMIZE · col 15
  MUTATE.
- **PROB / RST / SND** pages re-skin rows 0–5 for per-channel probability, reset
  interval + playback rate, and envelope/geode modes respectively.
- **KB mode** (row 6 col 12): gestural sequence entry across two pages.

### Screen / encoders / keys (secondary)
- **E1** select channel (1–6) · **E2** select param (hold **K1** → select step) ·
  **E3** change the focused step's value.
- **K2** launch/stop the selected channel · **K3** cycle page (MAIN→SND→PROB→RST) ·
  **K1+K3** open the scale/quantize picker.

Screen edits go through the same code path as grid edits, so both surfaces stay in
sync and screen-entered values remain grid-reachable.

### PARAMS menu
`scale`, `quantize` (events per whole note), and `FM mod index`. Tempo/clock source
live in the system **CLOCK** menu (`clock.tempo`); the script starts at 55 bpm.

## Architecture

| file | role |
|------|------|
| `potionshop.lua` | init/cleanup, grid wrapper + strobe metro, params, enc/key, reset scheduler |
| `lib/burst.lua` | sequencing core: channel state, geode math, lattice-sprocket scheduling, randomize/mutate |
| `lib/grid_ui.lua` | the grid controller / UI state machine (pages, pickers, KB, action modes) |
| `lib/screen_ui.lua` | screen navigation built on `lib/ui` (UI.Pages, UI.List) |
| `lib/scales.lua` | scales (via `musicutil`) + degree→frequency |
| `lib/quantize.lua` | division/beat snapping |
| `lib/seqx.lua` | glue over the stock `sequins` library |
| `lib/Engine_Potionshop.sc` | SuperCollider FM engine + master limiter |

**Stock libraries used:** `sequins` (pattern cycling), `musicutil` (pitch/scales),
`lattice` (clock-synced per-channel scheduling), `ui` (screen widgets).

**Scheduling note:** each channel is a lattice *sprocket* whose division is set to
`1/(div·rate)` and updated between bursts. A consequence is that the global
`quantize` knob collapses into lattice's division grid rather than snapping
arbitrary event times as the browser app did — an intentional adaptation. If a
timing nuance proves hard to express, the `er301_geode.lua` `clock.run`/`wait_beat`
coroutine model is the documented fallback.

## Testing

Pure modules are unit-tested off-hardware (the test harness ships faithful stubs of
the norns `sequins`/`musicutil`/`lattice` libs):

```
lua test/run.lua          # 55 checks: quantize, scales, sequins glue, geode math,
                          # randomize grid-alignment, sprocket scheduling, grid_ui wiring
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
- **MIDI output** — the web app's note-out path; not yet ported.
