# Algorithms — a visual guide

The voice is a **four-operator** synth. An *algorithm* is the wiring between the four
operators: who modulates whom, with what kind of modulation, and which operators you
actually hear. There are **32** of them, picked per channel on the **MIX page, col 15**
(`chN_algorithm`). The data lives in `lib/Engine_Potionshop.sc` (`algorithms`) — this
doc is a hand-drawn mirror of that table; keep it in step if the routings change.

This guide explains the three modulation *types* first (that's where the sound comes
from), then catalogs all 32 with diagrams.

---

## Operators & carriers

Four sine **operators**, numbered 4 → 1. An operator is either a **carrier** (it goes
to the output — you hear its pitch) or a **modulator** (it shapes another operator and
is *not* heard directly). The same op can be a modulator in one algorithm and a carrier
in another — which is exactly what drives the per-channel **op-ratio role sets**
(carriers pull from the 5-limit `CARRIER_RATIOS`, modulators from `MODULATOR_RATIOS`).

**op1 is a carrier in every algorithm** — the pitch anchor (its ratio defaults to 1.0).
op4 is the deepest modulator in most stacks (it also carries the per-op `feedback`).

The per-op **level** sets how loud a carrier is *or* how deep a modulator pushes; the
per-channel **mod index** is the master modulation depth over the whole voice.

---

## The three edge types

This is the heart of it. An edge from a higher op to a lower op can modulate in three
ways, each with a distinct spectral fingerprint:

```
 │   PM    phase modulation — classic FM. Generates MANY sidebands at
           carrier ± k·modulator (k = 1,2,3…). Rich, bright, the more depth
           the more harmonics. This is algorithms 1–16.

 ~   AM    amplitude modulation, carrier KEPT. Adds just two sidebands
           (carrier ± modulator) on top of the original carrier. Gentle:
           tremolo at low rates, a soft shimmer / two extra partials at audio
           rates. Politer than PM.

 ╳   ring  ring modulation, carrier REMOVED. Only the two sidebands remain
           (carrier ± modulator), no original pitch. Metallic, bell-like,
           clangorous. The sum/difference tones dominate.
```

Why these complement the **5-limit** key layout: with every operator ratio a 5-limit
just interval, ring/AM sum-and-difference tones (carrier ± modulator) land on *just*
thirds and fifths rather than beating against the tuning. AM/ring is arguably the more
5-limit-coherent generator — see `CLAUDE.md`.

> AM/ring **depth** currently shares the `mod_index` macro (normalized 0..1). At a low
> `mod_index` the AM/ring algorithms (17–32) sound nearly dry — turn it up to hear them.

### Reading the diagrams

```
4 3 2 1   operator numbers; signal flows DOWNWARD (modulators on top)
 │        a PM edge          ~  an AM edge          ╳  a ring edge
 ▀        the output bus — an operator resting on ▀ is a CARRIER (heard)
```

A modulator sits above the operator it feeds. Diagonals (`╲ ╱`) just fan a connection
out to / in from several operators; the **edge-type glyph** (`│ ~ ╳`) is what tells you
*how* it modulates. Every entry also has a plain-English line, which is authoritative if
a diagram is ever ambiguous.

---

## 1–16 · Phase modulation (the FM core)

The canonical Yamaha 4-op DX set (1–8) plus eight extended PM routings (9–16). All
edges are PM (`│`).

```
 1 · 4>3>2>1            2 · (4,3)>2>1          3 · 4>3>1 2>1          4 · 4>2>1 3>1
   4                      4 3                     4                      4
   │                      ╲ ╱                     │                      │
   3                       2                      3 2                    2 3
   │                       │                      ╲ ╱                    ╲ ╱
   2                       1                       1                      1
   │                       ▀                       ▀                      ▀
   1
   ▀
 one deep stack         4 & 3 → 2 → 1          4→3→1, plus 2→1       4→2→1, plus 3→1
 (brightest, thinnest)  thick single voice    twin mod into op1     twin mod into op1
```

