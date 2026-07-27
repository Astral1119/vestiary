# Fresco scene helper protocol

Version 1.

DECISION: Fresco and `fresco-scene` communicate through UTF-8
newline-delimited JSON over the helper's standard input and output. The helper
owns scene parsing and rendering. Fresco owns selection, lifecycle, recovery,
properties, audio capture and spectrum delivery, effective mute policy, media,
and fallback. The helper owns package sound registration, decode, and per-layer
playback. Fresco arbitrates which display assignment may be audible when an
exact wallpaper binding is cloned.

## Transport

Each line is one JSON object. The helper writes protocol events only to
standard output. Diagnostics that are not protocol events go to standard error
until assignment log paths are implemented.

Before a coordinated frame decision, the helper drains all input bytes that
are immediately readable and handles every complete line in order. A buffered
line without its terminating newline blocks frame scheduling but does not busy
poll; the helper waits for more input. End of file handles preceding complete
lines, discards an unterminated final fragment, and exits without another frame
decision.

The helper is silent at startup. Fresco sends `hello` before commands that
depend on advertised capabilities. Events for one assignment retain command
order. Protocol version 1 does not define cross-assignment ordering.

Every valid command and event contains these fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `protocolVersion` | integer | Exactly `1` |
| `type` | string | Command or event name |
| `assignmentID` | non-empty string | Fresco-owned identifier for one display assignment or inspection |

Malformed JSON and envelopes without a usable assignment ID return a `warning`
with an empty `assignmentID`. A protocol-version mismatch returns an
assignment-scoped `fatal` event.

## Commands

`hello` requests the helper version, renderer state, and capability names.

`inspect` requires `path`. The path may identify a project directory containing
`scene.pkg` or the package itself. Inspection opens no window and requires no
official asset root.

`validate-assets` requires `path`. The path may identify an `assets` directory
or its Wallpaper Engine installation parent. Validation is read-only. It checks
the built-in shaders used across the pinned 2D corpus and the Cat In Space halo
texture. The profile name is `fixture-corpus-2d-v1`.

`probe-opengl` creates an unshown AppKit desktop-level window, requests a
forward-compatible OpenGL 4.1 core context, clears a texture-backed framebuffer,
and reads one pixel. It is a platform gate, not a renderer-ready event.

`ping` requests a `heartbeat` event. It does not prove that a render loop is
advancing.

`load` requires `path` and `assetRoot` in a renderer-enabled build. Optional
`x`, `y`, `width`, and `height` values place the AppKit window in global screen
coordinates. `fps` defaults to 60 and accepts values from 1 through 240.
When present, `fps` is a non-boolean finite integer.
`policyRevision`, when present, is a non-boolean finite nonnegative integer and
is supervisor-owned. A load that omits them defaults to 60 FPS and revision 0.
`reasonTokens` records the reasons that selected the FPS ceiling. Fresco sends
all three fields in the initial load so a configured ceiling cannot race the
first frame loop. A malformed scheduling field makes the load assignment-fatal
without terminating the helper process.
`visible` defaults to true; tests set it false to exercise the render path
without ordering the window. `load.muted` defaults to true. Fresco always loads
a supervised renderer hard-muted and changes that state only through an
acknowledged `mute` or `unmute` command. `realtimeClock` defaults to false,
advancing the animation clock by a fixed `1/fps` step per frame so an unpaced
render reproduces bit-for-bit. Fresco sets it true in production so the clock
tracks real elapsed time and animation speed stays independent of the frame-rate
ceiling. `capture-frame-difference` evidence stays fixed-step regardless.
`load.userProperties` accepts the full
Wallpaper Engine property shape `{key: {value: scalar}}`, where a scalar is a
Boolean, finite number, or string. Sound-volume bindings accept only finite
numbers. The helper merges valid overrides with numeric defaults
from `project.json` before sound registration and autoplay. The helper
re-inspects the package, rejects model and light objects, revalidates the
official assets, creates the configured graphics context and window, renders
two fixed-step evidence frames, and reads back before presentation.
Particle-only scenes use a bounded 60-frame evidence
window so authored emitters can become visible. Tests may request an explicit
`evidenceFrames` value from 1 through 600 to reproduce temporal baselines; it
does not change steady-state scheduling. The helper emits `ready` only after a
completed GPU draw without a graphics error. `collectRenderDurationSamples`
defaults to false. Performance diagnostics set it true to retain the
prefix-stable per-frame render-duration history returned by `metrics`; hidden
and paused sessions do not extend that history.
Pixel range and variation remain
evidence fields, but an authored uniform startup frame is valid. Text-script
layer, update, and value-change counts provide additional evidence. The
inspection-only build returns `renderer-unavailable` and never emits `ready`.

