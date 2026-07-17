# Livery Look model

Livery resolves wallpaper and theme intent through one shared spine. A
`LookSpec` records what the user asked for; an immutable `LookManifest` records
the exact semantic theme and wallpaper artifact that adapters will consume.
The two directions share storage, provenance, validation, preview, apply, and
rollback, but they are deliberately not modeled as mathematical inverses.

## Contracts and identity

Both contracts use schema version 2 and are documented in
`schema/look.schema.json`.

- `authority` says which input is fixed: `wallpaper`, `theme`, `pair`, or
  `independent`.
- `operation` says what resolution must do: `derive-theme`,
  `grade-wallpaper`, or `identity`.
- `constraints.preserveThemeDomains` prevents the resolver from silently
  changing semantic domains that are outside the chosen operation.
- `pipeline` records operation names, engines, versions, and complete
  parameters.
- `placement` records image fit and focal point independently from image
  pixels.

Identity is intentionally split:

- `specDigest` hashes the complete user-facing intent, including its id and
  label.
- `derivationDigest` hashes canonical material inputs, pipeline, and placement
  while ignoring aliases.
- input and output descriptors carry the SHA-256 digest of actual bytes.
- the semantic-theme output carries a digest over canonical semantic roles.

This prevents a cache key from being confused with proof of an output
artifact. Originals are copied into `build/store/originals/<digest>.<ext>`;
derived images are cached by derivation identity and staged under their actual
artifact digest.

Image descriptors include dimensions, orientation, media type, byte size, and
color-profile evidence. The first renderer is intentionally SDR: Core Image
works in extended linear sRGB and writes an explicitly tagged sRGB PNG.

## Semantic theme

`schema/theme.schema.json` defines the standalone semantic-theme input. It has
no wallpaper/coherence fields; those belong to the Look contract.

- `ui`: surfaces, text, accents, outline, and selection.
- `signals`: success, warning, error, info, and attention. These are locked to
  the captured default during the first generated-theme experiments because
  they carry workflow meaning.
- `terminal.base16`: the raw Base16 scheme when the source generator provides
  one.
- `terminal.ansi`: terminal slots 0–15 after applying the Base16 terminal
  mapping. Base16 order is not ANSI order.
- `terminal.minimumContrast`: a renderer-level safety floor. Generated Looks
  use Ghostty's native 3:1 foreground/background check; the captured default
  keeps the native 1:1 behavior.
- `presentation`: decorative ramps such as the strings visualizer gradient.
- `presentation.barLegibility`: a display-crop-aware treatment for the open
  SketchyBar rail. It records foreground polarity, adjusted bar-only semantic
  colors, optional scrim, and measured lower-decile contrast.
- `effects`: opacity and blur policy, stored independently from RGB values.
- `targets`: optional per-application overrides. The captured `default` uses
  these where the existing configuration is intentionally irregular.
- `outputs`: resolved semantic-theme identity and either a content-addressed
  wallpaper artifact or a captured provider state.
- `provenance`: material descriptors, replay steps, renderer environment, and
  a reproducibility level (`stored`, `replayable`, or `reproducible`).
- `evidence`: direction-specific checks plus the resolved bar-legibility
  treatment.

Runtime validation verifies both contracts, their digest relationship, the
semantic-theme digest, the wallpaper artifact digest, and every target adapter
before anything can reach the transaction engine.

## Wallpaper catalogs and submission

Built-in fixtures remain reproducible inputs in `palettes.json`. Personal
wallpapers use a separate runtime catalog at
`~/.config/livery/library/wallpapers.json`; their untouched, content-addressed
image bytes live beneath `~/.config/livery/library/assets/`. `liveryctl
wallpapers --json` merges both catalogs into the single read model consumed by
the resolver and native panel.

`import-wallpaper` is deliberately ingest-first rather than reference-by-path.
It validates image metadata, hashes and copies the original, returns the
existing record when the same bytes are submitted twice, generates the three
pinned Matugen schemes, and atomically appends one fixture record. Moving or
deleting the source file later cannot invalidate a Look. The GUI performs a
review step for display name, descriptive tags, and credit/source before
calling this same command, then refreshes the merged catalog and selects the
result.

Numbers are optional presentation shortcuts for the first nine entries, not
wallpaper identity. Stable string IDs and content digests are the contracts;
adaptive grids and scrolling rails allow the library to grow independently of
panel dimensions.

The panel backdrop is a low-emphasis behind-window `NSVisualEffectView`
underneath a 46% selected semantic background tint. Wallpaper remains visible
through the pane, making blur a small spatial cue rather than the interface's
design language. Light semantic themes use their native light material
appearance, an 84% backing tint, and contrast-floored interface text; this
keeps variable wallpaper bleed from erasing dark labels without changing the
theme values shown in specimens or sent to adapters. SwiftUI's
standard indicators are hidden; a shared scroll container measures content in
its scroll coordinate space and draws a four-point theme-colored track and
proportional thumb for both axes.

