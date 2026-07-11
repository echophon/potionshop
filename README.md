<h1 align="center">potionshop</h1>

six channels repeatedly fire **bursts** — short flurries of FM notes
whose rhythm, pitch, density and tone come from a stack of looping value sequences.

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

in the maiden REPL type:

```
;install https://github.com/echophon/potionshop/archive/refs/tags/v0.4.1_multiselect.zip
```

on initial install, Norns will need to be restarted to load the new engine.

## start

on initial load, each channel sequence is randomized.  launch one or more channels from the launch strip on the bottom row (cols 5-10 = channels 1-6).
these will likely loop at different intervals creating evolving sequences.  refer to the guide for a step-by-step tutorial on the components of a sequence.

## the voice

each channel is a **four-operator FM** voice (Yamaha DX21/DX27/DX100/TX81Z-style):
4 sine operators, **16 algorithms** (operator routings — the canonical 8 DX shapes
plus 8 extended ones), per-operator feedback, and an always-on amp **geode**
(per-hit amplitude contour). the algorithm, geode mode and amp-decay env mode are
**per-channel** settings (algorithm on the MIX page; geode + env mode on the PRISM
page); each channel's individual colour comes from its **per-operator
ratios and levels** (OP page) and its two **envelopes**.

## grid UI

the grid is 16×8. rows 0–5 are the six channels; the bottom two rows hold
transport, page buttons, param select and channel actions. brightness carries
meaning — a value's brightness encodes the value, a full-bright key is the live
playhead or current selection, a dim key is an empty slot; a **fast blink** marks
the page/mode you're in, a **slow blink** a latched secondary state.

> note: coordinates below are **0-based** (col 0–15, row 0–7, channel 0–5),
> matching `lib/grid_ui.lua` and the HTML guide. they're written `[x: a-b, y: c]`
> for those reading without the diagrams. the hardware grid is 1-based; the script
> converts at the edge.

### step view

`[x: 0-15, y: 0-5]`

each of rows 0–5 shows one channel's **selected param** (chosen on row 7), split
into **two lanes side by side**: the left half `[x: 0-7]` and the right half
`[x: 8-15]`, each capped at 8 steps. for `note` / `level` the lanes are the **A**
layer (left) and the **B** additive-offset layer (right); for the paired pages they
are the two members (`div`|`reps`, `attack`|`decay`, `modatk`|`moddec`), both A.
lit cells are steps; the one dim cell just past the last step of a lane is its
**append slot**.

- **tap a step** → opens the value picker on it.
- **tap the append slot** → adds a step and opens the picker on it.
- when a channel runs, its current step glows full-bright as the **playhead**.

### step picker

`[x: 0-15, y: 6-7]`

opened by tapping a step. rows 6–7 become a 32-cell palette of every reachable
value for the param, low → high, while all six channel rows stay visible. the cell
matching the step's current value is full-bright; other values already used in the
sequence glow dim.

- **press a value** → writes it to the step and closes the picker.
- **press the already-lit current value** → removes the step (a toggle).
- **tap another step** on a channel row → hops the picker there; **re-tap the open
  step** → cancels/closes.

> the picker values are the grid-reachability contract: everything
> randomize/mutate can produce lands exactly on one of these cells, so generated
> values stay highlightable and hand-editable.

### launch

`[x: 5-10, y: 7]` — a contiguous 1×6 strip (col 5 = channel 1 … col 10 = channel 6)

toggle each channel running / stopped (bright = running). on **first run** (until
any channel has started) the idle buttons gently breathe (a slow pulse) to invite a
first press; once you've launched anything the breathing settles to a static dim. a
channel loops bursts until stopped; a channel whose `reps` sequence has a single
step is **single-shot** (it fires one burst and stops) — give `reps` two or more
steps to loop.

### param select

choose which param rows 0–5 show/edit — one button per **page**, split across the
two control rows:

- row 6 `[x: 0-4, y: 6]`: `0` **note** · `1` **op1 ratio** · `2` **op2 ratio**
  · `3` **op3 ratio** · `4` **op4 ratio**
