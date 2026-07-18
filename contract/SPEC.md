# Theme loop design — contract + adapter specification

**FROZEN v1.0 — 2026-07-17** (maintainer sign-off after comparative review §8 and
prior-art freeze-risk review: scopes reserved, vocabulary policy locked, verb
stability rules locked). Canonical copy: `~/personal/vestiary/contract/SPEC.md`.
Frozen surfaces: §2 (contract incl. evolution policy) and §3 (adapter verbs
incl. stability rules). Everything else is tunable. Companion to
SYSTEM-REVIEW.md §3A. Decided parameters: contract-first direction
worth speccing fully before code; tmux status-line full refactor to @livery_*
approved; nvim = overlay over moonfly; adapters live at
`~/personal/vestiary/adapters/`.

Project layout (2026-07-17): umbrella repo **vestiary** at `~/personal/vestiary/`
(contract/ orchestrator/ adapters/ livery/ fresco/ repose/), graduated from the
sketchybar-concepts lab with history. The wallpaper runtime is named **fresco**.
Contract/runtime state stays at `~/.config/livery/` and
`~/.config/wallpaper-runtime/` (path stability; renames deferred).

Ground truth about livery internals referenced here comes from the 2026-07-17
pipeline map (liveryctl line refs are to that day's source).

---

## 1. The shape

Three layers, with the boundary drawn so livery's specialist philosophy
(provenance, transactions, wallpaper derivation) stays in the producer layer and
never leaks into what other tools must understand:

```
PRODUCERS            CONTRACT                      ADAPTERS
livery (wallpaper↔   ~/.config/livery/current/     adapters/<target>
theme engine) — or   manifest.json (semantic       render | validate | reload
any future trivial   source) + per-target          one executable per app
picker               rendered subdirs
```

- A **producer**'s job ends at "resolved manifest installed + `current` flipped."
- An **adapter** knows nothing about wallpapers, digests, Matugen, or authority
  modes. It reads a manifest, emits one app's config fragment, and can reload
  that app. It must be comprehensible in isolation by someone who has never
  read liveryctl.
- The **orchestrator** (liveryctl today) discovers adapters by listing the
  adapters dir and drives them through the existing transaction. This creates
  the registry that doesn't exist today (everything is hardcoded at ~8 sites).

Generalized degradation principle (extends "agent-supported, not
agent-critical"): **theme-supported, not theme-critical.** Every consumer must
work with the contract absent — ghostty's `?` include, sketchybar's
pcall-fallback, and yabai's inline fallback already model this; tmux (`-q`
source) and nvim (pcall + no-op) must follow.

## 1b. Ship boundary (maintainer, 2026-07-17)

**Mechanism ships with vestiary; policy stays in dotfiles.** Vestiary ships the
contract, orchestrator, adapters (tmux adapter = generic palette-as-user-options
+ standard styles; livery.nvim = generic palette-overlay-with-watcher), livery,
fresco. It does NOT ship: loader lines in user configs (installed by the user,
by design), tmux.conf itself (the phone-cockpit status line and agent markers
are personal consumers of the generic `@livery_*` / `signals.*` primitives),
the moonfly-specific overlay choices (default config of a generic plugin), or
any agent affordance (hooks, cockpit, data plane) — `signals` carries no agent
concepts; agent integration remains a personal (or later optional) layer,
per agent-supported-not-critical. Decision #8's tmux refactor is thus two
workstreams: adapter (product) + the user's tmux.conf (personal), shipped
together but versioned apart.

## 2. Contract specification

### 2.1 Location and lifecycle

- Root: `~/.config/livery/` (env override `LIVERY_RUNTIME` reserved).
- `current` → immutable resolved profile dir (atomic symlink flip, `mv -h -f`).
- `previous` → last profile (rollback pair). `default` → captured baseline.
- Consumers MUST read via `current/` and fall back to `default/`, then to
  built-in values. Consumers MUST NOT write anywhere under the root.
- A profile dir is immutable once installed; readers never see partial state
  (staged in build/, installed via tmp-dir + mv, flipped atomically).
- **Scopes (reserved, not built)**: `current/` is the *global scope*. A future
  scoped profile lives at a sibling `current@<scope>/` (e.g.
  `current@display:<id>/`, `current@space:<n>/`); the consumer rule is
  "resolve the most specific scope you belong to, fall back to `current/`."
  This is the only per-monitor/per-space model with surviving precedent
  (X11 SCREEN_RESOURCES over RESOURCE_MANAGER; kitty per-window overrides
  over a global base — no surveyed system maintains N independent theme
  states, and systems with no scope concept devolve into mutate-global-on-
  switch hacks). Scoping is absorbed by the path/resolver layer: manifests
  never carry per-scope maps, adapters stay scope-blind, and
  `reload <profiledir>` is already the scoped hook (a future orchestrator
  passes `current@display:N` to the adapters that own per-output surfaces
  and `current` to the rest). Costs nothing today; prevents the
  open-source-time migration.

### 2.2 Public API surface of manifest.json (schemaVersion 2)

Stable, adapters may depend on:

| Domain | Keys | Notes |
|---|---|---|
| `ui` | background, surface, surfaceElevated, **overlay**, text, textMuted, primary, **onPrimary**, secondary, tertiary, outline, **outlineVariant**, selection | semantic roles. onPrimary = text/glyphs drawn ON any accent fill (one on-accent serves all three accents unless a `targets` override says otherwise). outlineVariant = the quieter outline (inactive borders). overlay = third surface tier. Reserved for the OSD phase: inverseSurface, inverseText, scrim |
| `terminal` | ansi[16] (ANSI order), base16[16] (generator order), background, foreground, cursor, cursorText, selectionBackground, selectionForeground, minimumContrast | terminal-domain consumers use THIS, not ui, for content colors. Schema doc MUST carry the base16↔ANSI permutation table + base00-0F slot semantics and state the brights-derivation policy (ansi[8..15]) — indexing base16 as ANSI is the classic footgun |
| `signals` | success, warning, error, info, attention | workflow semantics; locked across wallpaper derivation — the agent-marker colors. Crisp definitions (frozen): success = completed/ready; warning = degraded but working; error = failed/broken; info = neutral status, no action implied; attention = a human's input is wanted (distinct from warning: attention is a request, warning is a condition). Signal colors are for glyphs/text/accents on neutral surfaces; a *filled* signal chip needs an on-color — `onSuccess`-style names are RESERVED for future additive use; until then filled chips pair the signal fill with ui.background as text |
| `effects` | alpha/opacity/blur policy keys | separate from RGB by design |
| `variant` | "dark" \| "light" | active polarity |
| `variants` | optional: `variants.dark` / `variants.light` — both resolved palettes | additive; enables appearance-follow as a pure flip with no re-derivation (§6 step 4) |
| `meta` | name, source.{image, scheme, contrast}, producer.{name, version}, resolvedAt | public provenance-lite ("what theme am I on") — distinct from the internal `provenance` block, feeds future data-plane/UX |
| `targets` | `.targets.<adapter>.…` free-form per-app overrides | read via `// fallback` idiom: `.targets.tmux.accent // .ui.primary`; the fallback graph lives in the adapter, by design |

**Color value form:** every public color is `{hex: "#rrggbb", rgb: [r, g, b]}` —
adapters in any language get both without reimplementing hex parsing (the
adapter model has no shared template engine to do transforms, so the manifest
carries the two universally needed forms; anything fancier is the adapter's
problem). Casing: camelCase keys, lowercase hex, no alpha in hex (alpha policy
lives in `effects`).

**Schema doc must include** a normative mapping table (ui role → Material 3
role → base16 slot) so contributors from either ecosystem orient instantly —
e.g. text↔on_surface↔base05, textMuted↔on_surface_variant↔base04.

**Vocabulary evolution policy (frozen WITH the vocabulary — this is what makes
a named role set survivable, per the base16/VS Code/CSS4 record vs the M2→M3
and Tailwind-gray churn):**
1. Additive-only. Roles are never removed and never renamed.
2. Adapters MUST ignore unknown keys (in every domain — this is also what
   makes `meta.scope` and future reserved names safe).
3. Every future role declares a fallback chain to an existing role in the
   schema doc (VS Code's "new color inherits old color" rule) — so adapters
   that predate it keep working by construction.
4. A name is NEVER rebound to a different meaning (the Tailwind `gray`
   mistake). If a meaning must change, it gets a new name; the old one stays,
   deprecated-but-resolvable, forever.
5. If surface tiers ever run out, add container-scale roles additively
   (M3's move) — `surfaceElevated` keeps its meaning; it is not redefined.
6. `meta.scope` reserved, value `"global"` today (see §2.1 scopes).

Internal, adapters MUST NOT read: `provenance`, `evidence`, `outputs`, `locks`.
Surface-specific: `presentation.barLegibility.*` is computed for the bar-over-
wallpaper crop only — sketchybar's adapter is its only legitimate consumer;
`presentation.visualizerGradient` likewise belongs to visualizer surfaces.

Versioning rule: adapters check `schemaVersion == 2`; on mismatch, warn to
stderr and no-op (exit 0). Additive keys are non-breaking; renames/removals of
public keys bump the major.

### 2.3 minimumContrast

Ghostty enforces `terminal.minimumContrast` at render time; tmux and nvim run
inside ghostty, so the floor is inherited — terminal-domain adapters take no
action. Any future adapter for a surface NOT rendered through a
minimum-contrast-capable host must state how it satisfies the floor (bake or
document N/A).

## 3. Adapter interface specification

### 3.1 Form

One executable per target at `theming/adapters/<target>` (POSIX sh + jq for
house style; any executable is legal). Target name = filename. No config of its
own; everything comes from the manifest and argv.

```
<target> render   <manifest.json> <outdir>   # write fragment(s) into <outdir>
<target> validate <outdir>                    # syntax/lint the fragment
<target> reload   <profiledir>               # nudge the running app (best-effort)
<target> loader-check                         # is the user's config wired to consume? 0/1
```

**Interface stability rules (frozen with the verbs, per the git-hooks /
Nagios / systemd-generator record — none of which ever reshaped argv in
decades; and per the same record, NO version/capability handshake at this
scale — data-side versioning via the manifest's `schemaVersion` suffices):**
- Positional argv is frozen exactly as above. ALL future inputs arrive as
  `LIVERY_*` env vars, never new positionals (unknown env is ignored by old
  adapters for free; positional argv is the least extensible channel).
- Exit codes, standardized now: `0` success · `1` operation failed
  (diagnostics on stderr) · `2` usage error / **unknown verb** — the reserved
  meta-code, which gives the orchestrator free capability discovery for any
  future verb (invoke and check for 2, the missing-git-hook pattern) ·
  `3+` reserved.
- stdout convention (Nagios rule): first line is a one-line human status;
  anything structured follows after.

Rules:
- `render` is pure: reads manifest, writes only into `<outdir>`, no side
  effects, deterministic for a given manifest. Exit non-zero on any failure.
- `validate` uses the app's own parser where one exists (precedent:
  `ghostty +validate-config`, `luac -p`, borders regex at liveryctl:1712-1725).
  tmux: scratch-server parse (`tmux -L livery-validate -f <file> start-server ;
  kill-server`). nvim: `luac -p` (fragment is pure-data Lua).
- `reload` is **best-effort and always exits 0 when the target simply isn't
  running** (nvim closed, tmux server down = success, not failure). Non-zero
  only for "app is running and actively rejected the new state." It receives
  the installed profile dir (so it can do data-bearing one-shot reloads without
  re-deriving paths); orchestrator may also set `LIVERY_CHANGED_DOMAINS` as an
  optimization hint (adapters must work without it).
- `loader-check` greps the user's real config for the include line (precedent:
  `loaders_installed` liveryctl:1779). Lets the orchestrator warn-or-gate
  without adapters editing user configs — **adapters never touch user dotfiles**;
  installing the loader line is a one-time manual (or bootstrap) step.

### 3.2 Orchestration and failure semantics

Sequenced into the existing `apply_profile` transaction (liveryctl:2249):

1. Stage: for each adapter, `render` then `validate` into `build/<slug>/<target>/`.
   **Any failure aborts the apply pre-install** — transactionality preserved,
   nothing user-visible has changed.
2. Install + flip `current` (unchanged livery machinery).
3. Post-flip: for each adapter, `reload <profiledir>`. **Reload failures do NOT
   trigger rollback** — with N targets, one stuck app must not revert the other
   N−1; the orchestrator reports which targets are stale. (This deliberately
   relaxes livery's current reload-failure-rolls-back behavior at
   liveryctl:2281-2297 as adapter count grows; wallpaper apply failure still
   rolls back.)
4. Post-flip user hook: if `~/.config/livery/hooks/post-flip` is executable,
   run it with the profile dir as $1 (env: LIVERY_VARIANT, LIVERY_PROFILE) —
   the personal-scripting escape hatch every surveyed system grew (omarchy-hook,
   tinty hooks, caelestia postHook). Distinct from adapters; failures warn only.
5. `install_runtime_profile`'s hardcoded dir list (liveryctl:1796-1804) becomes
   "copy every `<target>/` subdir present in the staged build."
6. Orchestrator-level verbs (fall out of render's purity, no new adapter
   verbs): `--dry-run` (render+validate to temp, report, don't install) and
   `check` (re-render current profile's spec, diff against installed — drift
   detection, whiskers `--check` pattern). "Current theme" introspection API =
   `readlink current` + `current/manifest.json .meta`; document, don't build.
7. Produce-time contrast lint (warn-only, never abort): WCAG ratio check on
   ui.text/ui.background, ui.onPrimary/ui.primary, and each signals.* vs
   ui.background — catches an illegible producer output before adapters render
   it faithfully. Exceeds current ecosystem practice; cheap in the resolve path.

Migration: ghostty/sketchybar/borders renderers stay inline initially; they are
extracted into adapter files as a later mechanical step (§6). The orchestrator
loop must tolerate the mixed period.

## 4. tmux adapter spec

**Fragment:** `<profile>/tmux/livery.conf` — two sections:

1. Palette as user options (single source for format strings):
   `@livery_bg ui.background · @livery_fg ui.text · @livery_muted ui.textMuted ·
   @livery_accent ui.primary · @livery_secondary ui.secondary · @livery_outline
   ui.outline · @livery_selection ui.selection · @livery_attention
   signals.attention · @livery_success signals.success · @livery_warning
   signals.warning · @livery_error signals.error · @livery_info signals.info`
   — each via `.targets.tmux.<name> // <fallback>` idiom, emitted as
   `set -g @livery_x "#rrggbb"`.
2. Derived style options set directly: `status-style`, `message-style`,
   `mode-style`, `pane-border-style`, `pane-active-border-style`,
   `copy-mode-*-style`, `window-status-{,current-,bell-}style`.

**tmux.conf refactor (approved):** every color literal in status-left/right and
window-status format strings is replaced by `#{@livery_attention}`-style
references — including the peach ✳ / green ● agent markers, which thereby
track `signals.*` per-wallpaper. tmux.conf ends up with zero color literals.
Loader line: `source-file -q ~/.config/livery/current/tmux/livery.conf`
placed AFTER any local style defaults so livery wins.
Fallback texture: because `-q` no-ops when livery is absent, tmux.conf keeps
one block of neutral default `@livery_*` definitions above the source-file line
(theme-supported-not-critical: markers stay visible with no livery at all).

**Reload:** `tmux source-file <current fragment>` once against the running
server (server-wide). Verify on the PHONE view after first apply — narrow-width
status line is the load-bearing UI.

## 5. nvim adapter + livery.nvim spec

**Fragment:** `<profile>/nvim/livery.lua` — pure data, no logic:
`return { variant=…, ui={…}, terminal={ansi={…}, …}, signals={…} }`.

**Plugin `livery.nvim`** (local, lives with the nvim config; lazy.nvim `dir=`
spec): on startup and on change —
1. `pcall(dofile, current)` → fallback `default` → silent no-op (moonfly
   untouched) if both missing.
2. Applies an **overlay**, moonfly remains the colorscheme:
   - curated highlight groups: `Visual` (ui.selection), `FloatBorder`
     (ui.outlineVariant), `NormalFloat` tint (ui.surface), `Search/IncSearch`
     accents, `DiagnosticError/Warn/Info/Hint` + `GitSigns{Add,Change,Delete}`
     from `signals.*`. Any syntax-adjacent accents map from `terminal.base16`
     slots (per the documented base16 semantics — base08-0F carry syntax-hue
     meaning), NOT `terminal.ansi` — editors are base16 consumers, not ANSI
     consumers (tinted-vim precedent),
   - a generated lualine theme from ui roles (replaces the static one),
   - `vim.g.terminal_color_0..15` from `terminal.ansi`.
3. Watches the `current` symlink's parent with `vim.uv.fs_event`, debounced;
   re-applies on flip — closes the no-reload-signal gap without livery knowing
   nvim exists. ColorScheme autocmd re-applies the overlay if moonfly reloads.
4. The adapter script itself is thin: `render` = jq→lua-table emit;
   `validate` = `luac -p`; `reload` = no-op exit 0 (the watcher handles it);
   `loader-check` = grep for the plugin spec.

## 6. Rollout (unchanged order, now with an added step 0)

0. **Freeze** — comparative review done (§9), fixes folded in; maintainer sign-off
   on §2/§3 as the frozen v1 contract; then implementation begins. Livery's
   resolve path gains the new ui roles / structured values / meta block first
   (producer change), since adapters are written against the frozen shape.
1. tmux adapter + tmux.conf refactor + phone verification.
2. livery.nvim + nvim adapter.
3. Extract ghostty/sketchybar/borders into adapters (mechanical; proves the
   discovery loop; deletes ~130 lines of liveryctl here-docs).
4. Appearance-follow producer trigger: launchd watcher on
   AppleInterfaceThemeChangedNotification + NSWorkspace.didWakeNotification
   re-check (appearance can change during sleep), flipping between
   pre-rendered `variants.dark`/`variants.light` profiles (~30 lines,
   dark-mode-notify pattern).
5. OSD adapter (add inverseSurface/inverseText/scrim to `ui` then); data-plane
   design doc (separate — event channels for agent/system state into
   wallpaper/widgets, per SYSTEM-REVIEW §3A.3).

## 7. Resolved questions (maintainer, 2026-07-17)

1. **Failure semantics**: reload-failure→warn CONFIRMED (render/validate
   failures still abort pre-install).
2. **Adapter contract is language-agnostic** in the v1 docs: any executable
   honoring the four verbs + exit-code rules. sh+jq remains the house style for
   the first adapters, but nothing in the contract may assume it.
3. **Naming**: umbrella = **vestiary**, wallpaper runtime = **fresco** (chosen
   2026-07-17, restructure done same day); livery keeps its name as the
   producer. The contract *path* (`~/.config/livery/`) keeps its name for
   loader-shim stability; neutral rename deferred to open-source time.
4. **tmux defaults**: the current hardcoded literals become the shipped
   fallback `@livery_*` values — zero visual change when livery is absent.

## 8. Comparative review outcomes (2026-07-17)

Reviewed against: tinted-theming/base16+base24, tinty, Catppuccin whiskers +
style guide, matugen, stylix (NixOS), Omarchy, pywal16, wallust, Quickshell
shells (Noctalia/DankMaterialShell/Caelestia), VS Code theme model, M3 roles.

**Architecture validated**: Omarchy — closest cousin — *abandoned* hand-written
per-app theme fragments and converged on manifest(colors.toml)→generated
fragments with a migration shim; symlink-flip, pgrep-guarded "not running =
success" reloads, and `killall -SIGUSR2 ghostty` all independently match. Our
render+validate transaction exceeds ecosystem practice (Omarchy validates
nothing; template hooks are fire-and-forget).

**Adopted into §2/§3** (was missing): ui.onPrimary (the one real accessibility
hole — "text on accent" was unanswerable), outlineVariant + overlay tier,
structured {hex, rgb} color values, public `meta` provenance-lite block,
optional `variants.{dark,light}` dual-palette, reload receives profile dir,
post-flip user hook, --dry-run/check orchestrator verbs, produce-time contrast
lint, base16↔ANSI documentation requirements + ui→M3→base16 mapping table,
nvim maps syntax accents from base16 not ansi.

**Deferred (additive, safe post-freeze)**: `fonts` domain (stylix model —
monospace + per-context sizes; Ghostty/SketchyBar/OSD would consume),
per-surface-class `effects` split, inverseSurface/inverseText/scrim (OSD
phase), base16-scheme→manifest importer (open-source time), palette-per-
wallpaper cache in livery.

**Rejected with reasons**: OSC-escape live terminal recolor (pywal16 trick) —
viable on macOS but redundant + racy for Ghostty (config reload clobbers OSC
state, ghostty#2795; tmux intercepts/caches OSC) — revisit only for
reload-less terminals as an optional standalone adapter. Per-monitor theming —
the single-symlink contract structurally precludes it; accepted limitation,
recorded. User fragment-override overlay (Omarchy pattern) — out of scope v1;
`targets` covers color-level overrides.
