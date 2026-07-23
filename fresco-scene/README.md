# Fresco scene helper

`fresco-scene` is the separately licensed process boundary for Wallpaper
Engine scene support in Fresco. The executable inspects PKGV packages, reports
unsupported 3D objects, and implements the versioned supervisor protocol. A
renderer-enabled build owns an AppKit desktop window and renders the accepted
corpus-bounded 2D subset: images, particles and child systems, effects and
effect quads, custom shaders, text and text effects, SceneScript, media and
video textures, 2D puppets, and package sound. It emits `ready` only after a
completed draw without a graphics error. Fresco-supervised launches own
physical package playback through AVFAudio.

GBC Subaru, Arknights, and Lonely Cat satisfy the promotion contract. Elaina,
Hyuga Ghost, and Persona 3 Reload remain `reach`. GBC's independent five-bone
secondary motion passes on native OpenGL and ANGLE-on-Metal. Lonely Cat's
default English image-parent, font, passthrough, particle-child, lifecycle, and
performance gates pass on both backends. Arknights passes on both backends with
its authored cover crop retained. The other fixtures retain their documented
visual and configuration blockers.

The separate smoke target uses the same pinned upstream 2D scene core through
an AppKit OpenGL 4.1 context. Its baselines are Cat In Space, Shimmering
Particles, NieR, Balatro, Arknights, and Clock. The renderer-enabled protocol
tests also check Cat's first frame, 30 and 60 FPS cadence, runtime metrics,
pause and resume, clean shutdown, and a 3D rejection.

The helper is GPL-3.0. Fresco remains an MIT-licensed supervisor and
communicates with it through newline-delimited JSON over standard input and
output.

## Checkpoint status

The 2026-07-22 source checkpoint builds the complete native renderer, but it is
not a green or release-ready renderer checkpoint. The current native validation
run passes 128 of 130 tests. Scoped render-resource registration, explicit
audio-spectrum acknowledgement consumption, and distinct known-continuous
particle lifecycle evidence, source-contract alignment, and continuous media
preparation restored the current checkpoint. The SceneScript graph also
preserves Elaina's finite negative text-width state through the supported
zero-width crop. Media-properties events update hidden text layers
synchronously, which clears the media-text and Persona promotion gates. The
Persona generic-script tests also track the consolidated graph's deterministic
change totals. Rejected artwork retains its exact decoded content without using
continuous scene motion as mutation evidence. Session lifetime recovery uses
bounded time-sensitive pixel evidence and verifies retired resource generations.
Sub-millisecond coordinator wakes preserve the shared promotion runner's 60 FPS
cadence. Full-frame word hashing clears Elaina's video performance gate without
sampling. The media harness now distinguishes an exactly presented ready
revision from one newer revision decoded immediately after presentation. The
focused media evidence passes, but stress exposed a separate seek-deadline
replacement race. The latest full run still reported the superseded media
acknowledgment failure and a load-sensitive GBC performance miss; no full
checkpoint has run after the media correction.
Treat the promotion descriptions below as the intended acceptance contracts,
not as a claim that the current worktree satisfies every gate.

The isolated SDL3 slice remains green: its eight focused depth, correctness,
hostile-scheduling, and archive tests pass. Accepted lifecycle and SDL evidence
archives remain local and ignored by Git. See the repository handoff for their
identities and the exact native failure inventory.

## Build and test

The build requires macOS, CMake, the Xcode Command Line Tools, and Python 3.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

`tests/protocol_test.py` generates its own packages. When the Fresco fixture
manifest and Steam Workshop cache are present, the protocol and renderer suites
also compare helper behavior with every installed pinned package.

Build the renderer proof with:

```sh
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DFRESCO_SCENE_BUILD_RENDERER=ON
cmake --build build --target fresco-scene fresco-scene-render-smoke --parallel
ctest --test-dir build -R fresco-scene-renderer- --output-on-failure
```

CMake fetches the exact upstream renderer and dependency revisions recorded in
[`THIRD_PARTY.md`](./THIRD_PARTY.md). The correctness source manifest verifies
the renderer and GLM checkout revisions and tracked state. ANGLE builds instead
bind the declared ANGLE revision, consumed header hashes, and runtime dylib
content through their logical library paths. Retargeting a dylib symlink
therefore regenerates the manifest. Set `FRESCO_SCENE_RENDERER_UPSTREAM` to use
an existing checkout.
`FRESCO_SCENE_ASSETS` and
`FRESCO_SCENE_WORKSHOP_ROOT` override the auto-detected user-owned asset and
Workshop roots.

