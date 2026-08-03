# Fresco

A native macOS desktop-layer runtime for images and Wallpaper Engine video and
web wallpapers. Fresco renders one window per display and provides the
Wallpaper Engine JavaScript API to web projects. Scene (`.pkg`) wallpapers are
rendered by a separately licensed, supervised `fresco-scene` helper. The
accepted scene subset is a corpus-bounded 2D runtime for images, particles and
child systems, effects and effect quads, custom shaders, text and text effects,
SceneScript, media and video textures, 2D puppets, and package sound. Native
OpenGL 4.1 is the default backend; ANGLE-on-Metal is the opt-in comparison
backend. QuickJS exposes only corpus-proven surfaces and fails closed on
unclassified APIs and source shapes.

GBC Subaru, Arknights, and Lonely Cat are available. Elaina, Hyuga Ghost, and
Persona 3 Reload remain `reach`. GBC's bounded five-bone secondary motion
passes on native OpenGL and ANGLE-on-Metal. Lonely Cat passes its default
English composition, clock, fixed-pitch font fallback, audio bars, particle
children, image-parent, lifecycle, and performance gates on both backends.
Arknights passes its script, property, sound, image-parent, and three-particle
gates; its remaining cover crop is authored. Elaina, Hyuga, and Persona retain
their documented visual and configuration blockers.
Model, light, volume-light, broader camera, active IK, and 3D behavior remain
outside the supported runtime.

## Run

Foreground (development):

```sh
./run                                  # the bundled aurora shim-test wallpaper
./run ~/path/to/some-wallpaper-folder  # a WE project folder (project.json)
./run ~/path/to/loop.mp4               # a bare video file
./run ~/Pictures/still.jpg             # a static image
```

Ctrl-C stops it and the desktop returns to the static wallpaper. The
window sits just below the desktop icons (Plash-style), joins all
Spaces, ignores the mouse, and is invisible to yabai.

Daemon (daily driver):

```sh
./fresco set 3208430444                # workshop id (fetches if needed) or path;
                                       # starts the daemon, or hot-swaps via SIGUSR1
./fresco mute                          # toggle global audio (also control-option-M)
./fresco mute on | mute off | unmute   # explicit persistent audio policy
./fresco status | stop | restart
./fresco audio-permission              # show the stable app to grant once
./fresco install-agent                 # launchd: start at login, KeepAlive
```

State lives in `~/.config/fresco/` (`state.json`, disposable `status.json`,
the compatibility `current` projection, `properties/`, `pid`, `log`, and the
compiled `bin/fresco`); `fresco` recompiles
automatically when the source is newer than the binary. Daily-driver starts run
that mutable worker beneath `~/Applications/Fresco.app`, a frozen host with
bundle ID `local.vestiary.fresco`. Grant that app
Screen & System Audio Recording once. Normal worker rebuilds never rewrite or
re-sign the host, so its TCC identity and permission remain stable. The host is
only replaced if it is missing or its signature is invalid.

### TCC identity

Host app `~/Applications/Fresco.app` (note: user-level `~/Applications`),
bundle id `local.vestiary.fresco`, launchd label `local.fresco`, host binary
`fresco-host`, worker `bin/fresco`. The System Audio Recording grant is
anchored to the bundle id + signature; `build_host` preserves the exact bits,
so only a deliberate identity change needs a re-grant. Procedure: stop
everything, change identity, rebuild, then add `~/Applications/Fresco.app` in
System Settings → Privacy & Security → Screen & System Audio Recording (Audio
Only suffices; the entry is kTCCServiceAudioCapture, which manual + adds
create via the per-app mode dropdown), then `fresco restart`.

## What's implemented

- **Per-display desktop windows** — video via `AVPlayerLooper`
  (aspect-fill, muted), images via an aspect-fill Core Animation layer, and web
  via `WKWebView` with
  `allowFileAccessFromFileURLs` so WebGL wallpapers can load their local
  textures.
