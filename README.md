# vestiary

A coordinated-appearance system for macOS. One wallpaper-derived theme
contract; adapters retheme tmux, nvim, Ghostty, SketchyBar, and JankyBorders
transactionally from it; a Wallpaper Engine-compatible runtime plays video
and web wallpapers at the desktop layer and rethemes them live from the same
contract; a small file bus carries task state for bars and quiet-screens.

Design principle: **theme-supported, not theme-critical** — every consumer
works with the contract absent. And **agent-supported, not agent-critical** —
usable as a pure theming system by someone with no agents at all.

## What stands alone

The pieces compose but don't require each other:

- **livery** (with `contract/`, `adapters/`, `livery.nvim/`) — the theming
  engine — is fully standalone: ingest a wallpaper image, get pinned Matugen
  palettes and transactional themed surfaces. It calls fresco to set the
  live wallpaper only if fresco is built, and shrugs if it isn't.
- **fresco** — the wallpaper runtime — is standalone: it plays Wallpaper
  Engine video/web projects with no theming installed; the livery bridge
  activates only when a manifest exists. Owning Wallpaper Engine on Steam is
  needed **only for Workshop downloads** — local WE project folders, bare
  video files, and the `fetch-samples` wallpapers run without Steam.
- **herald** — the state bus — is a spec, conformance rules, and a one-line
  doorbell helper; publishers live in your own dotfiles/hooks.
- **repose** — the quiet-screen — is the exception: it composes over fresco.

## Layout

| Dir | What |
|---|---|
| `contract/` | The public API: manifest schema + normative docs (`SPEC.md`, frozen v1.0). Everything meets here. |
| `adapters/` | One executable per themed app: `render` / `validate` / `reload` / `loader-check`. Language-agnostic, directory-discovered. |
| `livery/` | Producer: the wallpaper↔theme engine (Matugen palettes, semantic themes, transactional Looks). `liveryctl` is the orchestrator. |
| `livery.nvim/` | The nvim consumer plugin (overlay + fs_event watcher), paired with `adapters/nvim`. |
| `orchestrator/` | Reserved: apply/transaction machinery extraction (spec §3.2); today that machinery lives in `livery/liveryctl`. |
| `fresco/` | The wallpaper runtime: Wallpaper Engine video/web wallpapers at the macOS desktop layer, WE JS API shim, livery bridge. |
| `herald/` | The state bus: per-channel JSON snapshots under `~/.config/herald/`, notifyd doorbell. Spec: `docs/DATA-PLANE-DESIGN.md`. |
| `repose/` | Quiet-screen: scene-pool cover with audio visualizer, composed over fresco. Roadmap: `repose/HANDOFF.md`. |
| `tools/`, `assets/` | matugen fetch step, shared wallpaper fixtures (livery siblings by path). |
| `docs/` | Design records: SYSTEM-REVIEW.md (roadmap), THEME-LOOP-DESIGN.md (spec history; frozen contract is contract/SPEC.md), theming research. |

## Quickstart

```sh
git clone https://github.com/Astral1119/vestiary.git
cd vestiary
./install
```

`./install` checks dependencies, fetches matugen, puts `livery`, `lvry`, and
`fresco` on PATH, and reports loader wiring.

```sh
livery apply default
# add the loader lines ./install printed for the surfaces you use
livery apply <profile>
```

Audio-reactive wallpapers need a one-time Screen & System Audio Recording
grant (`fresco audio-permission` prints the steps); everything else works
without it — ungranted wallpapers just play silent. Workshop wallpapers need
Wallpaper Engine on Steam plus `steamcmd`; the bundled and fetchable samples
don't.

## State

Runtime/contract state lives at `~/.config/livery/` (contract dir; the name
predates vestiary and is kept for path stability — compat rename deferred) and
`~/.config/fresco/` (fresco state; `~/.config/wallpaper-runtime` remains as a
compat symlink). Fresco's audio grant is anchored to a small frozen host app,
`~/Applications/Fresco.app` — worker rebuilds never disturb it; see
`fresco/README.md` for the TCC identity details.

History note: graduated 2026-07-17 from `sketchybar-concepts/experiments/`
(the design lab), full git history preserved; `wallpaper-runtime` was renamed
`fresco` in the move.
