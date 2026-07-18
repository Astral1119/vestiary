# adapters

One executable per target, each implementing the four verbs from
[`../contract/SPEC.md`](../contract/SPEC.md) §3.1: `render` / `validate` /
`reload` / `loader-check`.

All five stable targets live here: `tmux`, `nvim` (paired with
[`../livery.nvim/`](../livery.nvim/)), `ghostty`, `sketchybar`, `borders`.
liveryctl discovers adapters by listing this directory. Dropping a new
executable in is the whole registration; the orchestrator hardcodes no
target names.
