# Data plane design — the state bus

**FROZEN v1.0 — 2026-07-17** (astral sign-off after prior-art validation,
tasks reshape, and live publisher verification).
Sibling to contract/SPEC.md (the theme contract); this is the *state* contract.
Prior-art validation done (15-source survey: maildir, git lockfiles, pywal,
Hyprland/i3bar/waybar/eww/MPRIS/SketchyBar transports, FSEvents/kqueue/libuv
semantics, flock-on-macOS, Terraform/K8s envelopes, Claude Code hooks).

## 1. Problem

Agent/system state flows through an ad-hoc chain: hooks → tmux pane options →
window-title magic glyphs → yabai title scraping (jq poll) → SketchyBar
events; fresco separately shells into tmux for the same state; repose consumes
through fresco. The title-glyph hop is lossy (WORKFLOW.md's own hook-truth vs
glyph-truth flag). Every new consumer (wallpaper widgets, OSD) multiplies it.

## 2. Shape (research-validated)

**Files are the bus.** A state directory of per-channel JSON snapshots,
atomically written, consumed via directory watchers. No daemon, no broker, no
SQLite — refuted for this workload (channels are <1KB current-state snapshots;
SQLite's own guidance reserves it for growing/queryable stores; every daemon
precedent had a resident process already). Precedents for files-as-bus as a
*deliberate* design: maildir (built to eliminate locking), git refs/lockfiles,
pywal's cache dir (an ecosystem-scale channel directory).

**Doorbell layer (SHOULD, not MUST) — DECIDED (astral): purpose-built, not
sketchybar-coupled.** After each write, publishers fire a payload-free nudge
via macOS's built-in notifyd: `notifyutil -p vestiary.herald.<channel>`.
Herald ships a tiny `herald-post <channel>` helper wrapping it (and posting a
distributed notification, which SketchyBar can bind natively as a custom
event — the current `sketchybar --trigger` call becomes an implementation
detail of one consumer, not bus infrastructure). Files stay authoritative;
the doorbell is pure latency optimization; consumers that miss it converge
via the watcher. This is MPRIS's shape transposed: snapshot = property store,
signal carries no data, subscribers re-read.

**Principle (inherited):** state-supported, not state-critical. Every consumer
works with the bus absent; a missing file IS the channel's documented empty
state.

## 3. Layout

```
~/.config/herald/              # the state root
  tasks.d/<id>.json            # one file PER TASK, single-writer (§5)
  media.json                   # single-writer snapshot (future)
  system.json                  # single-writer snapshot (future)
```

**Multi-writer channels are directories, not files** — the strongest
research-mandated change. Per-pane hook invocations doing locked
read-modify-write on one shared file is the exact problem maildir was designed
to delete. Instead: each task's publisher writes ONLY its own file (atomic
replace; removed at task end), consumers glob-and-merge `tasks.d/*.json`.
Every publisher is single-writer; locking disappears from the write path
entirely; one crashed hook can't corrupt siblings. Single-publisher channels
(media, system) stay flat files with last-writer-wins.

## 4. Conformance rules (normative — this is what the research says breaks
naive implementations)

**Publishers:**
- P1. Write to a unique temp file IN THE SAME DIRECTORY as the target
  (`.<name>.<pid>.tmp`), then rename(2) over the target. Never write in place.
- P2. Consumers will see tmp-file events: names starting with `.` are
  contract-invisible; subscribers MUST ignore them.
- P3. No fsync required (local, non-durable; staleness is tolerated by design).
- P4. Envelope is mandatory (§6).

**Subscribers:**
- S1. Watch the DIRECTORY, never a file. Inode-anchored watches (kqueue
  EVFILT_VNODE, naive libuv file watches) die — or silently follow the orphaned
  inode — on the first atomic replace. FSEvents is path/dir-based natively.
- S2. Events are hints, not payloads: on any event, re-read the channel and
  reconcile by content (compare `seq`). FSEvents coalesces; never count events.