- **WE JS API shim** (injected at document start):
  `wallpaperRegisterAudioListener` receives 64 frequency bands per stereo
  channel from a 128-bar Cava system tap at 30 fps. The daemon preflights
  capture access without prompting. It sends silence when Cava or permission
  is unavailable. It never opens System Settings from the background.
  `wallpaperPropertyListener` uses WE's registration semantics: a
  setter trap applies pending properties after page initialization and
  immediately when registration happens late behind an async CDN import
  (SoundDancer does this). The bridge also supplies general FPS settings,
  pause notifications, `fetchall` directory events, and on-demand random-file
  callbacks. Empty file/text placeholders are never applied. Broken-image
  placeholders are hidden to match the CEF/Chromium behavior these wallpapers
  expect.
- **Per-wallpaper property overrides**: versioned target records under
  `~/.config/fresco/properties/` persist every documented editable type.
  `fresco property` exposes localized labels, options, display-condition state,
  typed set/reset operations, and current values. Scalar changes are delivered
  live as changed-only events. File and directory changes rebuild the web hosts
  because WebKit fixes local read access at navigation time. Selections are
  exposed through a temporary scoped tree containing the project and selected
  files. WebKit never receives a broad home-directory read grant.
  `properties.local.json` remains a project-level compatibility sidecar below
  preset and persisted target values; SoundDancer uses one for its stock colors.
  Scene projects use the same records and precedence. The scene runtime applies
  package-declared numeric sound-volume bindings and corpus-classified
  SceneScript property callbacks. Unclassified bindings remain persisted but
  are reported as unsupported. Scene presets are not yet supported.
- **Page diagnostics**: `window.onerror`, unhandled rejections, and shim
  errors are forwarded to the runtime's stdout as `page: …` lines. The console
  includes the source location and available JavaScript stack.
- **WE media integration**: all five `wallpaperRegisterMedia*Listener`
  APIs (status, properties, thumbnail, playback, timeline) fed from
  `media-control` — now-playing title/artist/album, playback state,
  a 1s interpolated timeline, and album art as a data-URL thumbnail with
  artwork-derived colors (`primaryColor`/`textColor`/
  `highContrastColor` per the WE contract). Listeners registered late
  replay the last payload, matching WE. Unlocks "(+Media Integration)"
  Workshop wallpapers; the aurora sample shows a track line + cover and
  tints its ribbons from the artwork.
- **Livery bridge**: the current Look's `ui` roles are merged over the
  project's default properties — `schemecolor` (WE community convention)
  gets `ui.primary`, and `liveryprimary/-secondary/-tertiary/-surface/
  -text` carry the full set. The manifest is watched; applying a Look
  rethemes the wallpaper within ~3s.
- **Input forwarding**: a global mouse monitor dispatches coordinate-mapped
  move, drag, button, click, context-menu, and wheel events into the page.
  Button and wheel events are sent only when no application window covers the
  pointer, so wallpapers do not react through foreground applications.
- **Occlusion-pause**: `NSWindow.occlusionState` pauses video playback
  and notifies and hides web views when the wallpaper is fully covered.
  Web-only audio, media, input, and theme services stop when the last web host
  closes.
- **Crash-isolated 2D scene runtime**: one GPL-3.0 helper per display owns its
  AppKit desktop window and OpenGL context. Fresco validates the package and
  user-owned official assets before `load`, retains the Workshop preview until
  a completed draw reports `ready`, and restores that preview if the helper
  exits. Model and light objects are rejected before window creation.

## Testing without Steam

`./tests/validate.sh` compiles the release worker and runs the bridge, property,
audio-layout, render-audit, agent-feed, host, and Workshop-ingestion checks. It
also builds and runs the standalone scene-helper protocol and package tests.
When the local official assets and Workshop corpus are present, the same gate
builds the renderer and runs the baseline and stretch corpus, explicit
unsupported variants, lifecycle, restart, visibility, property, media, sound,
particle, puppet, and 30 and 60 FPS gates.