Tests may set `staticContent` for an inspected empty scene containing no
effects, shader files, puppets, audio, or scripts. The helper then presents on
explicit change and sleeps after the initial evidence frames. Production scene
loads do not set this field. `FRESCO_SCENE_LEGACY_FRAME_LOOP` restores
continuous pacing for rollback and comparison. `schedulingMode` is
`static-present-on-change`, `tracked-particle-lifecycle`,
`tracked-media-lifecycle`, `tracked-audio-lifecycle`, or `legacy-continuous`.
The tracked particle mode
applies only when every
inspected object instantiates as a recognized finite particle system. Unknown
particle graphs retain conservative continuous scheduling and emit a warning.
Recognized continuous emitters and mixed particle graphs also retain continuous
scheduling, but are not reported as unknown lifecycle.
The tracked audio mode applies only to one supported image or text object with
one exactly classified 16-bin audio-vector scale transform and no effects,
custom shaders, puppets, audio assets, deferred scripts, or automatic dynamic
value animations. A recognized source-level near match remains a generic
audio-vector transform but does not qualify for tracked scheduling. Mixed or
unclassified audio scenes remain conservatively continuous.
`schedulingMechanism` distinguishes the `change-index-v1` coordinator from the
`legacy-frame-loop` rollback path.

`scheduling-policy` updates `fpsCeiling`, `policyRevision`, and `reasonTokens`
after `ready`. `fpsCeiling` is a non-boolean finite integer from 1 through 240;
`policyRevision` is a non-boolean finite nonnegative integer. The command does
not change pause or visibility. A successful update returns
`scheduling-policy-applied` with the applied values. Revisions must not
decrease. An older revision returns `stale-scheduling-policy`. Replaying an
identical payload at the applied revision is accepted idempotently. A different
payload at the applied revision returns `conflicting-scheduling-policy`. Both
warnings preserve the applied FPS, revision, and reason tokens.
Malformed updates return `invalid-scheduling-policy` and likewise leave the
applied policy unchanged.

`pause` and `resume` stop and restart frame production after `ready`. Each
returns a matching `paused` or `resumed` event.

`mute` and `unmute` suppress and restore helper-owned sound after `ready`.
Each returns a matching `muted` or `unmuted` event. Mute is independent of
pause: it changes player volume without changing render or playback state.

`user-properties` carries a changed-only `properties` object with the same
typed scalar shape. Known sound-volume bindings fan out to every bound sound
layer. Values are clamped from 0 through 1 in the audio registry.
Updates while muted change logical volume and take effect on the next unmute.
Invalid and unbound entries leave current volumes unchanged. A successful
command returns `user-properties-applied`; a command for another assignment
returns `assignment-mismatch`.

`hide` orders the desktop window out without destroying the renderer. `show`
orders it back at the desktop level. They return `hidden` and `shown` events.
Fresco retains the desired pause, mute, and visibility states across helper
restarts.

`metrics` returns a point-in-time renderer measurement after `ready`. It does
not force a draw or change lifecycle state.