- S3. Unconditional initial read at startup (no event replay exists).
- S4. Missing file/dir = documented empty state, silently.
- S5. Debounce 50–100ms then re-read once (FSEvents latency param can supply
  this; libuv on macOS has documented event-attribution quirks — reconcile by
  reading, ignore event details).
- S6. The state root itself is never renamed/replaced.

Two-word summary the docs lead with: **watch the directory; reconcile by
reading.**

## 5. Channel: tasks (v1 — the only channel implemented first)

**Reshaped 2026-07-17 (astral): agents are an INSTANCE, not the architecture.**
The channel models the generic thing: long-running work that sometimes needs
human attention and sometimes finishes. An AI agent session is one `kind`; a
CI run, a build, a backup, a deploy are others — any script can publish with
`herald-post` and a five-line JSON write. The validation research had already
shown this: the state vocabulary aligned with GitHub Actions and systemd, not
with anything agent-specific. Agent-only fields live in a kind-namespaced
extension block (the MPRIS xesam: move).

Governing precedents unchanged: `claude agents --json` (the claude kind is a
hook-derived superset of it), byte-compatible Claude/Codex hook field names,
OTel gen_ai.conversation.id as correlation key (`promptId` reserved for
per-turn granularity).

```json
{
  "schema": "tasks/1",
  "seq": 42,
  "updatedAt": "2026-07-17T22:00:00Z",
  "producer": "agent-state.sh",
  "data": {
    "id": "claude:<sessionId>",
    "kind": "claude" | "codex" | "<anything>",
    "title": "lattice",
    "cwd": "/Users/astral/personal/lattice",
    "state": "idle" | "working" | "waiting" | "done",
    "outcome": "success" | "failure" | "stopped",
    "attention": "permission" | "input" | "sandbox" | "dialog" | "idle_prompt",
    "urgent": true,
    "lastMessage": "Refactored the parser; tests green.",
    "startedAt": "2026-07-17T21:40:02Z",
    "since": "2026-07-17T21:58:11Z",
    "focus": { "space": 4, "tmux": { "pane": "%12", "window": "@3", "session": "cockpit" } },
    "claude": {
      "sessionId": "…",
      "pid": 12345,
      "model": "claude-fable-5",
      "permissionMode": "bypassPermissions",
      "lastEvent": "Notification",
      "sessionName": "lattice-parser",
      "transcriptPath": "~/.claude/projects/…/….jsonl"
    }
  }
}
```

Required: id, kind, state, since. Everything else optional — consumers MUST
tolerate absence. `id` is `<kind>:<native-id>` (collision-proof across
kinds and filename-safe: file is `tasks.d/<id>.json` with `:` → `-`).

**Generic core semantics:**
- `state`: idle (ready, nothing pending) | working | waiting (needs a human)
  | done (finished, unread). Failure via optional `outcome` (GitHub-Actions
  status/conclusion split); absent outcome ≙ indeterminate.
- `attention`: machine enum for WHY a human is wanted (XMPP show-vs-status
  pattern; `waitingFor` precedent). Open vocabulary; the five listed values
  are the claude/codex ones.
- `urgent`: the one shared "should I glow" bit — derived (waiting ⇒ true)
  today, independently settable later (done+unread ⇒ urgent for quiet-screen).
- `title`: short human label (project basename for agent kinds, derived from
  git toplevel not last-event cwd; "make test" for a build kind).
- `focus`: where to go to attend to this — space and/or tmux target, both
  optional; jump-to-task consumers use what's present.
- `lastMessage` (~120 chars): task line for pickers/quiet-screen with zero
  further derivation.
- **Liveness/eviction**: publishers SHOULD carry a pid in their extension
  block; consumers evict entries whose pid is dead or whose focus.tmux pane
  is gone (merge-time check). Mandatory in practice for the codex kind —
  Codex has NO SessionEnd hook — and the safety net for every kind whose
  publisher crashes.

