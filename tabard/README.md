# tabard

The herald's garment: vestiary's on-screen display. A small resident
agent that floats brief announcements over the desktop — a task needs
attention, a task finished, a look was applied — rendered on the theme
contract's inverse-polarity roles so the chip reads against any look.

Tabard subscribes to herald's tasks channel (files are the bus; tabard
watches the directory and reconciles by reading) and is the host's
designated reaper (herald `SPEC.md` §5): orphaned task files from
publishers without end hooks are unlinked once they are evictable and
stay so across two sweeps.

## Use

```
./tabard                 # run in the foreground
./tabard install-agent   # launchd agent: start at login, survive reboot
./tabard pause           # drop toasts (state stays wherever you show it)
./tabard resume
./tabard status
```

The wrapper builds the binary on first run and whenever the source is
newer (requires the Xcode Command Line Tools, already a vestiary
dependency). After a source update, re-run `./tabard install-agent` so
launchd picks up the fresh binary.

## Behavior

Toasts decay — 5s for completions and look changes, 10s for attention —
and the countdown holds while you are away from the machine, so a toast
fired mid-coffee is still there when you sit down. At most three are
visible; more collapse into a "+N" count. The panel is click-through
and never takes focus; jumping to a task belongs to your own tooling.
A transition in the tmux pane you are currently focused on does not
toast.

Tasks published with a `group` (herald `SPEC.md` v1.3 — batch
dispatches like agent swarms) digest instead of parading: completions
collect for 30s and annunciate as one chip with outcome counts
("7 finished · 2 failed"), updating in place while visible and
re-toasting at most every five minutes. Blocked group members
annunciate immediately — attention never waits in a collector — and
merge into one "N blocked" chip. The two tiers never share a chip.
Ungrouped tasks toast individually, as above.

Tabard is also the host's designated recorder: observed transitions
append to `~/.local/state/herald/events.jsonl`, one JSON object per
line — state changes, completions with outcome, attention requests,
reaps, and a `rebaselined` marker at every start declaring a possible
gap. The log is best-effort and prunes to 30 days at startup. Live
task state stays wherever you show it (a bar, a widget); the herald
snapshots remain authoritative.

## Theme

Tabard reads `~/.config/livery/current/manifest.json` directly:
`ui.inverseSurface` / `ui.inverseText` / `ui.inversePrimary` for the
chip, `fonts.display` for headings, `fonts.ui` for body text. With no
manifest present it falls back to a built-in monochrome chip —
theme-supported, not theme-critical.
