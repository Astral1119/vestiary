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
./tabard inbox           # toggle the inbox panel (bind this to a key)
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
visible; more collapse into a "+N" count. The panel never takes focus.
Each chip shows a countdown bar and pauses it while hovered;
middle-click or right-click dismisses. Left-click runs
`~/.config/tabard/attend-hook` if you have installed one — your own
jump-to-task tooling — and is quietly eaten otherwise. A transition in
a tmux pane that is on screen (any pane of the window you have up in an
attached session) does not toast.

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

## Inbox

Toasts cover the moment; the inbox covers what you missed. `./tabard
inbox` toggles a centered workbench panel — the livery panel's family:
a channel rail on the left, detail on the right, breadcrumb header,
keybind legend in the footer, esc to close. It takes keys while open
(j/k or arrows move the rail, enter attends the selected channel's
first waiting thread) and toasts are inhibited. Threads are tasks, or
whole groups when tasks were dispatched as a batch. Channels are
projects — the task title, normally the repo — grouped in the rail as
NEEDS YOU / NEW / QUIET with a presence dot per channel, no counts;
a unified newest-first feed sits pinned at the top. A channel is pure
scrollback with a NEW divider — the cockpit (panes, glyphs, the bar)
already owns the present, so the inbox owns only the past.

Reading happens by act, not by arrival, in Slack's shape: an unread
channel opens at the NEW divider and scrolling to the bottom marks it
read (a channel that fits on screen reads on entry; a clean one opens
at the bottom). Attending marks too, as does the task's tmux pane
being on the displayed window while you are at the machine. The feed
never marks.
Each thread's cursor lives in `~/.local/state/herald/seen.json`;
channels and the feed are stateless views over that one map, so the
partition can change without migrating anything. A thread is live
exactly while its herald task file exists — the inbox adds no second
lifecycle. A presence summary (`needsYou`/`unread` booleans, no
counts) is exported to `~/.local/state/tabard/badge.json` for
whatever status surface wants it.

## Theme

Tabard reads `~/.config/livery/current/manifest.json` directly:
`ui.inverseSurface` / `ui.inverseText` / `ui.inversePrimary` for the
chip, `fonts.display` for headings, `fonts.ui` for body text. The inbox
panel is a workspace surface, not a chip, and renders on the non-inverse
roles (`ui.surfaceElevated` falling back to `ui.surface`, `ui.text`,
`ui.textMuted`, `ui.primary`, `ui.outline`) with `fonts.mono` for
timestamps. With no manifest present both fall back to built-in
neutrals — theme-supported, not theme-critical.
