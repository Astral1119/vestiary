# GBC secondary-motion reference capture

DECISION: The accepted Windows reference set established the response of GBC
Subaru's five simulated ahoge bones to authored parent motion. The resulting
bounded solver passes native OpenGL and ANGLE-on-Metal promotion gates. This
capture remains the black-box visual compatibility reference. It does not
inspect or redistribute Wallpaper Engine code or Workshop assets.

## Required result

One accepted reference set contains three 12-second trials at each tested
Wallpaper Engine FPS limit:

| Trial | Input | Required observation |
| --- | --- | --- |
| `idle` | Cursor fixed at screen center | Rest behavior and startup/reset state |
| `cursor-step` | Center, left step, right step, center | Response delay, overshoot, damping, limits, and chain coupling |
| `cursor-sweep` | Two deterministic horizontal sweeps | Continuous response and direction |

Run the set at 30, 60, and 120 FPS. Wallpaper Engine documents that puppet
physics can change with the user's maximum FPS, so a single-rate recording is
not sufficient. The GBC chain uses spring simulation, Z rotation only, no
translation or gravity, rotational inertia 30, rotational stiffness 300,
rotational friction 38/33/29/27/26, mass 20, and limits of plus or minus pi.

The authoritative behavior being measured is documented by Wallpaper Engine's
[Bone Physics Simulation](https://docs.wallpaperengine.io/en/scene/puppet-warp/boneconstraints.html)
guide: spring bones return to their default rotation, friction reduces movement
per frame, inertia reduces the effect of parent animation, and chained spring
bones transfer motion. GBC's object `346` is the ahoge puppet. Its parent chain
ends at object `142`, whose authored SceneScript rotates with horizontal cursor
position. The cursor trials therefore excite the actual parent input without
editing the package.

## Windows prerequisites

- A user-owned Wallpaper Engine installation with Workshop item `3448290956`.
- FFmpeg and FFprobe on `PATH`, with the Windows `ddagrab` filter enabled.
- PresentMon 2.x. Pass the downloaded console executable to `capture.ps1`.
- A fixed display mode with scaling unchanged for the entire set.
- Wallpaper Engine audio response disabled or a silent input source.
- No foreground windows over the ahoge region.

RenderDoc is not required. Lossless desktop video supplies the deformation
trajectory; PresentMon supplies displayed-frame timing. This avoids relying on
GPU-resource names or proprietary renderer internals.

## Capture

Apply GBC Subaru as the desktop wallpaper. Set Wallpaper Engine's maximum FPS
to the first target and wait ten seconds. Determine a crop rectangle enclosing
only the ahoge and a small margin. Record screen coordinates in physical
pixels, not scaled logical points.

From an elevated PowerShell prompt:

```powershell
$root = "C:\path\to\vestiary\fresco-scene\tools\windows-gbc-capture"
$pm = "C:\Tools\PresentMon-2.3.1-x64.exe"

& "$root\capture.ps1" -OutputRoot C:\captures\gbc -PresentMon $pm `
  -Trial idle -WallpaperFps 60 -RoiX 1680 -RoiY 180 -RoiWidth 420 -RoiHeight 560

& "$root\capture.ps1" -OutputRoot C:\captures\gbc -PresentMon $pm `
  -Trial cursor-step -WallpaperFps 60 -RoiX 1680 -RoiY 180 -RoiWidth 420 -RoiHeight 560

& "$root\capture.ps1" -OutputRoot C:\captures\gbc -PresentMon $pm `
  -Trial cursor-sweep -WallpaperFps 60 -RoiX 1680 -RoiY 180 -RoiWidth 420 -RoiHeight 560
```

The coordinates above are examples. Repeat all three commands at 30 and 120
FPS after changing the Wallpaper Engine limit and waiting ten seconds. Do not
move the cursor manually during a trial. The script positions it and records
each input transition in `events.csv`.

Each run writes:

- `capture.json`: environment, package hash, display, trial, ROI, capture backend,
  and tool metadata;
- `capture.mkv`: lossless FFV1 video of the declared ahoge ROI, acquired through
  Windows Desktop Duplication at the requested capture rate, 120 Hz by default;
- `presentmon.csv`: presented-frame timing for `wallpaper64.exe`;
- `events.csv`: monotonic input events relative to capture start;
- `ffmpeg.log`, `ffmpeg-transcode.log`, `presentmon.log`, and
  `presentmon-error.log`: tool diagnostics.

The live capture is written as temporary uncompressed video, then converted to
FFV1 after PresentMon stops. This keeps lossless compression from competing
with the renderer during the measured interval. The temporary file is removed
only after a successful conversion.

Do not edit these files. Copy the complete trial directories back to macOS.

## Analyze

Run the analyzer once per trial directory:

```sh
python3 analyze.py /path/to/gbc-60-cursor-step-YYYYMMDD-HHMMSS
```

The analyzer requires FFmpeg and FFprobe. The set reducer also requires
Pillow:

```sh
python3 -m pip install Pillow
```

It verifies the package ID and hash, lossless video stream, ROI bounds, event
sequence, duration, monotonic frame timestamps, and PresentMon timing. It then
writes:

- `motion.csv`: per-frame baseline difference, previous-frame difference, and
  difference centroid inside the ahoge ROI;
- `analysis.json`: capture validity, frame-rate statistics, event-aligned motion
  peaks, rest noise, response delay, and SHA-256 hashes of the evidence files.

After all nine individual trials pass, reduce the selected set together:

```sh
python3 analyze_set.py --output-directory /path/to/gbc-reference \
  /path/to/gbc-30-idle-* \
  /path/to/gbc-30-cursor-step-* \
  /path/to/gbc-30-cursor-sweep-* \
  /path/to/gbc-60-idle-* \
  /path/to/gbc-60-cursor-step-* \
  /path/to/gbc-60-cursor-sweep-* \
  /path/to/gbc-120-idle-* \
  /path/to/gbc-120-cursor-step-* \
  /path/to/gbc-120-cursor-sweep-*
```

Each pattern must resolve to one directory. `analyze_set.py` rejects missing,
duplicate, or unexpected FPS/trial pairs. It also requires the same package,
host, display, capture rectangle, and ROI across the set. A change in capture
backend is retained as a warning because the backend does not change the
lossless output contract.

The reducer writes `set-analysis.json` and `set-motion.csv`. The JSON records
the measured presentation rate and each event's localized threshold crossing,
peak, residual, responsive cells, and ratio to the same-FPS idle adjacent-frame
envelope. The threshold crossing is a conservative detection time, not an
estimate of input latency. The CSV contains the event-aligned localized
displacement and change centroid for every analyzed frame. Each response window
is two seconds.

The localized metric divides a 110 by 140 grayscale reduction into 10-pixel
cells. It chooses cells whose event-window displacement exceeds their idle
adjacent-frame p99. This prevents background animation and large unrelated
areas in the crop from dominating the result, which full-frame mean absolute
difference does on this wallpaper.

An accepted set must meet all of these conditions:

1. All nine trials use the same `scene.pkg` SHA-256 and display geometry.
2. Video is FFV1, contains at least 95 percent of the requested frames, and has
   no timestamp regression.
3. PresentMon contains displayed frames from `wallpaper64.exe` and covers at
   least 90 percent of the video duration.
4. Idle motion establishes a localized adjacent-frame noise floor for the same
   FPS.
5. Each input event has a localized response record. `responseDetected` states
   whether two consecutive frames crossed the event threshold. A false result
   requires visual review before the capture can serve as a motion target.
6. The return-to-center segment is long enough to observe settling or a stable
   residual offset.

The implementation pass consumes the three `motion.csv` trajectories together.
It must reproduce response direction, onset, peak ordering along the chain,
damping, limit behavior, pause/reset behavior, and the observed FPS dependence.
It must not tune against a single screenshot or one frame rate.
