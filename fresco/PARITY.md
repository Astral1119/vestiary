# Wallpaper Engine parity

Fresco's web runtime is usable, but it is not yet a Wallpaper Engine
replacement. The reliability and persisted-property foundations are complete.
The scene review accepted a bounded 2D helper prototype and rejected in-process
linking, immediate Metal work, and a first-phase 3D claim.

The 2026-07-22 source checkpoint qualifies the historical acceptance results
below. The clean native renderer builds, but 129 of 130 tests pass in the
current worktree. Rejected artwork retains its exact decoded content. Session
lifetime recovery verifies bounded time-sensitive pixel evidence and three
retired generations before replacement. Sub-millisecond coordinator wakes clear
the Arknights, GBC, and Lonely promotion-performance gates. Full-frame word
hashing clears Elaina's video performance gate without sampling. No reproducible
renderer failure remains from the ready-revision assertion: the media harness
now permits one strictly newer decoded revision pending after an exactly
acknowledged presentation. Seek acknowledgments now carry their synchronous
deadline mutation instead of relying on a later PTS sample. Twenty consecutive
focused media runs pass. The latest native checkpoint passes 129 of 130 tests;
only GBC camera-control's load-sensitive framebuffer equality check failed, and
it passed in isolation. The focused SDL3 suite passes eight of eight tests, and
the accepted lifecycle and SDL archives still verify. See the repository
handoff for the native failure inventory. No new renderer capability should be
inferred from this document until that failure is triaged.

## Baseline

The 2026-07-19 audit of all 13 installed web projects and presets produced three
passes, ten warnings, and no hard failures. The warnings were six authored-page
diagnostic sets, three intentional uniform renders, and one inactive stale
Windows asset path. Every item produced a durable JSON report and PNG snapshot.
The audit left the selected wallpaper and daemon PID unchanged.

Property review described all 13 targets and 1,725 editable controls. Every
display condition resolved to active or inactive; none resolved to unknown.
Interaction tests persisted and reset a scalar through a one-key callback, then
staged and reset an external image. The scoped reloads preserved the daemon PID.

`fresco audit all` is the repeatable baseline. A pass means the page loaded,
painted, and exposed no captured diagnostics. A warning requires review but is
not evidence of a Fresco failure. A failure means a required resource, active
selection, navigation, content process, or render surface failed.

## Gap map

| Area | State | Remaining gap |
| --- | --- | --- |
| Web project and preset loading | Working | Broader corpus coverage and CEF-versus-WebKit compatibility cases |
| User-property delivery | Working web bridge, scene sound-volume and corpus-classified SceneScript bridges, state model, and typed CLI | Unclassified scene properties and a graphical settings surface |
| File and directory properties | Working, scoped, audited, and CLI-managed | No graphical picker |
| Audio visualizer API | Working | Capture permission remains a macOS installation concern; warning corpus needs manual visual review |
| Media integration | Working | More player and payload corpus coverage |
| Pointer input | Working on the desktop surface | No configurable interaction policy or keyboard-oriented compatibility work |
| FPS, pause, and lifecycle | Working | No Wallpaper Engine-style application rules or user-facing performance profiles |
| Images and video | Working with clone and per-display wallpaper or idle bindings | Basic playback only; playlist runtime integration remains deferred |
| Multi-display | Stable per-display assignments with clone compatibility | No span runtime, display CLI, or profile switching surface |
| Diagnostics | Working reports and snapshots | No interactive inspector, network log, or visual-diff baseline |
| RGB plugins | Not implemented | Low priority on macOS; official integrations target Windows device software |
| Scene wallpapers | Bounded 2D helper with promoted corpus fixtures | Image-parent residuals, unclassified script and particle variants, model, light, volume-light, broader cameras, and 3D remain gaps |
| Product surface | Workshop gallery exists | No unified library, settings editor, profiles, playlists, or application rules |