## Profiles

`profiles/default.json` captures the current behavior of the first three
targets exactly. It remains the semantic seed used by the resolver; resolved
runtime bundles are always v2 Looks.

Wallpaper-derived profiles are resolved from `palettes.json` with names such as
`wallpaper:warm-dunes:content`. They replace UI and terminal colors while
retaining the locked signal, presentation, and effects layers from `default`.
The legacy `warm-dunes:content` spelling remains an alias.

Independent themes live in `themes.json`, generated deterministically from the
human-edited `theme-presets.json`. Each entry is a complete v2 semantic theme:
UI roles, signals, Base16/ANSI terminal colors and contrast policy,
presentation colors, and opacity/blur effects. The catalog is independent of
wallpaper fixtures and is discoverable through `livery themes`. The initial
library intentionally includes dark and light, muted and saturated, organic
and technical, translucent and more opaque directions.

Theme-authoritative profiles use
`theme:<theme-ref>@<wallpaper>:<recipe>`. A theme reference may be `default` or
a named library theme such as `violet-hour`; wallpaper-derived references such
as `neon-city:vibrant` remain accepted for comparison. Recipes have five
ordered fields:

`<grade>~<mapping>~<quantization>~<dither>~<finish>`

The single-token legacy form remains accepted and fills the other fields with
`natural~continuous~none~clean`. The original four-field form is interpreted
as having `natural` mapping. The grading choices are:

- `subtle`: 0.32 strength, prioritizing source-image fidelity;
- `balanced`: 0.58 strength;
- `theme-forward`: 0.82 strength, prioritizing theme affinity.

The theme is projected into an image palette made from shadow, surface,
elevated, primary, secondary, tertiary, muted, and highlight UI roles. ANSI
slots and signal colors are not used as image colors. Grading performs
highlight/shadow, exposure, contrast, and saturation preparation before a
lightness-preserving OKLab color cube. Theme hues steer the image without
forcing already-colorful pixels down to the usually lower chroma of UI colors;
each preset records an explicit source-chroma retention floor.

The mapping stage follows grading and precedes any dithering or reduction.
`natural` emits no mapping operation. `duotone` maps luminance between the
theme's dark anchor and primary accent; `tritone` adds a primary midpoint and
secondary highlight; `gradient-map` uses a five-stop ramp across primary,
secondary, and tertiary colors with polarity-aware endpoints. Hue/chroma
mapping is intentionally stronger than lightness remapping so photographic
structure survives even highly stylized treatments.

Palette reduction is optional and maps pixels to 16, 8, or 4 projected colors
by nearest OKLab distance. Reduced image palettes reserve their scarce slots
for shadow/highlight anchors and synthesized dark, mid, and light variants of
the primary, secondary, and tertiary hues rather than spending most slots on
near-identical UI surfaces. Dither is an explicit preceding graph step:
8×8 Bayer or a deterministic 64×64 high-pass-ranked blue-noise tile.
Finishing is a following graph step: clean, deterministic grain, or Core Image
CMYK halftone. Dithering without a reduced palette is rejected. Semantic
region recoloring remains explicitly outside this version.

## Directional pipelines

Wallpaper-authoritative resolution runs Matugen analysis and theme synthesis,
then restores locked signal, presentation, and effect domains. The source
wallpaper bytes pass through unchanged.

Theme-authoritative resolution keeps every semantic theme domain fixed,
projects image-facing colors, and executes an ordered, deterministic static
image graph. The original and derivative remain separate artifacts, and the
manifest records both digests, the complete operation sequence, and all
renderer parameters. The same resolved graph feeds native preview and apply;
there is no preview-only filter path.

Animated or interactive wallpaper rendering is a separate future runtime. It
may reuse this graph as a preprocessing or shader contract, but it does not
change the static Look transaction, macOS wallpaper-store ownership, or
rollback model.

## Global Look and Space awareness

A Livery Look is global. Its semantic theme is shared by Ghostty, SketchyBar,
and borders, and its wallpaper covers every managed desktop Space. Space
awareness means complete transactional coverage, not independent application
themes that change during navigation.

`--colors-only` is an explicit transaction scope that deliberately leaves the
wallpaper unchanged; it does not mutate or mislabel the resolved Look.
Per-Space wallpaper variation is outside the initial model; a future
coordinated wallpaper family may add it without making application themes
change on every Space transition.

Numeric Space indices are not durable identity. The wallpaper engine must
reconcile yabai Space UUIDs, display UUIDs, and the current macOS wallpaper
topology. New Spaces inherit the active Look; reconnected displays are
reconciled; deleted Space records may remain in history for recovery.

## First adapters

- Ghostty receives semantic terminal background/foreground/cursor/selection
  values plus an ANSI palette derived from Base16.
- SketchyBar receives UI roles for glass surfaces and accents, locked signal
  roles for state, the existing alpha policy, and bar-only colors adjusted
  against the wallpaper crop. Popup roles remain tied to their own dark glass
  surface rather than the desktop.