`audio-spectrum` supplies the active renderer with one Wallpaper Engine
stereo spectrum frame in `values`. The array contains exactly 128 finite
numbers from 0 through 1: indices 0 through 63 are left-channel bins and 64
through 127 are right-channel bins. The renderer copies the 64-bin channels
directly and derives its 32- and 16-bin shader inputs by averaging adjacent
groups of two and four. A silence frame therefore clears values from a prior
nonzero frame. Output mute does not gate this external input: it suppresses
playback output while audio-reactive visual state continues to update. A
successful command returns `audio-spectrum-applied` with whether the float-bit
content changed, cumulative input and change counts, the exact 128-bin content
hash, the real stereo-16 downsample hash, and band-zero stereo average.
Malformed frames return one `invalid-audio-spectrum` warning; a frame whose
assignment does not own the active renderer returns one `assignment-mismatch`
warning. Rejected frames do not change renderer state.

Renderer builds advertise `script-audio-float-16-average0` for one accepted
SceneScript shape. GBC Subaru's two puppet animation-rate values call
`engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16)` and read
`audioBuffer.average[0]` from `update(value)`. The helper evaluates those two
float values once at registration and once per rendered frame. The getter
returns a new one-element array containing the stereo average of 16-bin band
zero. It is not a persistent `Float32Array` and does not implement the broader
AudioBuffers API. Other source shapes enter the generic corpus classifier and
are rejected if they use an unclassified API or value shape.

`media-session` requires `kind` and a `payload` object. Accepted kinds are
`status`, `playback`, `properties`, `timeline`, and `thumbnail`. Status carries
Boolean `enabled`; playback carries integer state 0 through 2; properties carry
optional string `title`, `artist`, and `albumTitle`; timeline carries
nonnegative finite `position` and `duration`; thumbnail carries a string data
URI plus optional color strings, or an empty string to clear artwork. The
renderer returns `media-session-applied` with revision and artwork evidence.

`media-video` requires action `seek` and a finite, nonnegative
`positionSeconds`. It applies the seek to every video texture in the active
assignment and returns `media-video-applied` with the action, position, and
player count. A seek starts a new rolling decoded-semantic-sequence epoch, so
sequence hashes compare post-seek decode paths without including earlier
playback history.

Tracked media lifecycle scheduling applies only to an exact media-only shape:
one object, one image object, one object type, one referenced video player,
and no fallback player, effect, shader, puppet, audio file, script value, or
automatic dynamic-value animation. A second object or player, an unreferenced
player, or any mixed automatic animation keeps the scene on conservative
continuous scheduling. This classification combines inspected package shape
with constructed runtime-player evidence.

Each tracked player reports one of four preparation facts: frame ready,
stalled, terminal, or a future presentation wake. Aggregation sums ready and
stalled evidence and selects the earliest player wake. Ready evidence wins
over simultaneous terminal evidence. The aggregate is terminal only when it
contains at least one player, every player is terminal, and no player has a
ready frame.

The coordinator represents the next decoded presentation timestamp as a typed
one-shot media deadline. A decoded and queued frame releases that deadline and
records a media resource-ready invalidation before the accepting frame
decision. Presentation acknowledges the same change revision. Replacing a
future timestamp replaces the one-shot lease; exhausting or deactivating the
player releases it. Paused or hidden sessions freeze the media clock and do
not decode, upload, evaluate, present, or retain a media deadline. Resume or
show continues from the frozen position rather than adding inactive wall
time. Terminal end of stream produces one terminally suppressed evaluation,
acknowledges its terminal change and consumed lease, and schedules no retry.

`cursor-down`, `cursor-move`, and `cursor-up` carry numeric scene coordinates in
`x` and `y`. They return `cursor-event-dispatched` with the phase and whether a
classified script handled it. `cursor-click` carries integer `objectID` and an
optional finite `monotonicMilliseconds` test clock. It returns `cursor-clicked`
with the object ID and handled state.

`capture-frame-difference` renders one fixed-step frame and compares its final
RGB framebuffer with the most recent evidence readback. It emits
`frame-difference`. Its `presented` Boolean reports whether that draw actually
reached surface presentation. A presented diagnostic frame advances the
coordinator's presentation floor without consuming pending invalidations. This
is a diagnostic and acceptance-test command; it does not alter the supplied
audio spectrum or lifecycle state.

