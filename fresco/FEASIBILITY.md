# Wallpaper Engine wallpapers on macOS — feasibility note

2026-07-16. Question: what would it take to run Wallpaper Engine
(Steam Workshop) wallpapers on macOS, with animation and interactivity,
as the live layer beneath the bar and the repose scene?

## Format reality

Wallpaper Engine content is four formats with very different costs:

| Format | Share of Workshop | macOS state |
|---|---|---|
| Video (mp4/webm) | large | **Solved** — existing open app plays per-display |
| Web (HTML/JS/WebGL) | most *interactive* ones | **Mostly working**; WE JS API needs shimming |
| Scene (.pkg, native engine) | majority overall | **Gap** — static layers only on macOS today |
| Application (Unity exe) | small | Never (Windows executables) |

## Existing bridges

- [Unayung/wallpaper-engine-mac](https://github.com/Unayung/wallpaper-engine-mac)
  (patched fork of [MrWindDog/wallpaper-engine-mac](https://github.com/MrWindDog/wallpaper-engine-mac),
  Swift, GPL-3.0): video ✓, web ✓ (local-texture WebGL fixes), scene =
  static image layers via SpriteKit (no shaders, particles, parallax,
  DXT, or audio scripting). Steam Workshop browse/download via steamcmd,
  per-display assignment, persists across Spaces. ~39 stars, active-ish.
- [Almamu/linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine)
  (C++/OpenGL): the mature scene renderer — PKGV/TEXV parsing, HLSL
  shader translation, particles, audio response, mouse parallax. No
  macOS backend; a port means a desktop-level NSWindow GL (or ANGLE →
  Metal) output surface and PulseAudio → Core Audio tap.
- [Official position](https://help.wallpaperengine.io/en/functionality/linuxmacos.html):
  no macOS support. Workshop content requires owning WE on Steam;
  steamcmd fetches items cross-platform.

## macOS-native advantages

- **Occlusion is free**: `NSWindow.occlusionState` reports when the
  desktop-level window is fully covered → pause rendering, no battery
  tax during work. (This was the hard problem for an always-on layer;
  the platform solves it.)
- Desktop-level windows are routine (Plash, Cadran precedent), invisible
  to yabai, behind icons.
- The Core Audio system tap already exists in this lab
  (zephyr-strings) — the WE `wallpaperRegisterAudioListener` shim is a
  thin bridge over it.

## Stack synergies

- **WE wallpapers as Livery adapters**: Workshop wallpapers commonly
  expose user properties, including color properties (`schemecolor`
  convention). A property bridge (web: `wallpaperPropertyListener`;
  scene: shader uniforms) lets a Look apply retheme the live wallpaper —
  Livery roles driving third-party animated scenes.
- **Repose layering**: the repose cover host gains a *transparent
  backdrop* mode — the live wallpaper shows through from desktop level;
  repose draws type/dots/grade veil above, swallows clicks, and forwards
  cursor position via the bridge so the wallpaper keeps reacting while
  input stays captured. Optional "performance" property push on entry
  (boost audio-react), restored on exit. The live wallpaper becomes the
  star; repose becomes its stage lighting.

## Status

**Phase 1 validated 2026-07-16**: all three third-party WE web wallpapers
(SoundDancer, Audio-responsive-wallpaper, Poly-Wallpaper — spanning WebGL
trails, particles, shaders, user properties, and an async CDN import) run
with live audio response, plus the bundled aurora and a generated video
loop. Remaining known risks are per-wallpaper API gaps on untested
Workshop content, surfaced as `page:` diagnostics.

Phase 1 is implemented in this directory as a single-file runtime
([`WallpaperRuntime.swift`](./WallpaperRuntime.swift), see
[`README.md`](./README.md)): video + web wallpapers, WE JS API shim over
the Cava tap, Livery property bridge, cursor forwarding, occlusion-pause.
A bundled WE-compatible test wallpaper
([`samples/aurora-web/`](./samples/aurora-web/)) validates the shim
without Steam.

## Recommended phases

0. **Zero code**: install the existing fork, run one video + one
   interactive web wallpaper for a few days. Validate appetite.
1. **Lean runtime (or upstream contributions)**: video + web, WE JS API
   shim (audio via the existing tap), Livery property bridge,
   occlusion-pause, cursor forwarding. Delivers animated + interactive +
   theme-coherent without touching the scene format.
2. **Scene support** (decide after living with 1): port
   linux-wallpaperengine's renderer behind a macOS output backend. The
   format/shader work is done and GPL'd; the port is the surface, audio,
   and input backends.

Repose is unblocked regardless: the transparent-backdrop hook is a
constructor flag on the cover host, not a design change.

## Livery integration path (staged; agreed worth pursuing 2026-07-16)

The custody question resolves by making the runtime **a Look adapter
inside Livery's transaction**, not a competing owner. Stages:

1. **Browse surface (now)**: `./workshop browse` — a generated local
   gallery themed with the current Look, animated Workshop previews,
   one-command run lines. Pure acquisition UX; no Livery changes.
2. **Library-level ingest** — *first half shipped 2026-07-16 as
   `workshop theme <id>`*: representative frame (ffmpeg `thumbnail`
   filter; video content or Workshop preview) → `livery
   import-wallpaper` with Workshop provenance as credit → pinned matugen
   schemes and resolvable `wallpaper:<id>:<scheme>` profiles, all
   through Livery's public CLI with zero Livery code changes. Every
   Workshop item yields a working Look; low-res preview frames are
   flagged for `--colors-only`. Remaining for stage 2 proper: ingesting
   the *item folder* content-addressed (steamcmd overwrites on update),
   live WKWebView snapshots as a higher-fidelity frame source for web
   items, and structured provenance rather than a credit string.
3. **Live wallpapers as first-class Looks — shipped 2026-07-16.**
   `import-wallpaper --live <path>` stores the payload on the record; it
   flows into `manifest.liveWallpaper` for wallpaper-authoritative
   profiles; `apply` (look scope) points the runtime via `fresco
   set`, static Looks clear it, rollback and failure paths restore.
   `workshop theme <id>` wires all of it automatically, so:
   `./workshop theme <id>` → `livery apply "wallpaper:<id>:content"` is
   the complete flow — Look derivation, system retheme, live layer, and
   the runtime pushing the derived roles back into the wallpaper.
   Remaining: theme-authoritative profiles (`theme:…@source:recipe`)
   don't carry live yet; content-addressed ingest of the item folder;
   live WKWebView snapshots as a better frame source.
4. **Panel Workshop tab**: the panel already *shows and applies* live
   entries with zero changes (records decode, apply shells liveryctl) —
   what remains is in-panel Workshop search/ingest, prototyped by
   `workshop gallery`.
