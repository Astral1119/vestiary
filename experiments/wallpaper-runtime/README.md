# wallpaper-runtime — phase-1 live wallpaper for macOS

A lean, single-file implementation of phase 1 from
[`FEASIBILITY.md`](./FEASIBILITY.md): Wallpaper Engine **video** and
**web** wallpapers rendered at the desktop layer, per display, with the
WE JavaScript API shimmed natively. Scene (.pkg) wallpapers are phase 2
and not supported here.

## Run

Foreground (development):

```sh
./run                                  # the bundled aurora shim-test wallpaper
./run ~/path/to/some-wallpaper-folder  # a WE project folder (project.json)
./run ~/path/to/loop.mp4               # a bare video file
```

Ctrl-C stops it and the desktop returns to the static wallpaper. The
window sits just below the desktop icons (Plash-style), joins all
Spaces, ignores the mouse, and is invisible to yabai.

Daemon (daily driver):

```sh
./wallpaperctl set 3208430444          # workshop id (fetches if needed) or path;
                                       # starts the daemon, or hot-swaps via SIGUSR1
./wallpaperctl status | stop | restart
./wallpaperctl install-agent           # launchd: start at login, KeepAlive
```

State lives in `~/.config/wallpaper-runtime/` (`current`, `pid`, `log`,
and the compiled `bin/wallpaper-runtime`); `wallpaperctl` recompiles
automatically when the source is newer than the binary.

## What's implemented

- **Per-display desktop windows** — video via `AVPlayerLooper`
  (aspect-fill, muted), web via `WKWebView` with
  `allowFileAccessFromFileURLs` so WebGL wallpapers can load their local
  textures.
- **WE JS API shim** (injected at document start):
  `wallpaperRegisterAudioListener` fed 128-sample frames from a 64-bar
  Cava system tap at 30 fps (falls back to silence when cava is absent);
  `wallpaperPropertyListener` implemented with WE's real semantics — a
  setter trap applies pending properties the moment the page registers
  its listener, even when registration happens late behind an async CDN
  import (SoundDancer does this). Empty file/text placeholders are never
  applied. Broken-image placeholders are hidden to match CEF/Chromium,
  the engine wallpapers were written for.
- **Per-wallpaper property overrides**: `properties.local.json` next to
  `project.json` stands in for WE's property UI — plain
  `{"key": value}` pairs merged over project defaults (SoundDancer ships
  one here; its stock trail colors are near-black).
- **Page diagnostics**: `window.onerror`, unhandled rejections, and shim
  errors are forwarded to the runtime's stdout as `page: …` lines — when
  a wallpaper misbehaves, the console names the missing API or failed
  fetch.
- **WE media integration**: all five `wallpaperRegisterMedia*Listener`
  APIs (status, properties, thumbnail, playback, timeline) fed from
  `media-control` — now-playing title/artist/album, playback state,
  a 1s interpolated timeline, and album art as a data-URL thumbnail with
  dominant-color extraction (`primaryColor`/`textColor`/
  `highContrastColor` per the WE contract). Listeners registered late
  replay the last payload, matching WE. Unlocks "(+Media Integration)"
  Workshop wallpapers; the aurora sample shows a track line + cover and
  tints its ribbons from the artwork.
- **Livery bridge**: the current Look's `ui` roles are merged over the
  project's default properties — `schemecolor` (WE community convention)
  gets `ui.primary`, and `liveryprimary/-secondary/-tertiary/-surface/
  -text` carry the full set. The manifest is watched; applying a Look
  rethemes the wallpaper within ~3s.
- **Cursor forwarding**: a global mouse-moved monitor dispatches
  synthetic `mousemove` events into the page (per display, coordinate-
  mapped), so parallax wallpapers react even though the window itself
  never receives events.
- **Occlusion-pause**: `NSWindow.occlusionState` pauses video playback
  and mutes the audio push when the wallpaper is fully covered — no
  battery tax while working.

## Testing without Steam

[`samples/aurora-web/`](./samples/aurora-web/) is a WE-compatible web
wallpaper written for this runtime: three audio-swelled, cursor-
parallaxed aurora ribbons colored by `schemecolor`/`livery*` properties.
Its status line (bottom-left) reports which bridge features are live —
`props:livery · audio:live` is full marks. It also runs in a plain
browser (bridge-guarded) for quick visual checks.

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
(GPLv3, the best-known open WE wallpaper) needs a TypeScript build —
worth trying once the simple three behave.

## Workshop content — the `workshop` client

One-time setup: own Wallpaper Engine on Steam, `brew install steamcmd`,
log in once (`steamcmd +login <user> +quit` in a real terminal — it
prompts for password + Steam Guard, then caches), and put the username in
`.steam-user` (or `$STEAM_USER`). Then:

```sh
./workshop gallery                       # THE browse surface: live local app —
                                         # search, animated previews, click-to-apply
                                         # (hot-swaps via wallpaperctl), current
                                         # wallpaper highlighted
./workshop search "audio visualizer"     # CLI search; --type video|scene|all
./workshop browse "clock"                # static HTML gallery (no server)
./workshop info 3208430444               # title, size, tags, page link
./workshop run 3208430444                # download (cached login) + launch foreground
```

The gallery is the interim for — and interaction prototype of — the
future Livery panel Workshop tab (FEASIBILITY.md stage 4).

## Wallpaper → theme

```sh
./workshop theme 3419679793
livery apply "wallpaper:codetime:content" --colors-only
wallpaperctl set 3419679793
```

`theme` extracts a representative frame — for video, ffmpeg's
`thumbnail` filter ~40% in; for web/scene, scanned from the Workshop
preview — and ingests it via `livery import-wallpaper` with Workshop
provenance as the credit. Livery's existing machinery does the rest:
three pinned matugen palettes, `wallpaper:<id>:<scheme>` profiles, full
transactional apply. Low-res preview-derived frames get a
`--colors-only` recommendation (palette yes, stretched static wallpaper
no — the live layer covers the desktop anyway). Loop closure: the
runtime then pushes the derived theme's roles back into the wallpaper as
`schemecolor` — the wallpaper is recolored by the theme it generated.

Search is keyless (public browse page for IDs + keyless details API for
titles/tags/sizes); set `STEAM_API_KEY` for the richer QueryFiles
backend. Downloads land under `~/Library/Application
Support/Steam/steamapps/workshop/content/431960/<id>/`. Web and video
items play; scene (.pkg) items download fine but need phase 2 (see
FEASIBILITY.md — the linux-wallpaperengine port path), and `info` warns
about them.

## Upstream note

The shim (bootstrap script + audio bridge + property push) is
deliberately self-contained so it can be offered upstream to
[Unayung/wallpaper-engine-mac](https://github.com/Unayung/wallpaper-engine-mac)
/ [MrWindDog/wallpaper-engine-mac](https://github.com/MrWindDog/wallpaper-engine-mac)
even if this runtime stays independent. The Livery bridge stays ours
either way.

## Repose interplay

The repose cover host's transparent-backdrop mode (see
[`../desktop-scenes/HANDOFF.md`](../desktop-scenes/HANDOFF.md)) shows
this layer through the cover: the live wallpaper becomes the star,
repose the stage lighting. During repose, cursor forwarding keeps the
wallpaper reactive while the cover swallows clicks.