`capture-puppet-evidence` emits `puppet-evidence` without forcing a draw. It
reports loaded meshes, vertices, masks, attachments, deformation uploads and
changes, mask passes, attachment resolutions, simulation-enabled bones, and
active IK bones. GBC currently reports five simulation-enabled bones and zero
active IK bones, but no independent secondary-motion step or change evidence.

`stop` requests a `stopped` event and clean process exit.

Unknown commands return `warning` and leave the process available.

## Events

`hello` contains `helperVersion`, `renderer`, and `capabilities`. A
renderer-enabled build also contains `backend`, `graphicsAPI`, and
`shaderTarget`, and advertises `audio-spectrum`, `mute-unmute`, and
`runtime-metrics` in addition to its render and lifecycle capabilities.
Renderer builds also advertise `frame-difference-evidence` and
`scheduling-policy-v1`. `shaderTarget` names its language, version, and
profile.

`inspected` contains the canonical `path`, `supported2D`, measured package
contents, deferred types, and warnings. It means the package lies inside the
declared 2D object boundary. It does not claim render compatibility.

`unsupported` has the same inspection payload and a non-empty
`hardUnsupportedTypes` array. Version 1 treats model and light objects as hard
3D boundaries.

`assets-validated` contains the canonical asset root, validation profile,
required paths, and an empty `missing` array.

`assets-invalid` contains the candidate path and either missing paths or an
input error. It does not modify the candidate directory.

`opengl-probed` contains the OpenGL version, vendor, renderer, profile flags,
framebuffer status, read pixel, GL error, window level, and ordering state. The
proof window must remain unshown.

`ready` contains the renderer name, backend, graphics API, shader target,
target FPS, framebuffer dimensions, rendered frame count, completed-draw
state, RGB range, varying-pixel count, text-script counters, ordering state,
window level, and any deferred-capability warnings found during package
inspection.
`display` contains the surface's logical and pixel dimensions, integer scale in
thousandths, maximum refresh rate in `maximumRefreshMilliHertz`, and AppKit
color-space name.
`programCacheEntries` is the number of live generated render programs owned by
the active render context.
`programCacheInsertions` is the cumulative number of generated programs
inserted for that context during the active session.
`soundVolumeBindings` counts bound sound layers. `soundVolumeProperties` counts
distinct property keys. `initialUserProperties` reports received, applied, and
ignored load overrides, accepted script properties, and queued property scripts
plus at most 16 diagnostics.

`ready`, `frame-difference`, and `metrics` include
`scriptedDynamicFloats`. Each entry contains its stable object-and-animation
key, current float value, update count, and change count. The aggregate
`scriptedDynamicFloatUpdates` and `scriptedDynamicFloatChanges` fields count
all accepted values. Paused renderers do not advance these counters.
Replacing the loaded renderer destroys the script closures. A same-assignment
reload starts new keys at their registration counts with a fresh silent
spectrum.

The same events include `sceneZoomActive` and `sceneZoom` for a supported
scene-level camera-zoom property script. `sceneZoomActive` distinguishes an
authored scene transform from the default value; `sceneZoom` is the finite,
positive zoom selected by the script's captured Boolean property. These fields
are independent of `camera2DActive` and `camera2DZoom`, which report the
separate bounded 2D camera-control API.

`ready`, `frame-difference`, and `metrics` include `textEffectChains`. Each
entry reports `objectID`, `mode`, `reason`, authored-order `activeEffectIDs`,
`blockingEffectIDs`, nullable `firstBlockingEffectID`, `firstBlockingStage`,
and `supportedActiveEffects`. `mode` is `composited`, `direct-fallback`, or
`rejected`. `firstBlockingStage` is `none`, `effect`, `pass`, or `material`.

`direct-fallback` means the renderer executed the direct glyph path for the
whole active chain. Inactive effects do not block the chain. An all-inactive
retained chain reports `direct-fallback` with reason
`text-effect-chain-inactive`. An unsupported or malformed active member, or a
final pass targeting an internal framebuffer, blocks the whole chain. The
renderer does not composite a supported prefix or suffix around a blocker.

