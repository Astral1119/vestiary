# vestiary

The coordinated-appearance system for this desktop: wallpaper, theme, bar,
terminal, and quiet-screen surfaces meeting at one contract.

Design principle: **theme-supported, not theme-critical** — every consumer
works with the contract absent. And **agent-supported, not agent-critical** —
usable as a pure theming/hotkey system by someone with no agents at all.

## Layout

| Dir | What |
|---|---|
| `contract/` | The public API: manifest schema + normative docs. Everything meets here. |
| `orchestrator/` | Apply/transaction machinery (being extracted from `livery/liveryctl`). |
| `adapters/` | One executable per themed app: `render` / `validate` / `reload` / `loader-check`. Language-agnostic. |
| `livery/` | Producer: the wallpaper↔theme engine (Matugen palettes, semantic themes, transactional Looks). |
| `fresco/` | The wallpaper engine: Wallpaper Engine video/web wallpapers at the macOS desktop layer, WE JS API shim, livery bridge. CLI: `fresco` (in ~/.local/bin). |
| `repose/` | Quiet-screen: scene-pool cover with audio visualizer, composed over fresco. Roadmap: `repose/HANDOFF.md`. |
| `tools/`, `assets/` | Pinned matugen, shared wallpaper fixtures (livery siblings by path). |
| `docs/` | Design records: SYSTEM-REVIEW.md (roadmap), THEME-LOOP-DESIGN.md (spec history; frozen contract is contract/SPEC.md), theming research. |

Runtime/contract state lives at `~/.config/livery/` (contract dir; the name
predates vestiary and is kept for path stability — compat rename deferred) and
`~/.config/fresco/` (fresco state; `~/.config/wallpaper-runtime` remains as a
compat symlink). Fresco's TCC identity was migrated 2026-07-17: host app
`~/Applications/Fresco.app`, bundle id `local.astral.fresco`, launchd label
`local.fresco`, host binary `fresco-host`, worker `bin/fresco`. The System
Audio Recording grant is anchored to the bundle id + signature; `build_host`
preserves the exact bits, so only a deliberate identity change needs a
re-grant — procedure: stop everything, change identity, rebuild, then add
`~/Applications/Fresco.app` (note: user-level ~/Applications) in System
Settings → Privacy & Security → Screen & System Audio Recording (Audio Only
suffices; the entry is kTCCServiceAudioCapture, which manual + adds create
via the per-app mode dropdown), then `fresco restart`.

History note: graduated 2026-07-17 from `sketchybar-concepts/experiments/`
(the design lab), full git history preserved; `wallpaper-runtime` was renamed
`fresco` in the move.
