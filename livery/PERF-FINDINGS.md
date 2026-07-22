# Livery panel open latency

## Verdict

The settled panel is slow because the warm-show path performs avoidable main-thread work before and during first paint. The largest measured cost is `TerminalSpecimen`: one body evaluation derives the same wallpaper representative color 20 times. Each derivation materializes `image.tiffRepresentation`, rebuilds an `NSBitmapImageRep`, and samples it. A matching benchmark measured 115–130 ms for the 20 repeated derivations on the bundled 402 KB and 1.0 MB fixtures.

`showPanel()` also posts `liveryPanelShown` before ordering the window. Combine delivers this notification synchronously on the main thread. The subscriber launches `liveryctl wallpapers --json`, waits for it to exit, reads its output, and decodes the merged catalog before `showPanel()` continues. The subprocess measured 11.5 ms median over 30 warm runs.

The image transformation pipeline and `BarLegibility` analyzer are not synchronous warm-show costs in the current code. `refreshPreview()` returns immediately under the default wallpaper authority. Under theme authority it dispatches `liveryctl render` to a global queue. That command can run `ImagePipeline.swift` and `LegibilityAnalyzer.swift`, but their work completes after first paint.

## Cost breakdown

### Cold source-change launch

`livery/run` pays compile and launch as separate serial costs. It copies 3.3 MB of resources, checks two source mtimes, compiles with `swiftc -O` when either source is newer, replaces the binary, retires a resident process with an explicit 300 ms wait, then calls `open`.

Measured compile time with the script's optimization and framework flags was 6.89, 6.92, and 6.92 s with warm compiler module caches. An empty isolated module cache took 30.00 s. The measurement selected the installed macOS 15.4 SDK because the default command-line-tools compiler and 26.5 SDK have mismatched build versions in this environment. The source and installed binary mtimes are 15 s apart for the current build, consistent with compile plus wrapper work but not precise enough to use as the primary result.

App launch to first ordered frame is estimated at 0.25–0.60 s. Existing `/tmp/lvry-runtime.log` markers have only one-second timestamp resolution; they put `applicationDidFinishLaunching`, `buildPanel`, `showPanel`, and the next-main-loop `showPanel end` marker in the same or adjacent wall-clock second. The estimate is the observed bound narrowed by the measured synchronous components below. LaunchServices could not start a separate measured instance from the restricted investigation environment, so this number is explicitly an estimate.

Expected source-change total is therefore about 7.1–7.5 s with warm compiler caches, or about 30.3–30.6 s with empty module caches. Add the script's 300 ms retirement wait when an old process is found. Compile dominates both totals; panel construction dominates the subsecond launch portion.

### Warm resident reopen

The Looks workspace warm show is estimated at 0.15–0.30 s from reopen handling to an ordered first frame. The estimate combines 11.5 ms of catalog reload, 115–130 ms of repeated representative-color work, synchronous SwiftUI evaluation and image setup, activation-policy transitions, activation, and AppKit ordering. Existing runtime markers show some `applicationShouldHandleReopen` to `showPanel begin` and `showPanel begin` to `showPanel end` intervals crossing a one-second clock boundary, but their timestamp precision cannot separate those stages further.

The Repose workspace has a different profile. Its subscriber still reloads wallpapers, then synchronously runs `fresco repose-state` at 25.93 ms median. Thumbnail discovery and generation are dispatched to a global queue. Repose first paint is estimated at 0.07–0.18 s when cached thumbnails exist, with later background decode and generation able to contend for CPU and disk.

## Synchronous warm-show trace

### Reopen and `showPanel()`

`applicationShouldHandleReopen` changes activation policy to `.regular`, schedules `showPanel()` on the next main-queue turn, and returns. `showPanel()` then does the following on the main actor:

1. Posts `liveryPanelShown` synchronously.
2. Records the previous frontmost application and reads `NSScreen.main`.
3. Repositions the panel.
4. Calls `setActivationPolicy(.regular)` a second time.
5. Activates the current application.
6. Calls `orderFrontRegardless()` and `makeKeyAndOrderFront()`.
7. Posts a distributed visibility notification synchronously.

The activation-policy calls, activation, and ordering were not independently measurable in the restricted session. They are synchronous AppKit operations and remain an unquantified fixed cost. The second `.regular` transition is redundant at the source level for the reopen path, although changing it requires deciding the app's Dock, menu-bar, and focus behavior.

### `liveryPanelShown` subscriber

The notification is posted before the first `showPanel begin` runtime marker and before either ordering call. `loadWallpaperFixtures()` launches `liveryctl wallpapers --json` with `Process`, calls `waitUntilExit()`, drains the pipe, and decodes the catalog on the main thread. Measured command cost was 11.5 ms median, 10.63–14.08 ms range over 30 warm samples. Swift JSON decoding of the roughly 46 KB combined catalog is additional but small.

`loadLockPolicy()` synchronously reads and decodes a 254-byte JSON file. Its expected cost is below 1 ms with a warm file cache.

When `workspace == .repose`, `refreshReposeWorkspace(generateThumbnails: true)` first calls `loadReposeSelection()` synchronously. That launches `fresco repose-state`, waits for exit, and decodes JSON. The command measured 25.93 ms median, 25.21–29.54 ms range over 30 warm samples. The function then dispatches `loadReposeScenes(generateThumbnails: true)` to a global queue, so `ffmpeg` generation does not directly block window ordering.

### SwiftUI evaluation and image work

Assigning a newly decoded wallpaper array invalidates `LiveryView` even when the catalog contents are unchanged. The Looks detail hierarchy eagerly constructs `TerminalSpecimen` inside a non-lazy `VStack` in the scroll view.