**The claude/codex kinds** (extension block, published by astral's
agent-state.sh — the example publisher, not shipped infrastructure):
- Lifecycle: SessionStart(source: resume) upserts the SAME file (session_id
  stable across --continue/--resume); SessionEnd(reason ≠ resume) removes
  it, as does the zsh precmd cleanup. Known v1 tradeoff: quitting a CLI with
  an unread done-state loses the marker (brief tombstone = later refinement).
  Recorded idea: done → idle decay on tmux pane-focus ("user saw it").
- Codex event mapping: SessionStart→idle, UserPromptSubmit→working,
  PermissionRequest→waiting(attention: permission), Stop→done,
  Subagent*→ignored (never flips task state), Pre/PostCompact→working.
  Blind spot: a Codex plain question has no hook — heuristics only.

**Transitions (bells/notifications):** NOT encoded as snapshot field flips —
coalescing watchers eat transient flips (research-confirmed). v1: transitions
ride the doorbell. **Event vocabulary reserved now, log deferred** (decided
with the events.jsonl deferral): event types are `state-changed` {id, from,
to}, `attention-requested` {id, attention}, `finished` {id, outcome} — today
they exist only as doorbell nudges + snapshot diffs; an append-only log MAY
materialize them later (per-task files if ever, never one shared append file
— that would reintroduce the multi-writer contention tasks.d/ eliminates).

## 6. Envelope (all channels)

`schema` (name/version), `seq` (monotonic per file, incremented every write),
`updatedAt` (ISO 8601 UTC), `producer`, `data`. Per-session files make `seq`
trivially safe (single writer). A `lineage` field (new UUID when a producer
restarts and seq resets) is reserved — consumers treat seq-going-backwards
with a new lineage as restart, not corruption. (Terraform serial/lineage;
K8s resourceVersion precedents.)

## 7. Future channels (schemas reserved, not built)

- `media.json`: MPRIS names verbatim — playbackStatus (Playing/Paused/
  Stopped), xesam:title/artist/album, mpris:artUrl/length — free Linux-port
  compatibility, existing-tooling familiarity. Rule stolen from MPRIS: never
  publish high-frequency fields (playback position) — publish rate+timestamp,
  consumers interpolate. Would replace fresco's direct media-control feed and
  sketchybar's media.lua shell-outs with one watcher each.
- `system.json`: whatever the OSD needs (volume/brightness/power events) —
  designed with the OSD agent, not before.

## 8. Ship boundary

Vestiary ships: this spec, the conformance rules, the channel schemas, and
consumer-side integrations (fresco watcher, a reference merge snippet).
The tasks publishers for the claude/codex kinds stay in astral's dotfiles (hooks are personal;
agent-supported-not-critical). Media/system publishers ship with vestiary
when built (they're generic).

## 9. Migration plan (v1)

1. State root + spec land in vestiary; name decided (§10).
2. agent-state.sh writes both (tmux option + tasks.d file). Verify with cat/jq.
3. agent_watch.lua: replace the yabai title-scrape jq with a channel read
   (merge tasks.d/*.json — generic: ANY urgent task lights the cluster);
   keep the sketchybar trigger path as the doorbell during migration.
   Title-glyph forwarding in tmux set-titles can then shrink to purely
   human-facing (or stay; it no longer carries machine truth).
4. fresco: agents feed switches to channel watcher (existing bridge pattern).
5. Delete the scraping path once bar + fresco both read the channel.

## 10. Open questions (astral)

1. **Name: herald** (decided 2026-07-17). Root `~/.config/herald/`; notifyd
   keys `vestiary.herald.<channel>`; component `vestiary/herald/`.
2. **Doorbell: notifyd-based `herald-post`** (decided — purpose-built over
   sketchybar coupling; see §2).
3. events.jsonl: DEFERRED (decided 2026-07-17) — event vocabulary reserved
   in §5; log materializes only when a second transition consumer needs
   replay (likely trigger: the OSD toasting task completions).
4. Schema: prior-art pass done; RESHAPED to the generic tasks channel
   (astral 2026-07-17 — "agents are an instance, not the architecture");
   kind-namespaced extension blocks. FREEZE-READY.