The comparison follows Wallpaper Engine's official documentation for
[web properties](https://docs.wallpaperengine.io/en/web/customization/properties.html),
[display conditions](https://docs.wallpaperengine.io/en/web/customization/displaycondition.html),
[localization](https://docs.wallpaperengine.io/en/web/customization/localization.html),
[audio](https://docs.wallpaperengine.io/en/web/audio/visualizer.html),
[media integration](https://docs.wallpaperengine.io/en/web/audio/media.html),
[FPS handling](https://docs.wallpaperengine.io/en/web/performance/fps.html), and
[scene capabilities](https://docs.wallpaperengine.io/en/scene/overview.html).

## Phase order

### 1. Reliability gate — complete

Resource diagnostics, scoped selected assets, isolated render workers, retries,
render metrics, PNG evidence, JSON reports, and corpus orchestration are in
place. Fixture review covers pass, warning, and failure outcomes. Installed
corpus review has no hard failures.

### 2. Property model and CLI — complete

Versioned per-target records apply after manifest defaults, project-local
compatibility values, and presets. The CLI supports every documented editable
type, reset, localized presentation, evaluated display conditions, and explicit
target selection. Scalar changes use changed-only delivery. File and directory
changes rebuild web hosts with a new isolated read scope.

Review results:

1. Schema review fixed the merge order and case-insensitive property identity.
2. Security review found the selected external image inside its per-host staged
   tree. The audit confirmed that the staged file existed.
3. Interaction review restored the initial scalar and image values. Changed-only
   scalar reset and scoped reloads both worked.
4. Corpus review described 1,725 controls with zero unknown conditions.
   `fresco audit all` remained at three passes, ten warnings, and zero failures.

### 3. Scene feasibility spike — complete

The review pinned
[linux-wallpaperengine revision `b016d7d`](https://github.com/Almamu/linux-wallpaperengine/tree/b016d7d1fdcf4e5fd2f9c9fa420a8aaa07fee02d)
and every submodule. The upstream work is GPL-3.0; the portable package reader,
glslang fork, SPIRV-Cross fork, and QuickJS built on arm64 macOS. The complete
application did not configure: its build still requires the Linux window,
audio, media, and monolithic web/video dependencies.

The accepted architecture is a separately licensed helper process that owns
its AppKit desktop window and OpenGL context. Fresco remains responsible for
selection, properties, audio, media, lifecycle, health, and static fallback.
The initial protocol uses versioned newline-delimited JSON. Sound-volume
property changes are delivered live after readiness and replayed in the full
load snapshot after helper restart.

The scope is 2D scene compatibility: image, sound, text, particle, effects,
custom shaders, and fixture-proven SceneScript behavior. The pinned renderer
does not render model, light, volume-light, or camera objects. A measured 3D
fixture contains all of those and must produce an explicit unsupported result.
3D parity is a separate feasibility decision.

Review results:

1. License and provenance review found a license file for the GPL renderer and
   every included submodule. A helper boundary reduces coupling but is not a
   substitute for distribution review.
2. Build review produced a native arm64 package probe and standalone builds of
   the shader translators and script VM. It rejected the upstream root target
   as the macOS build boundary.
3. Process review rejected in-process linking and initial IOSurface sharing.
   The helper owns its window; Fresco owns recovery and fallback.
4. Fixture review pinned 14 local Workshop packages. They cover small and
   integrated 2D, particles, SceneScript text, custom shaders, puppet and media
   behavior, high object and effect counts, and explicit mixed and full 3D
   boundaries. Package checks cover PKGV0001 through PKGV0024.
5. The official Wallpaper Engine asset root was acquired through the user's
   owned Steam installation. Fresco validates and references it in place; the
   files are not copied into the repository or helper build.
6. The macOS replacement pass removed X11, Wayland, DBus, PulseAudio, GLUT,
   CEF, and first-phase MPV from the scene target. It retained the portable
   renderer, parser, decoder, shader, script, and sound dependencies. Native
   OpenGL is the default proof baseline. The post-proof comparison produced an
   opt-in pinned ANGLE-on-Metal backend behind the same surface and shader
   boundary. SDL3 GPU would require a separate renderer rewrite.

The complete decision, build evidence, architecture, corpus, and acceptance
gate are in [FEASIBILITY.md](./FEASIBILITY.md).

### 4. 2D scene compatibility — bounded stretch pass complete

The GPL-3.0 `fresco-scene` target builds independently from Fresco and speaks
protocol version 1 over newline-delimited JSON. Inspection-only builds remain
available. Renderer builds use the pinned scene source only inside the helper.
The helper owns a desktop-level AppKit window. Native builds use OpenGL 4.1;
the opt-in development backend uses an EGL OpenGL ES 3.0 context through
ANGLE's Metal renderer. Fresco owns one supervisor per display, validates the
user-owned official asset root in place, retains the Workshop preview until
`ready`, restores it after a crash, and limits restarts to three in 60 seconds.

The declared runtime covers corpus-bounded images, particles and child systems,
effects and effect quads, custom shaders, text and text effects, SceneScript,
media and video textures, 2D puppet deformation, and package sound. `ready`
follows a completed draw without a graphics error; an authored uniform startup
frame is valid. The helper exposes target-FPS, frame-pacing, render-time,
script, media, puppet, pause, visibility, and final-frame evidence.

Six automated baselines pass: Cat In Space, Shimmering Particles, NieR,
Balatro, Arknights, and Clock. Clock updates its six scripted text values.
Balatro advances through its delayed authored fade. Arknights proves current
PKGV0024 parsing and three text scripts. Cat also passes the supervised
first-frame, pause, resume, hide, show, clean-stop, and static-fallback path.

The stretch pass promotes GBC Subaru, Arknights, and Lonely Cat. Elaina, Hyuga
Ghost, and Persona 3 Reload remain `reach`. Lonely Cat's default English
composition, clock, fixed-pitch font fallback, PM indicator, audio bars,
particle children, image parents, lifecycle, and performance gates pass on
both backends. Arknights passes its native and ANGLE lifecycle, property,
sound, particle, and performance gates; its remaining crop is authored.
Elaina, Hyuga, and Persona retain their documented visual and configuration
blockers.

The sound runtime registers package metadata, decodes through AVFAudio, and
supports corpus-proven single, loop, random, and multi-asset selection plus
scripted and cursor-triggered control. Fresco loads every helper hard-muted and
permits one audible assignment per exact binding through acknowledged ownership
transfer. Missing or duplicate layer ownership fails closed.

Numeric sound-volume bindings resolve from project defaults plus the full load
snapshot before sound registration. Changed-only updates use the same nested
property shape and update every bound layer while the helper remains hard-muted.
GBC proves two independent bindings. Persona proves a 17-layer music fan-out
plus its separate train-effect binding. This bridge remains separate from
QuickJS property delivery.

The QuickJS runtime exposes typed corpus-proven layer, scene, property, timer,
storage, cursor, camera, media, audio, video, text, sound, and animation
operations. Classification follows source and API structure. Fixture IDs,
hashes, names, and source lengths are not classifier inputs. Unclassified
surfaces fail closed, and scene-owned registries and storage are destroyed with
their renderer session.

GBC, Arknights, and Lonely Cat are `available`. GBC's cursor and camera scripts,
named animation, audio-rate floats, sound, puppet deformation, masks,
attachments, and independent secondary motion pass on both backends. The
package has five rotation-only
simulation bones affecting 246 vertices and no active IK. The native and
ANGLE promotion gates each pass across two helper generations. The executable
capture and analysis protocol is retained in
[`fresco-scene/tools/windows-gbc-capture/`](../fresco-scene/tools/windows-gbc-capture/).
Model and light objects remain hard unsupported;
volume lights, broader cameras, active IK, and 3D remain outside the runtime
contract.

The same manifest now seeds 14 representative stills into Livery. Eight are
marked `available`, three are marked `reach`, and three are marked `not yet
possible`. Available and reach records retain installed Workshop references.
Not-yet-possible records are still-only and state the model or light boundary
in the picker.

The automated performance gate runs Cat at 30 and 60 FPS. On the 2026-07-20
Apple silicon host it observed 29.8 and 60.0 FPS, about 3.1 ms average render
submission time, about 108 MiB resident memory, and sub-millisecond pause and
resume acknowledgements. It proves that frames stop while paused. The results
are machine-specific and do not substitute for GPU-counter or thermal review.

The earlier focused review passed the native transform and compositing suites;
the native and ANGLE GBC, Arknights, and Lonely Cat promotion gates; and their
30 and 60 FPS performance gates. The current clean native run does not reproduce
all of those results: 24 tests fail, including three 60 FPS promotion gates.
Distribution packaging, sleep, real lock-screen observation, occlusion, display
removal, GPU counters, and thermal behavior remain manual release checks.

The ANGLE feasibility gate remains a go for opt-in development. An AppKit-owned
window renders through EGL 1.5, OpenGL ES 3.0, and ANGLE's Metal backend on the
arm64 review host. Draw, readback, buffer swap, lifecycle, baseline, and stretch
gates pass with libraries built from pinned revision
`bc129145afe520b62f11dae1a80d821ebfd6f273`. The two arm64 dylibs occupy
5,911,200 bytes.

The renderer now exposes a backend/surface and shader-target boundary. Native
OpenGL remains the default implementation. Protocol version 1 retains its
existing renderer identity and adds backend, graphics API, and shader-target
evidence. ANGLE is an opt-in development backend; release support remains
gated on packaging, long-run stability, and distribution review. 3D is not
queued.

### 5. Web compatibility closure — diagnostic foundation complete

The warning taxonomy found no current warning that demonstrates a Fresco engine
defect. Nine warnings are authored behavior, inactive state, or expected default
renders. Item `3747222633` remains unresolved: WebGL2 initializes, but the audit
observed no shader or program compilation and a transparent framebuffer before
the uniform page snapshot.

Audit reports now carry bounded console, fetch/XHR, local and session storage,
IndexedDB, font, codec, media error, WebGL context, shader, link, context-loss,
and framebuffer evidence. Fixtures prove local API access, TTF and WOFF2 loads,
Ogg Opus, WebM VP8, and H.264 MP4 decode readiness, and WebGL1/WebGL2 output.
The 13-item corpus remains at three passes, ten warnings, and zero failures.
The live selection and daemon PID remained unchanged.

The remaining closure work is a Wallpaper Engine/CEF comparison for the
unresolved target and any compatibility cases the new evidence identifies. Add
an interactive inspector only when reports establish its required controls.
RGB plugin compatibility stays out unless a macOS consumer appears.

Reviews, in order:

1. Warning taxonomy review: engine defect, authored-page defect, or expected
   platform difference.
2. Bridge contract review against the official API pages.
3. Regression review with fixtures, installed corpus, and manual audio/media
   observation.

### 6. Display, performance, and automation — per-display runtime foundation complete

[`STATE.md`](./STATE.md) defines desired-only durable state and a separate
disposable status snapshot. It covers clone, per-display, and span layouts,
profiles, playlists, pause and mute controls, application rules, lifecycle
reasons, legacy migration, and validation failure policy.

The pure Swift planner resolves stable connected displays, layout bindings,
span viewports, profile overrides, scoped rules, minimum FPS ceilings, and
independent pause, mute, and hidden reasons. The runtime now validates and
atomically replaces durable state, migrates the legacy selection once, keys
assignments by stable display identity, publishes disposable status evidence,
and reconciles clone and per-display wallpaper or idle plans without restarting
unchanged hosts. A changed or removed binding affects only its display. Failed
target resolution retains that display's visible assignment and publishes
degraded evidence naming the requested target. Per-display web defaults remain
target-local before global runtime overlays are applied. Geometry and scale
changes rebuild only the affected assignment. Scene replacement waits for an
acknowledged mute or confirmed helper termination before the successor can own
audio. Resolution rejects web and video manifests whose referenced entry file
is missing or unreadable. Failures after a valid host has launched remain part
of the renderer-health and diagnostic path. `fresco set` and `clear` transact
through the store and wait for the accepted revision.

Span reconciliation, per-display CLI commands, and playlist runtime integration
remain implementation work. Pure playlist cursor tests cover sequential and
shuffled traversal, timing, repeat behavior, and checkpoint validation; the
cursor is not yet wired into runtime status or persistence. Application
observation and user-facing profile or rule surfaces also remain deferred.

Reviews, in order:

1. State and migration review before UI or command work.
2. Lifecycle review across restart, sleep, lock, display changes, and crashes.
3. Performance review with multiple web, video, and eventual scene hosts.
4. Interaction review for CLI and product-surface behavior.

### 7. Scene compatibility maintenance and product integration

Maintain the accepted scope through corpus-backed vertical slices, then expose
proven capabilities through the same library and settings model as web
wallpapers. GBC secondary motion now carries an authoritative Windows reference
and dual-backend promotion evidence. Each later slice repeats the contract,
fixture, corpus, and release reviews below.

The architecture harness now has native OpenGL and ANGLE-on-Metal adapter
baselines for eight correctness workloads: static, continuous, script,
particle, media, audio, masks/effects, and resource reload. Lifecycle
calibration and paired native/ANGLE subject campaigns are accepted. Minimal 3D
remains a contract-only shape check.

The isolated SDL3 study is advancing. Its accepted foundation covers static
rendering and minimal 3D. Its second accepted slice drives real Cocoa swapchain
presentation for static and continuous workloads through a virtual scheduler
with one-shot authorization before GPU acquisition. This is not a production
backend selection or a performance result. SDL-specific script, particle,
media, audio, masks/effects, resource-reload, and frame-packet mapping remain
open.

### 8. 3D scene decision

This is not a queued implementation phase. Reopen it only if the 2D helper and
product state model are stable and the supported corpus demonstrates enough
value to justify a second renderer project. Inventory `.mdl` parsing, model
animation, materials, lights, cameras, shadows, and the larger SceneScript
object API against a new upstream survey. End in another explicit go/no-go
scope before renderer implementation.

## Recurring release gate

Every parity slice uses the same sequence:

1. Contract review: define supported behavior, evidence, and failure policy.
2. Fixture review: encode healthy, ambiguous, and broken cases.
3. Corpus review: run isolated audits, inspect snapshots, and classify warnings.
4. Lifecycle review: confirm the live selection, daemon, staging, and permissions
   are unchanged unless the feature explicitly owns them.
5. Release review: compile with warnings as errors, run `tests/validate.sh`, and
   update this gap map before selecting the next slice.