- row 7 `[x: 0-4, y: 7]`: `0` **div / reps** (paired) · `1` **op1 env** · `2` **op2
  env** · `3` **op3 env** · `4` **op4 env**

`div / reps` is the only paired page (two A-layer lanes, no B). `note`, the four
op-ratio pages and the four **per-op envelope** pages show their A layer (left) and
B layer (right). For `note` B is an **additive offset** summed onto A each burst;
for an op ratio B is an **index offset** that micro-tunes A through the curated
ratio set; for an op envelope A is a **shape index** and B is an **index offset**
that walks the curated shapes table. Each operator gets its own envelope (DX-style
EG): a carrier's env shapes its amplitude, a modulator's its FM-depth contour.
channel level + per-op levels are **static** scalars on the MIX page, not sequenced.

### page buttons

`[x: 11-15, y: 6]`

- `11` **MIX** — per-channel algorithm / mod index / op levels / feedback / filter / pan / level
- `12` **PERF** — perf page (reset / octave / rate)
- `13` **PROB** — prob page (probability / alt-trig / op-seq & op-env trig)
- `14` **SCALE** — harmony page (mode / root / chord degree / quality / inversion / voicing / roles)
- `15` **PRISM** — per-channel quantize + env mode + geode page

### channel actions

`[x: 11-15, y: 7]`

armed modes, not instant: press one (it fast-blinks), then tap a channel in the
launch strip (cols 5-10, row 7) to apply. press again to disarm.

- `11` **COPY** — snapshot the A layer + the MIX-page static scalars
- `12` **PASTE** — write the snapshot in
- `13` **CLR** — reset the channel's A sequences to defaults
- `14` **RANDOMIZE** — scramble to fresh, grid-reachable values
- `15` **MUTATE** — nudge values ±

> CLR resets both layers; COPY / PASTE act on the **A** layer (leaving B to keep
> variating) and carry the channel's MIX-page voicing scalars along.

### MIX page

rows 0–5, per channel — the voice's static **mix + timbre** scalars (op ratios are
sequenced now, edited on their own row-7 pages, so they're not here):