The same events report the pinned property controllers through
`propertyScripts` and the aggregate `propertyScriptControllers`,
`propertyScriptInitializations`, `propertyScriptPropertyApplications`,
`propertyScriptUpdates`, and `propertyScriptErrors` fields. `soundControls`
reports bounded per-layer physical and logical requested playback state plus
script-request counts. `playerConstructed` reports successful backend player
construction. `activeAsset` is the selected authored asset path or `null`.
`error` contains the current layer error. Logical state remains available when
the physical backend is disabled and preserves intent across a global context
pause.

`paused` and `resumed` confirm the corresponding lifecycle command. `muted`
and `unmuted` confirm the corresponding audio command.

`user-properties-applied` contains `received`, `appliedProperties`,
`appliedSoundLayers`, `acceptedScriptProperties`, `queuedPropertyScripts`,
`ignored`, and at most 16 diagnostic strings. Counts are bounded aggregates;
the event does not enumerate sound assets or property values.

`hidden` and `shown` confirm the corresponding window command.

`scheduling-policy-applied` confirms the effective FPS ceiling, policy
revision, and reason tokens. It does not imply a draw.

`metrics` contains backend, graphics API, shader target, target FPS, elapsed
time, frame count, average and maximum frame interval, average and maximum
render submission time, missed interval count, text-script counters, and the
current pause, mute, and visibility states. `elapsedMilliseconds` is session
wall time; `sceneClockSeconds` is the scene animation clock that drives
shaders, particles, and puppets. Comparing the two over an interval measures
whether scene time runs at wall rate, which is what distinguishes a clock
defect from one in what consumes the clock. The `muted` field reports the
helper's current hard-mute state. The render timings include host
submission and buffer flush work. They are not GPU hardware counters. It also
contains `soundVolumeBindings`, `soundVolumeProperties`, and the current
`programCacheEntries` and cumulative `programCacheInsertions`.
`policyRevision` and `reasonTokens` identify the applied scheduling policy.
`schedulingMode` is `legacy-continuous`, `static-present-on-change`,
`tracked-particle-lifecycle`, `tracked-media-lifecycle`, or
`tracked-audio-lifecycle`.
`schedulingMechanism` is `change-index-v1` for the coordinator or
`legacy-frame-loop` for rollback. `schedulingEvidence` is `null` on the legacy
path. On the coordinator path it reports saturating invalidation, decision, evaluation,
presentation, suppression, external-presentation, and missed-deadline counts;
the next wake; reason counts; and the most recent decision and completion.
`nextWakeNanoseconds` is recomputed after every scheduler mutation. It is the
transport-authoritative deadline for the next poll rather than a snapshot of
the last frame decision.
It also reports `scriptTimerDeadlineSchedules` and
`scriptTimerDeadlineReleases`, plus `particleLeaseAcquisitions` and
`particleLeaseReleases`. Tracked media adds
`mediaFrameDeadlineSchedules`, `mediaFrameDeadlineReplacements`,
`mediaFrameDeadlineReleases`, and `mediaFrameDeadlineActive`. These count
typed lease acquisition, active-deadline replacement, release, and current
ownership rather than decoded frames. The bounded
last-decision and last-completion payloads carry the ready-change and
acknowledged-change revisions used to establish the causal path from a queued
media frame to its presentation. A terminal suppression increments
`presentationSuppressions`, reports the terminal result in `lastCompletion`,
and consumes the terminal revision without incrementing `presentations`.
Tracked audio adds `audioEnvelopeDeadlineSchedules`,
`audioEnvelopeDeadlineReplacements`, `audioEnvelopeDeadlineReleases`, and
`audioEnvelopeDeadlineActive`, plus typed audio-ready invalidation,
presentation, latest-revision, presented-revision, and decision-sequence
evidence. An authored transform change schedules one next-frame deadline. A
due unchanged tick consumes that one-shot deadline and becomes inactive
without counting an explicit release; pause or hide before the due tick counts
an explicit release. Exact float-bit input changes use the typed audio-ready
causal path, while repeated identical input does not invalidate.
`audioVectorScripts` counts all recognized audio-vector transforms.
`exactTrackedAudioVectorScripts` counts the exact source subtype eligible for
tracked lifecycle classification. `audioVectorValueX` reports the current
authored transform's x component after graph synchronization.
`scriptTimers` reports scheduled, fired,
cancelled, and pending counts; the next due time; the current graph clock; and
the most recent scheduled delay and fire times. `scriptTimeMilliseconds` is
the same graph clock used by authored timers. `deferredScriptValues` is the
exact runtime count of instantiated unclassified scripts.
Variable-length evidence is retained in fixed 16-item snapshots with an
explicit `truncated` count.
`reasonCounts` is indexed by the numeric `SchedulerReasonId`; continuous lease
is index 6 and FPS ceiling is index 8 in version 1.
Timer deadline is index 4 and conservative unknown-producer scheduling is
index 7. `continuousGenericPropertyScripts` counts scripts with an authored
`update` function or registered scene-update callback. Event-, property-, and
timer-only scripts are tracked on change; deferred scripts remain fail-live.
A `metrics` command wakes the transport loop and therefore contributes one
no-work scheduler decision after its snapshot. It does not cause an evaluation
or presentation for quiescent static content.
`renderDurationSamplesMilliseconds` is empty unless its load option was true.
`renderAllocations` reports live, peak, allocation, and deallocation counts
for generated pass and shader heap ownership diagnostics.
`mediaTextures` reports constructed, referenced, temporally active,
script-controlled, playing, paused, fallback, and end-of-stream player counts.
It also reports decode attempts, decoded frames, queued-frame readiness,
stalls, uploads, pending frames, seeks, uploaded bytes, decode milliseconds,
upload-submission milliseconds, the latest decoded presentation timestamp,
the latest decoded semantic hash, and the rolling decoded-sequence hash.
Global live, construction, and destruction counts span renderer-session
replacement within the helper process. Decode and upload timings measure host
work; they are not GPU hardware counters.
`particles` reports instantiated, finite, and unknown system counts; minimum
and maximum authored runtime seeds; whether a
continuous lease is required; quiescence; simulation and catch-up counts;
requested, simulated, and dropped time; maximum requested and simulated steps;
emitted, live, and peak-live particles; pool capacity and resize count;
resource initialization count; and a deterministic live-state hash. These are
runtime lifecycle and resource facts, not pixel-equivalence claims.
`audioSpectrumInputs`, `audioSpectrumChanges`, `audioSpectrumHash`,
`audioVectorHash`, and `audioVectorAverage0` report real spectrum ingestion and
downsampling. `audioVectorScriptUpdates`, `audioVectorScriptChanges`, and
`audioEnvelopeContinuousRequired` report the authored transform and whether
its most recent tick changed the dynamic value and therefore requires one
settling tick.

