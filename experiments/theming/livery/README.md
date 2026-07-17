# Livery Prototype

A native macOS panel and companion CLI for a bidirectional wallpaper/theme
workflow. The panel previews and explicitly applies reversible Looks through
the same `liveryctl` transaction engine as the CLI. Wallpaper-derived palettes
and independently authored semantic themes are separate checked-in catalogs,
so either side can be held fixed without pretending the operations are
inverses.

The interface is a graphical workbench with terminal sensibilities rather than a miniature desktop or a macOS settings panel. Grid mode is the source browser; detail mode uses the real image, semantic roles, a syntax-highlighted Lua specimen, and a draft terminal mapping as its inspection surfaces. JetBrains Mono, compact spacing, flat controls, hairline boundaries, explicit shortcut labels, restrained backdrop blur, and theme-colored scroll chrome follow the surrounding Ghostty/SketchyBar environment; decorative desktop mockups are intentionally absent.

## Run

```sh
./lvry
```

The same command shows or hides the persistent panel. Escape and the in-panel close button hide it. The process remains available for the next toggle. The runner builds an ephemeral app bundle under `/tmp`; no application is installed.

The panel is a transient all-Spaces `NSPanel`: it is absent while hidden and
appears on whichever Space is active when invoked. It behaves as a
yabai-unmanaged utility rather than a tiled application window. `cmd+alt+l`
toggles it through `skhd`; Escape restores the application that was active
before Livery opened.

The launcher uses an atomic per-user launch lock and collapses accidental
duplicate processes. Repeated shortcut strokes during a rebuild therefore
remain ordered toggles instead of creating independent panels. The app writes a
PID readiness marker after its panel and event handlers exist. Running toggles
use the native LaunchServices reopen event, which macOS recognizes as a
user-requested activation even after Livery has returned to accessory status.

## What works

- Browse the built-in and personal wallpaper library in an adaptive grid (`g`).
- Open a wallpaper's detail view by clicking it; the first nine retain direct
  `1`–`9` shortcuts. Return directly with `d`.
- Import an image with `i`, review its name, description, and credit/source,
  then generate its Content, Vibrant, and Neutral candidates. Imported bytes
  are copied into a managed personal library and appear immediately.
- Switch authority with `w` (wallpaper → theme) or `t` (theme → wallpaper).
- Compare three Matugen 4.1.0 schemes: Content (`c`), Vibrant (`v`), and Neutral (`n`).
- In theme-authoritative mode, choose one of nine independent semantic themes,
  then choose its target wallpaper separately.
- Grade a wallpaper toward a held theme with Subtle (`u`), Balanced (`b`), or
  Theme-forward (`f`). The displayed derivative is the exact staged artifact,
  not a separate approximation.
- Map image luminance through Natural, Duotone, Tritone, or a five-color theme
  gradient. Mapping preserves enough source lightness to retain structure while
  allowing deliberately graphic treatments.
- Optionally reduce that derivative to a theme-derived 16-, 8-, or 4-color
  OKLab palette; apply ordered Bayer or seeded noise before reduction; and add
  a clean, grain, or halftone finish. Every combination remains deterministic
  and content-addressed.
- Toggle the theme-first wallpaper between its original and exact graded
  artifact with `x`.
- Inspect the extracted source color, seven semantic roles, a token-colored Lua sample, and Matugen's 16-color Base16 `wal` output.
- Inspect a coherent Look in which the palette and wallpaper are intentionally related.

The checked-in `palettes.json` is generated in dark mode using each image's most dominant extracted source (`--source-color-index 0`). Semantic roles come from the selected Material scheme; the terminal map comes from Matugen's Base16 `wal` backend. The detail view shows this provenance rather than presenting the values as hand-authored choices.

## Theme library

The independent theme catalog deliberately spans different visual languages
rather than producing nine small variations on one dark palette:

- `current` — the captured working baseline;
- `violet-hour` — muted dark-purple, translucent, anime-nocturne glass;
- `sakura-static` — ink navy, dusty pink, and late-night signage;
- `moss-ledger` — organic green with an editorial, paper-and-ink temperament;
- `ember-archive` — warm archival brown, copper, and parchment;
- `polar-signal` — cold technical blue with crisp cyan signals;
- `graphite-mono` — restrained near-monochrome graphite;
- `acid-relay` — deliberately loud, high-contrast electronic color;
- `porcelain-day` — a warm light theme that tests the opposite end of the
  luminance range.

