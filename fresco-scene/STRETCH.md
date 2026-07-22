# Stretch scene compatibility

DECISION: GBC Subaru, Arknights, and Lonely Cat are available. Elaina, Hyuga
Ghost, and Persona 3 Reload remain `reach`. The image-parent and passthrough
residuals in Lonely Cat and Arknights are fixed. Lonely Cat and Arknights pass
their native and ANGLE promotion gates. This result does not add 3D scene
support or claim general Wallpaper Engine scene parity.

The implementation boundary has four renderer libraries: media and video
textures, generic SceneScript bindings, sound and advanced particles, and 2D
puppet deformation. Each library must have a fixture consumer, an explicit
unsupported result for variants outside its contract, and native OpenGL plus
ANGLE-on-Metal evidence before a picker status changes.

## Acceptance corpus

| Fixture | Status | Evidence or remaining blocker |
| --- | --- | --- |
| Elaina `3326873240` | `reach` | The composition, video, sound, and particles are recognizable. The authored prompt does not complete its lifecycle, and most wallpaper properties are not bound. |
| Lonely Cat `3299228616` | `available` | Shader coverage, clock text, fixed-pitch fallback, audio response, particle children, image parents, lifecycle, and 30 and 60 FPS performance gates pass on both backends. |
| Arknights `3460973721` | `available` | Current-format parsing, shader coverage, three clocks, bounded sound, image parents, cursor controls, properties, and all three particle systems pass on both backends. The remaining cover crop is authored. |
| Hyuga Ghost `3479521040` | `reach` | The composition and partial puppet rendering are recognizable, but the result is static and visibly soft; media, particles, and all 17 authored properties remain incomplete. |
| GBC Subaru `3448290956` | `available` | Cursor and camera scripts, named animation, audio-rate floats, sound, attachments, and independent five-bone secondary motion pass on both backends. |
| Persona 3 Reload `3151551777` | `reach` | The composition and sound controls are partial. The top-right date cluster, most composition controls, and a left-edge artifact remain unresolved. |

`available` means that the fixture's defining authored behavior works during
load, pause, resume, hide, show, property change, helper restart, and clean
stop. A recognizable still is insufficient. Exact pixel identity with the
Windows renderer is not required. Visual review must account for blend, font,
timing, and color-space differences.

## Library contracts

### Media and video textures

The media library owns decode, timing, loop state, frame upload, pause, resume,
visibility, and teardown. Renderer code consumes a backend-neutral texture
frame. AVFoundation remains outside the portable scene model. The contract
must distinguish an authored video texture from media-session data supplied by
Fresco.

### Generic SceneScript

The script library resolves authored objects by stable scene identity and
exposes only corpus-proven operations. The initial surface includes layer
transforms, visibility, color, animation rate, timers, property callbacks,
shared state, cursor input, and 2D camera control where the corpus requires
them. Source-shape classifiers are regression boundaries, not fixture-identity
checks.

### Sound and particles

The sound contract includes single, loop, random, and multi-asset playback;
scripted play, pause, stop, and state queries; cursor-triggered control; global
audio ownership; property volume; pause; and helper restart. Multi-asset
selection must be deterministic in tests.

The particle contract is defined by the particle documents referenced by the
acceptance corpus. New emitter, initializer, operator, renderer, child-system, and
audio-response variants require fixture evidence. Unknown variants produce a
diagnostic instead of silently approximating the effect.

### 2D puppets

The puppet library owns package parsing, mesh and texture binding, authored
deformation, animation inputs, composition order, pause, and teardown. It does
not cover Wallpaper Engine model objects, skeletal 3D animation, lighting, or
3D cameras. Unsupported puppet revisions or operators must fail independently
of the rest of the scene.

## Promotion result

GBC, Arknights, and Lonely Cat completed focused native OpenGL and
ANGLE-on-Metal lifecycle, restart, performance, and promotion gates. Elaina,
Hyuga, and Persona retain useful partial support but remain `reach` until their
fixture-specific blockers pass visual and behavioral review.

The isolated 2026-07-21 Lonely Cat run measured 30.163 and 59.993 FPS on ANGLE
with 9.274 and 1.588 ms p95 render submission time and zero missed intervals.
Native OpenGL measured 29.980 and 59.902 FPS with 8.014 and 6.260 ms p95 and
zero missed intervals. The earlier ANGLE failure ran alongside five leaked
full-resolution helpers. Supervisor retirement now retains ownership until the
child exits.

### GBC reference pass

Wallpaper Engine documents that spring bones return to their default rotation,
friction reduces motion per frame, inertia reduces the effect of parent
animation, chained spring bones transfer motion, and behavior can vary with the
user's maximum FPS. GBC's ahoge has no authored bone animation. Its input is the
cursor-driven rotation of parent object `142`, so the reference stimulus is a
deterministic horizontal cursor step rather than an arbitrary initial impulse.

[`tools/windows-gbc-capture/`](./tools/windows-gbc-capture/) contains the
Windows capture command, pinned package hash, three-trial protocol, evidence
schema, PresentMon timing gate, lossless-video reducer, and a synthetic analyzer
test. The accepted set covers idle, cursor-step, and cursor-sweep behavior at
30, 60, and 120 FPS. It established response direction, damping, chain
coupling, reset behavior, and FPS dependence for the bounded solver.

Each fixture promotion requires:

1. Package and authored-API inventory.
2. Focused contract tests for every new compatibility operation.
3. Native OpenGL lifecycle and visual evidence.
4. ANGLE-on-Metal lifecycle and visual evidence.
5. Failure, restart, pause, visibility, and property-change evidence.
6. Performance measurement against the 30 and 60 FPS gates.
7. Independent review and picker-status update.

Full 3D remains a separate decision. Model, light, volume-light, shadow, and
3D camera objects retain the existing unsupported boundary.