`frame-difference` contains the current frame evidence plus `presented`,
`changedPixels`,
`maximumChannelDelta`, and `totalChannelDelta`. Alpha is excluded. The first
field counts pixels with at least one changed RGB channel; the latter fields
report the largest single-channel absolute delta and the sum of all absolute
RGB channel deltas. A successful event follows a completed readback without a
graphics error and becomes the reference for the next capture.

`audio-spectrum-applied`, `media-session-applied`, `media-video-applied`, `cursor-event-dispatched`,
`cursor-clicked`, and `puppet-evidence` confirm their corresponding renderer commands. They are
assignment-scoped and return `renderer-not-loaded` or `assignment-mismatch`
warnings without changing renderer state when their preconditions fail.

`heartbeat` answers `ping`.

`warning` reports recoverable malformed input or an unknown command. It
contains `code` and `message`.

`fatal` contains `code`, `message`, and `scope`. Scope `assignment` rejects the
named operation while retaining the process. Scope `process` requires Fresco to
discard the helper and apply restart policy. Renderer setup and frame failures
are process-scoped. Input, package, and asset rejections are assignment-scoped.

`stopped` confirms a clean stop. End of file without `stopped`, a signal exit,
or a nonzero exit is an unclean helper termination.

The protocol does not yet emit periodic `frame` events. `ready` follows
successful window, asset, package, and first-frame setup.

