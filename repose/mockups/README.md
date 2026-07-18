# Repose composition mockups

A full-screen HTML harness for the aesthetic decisions the vertical slice
needs settled: composition geometry, type voice, agent-line grammar, and
legibility treatment. Open `index.html` in a browser, go fullscreen, sit
where you'd actually read it, and run the book test.

Everything uses production materials, not placeholders:

- Wallpapers from `../../livery/assets/` (the Livery fixture set).
- Colors from the live Livery manifest: text/muted roles, the locked
  signal colors (peach = waiting, green = done), and the
  `presentation.visualizerGradient` mint-to-blue for the strings.
- The mono voice's date uses the bar's `%a %F` grammar.

The strings are a **static SVG approximation at the baseline's ~4:1
aspect ratio** — they decide placement and scale only. Motion is frozen in the
zephyr-strings baseline (pre-graduation history; the shipped `strings`
visualizer carries it) and is not being judged here.

## Keys

| Key | Cycles |
|---|---|
| `←/→` | wallpaper |
| `1–5` | layout: corner · centered · lower third · top-right · headline |
| `f` | type voice: serif · sans · mono (in zephyr: Cantarell · system · SF Mono — applies to the plaque digits too) |
| `e` | extras: next-boundary runway + power chip (Tier A transfers from COMPONENT-BANK) |
| `v` | visualizer: strings · radial dial · mirrored bars |
| `c` | language: floating · composed (Livery) · zephyr (faithful port) |
| `g` | agent grammar: sentence · bar glyphs · dots |
| `a` | agent state: mixed · working · waiting · done · none |
| `p` | playing / silent |
| `s` | scrim: soft · off · strong · grade (color-grade + vignette, no blur) |
| `n` | night tint (StandBy-style single-hue re-render) |
| `d` | dark polarity (light-wallpaper stand-in for the Look analyzer) |
| `[` `]` | composition scale |
| `h` | help overlay |

State persists in localStorage; URL params override for direct links,
e.g. `index.html?layout=corner&voice=serif&wall=0&agents=mixed`.

## Layout notes

- **corner** — clock lower-left, strings running out of the clock's
  baseline toward the right; media and agent lines stacked beneath.
- **center** — the monolith (the layout curated lock-screen packs
  converge on; see `../RESEARCH.md`): date over clock on one axis, dots
  and media as footer, strings full-bleed at the foot.
- **lower** — cinematic lower third; media/agents right-aligned.
- **top-right** — time where the bar clock trained your eyes; the
  attention cluster lives directly beneath it, strings lower-left.
- **headline** — clock as masthead top-left, agent dots top-right, the
  visualizer full-bleed along the foot of the screen. Tuned for the
  zephyr plaque clock.

## Design language: two faithful candidates

A first cohesion pass that *blended* borrowed elements (glass cards, a
plaque clock in Ghostty glass, a media card, a workspace spine) was
rejected as gaudy. The verdict that survived: don't mix languages. `c`
now compares two faithful ones —

**composed (Livery)** — the wallpaper is the surface; cohesion from
typography and alignment, not chrome: one shared margin axis, a single
hairline rule, a modular type scale, the gradient confined to the
visualizer and a 1px progress line, signal colors only where they carry
workflow meaning, legibility from the Look-time scrim/polarity treatment.

**zephyr** — a faithful port of
[flickowoa/zephyr](https://github.com/flickowoa/zephyr)'s language:
Material You roles (its checked-in matugen default palette — warm surface,
peach primary, khaki tertiary), Cantarell/Avenir bold, a 12-hour plaque
clock **with seconds** — digits knocked out of solid primary-colored
chips, minutes ÷1.5 darker, seconds ÷2, stacked cells lightening 1+i/10,
zero chipless, columns rolling 500ms OutQuint (watch it live; screenshots
freeze it) — translucent separator bars, and the visualizer stroked
primary → tertiary.

Note the palettes are not the real fork: Zephyr regenerates its Material
roles from the wallpaper via matugen, exactly as Livery derives Looks. A
zephyr-language scene in production would consume Livery's roles the same
way. The fork is typographic and structural: editorial hairlines vs
plaque components, quiet minutes vs animated seconds.

## What to decide here

1. Layout and type voice (they cycle independently — 12 combinations).
2. Agent grammar and whether aggregate counts suffice at glance distance.
3. Scrim/polarity behavior per wallpaper — evidence for the Look-time
   legibility treatment named in the handoff (`d` on the alps or dunes
   wallpaper shows why polarity must flip).
4. Scale (`[`/`]`) — the persisted anchor/scale value the slice needs.

Record verdicts in `../HANDOFF.md` under the decision
ledger before starting the slice.