```
 5 · 2>1 4>3            6 · 4>1,2,3            7 · 4>3 +1,2           8 · additive
   2   4                  4                       4                    1 2 3 4
   │   │                ╱ │ ╲                     │                    ▀ ▀ ▀ ▀
   1   3                1 2 3                  1 2 3
   ▀   ▀                ▀ ▀ ▀                  ▀ ▀ ▀                  four pure sines,
 two 2-op stacks       op4 fans to three      op4 colors op3,        no modulation
 (organ-ish pair)      carriers (chorus)      op1/op2 stay pure      (drawbar / pad)
```

```
 9 · (4,3,2)>1         10 · 3>2>1 +4          11 · 4>2>1 +3          12 · 4>3>2 +1
  4 3 2                  3                       4                      4
  ╲ │ ╱                  │                       │                      │
    1                    2   4                   2   3                  3
    ▀                    │                       │                      │
                         1                       1                      2   1
 three mods stacked      ▀   ▀                   ▀   ▀                  ▀   ▀
 on one carrier        3→2→1 stack +           4→2→1 stack +          4→3→2 carrier +
 (fat, formant-y)      a pure op4              a pure op3             a pure op1
```

```
13 · 4>3>1 +2          14 · (4,3)>1 +2        15 · 4>1,2 +3          16 · 4>2 3>1
   4                     4 3                      4                    3   4
   │                     ╲ ╱                     ╱ ╲                   │   │
   3                      1   2                  1 2  3                1   2
   │                      ▀   ▀                  ▀ ▀  ▀                ▀   ▀
   1   2                4 & 3 → op1,            op4 → op1 & op2,      two separate
   ▀   ▀                pure op2               pure op3              2-op stacks
 4→3→1 stack +         (bright + pure)        (split + pure)        (4→2, 3→1)
 a pure op2
```

---

## 17–32 · Amplitude / ring modulation & hybrids

`~` = AM (carrier kept), `╳` = ring (carrier removed), `│` = PM. The pure AM/ring
routings (17, 18, 20, 21, 23, 24, 26, 30, 31) mirror earlier PM shapes with a metallic
or shimmering character; the hybrids (19, 22, 25, 27, 28, 29, 32) mix PM with AM/ring.

```
17 · 2x1 +3,4          18 · 2x1 4x3           19 · 4>3x1 +2          20 · 4~1,2,3
   2                     2   4                   4                      4
   ╳                     ╳   ╳                   │                    ~ ~ ~
   1   3   4             1   3                   3                    1 2 3
   ▀   ▀   ▀             ▀   ▀                   ╳                    ▀ ▀ ▀
 op2 ring-mods op1;    two ring pairs          1   2                op4 AM-shimmers
 op3,op4 bare         (metallic dyads)         ▀   ▀                three carriers
 (metallic + 2 tones)                       4 PM→ op3, op3 ring→    (gentle chorus)
                                            op1; pure op2
```

```
21 · 4x3x2x1          22 · (4,3)>1 2~1       23 · 2~1 4~3           24 · 4x1,2,3
   4                    4 3 2                   2   4                   4
   ╳                    │ │ ~                   ~   ~                 ╳ ╳ ╳
   3                    ╲ │ ╱                   1   3                 1 2 3
   ╳                      1                     ▀   ▀                 ▀ ▀ ▀
   2                      ▀                  two AM pairs            op4 ring-mods
   ╳                  op4,op3 PM→ op1;       (soft shimmer pair)    three carriers
   1                  op2 AM→ op1                                   (metallic chorus)
   ▀                  (bright + shimmer)
 ring chain (bell)
```

```
25 · 2>1 4~3          26 · 4~3~2~1           27 · 4>1 3x 2~         28 · 3>2>1 4~1
   2   4                4                      4 3 2                   3
   │   ~                ~                      │ ╳ ~                   │
   1   3                3                      ╲ │ ╱                   2   4
   ▀   ▀                ~                        1                    │   ~
 PM pair + AM pair      2                        ▀                    1 ◄─┘
 (FM tone + shimmer)    ~                  op1 hit three ways:        ▀
                        1                  PM(4)+ring(3)+AM(2)     3→2→1 PM stack +
                        ▀                  (max contrast)         op4 AM→ op1
                  AM chain (soft bell)
```

