# ANGLE feasibility probe

VERDICT: ANGLE's Metal backend can render through a hidden AppKit-owned
`NSWindow` on this arm64 host. The Fresco scene core compiles against the
pinned ANGLE OpenGL ES 3.0 headers and owns EGL through the renderer surface
boundary. The pinned runtime build passes the window probe and all seven ANGLE
tests, including four temporal wallpaper fixtures. The ANGLE renderer remains
opt-in and unsupported for release while packaging and long-run stability are
unproven.

The pinned revision is `bc129145afe520b62f11dae1a80d821ebfd6f273` from
2026-07-16. ANGLE documents complete OpenGL ES 3.0 support through Metal on
macOS 10.14 and later. Metal is selected with
`EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE`.

## Evidence

`probe.sh runtime` creates an AppKit `NSWindow`, passes its view's `CALayer` to
EGL, requests an OpenGL ES 3.0 context backed by Metal, clears the default
framebuffer, reads one pixel, and swaps buffers. It loads a caller-supplied
ANGLE distribution at runtime so the test does not make an installed browser
part of Fresco.

On 2026-07-20, the probe passed on an Apple M4 Pro running macOS 26.5.1. The
candidate libraries were the universal ANGLE dylibs bundled with Chrome
150.0.7871.125. The reported renderer was `ANGLE (Apple, ANGLE Metal Renderer:
Apple M4 Pro, Version 26.5.1 (Build 25F80))` under OpenGL ES 3.0. The readback
pixel was `[32,64,128,255]`. The two dylibs occupied 14,865,632 bytes. This
proves the window, EGL, ES 3.0, Metal, draw, readback, and presentation path.
It does not prove the pinned revision or any Wallpaper Engine fixture.

On 2026-07-20, the pinned revision built with Xcode 26.6, Metal Toolchain
17F109, and `depot_tools`. The Metal-only release graph disabled ANGLE's broad
build, SwiftShader, WebGPU, Vulkan, desktop GL, and null backends. It produced
`libEGL.dylib` and `libGLESv2.dylib` totaling 5,911,200 bytes. The runtime
probe reported ANGLE revision `bc129145afe5`, OpenGL ES 3.0, and the Apple M4
Pro Metal renderer; its readback pixel was `[32,64,128,255]`.

The opt-in runtime build was tested separately with the ANGLE libraries from
Chrome 150.0.7871.129. This is unpinned development evidence. Cat completed
EGL setup, two draws, pre-swap readback, pause and visibility commands, and
clean shutdown. Its 640 by 360 readback contained 230,399 varying pixels with
an RGB range of 0 through 254. Clock also rendered nonuniform output, updated
all six script layers, and shut down cleanly.

Shimmering Particles no longer crashes after guarding a failed bloom-object
construction. Its authored emitter has no visible output in the two-frame
image readiness window, so particle-only scenes now advance a bounded 60
fixed-step frames before capturing readiness evidence. Shimmering then renders
nonuniform output and shuts down cleanly. Balatro is intentionally uniform at
two frames and renders nonuniform output after its authored 600-frame fade.

The pinned temporal ANGLE gate requests the same evidence frames as the native
baselines: Cat 120, Shimmering 120, Balatro 600, and Clock 120. All four produce
nonuniform readback with clean script and lifecycle evidence. This proves the
image, particle, effect, custom-shader, text, and text-script capabilities for
the pinned opt-in build. The complete ANGLE suite passes 8 of 8 tests:
protocol, audio-spectrum, sound registry, sound corpus/decode, helper lifecycle,
performance, ANGLE temporal coverage, and the internal QuickJS sound bridge.
The sound-registry test proves the
backend-independent lazy-player and single/loop state machine. The corpus test
proves that AVFAudio accepts selected NieR, Arknights, GBC Subaru, and Persona
assets. ANGLE validation does not enable runtime audio, so these checks do not
prove audible playback through an ANGLE renderer. The helper test also drives GBC
Subaru (`3448290956`) from a zero spectrum to 128
energized bins. Its final framebuffer changes 2,083 of 230,400 pixels with a
maximum RGB-channel delta of 154 and no graphics or script error, matching the
native pixel count and maximum delta.

The same helper gate evaluates GBC's two scripted animation-rate floats.
Silence yields 1.5 and energized 16-bin band zero yields 10 for both stable
keys. Their independent counters freeze while paused. A same-process reload
destroys the old closures and recreates exactly two keys at 1.5 with fresh
counters. Native OpenGL and pinned ANGLE produce identical value and lifecycle
evidence.

The helper accepts audited delayed selection, visibility selection, and cursor
single-shot controller shapes without fixture fingerprints. Both backends prove
ordered initial and changed property delivery, logical sound requests,
pause-safe stop ordering, and fresh same-process reload state. Arknights binds
its private delay through authored dynamic-value metadata and transitions within
the bounded paced-frame gate. Missing or duplicate sound-name ownership fails
closed. Generic property scripts remain excluded.