These are semantic application themes, not wallpaper-derived aliases. They
define UI roles, signal colors, terminal ANSI slots and contrast floors,
visualizer colors, and transparency/blur policy. `theme-presets.json` is the
human-edited source; `themes.json` is its deterministic generated catalog.

```sh
./generate-themes
livery themes
livery plan theme:violet-hour@purple-brutalism:balanced
livery plan theme:porcelain-day@blue-alps:subtle
```

## Regenerate palettes

The generator is pinned to concept-local Matugen 4.1.0 under `../tools`; it runs with `--dry-run` and cannot apply a wallpaper, run reload commands, or write live configuration.

```sh
cargo install matugen --version 4.1.0 --locked --root ../tools
./generate-palettes
```

## Target infrastructure

`liveryctl` resolves a canonical Look manifest and renders staged adapters for
Ghostty, SketchyBar, borders, and the wallpaper. A normal `apply` means one
global Look: coordinated colors plus one wallpaper across every managed desktop
Space. `--colors-only` is an explicit manual override, not the default workflow.
`livery` is the short command installed on `PATH`.

```sh
livery list
livery wallpapers
livery themes
livery import-wallpaper ~/Pictures/example.png --name "Example"
livery plan default
livery plan wallpaper:warm-dunes:content
livery plan theme:violet-hour@warm-dunes:balanced
livery plan 'theme:violet-hour@purple-brutalism:balanced~tritone~q8~bayer~grain'
livery plan theme:neon-city:vibrant@warm-dunes:theme-forward
livery current
livery apply wallpaper:warm-dunes:content
livery apply theme:violet-hour@warm-dunes:balanced
livery apply wallpaper:warm-dunes:content --colors-only
livery rollback
./tests/validate.sh
```

The legacy `warm-dunes:content` spelling remains accepted. Canonical profile
names state their authority explicitly:

- `wallpaper:<source>:<scheme>` derives a semantic theme while preserving the
  source image bytes.
- `theme:<theme-ref>@<source>:<recipe>` holds the semantic theme fixed and
  emits a deterministic sRGB wallpaper derivative. A recipe is
  `<grade>~<mapping>~<quantization>~<dither>~<finish>`.

The default-compatible recipe is
`balanced~natural~continuous~none~clean`; the legacy single-token `balanced`
and original four-field grammar remain accepted. Mapping may be `natural`,
`duotone`, `tritone`, or `gradient-map`. Quantization may be `continuous`,
`q16`, `q8`, or `q4`. Dither may be `none`, `bayer`, or `blue-noise` and is
only meaningful with a reduced palette. Finish may be `clean`, `grain`, or
`halftone`. The ordered operation list and every parameter are stored in the
Look manifest, and the derivation cache hashes the complete graph.

`<theme-ref>` may be a name from `livery themes`, `default`, or the legacy
wallpaper-derived `<wallpaper>:<scheme>` form. Named library themes are the
primary theme-first workflow; the legacy form remains useful for comparison.

## Lock image

The live-wallpaper runtime covers the working desktop, so macOS's system
wallpaper is the still shown by the lock screen. Livery manages that slot as a
global policy, independently from Look history:

```sh
livery lock                         # show the current policy
livery lock ~/Pictures/lock.png     # pin an image across apply and rollback
livery lock scene:pixel-dusk-city   # pin a cached still from a Repose scene
livery lock theme                   # follow the current Look's wallpaper
livery lock off                     # stop lock-specific management
```

File and scene pins live in `~/.config/livery/lock.json` and win whenever a
normal Look apply or rollback touches the wallpaper store. `theme` follows the
active profile and updates with later Look changes; `off` leaves the current
store alone and returns future applies to their normal wallpaper behavior.
Video scenes are resolved from `~/.config/wallpaper-runtime/scenes/` and
reduced with ffmpeg to a content-addressed PNG beneath
`~/.config/livery/lock/scenes/`. The source scene selection remains in the
state record so the native panel can expose the same policy later.

## Personal wallpaper library

The native `i` flow and the CLI share the same importer:

```sh
livery import-wallpaper ~/Pictures/night-train.png \
  --name "night train" \
  --subtitle "anime / violet / nocturne" \
  --credit "personal collection"
livery wallpapers
livery plan wallpaper:night-train:content
livery plan theme:violet-hour@night-train:balanced
livery plan 'theme:violet-hour@night-train:theme-forward~q8~blue-noise~grain'
```