```
29 · (4,3)>2x1        30 · 4x2 3x1           31 · 4~2 3~1           32 · 4>3 3~2~1
  4 3                   3   4                   3   4                   4
  ╲ ╱                   ╳   ╳                   ~   ~                   │
   2                    1   2                   1   2                   3
   ╳                    ▀   ▀                   ▀   ▀                   ~
   1                  two ring pairs          two AM pairs             2
   ▀                  (4╳2, 3╳1)             (4~2, 3~1)                ~
 op4,op3 PM→ op2,                                                     1
 op2 ring→ op1                                                        ▀
 (PM-fed metallic)                                              4 PM→ op3, then
                                                               AM chain 3~2~1
```

---

## At a glance

| #  | name        | type   | character                              |
|----|-------------|--------|----------------------------------------|
| 1  | 4>3>2>1     | PM     | one deep stack — brightest, thinnest   |
| 2  | (4,3)>2>1   | PM     | thick single voice                     |
| 3  | 4>3>1 2>1   | PM     | twin mod into op1                      |
| 4  | 4>2>1 3>1   | PM     | twin mod into op1 (parallel)           |
| 5  | 2>1 4>3     | PM     | two 2-op stacks (organ-ish pair)       |
| 6  | 4>1,2,3     | PM     | op4 fans to three carriers (chorus)    |
| 7  | 4>3 +1,2    | PM     | one colored op + two pure              |
| 8  | additive    | —      | four pure sines (drawbar / pad)        |
| 9  | (4,3,2)>1   | PM     | three mods on one carrier (fat)        |
| 10 | 3>2>1 +4    | PM     | 3-op stack + a pure tone               |
| 11 | 4>2>1 +3    | PM     | 3-op stack + a pure tone               |
| 12 | 4>3>2 +1    | PM     | 3-op stack + a pure op1                |
| 13 | 4>3>1 +2    | PM     | 3-op stack + a pure op2                |
| 14 | (4,3)>1 +2  | PM     | double-mod op1 + pure op2              |
| 15 | 4>1,2 +3    | PM     | op4 splits to two + pure op3           |
| 16 | 4>2 3>1     | PM     | two separate 2-op stacks               |
| 17 | 2x1 +3,4    | ring   | metallic dyad + two clean tones        |
| 18 | 2x1 4x3     | ring   | two metallic dyads                     |
| 19 | 4>3x1 +2    | hybrid | PM-fed ring + a pure tone              |
| 20 | 4~1,2,3     | AM     | op4 shimmers three carriers            |
| 21 | 4x3x2x1     | ring   | ring chain — bell / clangorous         |
| 22 | (4,3)>1 2~1 | hybrid | bright PM + AM shimmer                  |
| 23 | 2~1 4~3     | AM     | two soft shimmer pairs                  |
| 24 | 4x1,2,3     | ring   | metallic chorus (3 carriers)           |
| 25 | 2>1 4~3     | hybrid | FM tone + AM shimmer                    |
| 26 | 4~3~2~1     | AM     | AM chain — soft bell                    |
| 27 | 4>1 3x 2~   | hybrid | op1 hit PM + ring + AM (max contrast)  |
| 28 | 3>2>1 4~1   | hybrid | PM stack + AM shimmer on the carrier   |
| 29 | (4,3)>2x1   | hybrid | PM-fed metallic                        |
| 30 | 4x2 3x1     | ring   | two metallic dyads (parallel)          |
| 31 | 4~2 3~1     | AM     | two shimmer pairs (parallel)           |
| 32 | 4>3 3~2~1   | hybrid | PM into an AM chain                     |

---

## Tips

- **Start on 1 or 8** to learn a channel's pitch, then explore. 1 is the brightest FM
  stack; 8 is four pure sines (set op ratios to a chord).
- **AM/ring (17–32) need `mod_index` up** to be audible — they're dry at low depth.
- **Ring (`╳`) kills the carrier pitch**, so the perceived pitch comes from the
  operator *ratios* (the sum/difference tones). Lean on the 5-limit carrier ratios to
  keep ring algorithms in tune.
- **Hybrids (19, 22, 25, 27–29, 32)** give the most movement: a PM-bright core with a
  metallic or shimmering layer.
- The op-ratio picker re-anchors to the **carrier** or **modulator** set per operator as
  you change algorithm — so the same grid cell means a just interval on a carrier op and
  a harmonic ratio on a modulator op.
