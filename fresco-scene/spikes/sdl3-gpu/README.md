# SDL3 GPU static render foundation

This spike tests SDL3 GPU as a Metal graphics foundation. It renders an opaque
black offscreen clear and the minimal-3D contract: indexed textured geometry,
pushed vertex constants, depth testing, framebuffer-space front-face mapping,
culling, deterministic transforms, resize, readback, and completion-aware
retirement.

The clear is `static-render-foundation`, not the common `static-no-media`
workload. Scheduler quiescence, invalidation, presentation suppression, and
resize-driven presentation remain a follow-on. This spike does not change the
workload catalog classification.

Configure and build with Apple Clang:

```sh
cmake -S . -B /tmp/fresco-sdl3-gpu \
  -DCMAKE_C_COMPILER=/usr/bin/clang \
  -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
  -DCMAKE_OBJC_COMPILER=/usr/bin/clang \
  -DCMAKE_OBJCXX_COMPILER=/usr/bin/clang++ \
  -DFRESCO_SCENE_BUILD_SDL3_GPU_SPIKE=ON \
  -DFRESCO_SCENE_BUILD_RENDERER=OFF
cmake --build /tmp/fresco-sdl3-gpu \
  --target fresco-scene-sdl3-gpu-spike --parallel
ctest --test-dir /tmp/fresco-sdl3-gpu --output-on-failure \
  -R 'fresco-scene-sdl3-gpu|fresco-scene-common-harness-minimal-3d-contract'
```

Generate the formal correctness archive with:

```sh
python3 spikes/sdl3-gpu/generate_evidence.py \
  --evidence-root /absolute/path/to/.fresco-evidence/sdl3-gpu-static-render-foundation-v2 \
  --operator astral --agent-role subagent
```

The generator refuses to overwrite an existing evidence root. The archive
verifier reads the resulting tarball without extraction and rederives its
artifact, reference, build, shader, capability, ordering, resize, lifecycle,
and verdict checks.

The formal configuration uses Unix Makefiles, `Release`, and an explicit
macOS 14.0 deployment target. The archive records the CMake executable and
version identity plus `CMakeCache.txt`. The v2 evidence archive supersedes the
preserved v1 archive; it does not overwrite it.

The slice is Metal-only, offscreen, synchronous, and debug-validation enabled.
It contains no presentation loop, scheduler, performance measurements,
production renderer integration, install rule, or cross-platform shader path.

## Presentation and scheduling slice

`fresco-scene-sdl3-presentation-spike` is a separate standalone target. It
uses hidden Cocoa SDL windows and real SDL GPU swapchains for the accepted
`static-no-media` and `continuous-animation` scheduling semantics. A standalone
virtual scheduler owns cadence, invalidation coalescing, pause state, deadlines,
decisions, and presentation completion. Only its `present` decisions acquire and
submit an SDL swapchain texture. Recorded wall observations establish ordering
only and are not performance measurements.

```sh
cmake --build /tmp/fresco-sdl3-gpu \
  --target fresco-scene-sdl3-presentation-spike --parallel
ctest --test-dir /tmp/fresco-sdl3-gpu --output-on-failure \
  -R 'fresco-scene-sdl3-presentation'
```

The static workload includes constructor presentation, durable quiescence,
one property wake, requiescence, and a spike-local resize extension. The
continuous workload includes 15/30/60 FPS ceilings, coalescing, live retiming,
pause, and bounded resume. This remains harness code: it does not install or
connect to the production renderer.

Generate the formal presentation archive with:

```sh
python3 spikes/sdl3-gpu/generate_presentation_evidence_v3.py \
  --evidence-root /absolute/path/to/.fresco-evidence/sdl3-presentation-scheduling-v3 \
  --operator astral --agent-role subagent
```

The v3 archive supersedes the preserved presentation v2 archive and retains the
presentation v1 and static-render foundation v2 archives as predecessors. The
verifier replays the input events through an independent scheduler model and
checks all three predecessor files. One-shot scheduler authorization occurs
before GPU acquisition. Rejected zero, forged, stale, duplicate, and completed
sequences have zero GPU and resource counter deltas. Retained offscreen frames
are mirrored render oracles, not drawable pixel readbacks. The archive makes no
performance claim.
