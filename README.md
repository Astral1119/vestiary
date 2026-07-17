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
`~/.config/wallpaper-runtime/` (fresco state; same policy). Fresco's TCC
identity — host app `~/Applications/Wallpaper Runtime.app`, bundle id
`local.astral.wallpaper-runtime`, launchd label, worker/host binary names —
is DELIBERATELY not renamed: it anchors the System Audio Recording grant.
Rename only at a packaging milestone, with the grant-while-stopped procedure.

History note: graduated 2026-07-17 from `sketchybar-concepts/experiments/`
(the design lab), full git history preserved; `wallpaper-runtime` was renamed
`fresco` in the move.