- **pan** `[x: 6]` — stereo position, hard-left (-1) … centre … hard-right (+1)
- channel **level** `[x: 7]` — overall channel volume
- per-op **level** `[x: 8-11]` — op1..op4 output level (FM depth when the op is a
  modulator, mix gain when it's a carrier)
- **mod index** `[x: 12]` · **FM feedback** `[x: 13]` · **algorithm** `[x: 15]`
  (col 14 is dark, separating the scalar strip from the algorithm picker)

tap any cell to open its value picker on rows 6–7. these are all exempt from
randomize/mutate and travel with copy/paste.

### PROB page

rows 0–5, per channel:

- note alt-trig: **hold / step** `[x: 0-1]`
- burst probability: **25 / 50 / 75 / 100%** `[x: 11-14]`
- **burst / hit** toggle `[x: 15]` — gate whole bursts (off) or each hit (on)

alt-trig **step** arpeggiates: the B note sequence advances per hit on top of the
held A value.

### PERF page

rows 0–5, per channel:

- reset interval: **off / 1 / 2 / 4 bars** `[x: 0-3]` — rewinds the sequences and
  re-anchors a running burst to the bar
- octave: **−2 / −1 / 0 / +1 / +2** `[x: 5-9]` (centre = home; brightness scales
  with distance from home)
- rate: **0.25 / 0.5 / 1 / 2 / 4×** `[x: 11-15]` — scales burst timing without
  changing tempo

### PRISM page

rows 0–5, per channel — three selectors sharing one page:

- **quantize** `[x: 0-7]` — the grid each channel's hits snap forward onto, from the
  curated set **1/3 · 1/4 · 1/6 · 1/8 · 1/12 · 1/16 · 1/24 · 1/32** (events per whole
  note). quantize is **per channel**, so a channel can lock to a coarser or finer grid
  than its neighbours. tempo is never changed, only *when* a hit lands.
- **env mode** `[x: 9-11]` — amp-decay timing: **shape** (gap-relative) · **burst**
  (locked to the burst length) · **hit** (locked to the per-hit slot).
- **geode** `[x: 13-15]` — per-hit amplitude contour across a burst: **transient** ·
  **sustain** · **cycle**. the geode is always on.

cols 8 and 12 are dark separators. env mode + geode are also on the screen PERF page.

### harmony page

opened by **SCALE** (row 6, col 14). modal music theory made playable (modeled on
the Instruō harmonàig): a global **harmonic context** — mode, root, chord degree,
chord quality, inversion, voicing — resolves a four-tone seventh chord, and any
channel can be assigned one of its tones as a **role**:

- modes `[x: 0-6, y: 0-1]` — row 0 = the seven Ionian modes (ionian · dorian ·
  phrygian · lydian · mixolydian · aeolian · locrian), row 1 = the seven
  harmonic-minor modes (aeolian♯7 · locrian♯6 · ionian♯5 · dorian♯4 · phrygian♯3 ·
  lydian♯2 · super locrian)
- chord degree `[x: 0-6, y: 2]` — **I..VII**. unselected degrees brightness-encode
  their diatonic chord quality (bright = major-type, mid = minor, dark =
  diminished), so the mode's harmonization reads at a glance. pressing a degree
  re-harmonizes every role channel on its next hit — play chord progressions live.
- quality `[y: 3]` — **DIA** `[x: 0]` toggles diatonic auto-quality (derived from
  mode + degree); the eight seventh-chord qualities `[x: 2-9]` — **mM7 · o7 ·
  m7b5 · m7 · 7 · M7 · +M7 · +7** — and picking one takes manual control (DIA
  hands it back)
- root keyboard `[x: 0-6, y: 4-5]` — pick the tonic (compact piano)
- inversion `[x: 8-11, y: 4]` — **root / 1st / 2nd / 3rd** (lowest tone hops up
  an octave)
- voicing `[x: 8-11, y: 5]` — **close / drop2 / drop3 / spread** (octave-spread
  the chord tones)
- roles `[x: 12-15, y: 0-5]` — per channel (row = channel), assign **R / 3 / 5 /
  7**: the channel's pitch follows that chord tone instead of its note lane
  (which keeps advancing underneath, and per-channel octave still applies).
  re-press the lit role to free the channel.

free channels' note lanes index degrees of the selected mode, so everything stays
diatonic. all context params (`mode`, `root`, `chord_degree`, `chord_quality`,
`diatonic`, `inversion`, `voicing`, `chN_role`) are MIDI-mappable, so a
progression can also be driven externally. the **per-channel root transpose**
(`chN_root`, an additional ±octave tonic shift that composes with the global
root) and the **tuning** switch (**just intonation** ↔ **12-TET**) are
PARAMETERS-menu globals/scalars, not grid pages.

opened by **SCALE** (row 6, col 14). scale presets moved to the PARAMETERS menu
(expanded list), freeing room for three stacked mini-keyboards:

- note-**mask** keyboard `[x: 0-6, y: 0-1]` — compact piano (black row above white);
  toggle scale degrees in/out. the mask is **global** (shared by all channels).
- **root** keyboard, two octaves — upper `[x: 0-6, y: 2-3]` = offsets 0..+11 (white
  pc0 = base tonic, no transpose), lower `[x: 0-6, y: 4-5]` = offsets −12..−1. one
  press sets the targeted channel(s)' **root** as a signed semitone transpose (±1
  octave). **root is per-channel.**
- channel **selectors** `[x: 5-10, y: 7]` — the launch strip becomes channel
  selectors here: lit = targeted. a root press applies to **all** selected channels.
  with a **single** target, each press then auto-advances the target to the next
  channel; with **multiple** targets it applies to all and does not advance.