Livery inspects the image, hashes and copies the untouched bytes beneath
`~/.config/livery/library/assets/`, deduplicates repeat submissions, and writes
the generated metadata to `~/.config/livery/library/wallpapers.json`. The
checked-in fixtures and personal catalog are merged at read time; importing
does not rewrite this experiment or install an application. The original
source path can therefore move or disappear after a successful import.

The grid uses adaptive card widths, the detail thumbnail rail scrolls
horizontally, and theme cards are full-surface hit targets. Catalog growth no
longer changes the meaning of existing item IDs or requires assigning every
wallpaper a keyboard shortcut. Standard scroll indicators are replaced by
thin Livery-owned tracks and thumbs sized from the actual viewport and content
extent.

`liveryctl resolve` emits a v2 resolved Look manifest. Its companion
`spec.json`, content-addressed wallpaper, and rendered target adapters are
installed together in the immutable runtime profile. Spec identity,
derivation identity, semantic-theme identity, and actual image-byte identity
are recorded separately.

Plain `apply` performs an all-managed-Spaces Look transition. The native engine
asks WallpaperAgent to generate its private image payload, normalizes that
payload into `AllSpacesAndDisplays`, clears per-Space/display overrides, and
verifies convergence before the target reload completes. `--colors-only`
remains available when deliberately breaking coherence. Rollback restores the
exact preceding wallpaper-store snapshot, including Apple aerial/dynamic
provider state. The restored Apple aerial and complete wallpaper store are the
new baseline; the earlier per-display URL capture is legacy evidence only.

Generated Looks also carry a deterministic SketchyBar legibility treatment.
Livery samples the top wallpaper band for every connected display, chooses
light or dark bar roles by lower-decile contrast, adjusts bar-only accents and
signals when necessary, and introduces the smallest required scrim only when an
open rail cannot reach 4.5:1. Popup colors are kept separate.

`default`/`current` is an exact capture of the current colors for those three targets:
its Ghostty and SketchyBar diffs are empty and its proposed borders command is
identical to the running configuration. Generated profiles retain the default
signal colors, visualizer gradient, and opacity policy while replacing UI and
terminal colors. Independently authored library themes may instead define all
of those semantic domains explicitly.

Ghostty reads the active runtime profile through an optional config include and
retains `catppuccin-mocha.conf` as its fallback. Apply and rollback send
Ghostty its native `SIGUSR2` configuration-reload signal, so an already-running
application updates without taking focus. `cmd+shift+,` remains the manual
fallback.

The detail view applies its selected Look with `p` or the minimal apply hint. It
invokes the same transactional `liveryctl apply` path as the CLI. Theme-first
preview likewise invokes `liveryctl render` and opens the wallpaper artifact
named by the resolved manifest, so preview and apply use identical pixels.

Generated Looks set Ghostty's native `minimum-contrast` floor to `3`. Ghostty
checks foreground text against its cell background at render time without
modifying background colors, including colors selected by terminal
applications. The captured `default` retains Ghostty's native `1` setting.
Livery's terminal specimen previews that behavior over the selected wallpaper
and translucent terminal background.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the semantic/UI, signal, Base16,
ANSI, presentation, and effects boundaries.

## Built-in wallpaper fixtures

- `warm-dunes.jpg` — [Zetong Li on Unsplash](https://unsplash.com/photos/a-group-of-sand-dunes-in-the-desert-HEf0fKgJA1Q)
- `cool-neon-city.jpg` — [Ramon Buçard on Unsplash](https://unsplash.com/photos/nighttime-cityscape-with-neon-lights-and-shadows-NixS7RCFI_E)
- `forest-path.jpg` — [Daniel Gomez on Unsplash](https://unsplash.com/photos/an-aerial-view-of-a-forest-with-trees-bIvVy0syYI4)
- `purple-brutalism.jpg` — [Justin Luca Krause on Unsplash](https://unsplash.com/photos/a-group-of-buildings-with-a-purple-sky-EbQZ6C_wkqY)
- `blue-alps.jpg` — [Jörg Angeli on Unsplash](https://unsplash.com/photos/snow-mountain-during-daytime-Nt84Ou3a-is)
- `moonlit-ocean.jpg` — [set.sj on Unsplash](https://unsplash.com/photos/a-black-and-white-photo-of-the-moon-over-the-ocean-YPMdLzi-ol0)

All six photographs are used under the [Unsplash License](https://unsplash.com/license).