## Scene asset prerequisite

Scene rendering requires the `assets` directory from a user-owned Wallpaper
Engine installation. Fresco validates and stores its path without copying it:

```sh
./fresco scene-build
./fresco scene-assets validate /path/to/wallpaper_engine
./fresco scene-assets set /path/to/wallpaper_engine/assets
./fresco scene-assets
```

The validator accepts either the installation directory or its `assets`
directory. It checks the built-in shaders used by the pinned 2D corpus and the
first particle texture. The canonical path is stored in
`~/.config/fresco/scene-assets`. `scene-assets clear` removes only that setting.
`scene-build` requires CMake, Git, pkg-config, LZ4, and FreeType. Its first
renderer build fetches the exact upstream revisions recorded in
`fresco-scene/THIRD_PARTY.md`.

The measured 14-wallpaper scene corpus can be added to Livery after its
Workshop packages are installed:

```sh
./fresco scene-samples
```

The command extracts representative PNGs from the installed previews and is
safe to repeat. Samples marked `available` or `reach` retain a reference to the
installed live package. Samples marked `not yet possible` remain still-image
references because they cross the current 3D boundary. The command requires
ffmpeg and all packages named by `tests/scene-fixtures.json`.
Rerun it after fixture-status changes; reimport updates existing Livery records.

## Editing project properties

```sh
./fresco property list
./fresco property get showDate
./fresco property set showDate false
./fresco property reset showDate
./fresco property 1081733658 set background_enable true
./fresco property 1081733658 describe   # full JSON schema and presentation
```

The current wallpaper is the default target. An id or path before the action
edits another installed target without applying it. Boolean, slider, color,
combo, text-input, file, and directory values are validated before the state
record is written. `list` marks conditionally hidden controls inactive and uses
the best manifest localization for the current macOS language. Scene controls
without an implemented runtime binding are marked unsupported.

## Auditing web wallpapers

```sh
./fresco audit                 # current wallpaper
./fresco audit 3380416096      # one or more Workshop ids or paths
./fresco audit all             # every installed web item and web preset
```

An audit renders each target in its own offscreen worker and writes a JSON
report plus a PNG snapshot under `~/.config/fresco/audits/<timestamp>/`.
It does not rewrite `current`, signal the daemon, or replace the visible
wallpaper. Missing active property assets, required local visual or code
resources, navigation failures, transparent output, and WebKit process failure
are hard failures. Authored page errors, optional media failures, inactive stale
paths, and opaque uniform frames are warnings retained for review. The command
returns nonzero only when at least one target has a hard failure.

See [`PARITY.md`](./PARITY.md) for the current Wallpaper Engine gap map, phase
order, and review gates.

[`samples/aurora-web/`](./samples/aurora-web/) is a WE-compatible web
wallpaper written for this runtime: three audio-swelled, cursor-
parallaxed aurora ribbons colored by `schemecolor`/`livery*` properties.
Its status line (bottom-left) reports which bridge features are live;
`props:livery · audio:live` means every bridge feature is up. It also runs in a
plain browser (bridge-guarded) for quick visual checks.

## Real WE wallpapers without Steam

`./fetch-samples` clones three author-published, ready-to-run WE web
wallpapers from their own GitHub repos (their sanctioned distribution —
no workshop mirrors):

- `samples/third-party/SoundDancer` — WebGL audio-reactive trails
- `samples/third-party/Audio-responsive-wallpaper` — audio bars +
  particles, exercises user properties
- `samples/third-party/Poly-Wallpaper` — shader-based visualizer