the per-channel root sums with the PERF-page `octave` (±2). press **SCALE** again to exit.

## norns UI

a complete secondary surface that stays in sync with the grid. six pages:
**main · alt · perf · prob · scale · op**.

- **E1** — select channel (1–6)
- **E2** — on main/alt: walk the cursor through every position (the `run` line,
  then each step of each param line, each ending in a `_` add slot). on
  perf/prob/scale/op: select a line.
- **E3** — edit under the cursor. on `run`: right = launch, left = stop. on a
  step: change the value (snapped to the picker grid); decrement below the lowest
  value to remove the step; on `_`, increment to append one.
- **K2 / K3** — page back / forward (clamped at the ends)
- **K1** — left to the norns system menus

**main** edits the six A-layer sequences; **alt** is its clone for the B (additive
offset) layer. **perf / prob / scale / mix** edit the same per-channel fields as the
grid's matching pages (the screen folds per-channel **quantize**, **env mode** and
**geode** onto its perf page, which the grid keeps on its own PRISM page), and the
grid's mode buttons switch the screen tab to match. the **scale** tab is the harmony
page: 13 lines (mode, root, degree, diatonic, quality, inversion, voicing, ch1–6
roles) beside a root keyboard and a live chord readout — the symbol (e.g. `V7`) and
the four voiced tones the role channels will play. screen edits go through the same
code path as grid edits, so both surfaces stay in sync and screen-entered values
remain grid-reachable.

## outputs

per-channel note routing, in the PARAMETERS menu under **OUTPUTS** (no grid/screen
page). external voices receive the final geode-bent freq / level / length. the
"brightness" modulation below is a proxy: the largest active modulator ratio for
the current algorithm.

| destination | sends |
|-------------|-------|
| `audio` | the internal `Potionshop` FM engine (default) |
| `midi` | note on/off (assignable device + channel); modwheel (CC1) = brightness |
| `audio + midi` | both |
| `crow 1+2` | v/oct on output 1, AR envelope on output 2 |
| `crow 3+4` | v/oct on output 3, AR envelope on output 4 |
| `crow ii jf` | Just Friends — `play_voice` per hit, JF voice = channel |
| `crow ii er301` | ER-301 — sc.cv pitch + sc.tr trigger, port = channel; 2nd CV = brightness |

## concepts

- **channel** — one of six independent four-operator FM voices (grid rows 0–5).
- **burst** — one firing event: `reps` hits spaced `4/div` beats apart. after it,
  the channel draws fresh values and fires the next.
- **sequins** — every sequenced param is a looping value list, advanced one value
  per burst; patterns evolve as lists of different lengths cycle.
- **A / B layers** — `note` and `level` each have a base (A) sequence and a B
  sequence summed onto it as an additive offset.
- **rest** — a `reps` value of `0` or less fires nothing but still consumes
  `1 − reps` div-steps of time, so the rhythm holds. a deterministic silence,
  distinct from `level = 0` (a triggered-but-silent voice) and from probability.
- **algorithm** — the FM operator routing (which operators modulate which, and
  which reach the output). engine-wide, one of 16.
- **geode** — per-hit amplitude shaping across a burst's hits, derived from the
  `level` "run CV" (0.5 = neutral). always on.
- **quantize** — the grid a channel's firing instant snaps forward onto. per
  channel, so channels with different divisions can lock to different grids. tempo
  is never changed, only *when* a hit lands.
- **probability** — per channel, skip a burst (or each hit) by chance.
- **reset** — optionally rewind a channel's sequences every 1/2/4 bars, re-anchoring
  to the bar grid so duplicates stay locked.

## params & PSETs

the entire instrument is norns params (`lib/params_sync.lua`), so everything saves
to PSETs and is MIDI-mappable:

- **globals** — `tuning` (just intonation / 12-TET) plus the harmonic context:
  `mode`, `root`, `chord_degree`, `chord_quality`, `diatonic`, `inversion`,
  `voicing`. there is no VOICE group — `env mode`, `geode`, `algorithm`, `mod index`
  and `fm feedback` are all per-channel now.
