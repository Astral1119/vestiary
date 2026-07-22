# Fresco State Model

Fresco keeps durable wallpaper policy separate from runtime evidence.
`state.json` is the only authoritative record. `status.json` is a disposable
snapshot for inspection and convergence tracking. Renderer process, window,
context, and device ownership are outside both contracts.

## Durable state

DECISION: `~/.config/fresco/state.json` contains desired policy only.

Every accepted transaction writes one complete state record through a
temporary file, `fsync`, and rename in the same directory. `revision` increases
for every accepted replacement. The record contains the stable display
registry, layouts, profiles, playlists, application rules, and the current
desired selection.

Observed inputs, resolved state, renderer health, and playlist cursors do not
belong in this record. No runtime producer may advance its revision.

## Status snapshot

DECISION: `~/.config/fresco/status.json` is non-authoritative runtime evidence.

The status publisher replaces or removes this file independently of durable
state. The state transaction never writes status. Status has no monotonic
writer revision; `desiredRevision` only identifies the durable input used by
the resolver. The snapshot records current observed inputs, effective
per-display output, and renderer evidence. Readers tolerate an absent, stale,
or unreadable snapshot.

Restart reconstructs status from durable state and current system observation.
Deleting status cannot change desired policy. A status snapshot never repairs
or overrides state.

## Stable identity

DECISION: display, profile, playlist, playlist-entry, and rule references use
opaque stable IDs.

Display IDs survive display reordering. The display registry may derive an ID
from durable hardware identity and retain a local alias when macOS cannot
provide one. Names are presentation data.

A connected display that is not yet in the durable registry still enters the
effective plan. Clone and span layouts include it. A per-display layout applies
its default binding. Explicit per-display assignments require a registered ID.

Wallpaper bindings retain Fresco's existing id-or-path target syntax in schema
version 1. A target is a Workshop ID or filesystem path accepted by `fresco
set`. Stable wallpaper-library identity can be added without changing these
bindings in a later schema version.

## Layouts

DECISION: every layout is exactly one of `clone`, `perDisplay`, or `span`.

`clone` applies one binding to every connected logical display.

`perDisplay` maps stable display IDs to bindings. `defaultBinding` applies to a
connected display without an assignment. An absent default leaves that display
idle. Assignments for disconnected displays remain durable.

`span` applies one binding across all connected logical displays. Version 1
does not persist a display subset or display order. Logical geometry and pixel
scaling come from observed status.

A binding is a wallpaper target, playlist reference, or idle request.

## Profiles and manual controls

DECISION: a profile is a named reusable layout, pause, mute, and optional FPS
ceiling policy.

The top-level `desired.profileId` selects a profile. Top-level layout, controls,
or FPS ceiling fields override the corresponding profile fields. An absent
profile selection uses the top-level values directly.

Durable manual controls are `paused` and `muted`. Hidden state is lifecycle
output. Lock, sleep, and other visibility producers report hidden reasons only
in status.

## Playlists

DECISION: playlist order and timing are durable; traversal position is runtime
status.

A playlist is an ordered, nonempty array of entries. Every entry has a stable
entry ID, one wallpaper target binding, and its own positive duration. A
playlist also declares sequential or shuffled traversal and whether traversal
repeats.

Status records the active entry and cursor checkpoint. Restart may resume from
that checkpoint when it remains compatible with durable state. Reordering an
entry does not change its identity.

## Application rules

DECISION: application rules apply temporary policy in ascending integer
priority with stable rule-ID tie breaking.

A rule names one or more bundle IDs. Running, frontmost, and fullscreen
conditions are each `ignore`, `require`, or `exclude`. Rule order in the JSON
array has no semantic effect. For equal priority, lexicographically later rule
IDs apply later.

Rule scope is global or the displays affected by matching applications.
Observed application windows determine affected displays. A rule with affected
display scope has no effect when the observer cannot associate a matching
application with a display.

Effects are limited to temporary profile selection, pause, mute, and FPS
ceiling. Profile selection is global-only because a profile owns the complete
layout. An affected-display rule may request pause, mute, and an FPS ceiling.
Pause and mute are positive requests. A later matching global rule wins for
profile selection. All matching FPS ceilings combine by taking the minimum.
Rule effects never persist into desired state.

## Effective reasons

DECISION: pause, mute, and hidden are independent effective states.

Each effective display in status contains one reason array for each state. Its
boolean is true exactly when its reason array is nonempty. Reason tokens are
stable strings such as `user`, `rule:<id>`, `locked`, `sleeping`, and
`occluded`. Producers add and remove only their own tokens.

Pause stops time-based rendering and media playback. Mute suppresses audio
without stopping rendering. Hidden removes visible output without implying
pause or mute. FPS ceiling resolution has its own reason array.

Scene audio ownership is runtime evidence derived from effective mute policy.
Assignments are grouped by exact `FrescoBinding` equality. Each group elects
the eligible assignment with the lexicographically smallest stable display ID;
all siblings remain hard-muted. An ownership change first waits for the former
owner's `muted` acknowledgement, then sends `unmute` to the current successor.
A stale unmute acknowledgement is reversed before another endpoint becomes
audible. Ownership and transfer progress never enter durable state.

## Lifecycle

DECISION: lifecycle changes update observation and effective status without
rewriting desired state.

Lock and sleep add hidden, paused, and muted reasons. Unlock and wake remove
only those reasons. Occlusion adds a pause reason according to effective
performance policy. Display disconnect removes that display from effective
status while preserving durable assignments. Display reconnect resolves the
same stable assignment again.

A renderer crash marks runtime status degraded. A restart creates a new runtime
generation and converges on the effective snapshot. Effective reasons remain
until their producers remove them.

## Legacy migration

DECISION: the legacy `~/.config/fresco/current` file is imported only when
`state.json` does not exist.

An empty legacy file becomes an idle clone layout. A nonempty value becomes a
clone wallpaper binding with the same id-or-path target text. Migration writes
schema version 1 at revision 1 and preserves `current` as rollback evidence.

Once state exists, `current` is a compatibility projection written from an
effective clone wallpaper when one exists. It is never read as a competing
authority. Status absence does not reactivate legacy migration.

## CLI compatibility

DECISION: existing commands remain shorthand for desired-state transactions.

`fresco set <target>` selects a clone wallpaper binding using the target text
unchanged. `fresco clear` selects an idle clone binding. `stop`, `restart`,
`status`, property commands, audits, scene asset commands, and agent
installation retain their current meanings.

Future display, profile, playlist, pause, and mute commands update state and
wait for an accepted revision before reporting success. Runtime-only visibility
commands operate through a lifecycle producer and do not create durable hidden
policy.

## Validation and recovery

DECISION: validation failure preserves the last accepted state and visible
output.

The state schema rejects malformed values and unknown fields. Semantic
validation additionally rejects duplicate stable IDs and dangling profile,
playlist, and display references. The status schema rejects malformed evidence
and mismatched booleans and reason arrays.

Startup preserves an invalid `state.json` for diagnosis and reports exact
validation errors. It may use a separately retained last-known-good state. It
must not partially load the invalid record, reset policy, or fall back to
`current` after versioned state has existed.

Schema version 1 readers reject unsupported versions. Future migration reads
one complete accepted version and writes one complete newer version.

## Verification

The fixtures cover clone, per-display, span, profiles, playlists, scoped rules,
status reasons, and legacy migration. Invalid cases cover structural and
cross-reference failures.

```sh
python3 tests/state_contract_test.py
```