## Inspection boundary

Inspection reports package version, byte and file counts, object counts by
type, effects, shader files, puppet models, audio files, and scripted values.
The helper validates the package table and every file range before calling the
pinned upstream parser.

Script counts separate `textScriptValues`, `audioFloatScriptValues`, and
`deferredScriptValues`. The audio-float count uses the same exact source
recognizer as runtime registration, so inspection does not classify broader
AudioBuffers scripts as accepted.

Model and light objects produce `unsupported`. Unsupported cameras and
volume-light shapes produce deferred diagnostics. Empty-path 2D cameras,
effect quads, and bounded puppet packages remain inside the structural 2D
boundary. Puppet deformation, masks, layers, attachments, and GBC-bounded
independent secondary motion are supported. Active IK remains deferred. Static
text, text effects, persistent text-layer SceneScript, and the GBC-compatible 16-bin
band-zero animation-rate subset are supported. Package sound is available on
the supervisor-enabled physical-playback path.

The internal QuickJS foundation exposes an `ISoundLayer` adapter to persistent
script wrappers. `thisScene.getLayer` accepts exact names or
numeric authored layer indices; missing, invalid, and non-sound lookups return
`null`. The adapter contains writable finite clamped `volume`, `play`, `pause`,
`stop`, and `isPlaying`.

Runtime SceneScript classification follows source and API structure and rejects
unclassified surfaces. Fixture IDs, object names, source lengths, and hashes
are not classifier inputs. The acceptance corpus includes delayed and
visibility selection, cursor sound, layer and camera transforms, storage,
timers, media, text, sound, and animation controls. Referenced sound names must
resolve to exactly one authored layer; missing and duplicate names remain
unowned. Dynamic SceneScript outside the classified corpus remains deferred.

The acceptance gate expects aggregate `propertyScriptControllers`,
`propertyScriptInitializations`, `propertyScriptPropertyApplications`,
`propertyScriptUpdates`, and `propertyScriptErrors` fields. Its bounded
`propertyScripts` entries identify `key`, `profile`, `objectId`, `property`,
authored `value`, initialization state, seeded and active delay seconds,
property-application count, and update count. Existing evidence labels remain
`bounded-private-music-visibility-v1` and `music-visibility-property-v1` for
protocol continuity; keys and object IDs are evidence, not classifier inputs.

Each controller is compiled during object construction. Its first rendered
tick seeds Arknights' private `delayTime` string from the effective full-snapshot
authored user-property binding from `DynamicValue` metadata, calls `init` once,
applies the full initial user-property
snapshot, and then calls `update` when present. Changed properties apply before the next
update; paused changes remain queued until resume, and apply before audio is
resumed. Undefined or non-Boolean update results preserve the authored visible
value. Destruction invokes an optional `destroy` hook before scene objects are
released.

Sound-volume user bindings do not pass through QuickJS. The helper resolves
their numeric project defaults and load overrides before `CScene` construction,
then applies changed-only updates through the audio registry. This path does not
enter QuickJS.

The helper advertises `sound-playback` only when
`FRESCO_SCENE_SOUND_EXPERIMENTAL=1` and `FRESCO_SCENE_AUDIO_DISABLED` is not
`1`.

Inspection's `deferredScriptValues` count is conservative because inspection
does not instantiate the runtime classifier. Promotion decisions use runtime
readiness and semantic-classification evidence, not that structural count
alone.

## Compatibility

New optional event fields are additive within version 1. Receivers ignore
unknown fields. New commands, changed field meaning, or new required fields
need a protocol-version decision. The helper rejects unsupported versions
instead of guessing compatibility.
