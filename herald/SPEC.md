# Data plane design — the state bus

**FROZEN v1.0 — 2026-07-17** (astral sign-off after prior-art validation,
tasks reshape, and live publisher verification).
**v1.1 — 2026-07-18**: §5 eviction corrected to pane-primary (a dead pid
alone never evicts — no shipped consumer ever implemented pid-eviction);
the worked kind example is now non-agent, and kind documentation moved
out to the publishers that own it (ship boundary, §8).
**v1.2 — 2026-07-19**: §5 gains reaping — the amendment reserved in v1.1's
liveness wording, signed off with the tabard (OSD) design. A designated
reaper may unlink evictable entries under a two-observation grace rule.
**v1.3 — 2026-07-19**: §5 tasks core gains optional `group` — a
publisher-stamped correlation id for tasks dispatched as one batch.
Signed off with the tabard grouping/anti-fatigue design (TABARD-DESIGN
§12); additive, consumers that ignore it are unaffected.
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
  "producer": "make-watch",
  "data": {
    "id": "build:lattice-test",
    "kind": "build" | "<anything>",
    "title": "make test",
    "cwd": "~/personal/lattice",
    "state": "idle" | "working" | "waiting" | "done",
    "outcome": "success" | "failure" | "stopped",
    "attention": "permission" | "input" | "sandbox" | "dialog" | "idle_prompt",
    "urgent": true,
    "lastMessage": "3 of 214 tests failing",
    "group": "lattice-audit-swarm",
    "startedAt": "2026-07-17T21:40:02Z",
    "since": "2026-07-17T21:58:11Z",
    "focus": { "space": 4, "tmux": { "pane": "%12", "window": "@3", "session": "cockpit" } },
    "build": {
      "pid": 12345,
      "target": "test",
      "log": "/tmp/lattice-test.log"
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
  come from the AI-agent kinds that drove v1.
- `urgent`: the one shared "should I glow" bit — derived (waiting ⇒ true)
  today, independently settable later (done+unread ⇒ urgent for quiet-screen).
- `title`: short human label (project basename for agent kinds, derived from
  git toplevel not last-event cwd; "make test" for a build kind).
- `focus`: where to go to attend to this — space and/or tmux target, both
  optional; jump-to-task consumers use what's present.
- `lastMessage` (~120 chars): task line for pickers/quiet-screen with zero
  further derivation.
- `group` (v1.3, optional): opaque correlation string stamped by the
  publisher on tasks dispatched as one batch (an agent swarm, a test
  matrix). Publishers SHOULD pick short human-readable slugs — the value
  may surface verbatim in UIs. Consumers MAY aggregate same-group entries
  (digest toasts, collapsed rows) and MUST treat entries without the
  field as ungrouped; the field never affects liveness, eviction, or
  reaping. Grouping semantics beyond membership (windows, tiers) are
  consumer policy, not bus contract.
- **Liveness/eviction** (amended v1.1 — the v1.0 wording made a dead pid
  alone sufficient, which no shipped consumer implements): pane-liveness is
  the eviction primary — consumers evict entries whose focus.tmux pane is
  gone (merge-time check). For a PANE-ANCHORED entry a pid in the extension
  block is advisory only — consumers MUST NOT evict it on a dead pid alone
  (some kinds' pids are transient by nature: a hook runner's parent can die
  between events under a live session). For an entry carrying NO focus.tmux
  identity, pane eviction cannot reach it; consumers MAY fall back to pid
  liveness there, and SHOULD, since an end-hook-less publisher (codex) would
  otherwise leave the entry immortal until a reaper exists (reserved as a
  future amendment). The rule in one line: pane present ⇒ pane decides, pid
  ignored; pane absent ⇒ pid is the best signal available. Kinds MAY define
  stricter liveness in their own documentation. Pane eviction remains the
  safety net for every pane-anchored kind whose publisher crashes.
- **Reaping** (v1.2): file removal is normally the publisher's job, but
  publishers without end hooks leave orphans. A single designated reaper
  per host MAY unlink a task file that is *evictable* under the rules
  above — focus.tmux pane present but dead, or no pane identity and a
  dead extension-block pid — provided the entry has been evictable across
  two observations at least 60 seconds apart (grace against races; an
  unlink concurrent with an atomic replace removes only the old inode,
  and a live publisher's next write recreates the file whole). Entries
  with neither pane identity nor a pid are exempt — the reaper MUST NOT
  age things out by time alone. Consumers already hide evictable entries;
  reaping changes disk state, not rendered state. The designated reaper
  is whichever resident consumer the operator runs (tabard, when
  present); running two reapers is harmless in effect (unlink of an
  absent file is a no-op) but unsupported.

**A worked kind example (build):** a make wrapper publishes
`tasks.d/build-<name>.json` — working on start, done + outcome on exit,
waiting(attention: input) if it ever prompts; its extension block carries
the target and a log path. Removal at process exit is the publisher's job;
the pane check evicts it if the wrapper dies inside a tmux pane, and if it
has no pane identity the pid fallback catches a crashed wrapper.

Kind extension blocks are documented by their publishers, not here. The
AI-agent kinds that drove this design live with their publisher in the
operator's dotfiles (ship boundary, §8).

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