Plus `samples/gradient-loop.mp4`, generated locally with ffmpeg, for the
video path. [hexxone/audiorbits](https://github.com/hexxone/audiorbits)
(GPLv3, the best-known open WE wallpaper) needs a TypeScript build;
worth trying once the three above work.

## Workshop content — the `workshop` client

One-time setup: own Wallpaper Engine on Steam, `brew install steamcmd`,
log in once (`steamcmd +login <user> +quit` in a real terminal — it
prompts for password + Steam Guard, then caches), and put the username in
`.steam-user` (or `$STEAM_USER`). Then:

```sh
./workshop gallery                       # THE browse surface: live local app —
                                         # search, animated previews, click-to-apply
                                         # (hot-swaps via fresco), current
                                         # wallpaper highlighted
./workshop search "audio visualizer"     # CLI search; --type video|scene|all
./workshop browse "clock"                # static HTML gallery (no server)
./workshop info 3208430444               # title, size, tags, page link
./workshop run 3208430444                # download (cached login) + launch foreground
```

The gallery is the interim browse surface and interaction prototype for
the future Livery panel Workshop tab.

The panel and CLI call the repository's `livery/liveryctl` directly during
ingestion. They do not depend on `~/.local/bin` being present in an application
process's `PATH`.

## Wallpaper → theme

```sh
./workshop theme 3419679793
livery apply "wallpaper:codetime:content" --colors-only
./fresco set 3419679793
```

`theme` extracts a representative frame — for video, ffmpeg's
`thumbnail` filter ~40% in; for web/scene, scanned from the Workshop
preview — and ingests it via `livery import-wallpaper` with Workshop
provenance as the credit. Livery's machinery handles the rest: three pinned
matugen palettes, `wallpaper:<id>:<scheme>` profiles, full transactional
apply. Low-res preview-derived frames get a
`--colors-only` recommendation (palette yes, stretched static wallpaper
no — the live layer covers the desktop anyway). The
runtime then pushes the derived theme's roles back into the wallpaper as
`schemecolor`, so the wallpaper is recolored by the theme it generated.

Search is keyless (public browse page for IDs + keyless details API for
titles/tags/sizes); set `STEAM_API_KEY` for the QueryFiles
backend. Downloads land under `~/Library/Application
Support/Steam/steamapps/workshop/content/431960/<id>/`. Web and video items
play. Scene packages download and can be inspected by the standalone helper,
but Fresco does not select them for rendering yet.

## Upstream note

The shim (bootstrap script + audio bridge + property push) is
deliberately self-contained so it can be offered upstream to
[Unayung/wallpaper-engine-mac](https://github.com/Unayung/wallpaper-engine-mac)
/ [MrWindDog/wallpaper-engine-mac](https://github.com/MrWindDog/wallpaper-engine-mac)
even if this runtime stays independent. The Livery bridge stays ours
either way.

## Repose interplay

The Repose cover host's transparent-backdrop mode shows this layer through the
cover. Images and live wallpapers remain visible beneath the composition.
During Repose, cursor forwarding keeps web wallpapers reactive while the cover
swallows clicks.

The scene directory is the catalog, while `repose.json.scenePool` is the
ordered rotation. Missing `scenePool` means every catalog scene in the legacy
sorted order. The Livery panel toggles membership and drag order; in-cover
left/right keys cycle only that list. Exclusion never deletes a scene.

`fresco repose-add <path-or-id>` symlinks a source into the catalog and
appends it to the rotation. An explicit pool filters the catalog, so a scene
that only reached the directory stayed unreachable from both pickers. The link
keeps the source's extension, which is what the catalog matches loose video
files on.

`repose.json.viz` selects the composition's audio renderer. `strings` keeps
the frozen 10-band Zephyr geometry; `spectrum` uses 24 frequency groups mirrored
around the center (bass inward, treble outward). Both share the same rolling
normalization and attack/release model, settle and park in silence, and react to
quiet/loud placement independently of the selected Look. In-cover `b` cycles
the renderer; `fresco repose-viz strings|spectrum` is the external editor.