`TerminalSpecimen.terminalColor()` reads the computed `cellBackground` 20 times. Every read calls `representativeColor(in:)`. That function asks the wallpaper `NSImage` for a TIFF representation, creates a bitmap representation, and samples 35 pixels. A release-mode standalone benchmark of the same algorithm measured 121.0 and 120.1 ms for 21 calls on `blue-alps.jpg`, and 132.8 and 132.6 ms on `forest-path.jpg`. Scaled to the 20 call sites, this is roughly 115–130 ms on the main thread per body evaluation. A first isolated call was 24.9–37.6 ms because it also forced initial image decode.

`wallpaperImage` is another computed property. The body evaluates it separately for `SourcePane` and `PalettePane`, and `fixture.image` creates an `NSImage(contentsOf:)` each time. AppKit defers much of the decode until drawing, but the repeated object and disk lookup work is still on the first-frame path.

`onAppear` calls `refreshPreview()`. It does no image work for the default wallpaper authority. For theme authority it captures the profile, changes status, and dispatches `renderLookPreview()` to a user-initiated global queue. `renderLookPreview()` synchronously invokes `liveryctl render` only on that background queue. A cache miss can run the Core Image transformation helper; every theme-authoritative render then runs bar legibility analysis over the output and reads the resulting artifact. These operations can delay the derived preview and compete with UI work, but they do not block the initial order call.

### View construction and `@State`

Cold app launch constructs `LiveryView()` inside `buildPanel()`. Four state initializers perform eager I/O:

- `wallpapers = loadWallpaperFixtures()` pays the 11.5 ms catalog subprocess plus decode.
- `reposeSelection = loadReposeSelection()` pays the 25.93 ms Fresco subprocess even though the initial workspace is Looks.
- `reposeScenes = loadReposeScenes()` enumerates 50 scene-directory entries and opens 25 cached thumbnail images. An exact release-mode replica measured 75.9 ms with cold OS caches and 9.4–10.5 ms thereafter. Forcing all 25 thumbnail images through TIFF decode measured 97.3 ms cold and 24.4–25.7 ms warm; initial Looks construction does not force those TIFF decodes.
- `lockPolicy = loadLockPolicy()` reads the small policy JSON.

The top-level bundled palette and theme catalogs also synchronously read and decode 25 KB and 29 KB JSON resources during process initialization.

## Ranked recommendations

### 1. Compute the terminal background once per wallpaper and terminal background

Hoist `representativeColor` or `cellBackground` out of the 20 `terminalColor()` calls. Cache it at the `TerminalSpecimen` evaluation boundary or in state keyed by wallpaper identity and terminal background. This targets the measured 115–130 ms dominant Looks cost.

Tradeoff: a persistent cache needs an invalidation key that tracks derived-image replacement and palette opacity changes. A body-local value avoids invalidation state but still recomputes once on every body evaluation.

### 2. Remove the synchronous catalog subprocess from pre-order notification delivery

Order the resident panel from its current `@State`, then refresh the wallpaper catalog asynchronously. A narrower option is to refresh only after an import or an explicit external-library change notification. This removes at least 11.5 ms from every show and avoids forcing the expensive Looks body before ordering.

Tradeoff: the first frame can show a stale catalog. Event-driven invalidation adds coordination between `liveryctl` and the resident app.

### 3. Consolidate activation-policy transitions and measure them separately

The reopen handler and `showPanel()` both call `setActivationPolicy(.regular)`. Keep only the transition required by the chosen app lifecycle, or keep a stable policy while resident if that preserves the required behavior. Add signposts around policy change, activation, and ordering before making this decision.

Tradeoff: activation policy controls Dock presence, menu-bar ownership, focus transfer, and reopen delivery. Lower latency may change those semantics.

### 4. Defer Repose-only state initialization and refresh

Do not launch `fresco repose-state` or enumerate thumbnails while constructing an initial Looks view. Load Repose state when the workspace is first selected. On a Repose reopen, move the state subprocess off the main actor and render the saved resident state first.

Tradeoff: the first Repose visit or reopened first frame can show stale selection and thumbnails until refresh completes.

### 5. Coalesce background thumbnail refreshes

Thumbnail generation is already off the main thread. Retain that property, skip work for valid cache entries, cancel or coalesce overlapping show and workspace-selection refreshes, and consider lower QoS during window presentation.

Tradeoff: lower priority and coalescing delay newly generated previews. Stronger cache reuse can preserve a stale thumbnail when source identity or modification metadata is incomplete.

### 6. Reuse decoded wallpaper images across panes and catalog refreshes

Resolve the selected fixture image once and pass the same `NSImage` through the view hierarchy. Preserve decoded images when a catalog refresh returns the same asset identity.

Tradeoff: image caching increases resident memory and needs invalidation when a path is replaced without an identity change.

### 7. Keep transformation and legibility analysis asynchronous, with stale-result rejection

The current theme-authority render is correctly outside the main-thread show path. Preserve that boundary. If profiling finds CPU contention during show, lower its priority or delay new work until the panel has ordered while retaining the existing requested-profile guard.

Tradeoff: delaying or lowering priority extends the time that the source or previous derived preview remains visible.

## Verification and limitations

No timing instrumentation was added to `LiveryPreview.swift`; its SHA-256 remained `9b533ec4be858403b4ee20f12d4bf712addb94b73ee8cd661858c088551852b` throughout the investigation. The file already had an unrelated worktree diff on entry. That pre-existing diff remains byte-for-byte unchanged, so the investigation's diff for `LiveryPreview.swift` is clean even though repository-wide `git diff -- livery/LiveryPreview.swift` is not empty.

Only `livery/PERF-FINDINGS.md` was added. No panel behavior, appearance, source, runtime catalog, or repository build artifact was changed. Temporary benchmark executables and compiler caches were written under `/tmp`.
