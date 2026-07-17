# Repose ecosystem survey — what's worth taking

2026-07-16. Three research lanes over the configs where this genre lives:
the Quickshell/QML shell ecosystem, Linux lock/idle screens and desktop
widgets, and macOS desktop-layer/ambient software. Findings filtered
against the book test, the zephyr language, and the no-blending rule.

## Adopted into the mockup harness now

- **Centered monolith is the genre's answer** — every curated hyprlock
  pack ([MrVivekRajan/Hyprlock-Styles](https://github.com/MrVivekRajan/Hyprlock-Styles),
  [mahaveergurjar/Hyprlock-Dots](https://github.com/mahaveergurjar/Hyprlock-Dots)),
  caelestia's lock, and noctalia converge on one vertical axis: date over
  clock, everything else demoted to a footer. Corner layouts survive only
  on desktop widgets that must coexist with windows — repose owns the
  screen, so center wins. The harness's center layout is now this
  monolith, with the visualizer as full-bleed foot terrain (the canonical
  [GLava](https://github.com/jarcode-foss/glava) `--desktop` placement:
  bottom strip, edge-anchored, behind the type).
- **Grade, don't blur** (`s` → grade) — the best hyprlock styles ship
  `blur_passes = 0` with a color-grade (`contrast .89 · brightness .82 ·
  desaturate`) plus vignette
  ([swaylock-effects](https://github.com/mortie/swaylock-effects)
  `--effect-vignette`): the wallpaper stays recognizable, luminance funnels
  toward the composition. More Livery-compatible than any scrim.
- **Odometer polish** — from [qylock](https://github.com/Darkkal44/qylock)
  clockwork and [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)'s
  lock clock: fixed-width digit slots so the composition never jiggles,
  and read-line emphasis (settled digit full opacity, passing digits
  dimmed during the roll).
- **StandBy night tint** (`n`) — Apple StandBy re-renders the whole scene
  in one red monochrome tint at night instead of merely dimming: layout
  and hierarchy survive, color contrast dies. One compositing filter in
  production (`CALayer` filter over the scene host).

## For the vertical slice (motion / native, can't mock in HTML)

- **Smoothstep pre-roll** (qylock `clockwork/tape`): the minute reel
  eases into position during the last 0.2s of second 59
  (`p*p*(3-2*p)`), arriving exactly on the boundary. The reference math
  for the Swift odometer.
- **Settle-and-park** (caelestia `Visualiser.qml`): when audio goes
  quiet the bars decay to flat and the render loop *stops*; slide/fade
  off when hidden. The visualizer's idle contract — zero CPU at rest.
- **Separate analysis from rendering** (caelestia `Audio.qml`): its visible
  background bars consume a `libcava` provider, while a separate
  [Aubio-backed beat tracker](https://github.com/caelestia-dots/shell/blob/main/plugin/src/Caelestia/Services/beattracker.cpp)
  reads raw PCM. Source inspection corrected the earlier survey claim: the
  beat tracker currently paces the dashboard media GIF, not the background
  bars. The transferable idea is the boundary, not a Caelestia pacing recipe:
  one analysis service, renderers as replaceable views.
- **Entrance choreography** ([Dejal Time Out](https://www.dejal.com/timeout/),
  swaylock-effects `--fade-in`): dim the screen first, then fade the
  scene in over 1–2s — invocation reads as the room's lights going down.
  Exit reverses it (caelestia scales content down while the desktop fades
  back).
- **Plaque made of wallpaper**: caelestia samples and blurs the exact
  wallpaper rect behind its desktop clock; on macOS,
  `NSVisualEffectView(.behindWindow)` gives the same "frosted wallpaper,
  not painted chrome" plaque nearly free. Worth one A/B against the solid
  Material chips in Swift.
- **Two-tone role digits** (caelestia `DesktopClock.qml`): hours
  `primary`, minutes `secondary`, colon `tertiary` — palette does the
  hierarchy before size does. An alternative to darkness-graduated chips
  if they ever feel heavy.

## Validations (existing choices confirmed by the survey)

- **The element set is right**: the Übersicht ecosystem's long-lived
  widgets are exactly clock, now-playing, and actionable status —
  decorative full-desktop compositions get built, screenshotted, and
  abandoned. E-ink dashboard projects converge on the same tiny budget.
- **Media restraint**: StandBy shows only a small audio-levels presence
  while music plays; the full media view must be summoned. The visualizer
  *is* the presence indicator — no media card, conditional render
  (Regulus conky: the Spotify block simply doesn't exist when silent).
- **No quotes/greetings**: across curated lock packs, the only "voice"
  text that survives is text that is true right now (song title, status).
  Static aphorisms read as kitsch.
- **Scale as the one tunable** ([Fliqlo](https://fliqlo.com/)'s twenty-year
  lesson): one dominant object, user-scalable, dimmable — and every
  ornament gets an off switch.
- **Padbury check**: the two clocks people keep for decades (Fliqlo,
  Padbury) have zero container chrome. The chipless floating/composed
  modes stay one keystroke away from the plaques for a reason.

## Rejected

- Three-column lock dashboards (caelestia's weather/stats side columns) —
  reads as dashboard, not repose.
- Film-sprocket/orbital theatrical clock themes (qylock) — steal the
  math, not the dressing.
- Quote lines, weather, greeting text.
- Neon-card music widgets (eww's most-starred style) — the anti-pattern
  the gaudy verdict already named.

Full agent findings with per-item sources live in the session transcripts;
the load-bearing sources are linked inline above.