## Scene-core boundary

The `angle-gles-compile` backend builds the pinned Fresco-linked scene core
against caller-supplied ANGLE headers. The authored shader and glslang
intermediate remain in the upstream desktop GLSL 330 dialect; SPIRV-Cross
alone emits GLSL ES 3.00. Converting the intermediate to the ES dialect made
previously tolerated undefined macros and mixed float/integer arithmetic fail
before translation. Wallpaper composition and text shaders compile directly
as ES 3.00. The native build remains the default.

The compatibility layer converts the two double-uniform paths to floats.
Border clamp falls back to edge clamp. Depth clamp and anisotropic filtering
are skipped because ES 3.0 does not guarantee their extensions. Debug labels
and groups compile to no-ops. Dormant upstream texture-readback and BGRA paths
remain outside the linked source set.

The raw-upstream audit still reports the 16 desktop occurrences and 21 debug
calls that the compatibility layer covers. The compile gate is authoritative:
it compiles every source linked into the scene core with `GLES3/gl3.h`. On
2026-07-20 it passed against the headers from pinned ANGLE revision
`bc129145afe520b62f11dae1a80d821ebfd6f273`.

Cat In Space (`3351508588`) passes the image baseline with nonuniform
readback. Clock (`2999232230`) passes the text-script baseline after placing
the ES `#version` directive at byte zero. Shimmering Particles (`1568648985`)
passes the particle/effect baseline after its bounded readiness warm-up.
Balatro (`3402326745`) passes the delayed custom-shader baseline at 600 frames.
All four fixtures therefore pass with the pinned libraries; release support is
not yet claimed.

Run the gates with:

```sh
fresco-scene/angle/probe.sh preflight
fresco-scene/angle/probe.sh build /path/to/angle-checkout
fresco-scene/angle/probe.sh runtime /path/to/pinned-angle/out/fresco-metal
fresco-scene/angle/probe.sh audit /path/to/linux-wallpaperengine
fresco-scene/angle/compile-gate.sh /path/to/pinned-angle-checkout
fresco-scene/angle/validate.sh /path/to/pinned-angle-checkout
```

The compile gate verifies the checkout revision before using its headers. It
does not link ANGLE or advertise an ANGLE renderer through the helper protocol.
The validation gate checks the pinned revision, arm64 dylibs, dylib install
names, and fixture package hashes. It then builds the opt-in runtime and runs
the protocol, audio-spectrum, sound-registry, sound-script-bridge,
sound-corpus/decode, helper, performance, and temporal tests. Runtime sound
remains muted during this gate.

The development runtime build additionally accepts
`FRESCO_SCENE_RENDER_BACKEND=angle-metal`,
`FRESCO_SCENE_ANGLE_INCLUDE_DIR`, and `FRESCO_SCENE_ANGLE_LIBRARY_DIR`. Only
that configured build advertises `angle-metal`. Native OpenGL remains the
default. Its executable rewrites the candidate libraries' relative install
names to `@rpath` references, so a normal helper launch does not require a
`DYLD_LIBRARY_PATH` wrapper.

The pinned ANGLE build should use a standalone checkout at the revision in
`REVISION`, `target_cpu = "arm64"`, `is_component_build = false`,
`is_debug = false`, `angle_build_all = false`, and only the Metal backend
enabled. The `build` gate clones,
syncs, builds `libEGL` and `libGLESv2`, verifies that the checkout stayed at the
pinned revision, and runs the window probe. An existing checkout resumes only
when its origin and current revision match the pinned source. The result is
ready for the four fixture gates only after the compatibility audit is clean.

## Distribution and rollback

A Fresco release would ship `libEGL.dylib`, `libGLESv2.dylib`, ANGLE's license,
and the source/revision offer required by Fresco's GPL helper distribution.
The pinned arm64 dylib footprint is about 5.6 MiB before signing or universal
architecture policy. CMake rejects installation of an `angle-metal` build
until that packaging work exists. Build-tree execution remains the supported
development path.

The current AppKit/OpenGL renderer remains the rollback path. ANGLE work should
enter behind a build option and runtime backend selection. Removing the ANGLE
option and its two dylibs restores the current helper without changing the
supervisor protocol or AppKit window ownership.

Primary references: [ANGLE development setup](https://chromium.googlesource.com/angle/angle/+/bc129145afe520b62f11dae1a80d821ebfd6f273/doc/DevSetup.md),
[ANGLE platform support](https://chromium.googlesource.com/angle/angle/+/bc129145afe520b62f11dae1a80d821ebfd6f273/README.md), and
[`EGL_ANGLE_platform_angle_metal`](https://chromium.googlesource.com/angle/angle/+/bc129145afe520b62f11dae1a80d821ebfd6f273/extensions/EGL_ANGLE_platform_angle_metal.txt).
