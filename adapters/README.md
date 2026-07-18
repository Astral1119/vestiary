# adapters

One executable per target, each implementing the four verbs from
[`../contract/SPEC.md`](../contract/SPEC.md) §3.1: `render` / `validate` /
`reload` / `loader-check`.

All five stable targets live here: `tmux`, `nvim` (paired with
[`../livery.nvim/`](../livery.nvim/)), `ghostty`, `sketchybar`, `borders`.
liveryctl discovers adapters by listing this directory. Dropping a new
executable in is the whole registration; the orchestrator hardcodes no
target names.

## sketchybar shim

The sketchybar loader is a shim at `~/.config/sketchybar/colors.lua` that
your bar config `require`s in place of a static color table. It reads the
applied profile and falls back to the default profile when none is
current:

```lua
local root = os.getenv("HOME") .. "/.config/livery"
local current = root .. "/current/sketchybar/colors.lua"
local fallback = root .. "/default/sketchybar/colors.lua"

local ok, colors = pcall(dofile, current)
if ok then return colors end

return dofile(fallback)
```
