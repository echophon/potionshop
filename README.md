<h1 align="center">potionshop</h1>

six channels repeatedly fires **bursts** — short flurries of FM notes
whose rhythm, pitch, density and tone come from a stack of looping value sequences.

> 📖 **graphical documentation:** a rich, page-by-page guide with grid diagrams
> lives in [`docs/potionshop-guide.html`](docs/potionshop-guide.html) (open it in
> a browser), plus a printable [cheatsheet](docs/potionshop-cheatsheet.html). the
> text below mirrors them.

## hardware

**required**

- [norns](https://github.com/p3r7/awesome-monome-norns)

**recommended**
- [grid](https://monome.org/docs/grid/) — 128 (16×8); the layout uses all 16
  columns and 8 rows

**also supported**

- [crow](https://monome.org/docs/crow/) — CV out, and i2c to Just Friends / ER-301
- MIDI output (assignable device + channel, per channel)

## install

copy the script folder to norns so it lands at `~/dust/code/potionshop`:

the folder name **must** be `potionshop` so `engine.name = "Potionshop"` resolves
`lib/Engine_Potionshop.sc`.

## start

recommended: launch the script from the norns
[SELECT](https://monome.org/docs/norns/play/#select) menu.

or load it from the maiden
[REPL](https://monome.org/docs/norns/maiden/#repl):

```
norns.script.load('/home/we/dust/code/potionshop/potionshop.lua')
```

a grid auto-connects via `grid.connect()`. the script seeds 55 bpm on init (the
web default); tempo & clock source live in the norns system **CLOCK** menu.

## grid UI

the grid is 16×8. rows 0–5 are the six channels; the bottom two rows hold
transport, page buttons, param select and channel actions. brightness carries
meaning — a value's brightness encodes the value, a full-bright key is the live
playhead or current selection, a dim key is an empty slot; a **fast blink** marks
the page/mode you're in, a **slow blink** a latched secondary state (e.g. the B
layer).

> note: coordinates below are **0-based** (col 0–15, row 0–7, channel 0–5),
> matching `lib/grid_ui.lua` and the HTML guide. they're written `[x: a-b, y: c]`
> for those reading without the diagrams. the hardware grid is 1-based; the script
> converts at the edge.

### step view

`[x: 0-15, y: 0-5]`

each of rows 0–5 shows one channel's sequence of the **selected param** (row 7),
in the current A or B layer. lit cells are steps; the one dim cell just past the
last step is the **append slot**.

- **tap a step** → opens the value picker on it.
- **tap the append slot** → adds a step and opens the picker on it.
- when a channel runs, its current step glows full-bright as the **playhead**.

### step picker

`[x: 0-15, y: 0-1]`

opened by tapping a step. rows 0–1 become a 32-cell palette of every reachable
value for the param, low → high. the cell matching the step's current value is
full-bright; other values already used in the sequence glow dim.

- **press a value** → writes it to the step and closes the picker.
- **press the already-lit current value** → removes the step (a toggle; this is
  the only remove path reachable for the channels whose rows sit behind the value
  grid).

> the picker values are the grid-reachability contract: everything
> randomize/mutate can produce lands exactly on one of these cells, so generated
> values stay highlightable and hand-editable.

### launch

`[x: 0-5, y: 6]`

toggle each channel running / stopped (bright = running). a channel loops bursts
until stopped; a channel whose `reps` sequence has a single step is **single-shot**
(it fires one burst and stops) — give `reps` more than one step to loop.

### param select

`[x: 0-5, y: 7]`

choose which param rows 0–5 show/edit: `div` · `reps` · `note` · `level` ·
`harm` · `env`. press the **selected** param again to flip the A↔B layer (the
button slow-blinks on B). B is an **additive offset** summed onto A each burst
(its value set adds a literal `0` = no offset).

### page buttons

`[x: 11-15, y: 6]`

- `11` **KB** — keyboard mode (fast sequence entry)
- `12` **PERF** — perf page (reset / octave / rate)
- `13` **PROB** — prob page (probability / alt-trig)
- `14` **QNT** — scale & quantize picker
- `15` **SND** — sound page (envelope / geode modes)

### channel actions

`[x: 11-15, y: 7]`

armed modes, not instant: press one (it fast-blinks), then tap a channel on row 6
to apply. press again to disarm.

- `11` **CLR** — reset the channel's A sequences to defaults
- `12` **COPY** — snapshot the A layer
- `13` **PASTE** — write the snapshot in
- `14` **RANDOMIZE** — scramble to fresh, grid-reachable values
- `15` **MUTATE** — nudge values ±

> CLR / COPY / PASTE act on the **A** layer only, leaving B to keep variating.

### PROB page

rows 0–5, per channel:

- note alt-trig: **hold / step** `[x: 0-1]`
- harm alt-trig: **hold / step** `[x: 3-4]`
- burst probability: **25 / 50 / 75 / 100%** `[x: 11-14]`
- **burst / hit** toggle `[x: 15]` — gate whole bursts (off) or each hit (on)

alt-trig **step** arpeggiates: the B sequence advances per hit on top of the held
A value.

### PERF page

rows 0–5, per channel:

- reset interval: **off / 1 / 2 / 4 bars** `[x: 0-3]` — rewinds the sequences and
  re-anchors a running burst to the bar
- octave: **−2 / −1 / 0 / +1 / +2** `[x: 5-9]` (centre = home)
- rate: **0.25 / 0.5 / 1 / 2 / 4×** `[x: 11-15]` — scales burst timing without
  changing tempo

### SND page

rows 0–5, per channel — four three-way mode banks:

- env (amp decay timing): **shape / burst / hit** `[x: 0-2]`
- geode (amp per-hit shape): **transient / sustain / cycle** `[x: 4-6]`, always on
- h.env (harm sweep timing): **off / hit / burst** `[x: 8-10]`
- harm geode (FM-ratio per-hit shape): **transient / sustain / cycle** `[x: 12-14]`, always on

the two geodes are always-on shaping curves; the `level` value (0–1) is the
bipolar "run CV" that drives them (0.5 = neutral).

### scale & quantize picker

opened by **QNT** (row 6, col 14):

- scale presets `[x: 0-6, y: 0]` — major · minor · pentatonic · dorian · akebono ·
  hijaz · rast
- degree (note-mask) keyboard `[x: 0-6, y: 1-2]` — compact piano (black row above
  white); toggle scale degrees in/out
- root keyboard `[x: 0-6, y: 4-5]` — pick the tonic
- quantize block `[x: 8-15, y: 1-4]` — 8×4 = 32 values, the shared snap grid
  (events per whole note); every channel's hits snap forward onto it, so different
  divisions stay locked together

press **QNT** again to exit.

### keyboard mode

entered by **KB** (row 6, col 11): tap out whole sequences in value bands instead
of one step at a time.

- page 1 bands: `note` `[y: 0-1]` · `div` `[y: 2-3]` · `reps` `[y: 4-5]`
- page 2 bands: `level` `[y: 0-1]` · `harm` `[y: 2-3]` · `env` `[y: 4-5]`
- channel select `[x: 0-5, y: 7]` (press the selected channel again to flip B)
- page toggle `[x: 13, y: 7]` · clear buffers `[x: 14, y: 7]`
- exit `[x: 11, y: 6]` (commits whatever is buffered)

## norns UI

a complete secondary surface that stays in sync with the grid. five pages:
**main · alt · snd · prob · perf**.

- **E1** — select channel (1–6)
- **E2** — on main/alt: walk the cursor through every position (the `run` line,
  then each step of each param line, each ending in a `_` add slot). on
  snd/prob/perf: select a line.
- **E3** — edit under the cursor. on `run`: right = launch, left = stop. on a
  step: change the value (snapped to the picker grid); decrement below the lowest
  value to remove the step; on `_`, increment to append one.
- **K2 / K3** — page back / forward (clamped at main and perf)
- **K1** — left to the norns system menus

**main** edits the six A-layer sequences; **alt** is its clone for the B (additive
offset) layer. **snd / prob / perf** edit the same per-channel mode fields as the
grid's matching pages, and the grid's mode buttons switch the screen tab to match.
screen edits go through the same code path as grid edits, so both surfaces stay in
sync and screen-entered values remain grid-reachable.

## outputs

per-channel note routing, in the PARAMETERS menu under **OUTPUTS** (no grid/screen
page). external voices receive the final geode-bent freq / level / length.

| destination | sends |
|-------------|-------|
| `audio` | the internal `Potionshop` FM engine (default) |
| `midi` | note on/off (assignable device + channel); modwheel (CC1) = harmonicity |
| `audio + midi` | both |
| `crow 1+2` | v/oct on output 1, AR envelope on output 2 |
| `crow 3+4` | v/oct on output 3, AR envelope on output 4 |
| `crow ii jf` | Just Friends — `play_voice` per hit, JF voice = channel |
| `crow ii er301` | ER-301 — sc.cv pitch + sc.tr trigger, port = channel; 2nd CV = harmonicity |

## concepts

- **channel** — one of six independent FM voices (grid rows 0–5).
- **burst** — one firing event: `reps` hits spaced `4/div` beats apart. after it,
  the channel draws fresh values and fires the next.
- **sequins** — every param is a looping value list, advanced one value per burst;
  patterns evolve as lists of different lengths cycle.
- **A / B layers** — each param has a base (A) sequence and a B sequence summed
  onto it as an additive offset.
- **geode** — per-hit modulation shaping a burst's amplitude and FM ratio across
  its hits, derived from the `level` "run CV". always on.
- **quantize** — a shared grid every channel's firing instant snaps forward onto,
  so channels with different divisions lock together. tempo is never changed, only
  *when* a hit lands. The pacing will notably adjust even though tempo doesn't.
- **probability** — per channel, skip a burst (or each hit) by chance.
- **reset** — optionally rewind a channel's sequences every 1/2/4 bars, re-anchoring
  to the bar grid so duplicates stay locked.

## params & PSETs

the entire instrument is norns params (`lib/params_sync.lua`), so everything saves
to PSETs and is MIDI-mappable:

- **globals** — `scale`, `root`, `quantize` (events per whole note), `mod index`
- **OUTPUTS** — per-channel destination (see [outputs](#outputs))
- **ch1–ch6 groups** — run, rate, prob, the mode fields, reset, octave, the
  randomize/mutate/clear/copy/paste triggers, and every sequence × layer as a text
  param (the whole sequence as a string) plus step/value cursor params

param edits, grid presses, and screen edits all stay bidirectionally in sync. tempo
lives in the system **CLOCK** menu; the script starts at 55 bpm.

## architecture

| file | role |
|------|------|
| `potionshop.lua` | init/cleanup, grid wrapper + strobe metro, enc/key routing, reset scheduler, params wiring |
| `lib/burst.lua` | sequencing core: channel state, geode math, clock-coroutine scheduling, randomize/mutate |
| `lib/params_sync.lua` | the whole instrument as norns params (PSETs / MIDI map), bidirectionally synced with grid + screen |
| `lib/outputs.lua` | per-channel output routing (audio / MIDI / crow CV / crow ii JF + ER-301), params-only |
| `lib/grid_ui.lua` | the grid controller / UI state machine (pages, pickers, KB, action modes) |
| `lib/screen_ui.lua` | hand-drawn minimalist screen: focus-brightness lines, note glyph, A/B step squares |
| `lib/scales.lua` | scales (via `musicutil`) + degree→frequency |
| `lib/quantize.lua` | division/beat snapping |
| `lib/seqx.lua` | glue over the stock `sequins` library |
| `lib/Engine_Potionshop.sc` | SuperCollider FM engine + master limiter |

**stock libraries used:** `sequins` (pattern cycling), `musicutil` (pitch/scales).

**scheduling:** each launched channel runs a `clock.run` coroutine that draws the
next value from each sequins per burst, waits until the (quantized) target beat,
fires, and advances.  The global `quantize` knob snaps every event's target beat
forward via `quantize.snap_beat` 

## development

pure modules are unit-tested off-hardware (the harness ships faithful stubs of the
norns `clock` / `sequins` / `musicutil` / `screen` / `params` libs in
`test/norns_stub/`):

```
lua test/run.lua          # ~165 checks: quantize/snap-forward, scales, sequins glue,
                          # geode math, randomize grid-alignment, clock-coroutine
                          # scheduling, grid_ui wiring, screen pages + edits,
                          # params <-> engine sync, output routing
```

the SynthDef graphs can be build-checked with stock SuperCollider:

```
sclang /tmp/potion_synthdef_check.scd   # -> "SYNTHDEFS_OK"
```

full audio + grid behavior must be verified on norns hardware.

## extending

- **additive / formant voices** — add SynthDefs to `Engine_Potionshop.sc` and
  branch in the `trig` command on the (currently ignored) `voiceType` arg.
- **3-band master compressor** — the web master bus; currently a single `Limiter`.

MIDI output (the web app's note-out path) *is* ported — see `lib/outputs.lua` and
the OUTPUTS params group, which also add crow CV and crow ii (Just Friends /
ER-301) destinations the web app never had.

## credits

- native norns port of the browser app **potionshop**, descended from the
  **`er301_geode`** patch.
- built on monome's stock `sequins` and `musicutil` libraries.
- screen surface in the spirit of `less concepts` (vicimity / dndrks).
