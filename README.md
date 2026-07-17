# SketchyBar concept lab

This sibling directory is an isolated design lab for the live configuration in
`../sketchybar`. Every concept remains a static JSON specification. The optional
`live-preview` controller materializes temporary runtime configs outside this
directory and registers only uniquely named preview instances.

The lab is intentionally separate because the brief was to explore freely
without applying anything. The live config was treated as read-only throughout.

## What is here

- `LIVE-PREVIEW.md` documents the isolated live-preview controller.
- `live-preview` launches, switches, exercises, captures, and stops a separate
  named SketchyBar instance. The preview bar carries an in-bar switcher
  (`‹ concept · mode  scenario ›`) so concepts, scenarios, and data modes can
  be cycled by clicking, without returning to the terminal.
- `CATALOG.md` compares eight cohesive layout directions.
- `COMPONENT-BANK.md` ranks the useful component ideas and records the cutoff
  where more menu-bar content stops earning its pixels.
- `RESEARCH.md` records the local audit, ecosystem findings, constraints, and
  source links.
- `concepts/*/concept.json` contains one self-contained layout specification per
  concept: pixel budget, zones, reveal behavior, interactions, event feeds, and
  risks.

The preview borrows the production bar's visual assets so prototypes read
like the real thing: space cells render the space number plus
`sketchybar-app-font` app icons (the same map as
`../sketchybar/helpers/app_icons.lua`), and system components use the
production SF Symbols (apple, battery, wifi, cpu) — see
`preview/lib/glyphs.lua`.

The concepts target the observed 1728-point-wide laptop display. Widths are
design allowances rather than exact measurements; gaps, the notch, and dynamic
text still need a small integration reserve if a concept is implemented later.

## Suggested reading order

1. Start with **Calm Islands** for the strongest all-day default.
2. Compare **Agent Flightdeck** for the terminal/AI-heavy workflow.
3. Inspect **Quiet Signal** to see how little can remain persistent.
4. Treat **Chameleon** as a state architecture that can borrow pieces from the
   other seven layouts.

## Isolation check

The concept files can be syntax-checked without executing anything:

```sh
jq empty concepts/*/concept.json
```

The static concept specifications remain inert. The optional preview runtime is
the only executable portion of the lab; it targets a generated per-session bar
name and never sources the production configuration.