- borders receives the primary accent, with inactive alpha preserved as an
  effect.

The adapters stage beneath `build/<profile>/`. Ghostty validates its config
with `+validate-config`; SketchyBar Lua is checked with `luac`; the borders
command is checked against a strict argument shape.

## Live runtime and transaction

Validated profiles are installed immutably beneath
`~/.config/livery/profiles/<name>-<manifest-hash>/`. The `current` and
`previous` symlinks are replaced atomically; stable loaders in Ghostty,
SketchyBar, and yabai follow `current`. `default` is also retained as a stable
fallback pointer.

An apply performs the following transaction:

1. resolve and validate the v2 LookSpec and LookManifest;
2. render and validate every enabled target in staging;
3. install the spec, manifest, adapters, and wallpaper artifact as one
   immutable runtime profile;
4. atomically switch `current` while retaining the old target as `previous`;
5. set the resolved wallpaper artifact across all managed desktop Spaces, then reload
   Ghostty and SketchyBar and update the running borders process;
6. restore the old pointer, live targets, and pre-transaction wallpaper if any
   required target fails.

Ghostty's config includes the current runtime file optionally and retains its
original Catppuccin theme as a fallback. Ghostty's macOS runtime handles
`SIGUSR2` as an application-wide configuration reload, which Livery sends after
swapping the runtime pointer. `cmd+shift+,` remains a manual fallback.
Rollback swaps `current` and `previous`, making repeated comparison reversible.
Reapplying the active profile repairs convergence without rotating the rollback
pointer.

The native lab's preview shells out to `liveryctl render`, reads the resolved
manifest, and displays its exact wallpaper artifact. Apply shells out to
`liveryctl apply`. The panel therefore has neither a second renderer nor a
second transaction implementation. In theme-authoritative mode the theme and
target wallpaper selectors are independent. The original/graded comparison
toggles between the untouched input image and that exact rendered artifact,
not a UI approximation.

The panel records the frontmost application before becoming key and restores it
when dismissed. This is required for focus-follows-mouse setups: ordering out an
accessory panel without deactivating it leaves no mouse-enter transition for
the already-under-cursor window. The panel uses transient `canJoinAllSpaces`
behavior and unconditional front ordering; it is hidden rather than parked on
a particular Space, so one toggle always presents it on the active Space.

The launcher serializes cold starts with a per-user lock. The application
publishes its PID only after the panel and event handlers exist. Running
toggles use LaunchServices' reopen event rather than a Unix signal, allowing
macOS to grant foreground activation after Livery has returned to accessory
status. If old duplicate processes exist, the ready instance is retained and
the rest are terminated.

Livery retains the untouched generator output in `terminal.base16` and maps it
to ANSI order without rewriting the shared foreground/background slots.
Ghostty's renderer floor covers ANSI, truecolor, and 256-color foregrounds
selected by applications while leaving background colors unchanged. Ghostty
1.3.1 replaces a foreground below the floor with whichever of black or white
has greater contrast; block-drawing glyphs can opt out to preserve terminal
graphics.

Wallpaper remains a separate adapter inside the coordinated transaction, but
it is not an independently scoped default action. `--colors-only` is an
explicit manual override. Before the first managed Look, Livery captures the
complete wallpaper topology and opaque macOS store as recovery evidence;
rollback restores that topology rather than a single visible-screen URL.
Generated wallpaper derivatives retain their original source provenance.

The wallpaper engine uses AppKit only to ask WallpaperAgent to generate a valid
private image-provider payload. Because `NSScreen` describes visible displays
rather than every hidden desktop Space, the engine then promotes that generated
payload to `AllSpacesAndDisplays`, clears Space/display overrides, restarts
WallpaperAgent, and verifies global convergence. It never fabricates provider
configuration data.

Before every apply—including a colors-only manual override—Livery snapshots the
complete wallpaper store into immutable, content-addressed history. Apply
records the before and after snapshots alongside the theme pointers. Rollback
restores and swaps both pairs, so captured Apple aerial/dynamic state and custom
image state remain exactly reversible.

## SketchyBar legibility

Generated Looks sample the top 40-point wallpaper band after aspect-fill
cropping for every connected display. The analyzer compares the theme's light
text with its dark background role using the tenth-percentile WCAG contrast,
chooses the stronger polarity, and requires 4.5:1. If neither polarity clears
that threshold, it computes the smallest black or white global scrim that does.

Muted, accent, and semantic signal colors use a 3:1 lower-decile target. Colors
that already pass remain unchanged; failing colors move only as far toward the
selected foreground as needed. These adjusted colors are scoped to the open bar.
Popups continue using the unmodified palette on their controlled surface.

The result is stored in the immutable Look manifest, so applying a Look does not
recalculate or flicker during Space changes. A new render on a materially
different display topology may produce a new content-addressed profile.