The renderer tests require those local assets. They cover six baselines, the
stretch acceptance corpus, explicit unsupported variants, lifecycle and
restart, visibility, properties, media, sound, particle, puppet, and 30 and 60
FPS gates. The helper test opens its window without ordering it. The tests
remove temporary images and do not commit Workshop content.

The default CTest manifest enables assertion-style performance gates only for
fixtures marked `available`. Set
`FRESCO_SCENE_ENABLE_REACH_PERFORMANCE_GATES=ON` while working on a `reach`
fixture. Those gates fail until the fixture satisfies the promotion budget.

[`angle/README.md`](./angle/README.md) records the bounded ANGLE-on-Metal
feasibility probe, its pinned revision, the GLES scene-core compile gate, and
the runtime boundary. The production renderer remains AppKit and OpenGL.

On the 2026-07-20 Apple silicon review host, the performance test observed 29.8
and 60.0 FPS, about 3.1 ms average render submission time, about 108 MiB RSS,
and sub-millisecond pause and resume acknowledgements. These are local test
results. They are not GPU-time or thermal measurements.

## Protocol

Every command and event carries `protocolVersion` and `assignmentID`.
Protocol version 1 currently accepts `hello`, `inspect`, `validate-assets`,
`probe-opengl`, `ping`, `load`, `metrics`, `audio-spectrum`, `media-session`,
`cursor-down`, `cursor-move`, `cursor-up`, `cursor-click`,
`capture-frame-difference`, `capture-puppet-evidence`, `user-properties`,
`pause`, `resume`, `mute`, `unmute`, `hide`, `show`, and `stop`. An
inspection-only build returns
`renderer-unavailable` from `load`. A renderer-enabled build revalidates the
package and assets, rejects model and light objects, creates its desktop window,
renders two frames, checks the completed draw, and then emits `ready`.
`load.muted` defaults to true, and the supervisor retains the hard mute until
its selected audio owner receives an acknowledged `unmute`.

`load.userProperties` carries a full nested `{key: {value: scalar}}` snapshot;
scalars are Booleans, finite numbers, or strings. `user-properties.properties`
carries changed-only updates. Finite sound-volume values resolve before autoplay
and fan out through the audio registry without entering QuickJS. The helper
preserves logical updates while muted.

`inspect` accepts a project directory or `scene.pkg` path. It classifies package
structure, not runtime readiness. Model and light objects return `unsupported`.
Unsupported cameras and volume-light shapes remain deferred. Empty-path 2D
cameras, effect quads, and bounded puppet packages remain inside the accepted
structural boundary. Runtime load performs the narrower semantic checks.

The runtime supports corpus-classified SceneScript, audio-responsive shaders
and particles, random and multi-asset sound, scripted and cursor-triggered
sound, media-session data and artwork, authored video textures, particle child
systems, and bounded puppet deformation, masks, layers, and attachments.
Unclassified script shapes and particle or puppet variants fail closed. GBC's
independent puppet secondary motion is supported; active IK remains deferred.
Model and light scenes remain hard unsupported; broader cameras, volume lights, and 3D
remain outside the runtime contract.

An exact scene containing one image object and one referenced nonfallback video
player, with no other object type or automatic runtime, uses tracked media
lifecycle scheduling. Decoded presentation timestamps become typed one-shot
deadlines, queued frames become revisioned resource-ready changes, and an
all-player end of stream is acknowledged once without retry scheduling.
Mixed media scenes retain conservative continuous scheduling. Pause and hide
freeze tracked playback until resume or show.

The internal QuickJS runtime exposes only corpus-proven APIs. Source and API
structure define runtime classification; fixture IDs, hashes, names, and source
lengths do not.

The real-package lifecycle gate exercises Arknights' delayed selection,
Persona's visibility selection, and GBC Subaru's cursor single-shot controller.
Recognition follows audited source semantics rather than fixture identity.
Referenced sound names must resolve uniquely; missing or duplicate ownership
fails closed. Private delay values retain their authored user-property binding
from dynamic-value metadata. The helper applies initial and changed properties
in lifecycle order and reports controller and sound-request evidence.

The protocol uses standard input and output exclusively. Renderer logs must go
to the assignment log path when persistent diagnostics are implemented.

[`PROTOCOL.md`](./PROTOCOL.md) defines the complete version 1 envelope,
commands, events, failure scope, and forward-compatibility rules.

## Provenance

The package reader files under `upstream/` are copies with normalized final
newlines from
linux-wallpaperengine commit
`b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d`. See
[`THIRD_PARTY.md`](./THIRD_PARTY.md) for the exact source map.

Distribution of a helper or renderer binary must include this source, the
corresponding upstream source and notices used by that build, local patches,
and build instructions. The current source layout is not a release packaging
decision.
