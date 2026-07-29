# Adapters and consumers

Livery exposes one semantic manifest through two integration models. An adapter
renders a target-owned artifact inside the Livery transaction. A direct
consumer watches the active manifest and applies the public roles through its
own API.

Use an adapter when an application can include or source a generated file. Use
a direct consumer when the application provides a live configuration API or an
extension host. The generic CSS adapter is the portable artifact example. The
Visual Studio Code extension in [`../integrations/vscode/`](../integrations/vscode/)
is the direct-consumer example.

## Adapter interface

An adapter is an executable named for its target. It implements the four verbs
defined by [`../contract/SPEC.md`](../contract/SPEC.md) §3.1:

```text
render <manifest> <outdir>
validate <outdir>
reload <profiledir>
loader-check
```

Unknown verbs and invalid argument counts exit 2. Operational failures exit 1.
Successful operations exit 0. `loader-check` may exit 1 when an installed
consumer is not wired; an absent consumer should exit 0. Rendering must be
deterministic for the same manifest.

Run the conformance check by adapter ID or executable path:

```sh
livery adapter-check css
livery adapter-check ~/.config/vestiary/adapters.d/example
```

The check validates metadata when present, renders twice, validates both
outputs, compares them byte-for-byte, and verifies the reserved exit statuses.

## Discovery and selection

Livery searches the bundled `adapters/` directory, then
`~/.config/vestiary/adapters.d/`. The first executable with a given basename
wins. `LIVERY_ADAPTER_PATH` replaces that search path with a colon-separated
list. `LIVERY_USER_ADAPTERS_ROOT` changes only the user directory.

Every discovered adapter is enabled by default. Configure an allowlist, a
denylist, or both in `~/.config/vestiary/targets.json`:

```json
{
  "enabled": ["css", "ghostty"],
  "disabled": []
}
```

When `enabled` is present, adapters not named there are disabled. `disabled`
can further narrow an allowlist; the same ID may not appear in both arrays.
Every configured ID must resolve to a discovered adapter. Inspect the resolved
search order and state with `livery targets`.

An adjacent `<id>.target.json` file supplies descriptive metadata:

```json
{
  "schemaVersion": 1,
  "id": "example",
  "displayName": "Example application",
  "kind": "adapter",
  "consumes": ["ui", "signals", "terminal", "variant"],
  "detect": {"command": "example"}
}
```

Metadata is optional for discovery. `consumes` may name `ui`, `signals`,
`terminal`, `effects`, `variant`, `presentation`, or `fonts`. The `detect`
object is descriptive in this version; the adapter remains responsible for
`loader-check`.

`presentation` names the domains Livery solves against the wallpaper at render
time rather than reading from the theme: `barLegibility` for the bar strip and
`terminalLegibility` for the composited terminal backdrop. Both are absent from
theme-authored manifests, so an adapter that consumes them must fall back to the
authored domain rather than fail.

## Background opacity

`effects.backgroundOpacity` is the Look's general background translucency,
theme-authorable and in the range (0, 1]. Every surface that composites over
the wallpaper reads it through the standard idiom:

```sh
jq -r '.targets.<adapter>.backgroundOpacity // .effects.backgroundOpacity // 1'
```

The terminal is the exception, and it is deliberate. Its opacity is chosen for
legibility rather than for looks — the palette in
`presentation.terminalLegibility` is solved against the cell background
composited over the wallpaper at exactly that value — so
`effects.ghosttyBackgroundOpacity` sits between the targets override and the
general key and wins for the terminal alone.

Opacity multiplies wherever two layers both apply it. An application that
composites its own translucent background must therefore be left opaque by the
window manager, or the result is the product of the two and the legibility solve
no longer describes the screen. The yabai adapter carries that exclusion as a
rule; extend its application list rather than adding a second one.

## yabai window opacity

The `yabai` adapter emits `~/.config/livery/current/yabai/yabai.sh`, an
sh-sourceable fragment of `yabai -m config` lines and one rule. A yabairc
sources it:

```sh
source "$HOME/.config/livery/current/yabai/yabai.sh"
```

Unfocused windows take `effects.backgroundOpacity`; focused windows stay opaque
unless `targets.yabai.activeWindowOpacity` says otherwise.
`targets.yabai.normalWindowOpacity` overrides the general key per Look, and
`targets.yabai.opacityDuration` sets the fade.

Rules bind when yabai sees a window created, so an application restarted after
the fragment was sourced can come up without its opacity while
`yabai -m rule --list` still looks correct. `reload` runs `yabai -m rule --apply`
for that reason, and it is idempotent.

## Generic CSS artifact

The `css` adapter exports public semantic roles as custom properties. The
stable active path is:

```text
~/.config/livery/current/css/vestiary.css
```

Color roles provide a hex property and a companion `-rgb` triplet for alpha
composition:

```css
@import url("/Users/example/.config/livery/current/css/vestiary.css");

.panel {
  color: var(--vestiary-ui-text);
  background: rgb(var(--vestiary-ui-surface-rgb) / 80%);
}
```

The artifact includes `variant`, `ui`, `signals`, `terminal`, `effects`, and
`fonts`. Target overrides, wallpaper presentation data, and internal
transaction metadata remain outside the portable artifact.

## SketchyBar shim

The SketchyBar loader is a shim at `~/.config/sketchybar/colors.lua`. A bar
configuration loads it in place of a static color table:

```lua
local root = os.getenv("HOME") .. "/.config/livery"
local current = root .. "/current/sketchybar/colors.lua"
local fallback = root .. "/default/sketchybar/colors.lua"

local ok, colors = pcall(dofile, current)
if ok then return colors end

return dofile(fallback)
```
