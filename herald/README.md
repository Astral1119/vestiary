# herald

The state bus: `~/.config/herald/` — per-channel JSON snapshots, atomically
written, watched by consumers.

**Watch the directory; reconcile by reading.**

- Publishers: write `.name.$$.tmp` in the target's directory, then rename.
  Envelope: `schema`, `seq`, `updatedAt`, `producer`, `data`. Fire
  `herald-post <channel>` after the rename (optional doorbell — notifyd key
  `vestiary.herald.<channel>`; subscribe with `notifyutil -w`).
- Subscribers: watch the directory (never a file — atomic renames kill
  inode-anchored watches); treat events as hints and re-read; unconditional
  initial read; missing file/dir = empty state; debounce 50–100ms; ignore
  dotfiles.
- `tasks.d/` is the multi-writer channel done maildir-style: one file per
  task, single writer each, glob-and-merge to consume, evict entries whose
  focus.tmux pane is gone (pane-primary; a pane-anchored entry's pid never
  evicts on its own, but a pane-less entry MAY fall back to pid liveness).

Every consumer works with this directory absent.