- **OUTPUTS** — per-channel destination (see [outputs](#outputs))
- **ch1–ch6 groups** — run, rate, quantize, `root` (−12..+11 transpose), `env mode`,
  `geode`, prob, alt-trig, chord role, reset, octave, the per-channel voice scalars
  (`mod index`, `fm feedback`, `algorithm`), the per-op ratios/levels, the
  randomize/mutate/clear/copy/paste triggers, and every sequence × layer as a text
  param (the whole sequence as a string) plus step/value cursor params

param edits, grid presses, and screen edits all stay bidirectionally in sync. tempo
lives in the system **CLOCK** menu (the script uses whatever it's set to).

## architecture

| file | role |
|------|------|
| `potionshop.lua` | init/cleanup, grid wrapper + strobe metro, enc/key routing, reset scheduler, params wiring |
| `lib/burst.lua` | sequencing core: channel state, geode math, clock-coroutine scheduling, randomize/mutate |
| `lib/params_sync.lua` | the whole instrument as norns params (PSETs / MIDI map), bidirectionally synced with grid + screen |
| `lib/outputs.lua` | per-channel output routing (audio / MIDI / crow CV / crow ii JF + ER-301), params-only |
| `lib/grid_ui.lua` | the grid controller / UI state machine (pages, pickers, action modes) |
| `lib/screen_ui.lua` | hand-drawn minimalist screen: focus-brightness lines, note glyph, A/B step squares |
| `lib/scales.lua` | pitch math: degree/semitone→frequency (via `musicutil`) |
| `lib/chords.lua` | modal harmony: 14 modes, chord qualities, inversion/voicing math |
| `lib/quantize.lua` | division/beat snapping |
| `lib/seqx.lua` | glue over the stock `sequins` library |
| `lib/Engine_Potionshop.sc` | SuperCollider four-operator FM engine (16 algorithms) + master limiter |

**stock libraries used:** `sequins` (pattern cycling), `musicutil` (pitch/scales).

**scheduling:** each launched channel runs a `clock.run` coroutine that draws the
next value from each sequins per burst, waits until its (quantized) target beat,
fires, and advances. each channel's `quantize` setting snaps that channel's events
forward via `quantize.snap_beat`.

## development

pure modules are unit-tested off-hardware (the harness ships faithful stubs of the
norns `clock` / `sequins` / `musicutil` / `screen` / `params` libs in
`test/norns_stub/`):

```
lua test/run.lua          # ~300 checks: quantize/snap-forward, scales, sequins glue,
                          # geode math, randomize grid-alignment, clock-coroutine
                          # scheduling, grid_ui wiring, screen pages + edits,
                          # params <-> engine sync, output routing
```

the SynthDef graphs can be build-checked with stock SuperCollider:

```
sclang test/potionshop_synthdef_check.scd   # -> "SYNTHDEFS_OK"
```

full audio + grid behavior must be verified on norns hardware.

## extending

- **more algorithms / operator control** — the 16 routings live as a data table
  in `Engine_Potionshop.sc`; adding one is a data + arg change, not a graph rewrite.
- **JF / Mangrove voices** — add `PotionJF` / `PotionMG` SynthDefs and branch in the
  SC `trig` command on a voice-type arg (re-introducing per-channel voice selection).
- **3-band master compressor** — the web master bus; currently a single `Limiter`.

MIDI output (the web app's note-out path) *is* ported — see `lib/outputs.lua` and
the OUTPUTS params group, which also add crow CV and crow ii (Just Friends /
ER-301) destinations the web app never had.

## credits

- built on monome's stock `sequins` by @trentgill & @tyleretters and `musicutil` by @markeats.
- bursts are heavily influenced by Just Type 'geode' mode by @trentgill
- A/B sequences influence from kria by @tehn & @zebra

## LLM disclosure

potionshop code & docs have been built with the assistance from Claude Code.  
</content>
</invoke>
