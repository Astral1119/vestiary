import AppKit
import WebKit
import AVFoundation

// Phase-1 live-wallpaper runtime: desktop-level
// per-display windows playing Wallpaper Engine video and web wallpapers,
// with the WE JavaScript API shimmed natively — audio via a Cava system
// tap, cursor forwarding, occlusion-pause, and Livery Look colors pushed
// as WE user properties.

// MARK: - Runtime paths (daemon mode)

let runtimeDirectory = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".config/fresco")
let configFile = runtimeDirectory.appendingPathComponent("current")
let pidFile = runtimeDirectory.appendingPathComponent("pid")
let reposeCommandFile = runtimeDirectory.appendingPathComponent("repose-command")
let reposeStateFile = runtimeDirectory.appendingPathComponent("repose.json")
let scenesDirectory = runtimeDirectory.appendingPathComponent("scenes")

func loadConfiguredWallpaper() -> Wallpaper? {
    guard let path = try? String(contentsOf: configFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
    return resolveWallpaper(path)
}

// MARK: - Repose state (the single selection record — see HANDOFF
// "Selection model": every picker is a thin writer over this file)

struct ReposeState {
    var look = "zephyr"
    var scene = "desktop"
    var viz = "strings"
    var variant = "quiet"
    var grade = "on"
    var night = "off"
    var pixels = "on"
    var label = "on"
    var scenePool: [String] = []

    static func load() -> ReposeState {
        var state = ReposeState()
        guard let data = try? Data(contentsOf: reposeStateFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return state }
        if let value = object["look"] as? String { state.look = value }
        if let value = object["scene"] as? String { state.scene = value }
        if let value = object["viz"] as? String { state.viz = value }
        if let value = object["variant"] as? String { state.variant = value }
        if let value = object["grade"] as? String { state.grade = value }
        if let value = object["night"] as? String { state.night = value }
        if let value = object["pixels"] as? String { state.pixels = value }
        if let value = object["label"] as? String { state.label = value }
        if let value = object["scenePool"] as? [String] { state.scenePool = value }
        state.reconcileScene()
        return state
    }

    func save() {
        let object: [String: Any] = ["look": look, "scene": scene, "viz": viz,
                                     "variant": variant,
                                     "grade": grade, "night": night, "pixels": pixels,
                                     "label": label, "scenePool": scenePool]
        if let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reposeStateFile)
        }
    }

    // the scene's display name (the backdrop itself is runtime-side)
    var sceneName: String {
        scene == "desktop" ? "desktop"
            : ((scene as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    mutating func reconcileScene() {
        let rotation = reposeRotation(scenePool)
        if !rotation.contains(scene), let first = rotation.first {
            scene = first
        }
    }

    // the record as WE user properties
    var properties: [String: Any] {
        ["reposelook": ["value": look],
         "reposeviz": ["value": viz],
         "reposevariant": ["value": variant],
         "reposegrade": ["value": grade],
         "reposenight": ["value": night],
         "reposepixels": ["value": pixels],
         "reposescene": ["value": sceneName],
         "reposelabel": ["value": label]]
    }
}

// The scene library both pickers iterate: the implicit desktop mirror plus
// everything in scenes/ (videos, WE project dirs, or symlinks to either).
func sceneLibrary() -> [String] {
    var library = ["desktop"]
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: scenesDirectory.path)) ?? []
    for entry in entries.sorted() where !entry.hasPrefix(".") {
        let path = scenesDirectory.appendingPathComponent(entry).path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
        if isDirectory.boolValue {
            if FileManager.default.fileExists(atPath: path + "/project.json") {
                library.append(path)
            }
        } else if ["mp4", "mov", "m4v"].contains((entry as NSString).pathExtension.lowercased()) {
            library.append(path)
        }
    }
    return library
}

func reposeSceneID(_ scene: String) -> String {
    scene == "desktop" ? "desktop" : (scene as NSString).lastPathComponent
}

// An absent pool preserves the pre-pool behavior (all catalog scenes in
// deterministic order). Explicit pools are ordered, de-duplicated, and
// filtered against the current catalog without mutating that catalog.
func reposeRotation(_ scenePool: [String]) -> [String] {
    let library = sceneLibrary()
    guard !scenePool.isEmpty else { return library }
    let byID = Dictionary(uniqueKeysWithValues: library.map { (reposeSceneID($0), $0) })
    var seen = Set<String>()
    let rotation = scenePool.compactMap { sceneID -> String? in
        guard seen.insert(sceneID).inserted else { return nil }
        return byID[sceneID]
    }
    return rotation.isEmpty ? ["desktop"] : rotation
}

func jsonString(_ object: [String: Any]) -> String {
    (try? JSONSerialization.data(withJSONObject: object))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

// Per-scene theme sidecar (qylock precedent: each scene carries its own
// palette). `<scene minus extension>.theme.json` holds hex roles that
// override the Livery Look while that scene is up.
func sceneThemeProperties(_ scene: String) -> [String: Any] {
    guard scene != "desktop", !scene.isEmpty else { return [:] }
    let base = (scene as NSString).deletingPathExtension
    let sidecar = URL(fileURLWithPath: base + ".theme.json")
    guard let data = try? Data(contentsOf: sidecar),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    var properties: [String: Any] = [:]
    for role in ["primary", "secondary", "tertiary", "surface", "background",
                 "text", "textmuted", "attention", "success", "viz1", "viz2"] {
        if let color = weColor(hexString(object[role])) {
            properties["livery" + role] = color
        }
    }
    if let color = weColor(hexString(object["primary"])) {
        properties["schemecolor"] = color
    }
    return properties
}

// MARK: - Shell helper

@discardableResult
func shell(_ arguments: [String]) -> (status: Int32, stdout: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    do { try process.run() } catch { return (127, "") }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Wallpaper resolution

enum Wallpaper {
    case video(URL)
    case web(index: URL, root: URL, properties: [String: Any])
}

func resolveWallpaper(_ path: String) -> Wallpaper? {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

    if !isDirectory.boolValue {
        return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) ? .video(url) : nil
    }

    let projectURL = url.appendingPathComponent("project.json")
    guard let data = try? Data(contentsOf: projectURL),
          let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    // Preset items configure another wallpaper: resolve the dependency and
    // overlay the preset's property values (WE downloads deps the same way).
    if let dependency = project["dependency"] as? String, !dependency.isEmpty {
        let baseURL = url.deletingLastPathComponent().appendingPathComponent(dependency)
        guard FileManager.default.fileExists(
            atPath: baseURL.appendingPathComponent("project.json").path) else {
            print("preset depends on workshop item \(dependency), which is not "
                + "downloaded — run: workshop get \(dependency)")
            return nil
        }
        guard let base = resolveWallpaper(baseURL.path) else { return nil }
        guard case .web(let index, let root, var properties) = base else { return base }
        if let preset = project["preset"] as? [String: Any] {
            for (key, value) in preset {
                properties[key] = ["value": value]
                properties[key.lowercased()] = ["value": value]
            }
        }
        return .web(index: index, root: root, properties: properties)
    }

    guard let file = project["file"] as? String else { return nil }
    let type = (project["type"] as? String ?? "").lowercased()
    let target = url.appendingPathComponent(file)

    if type.contains("video") { return .video(target) }
    if type.contains("web") {
        let general = project["general"] as? [String: Any]
        var properties = general?["properties"] as? [String: Any] ?? [:]
        // properties.local.json stands in for Wallpaper Engine's property
        // UI: per-wallpaper user overrides, merged over project defaults.
        let localURL = url.appendingPathComponent("properties.local.json")
        if let data = try? Data(contentsOf: localURL),
           let overrides = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in overrides {
                properties[key] = value is [String: Any] ? value : ["value": value]
            }
        }
        return .web(index: target, root: url, properties: properties)
    }
    return nil
}

// MARK: - Livery Look → WE user properties

// Livery v3 manifests wrap colors as {hex, rgb} objects; v2 carried bare hex
// strings. Accept both so the bridge never silently drops theme colors.
func hexString(_ value: Any?) -> String? {
    if let hex = value as? String { return hex }
    if let object = value as? [String: Any] { return object["hex"] as? String }
    return nil
}

func weColor(_ hex: String?) -> [String: Any]? {
    guard let hex, hex.hasPrefix("#"), hex.count == 7 else { return nil }
    let components = [1, 3, 5].compactMap { start -> Double? in
        let index = hex.index(hex.startIndex, offsetBy: start)
        guard let value = UInt8(hex[index...hex.index(index, offsetBy: 1)], radix: 16) else { return nil }
        return Double(value) / 255.0
    }
    guard components.count == 3 else { return nil }
    return ["value": components.map { String(format: "%.4f", $0) }.joined(separator: " ")]
}

func liveryProperties() -> [String: Any] {
    let manifest = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/livery/current/manifest.json")
    guard let data = try? Data(contentsOf: manifest),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ui = object["ui"] as? [String: Any] else { return [:] }

    var properties: [String: Any] = [:]
    if let color = weColor(hexString(ui["primary"])) { properties["schemecolor"] = color }
    for role in ["primary", "secondary", "tertiary", "surface", "surfaceElevated",
                 "background", "text", "textMuted"] {
        if let color = weColor(hexString(ui[role])) {
            properties["livery" + role.lowercased()] = color
        }
    }
    if let signals = object["signals"] as? [String: Any] {
        for role in ["attention", "success", "warning", "error", "info"] {
            if let color = weColor(hexString(signals[role])) {
                properties["livery" + role] = color
            }
        }
    }
    if let presentation = object["presentation"] as? [String: Any],
       let rawGradient = presentation["visualizerGradient"] as? [Any] {
        let gradient = rawGradient.compactMap(hexString)
        if gradient.count == 2 {
            if let color = weColor(gradient[0]) { properties["liveryviz1"] = color }
            if let color = weColor(gradient[1]) { properties["liveryviz2"] = color }
        }
    }
    return properties
}

func liveryManifestModificationDate() -> Date? {
    let manifest = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/livery/current/manifest.json")
    return (try? FileManager.default.attributesOfItem(atPath: manifest.path))?[.modificationDate] as? Date
}

// MARK: - Cava audio tap (64 bars → 128-sample WE frames)

final class AudioTap {
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var configURL: URL?
    private var cavaPath: String?
    private var watchdog: Timer?
    private var consecutiveFailures = 0
    private var lastFrameAt = Date.distantPast
    private var framesThisLaunch = 0
    var onFrame: (([Double]) -> Void)?
    private(set) var live = false
    private(set) var framesReceived = 0
    private(set) var capturePermissionAvailable = true

    func start() {
        // Never let a background wallpaper process initiate macOS's capture
        // permission flow. Rebuilding this ad-hoc-signed binary can invalidate
        // its old TCC grant; launching cava's system-output tap in that state
        // repeatedly opens System Settings as the watchdog retries it.
        guard CGPreflightScreenCaptureAccess() else {
            capturePermissionAvailable = false
            return
        }
        guard let cava = findCava() else { return }
        cavaPath = cava
        // Mirrors the proven zephyr-strings tap config (Core Audio system
        // output tap); without the [input] section cava reads the default
        // device and delivers silence.
        let config = """
        [general]
        bars = 64
        framerate = 30
        lower_cutoff_freq = 40
        higher_cutoff_freq = 16000
        [input]
        method = coreaudio
        source = tap
        channels = 2
        [output]
        method = raw
        raw_target = /dev/stdout
        data_format = ascii
        ascii_max_range = 1000
        bar_delimiter = 59
        frame_delimiter = 10
        channels = mono
        mono_option = average
        [smoothing]
        integral = 0
        waves = 0
        gravity = 8000000
        noise_reduction = 25
        """
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresco-cava-\(getuid()).conf")
        try? config.write(to: configURL, atomically: true, encoding: .utf8)
        self.configURL = configURL
        launch()

        // Cava emits frames continuously (zeros in silence), so a stall means
        // the tap died — commonly an output-device switch (AirPods) breaking
        // the CoreAudio tap while the process keeps running. Relaunch heals it.
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    private func launch() {
        guard let cavaPath, let configURL else { return }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cavaPath)
        process.arguments = ["-p", configURL.path]
        process.standardOutput = pipe
        process.standardError = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        framesThisLaunch = 0
        lastFrameAt = Date()
        do { try process.run(); live = true } catch { live = false }
        self.process = process
        self.pipe = pipe
    }

    private func checkHealth() {
        guard live, let process else { return }
        let stalled = framesThisLaunch > 0 && Date().timeIntervalSince(lastFrameAt) > 15
        guard !process.isRunning || stalled else { return }
        // A launch that never delivered a frame is a hard failure — most
        // often TCC denying the system-audio tap (a rebuild changes the
        // daemon's ad-hoc signature and invalidates the old grant), and
        // every retry re-triggers the permission flow, popping System
        // Settings. Cap it; frames arriving resets the count.
        if framesThisLaunch == 0 {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                print("audio: cava failed \(consecutiveFailures)x with no frames — giving up. "
                    + "Grant System Audio Recording to Fresco "
                    + "(System Settings > Privacy & Security), then fresco restart.")
                pipe?.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                live = false
                watchdog?.invalidate()
                watchdog = nil
                return
            }
        } else {
            consecutiveFailures = 0
        }
        print("audio: cava \(process.isRunning ? "stalled" : "exited") — restarting tap")
        pipe?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        launch()
    }

    private func findCava() -> String? {
        for candidate in ["/opt/homebrew/bin/cava", "/usr/local/bin/cava"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let text = String(data: line, encoding: .utf8) else { continue }
            let bands = text.split(separator: ";").compactMap { Double($0) }.map { $0 / 1000.0 }
            guard bands.count >= 32 else { continue }
            // WE convention: 64 left + 64 right; mirror our mono bands.
            let frame = bands + bands.reversed()
            DispatchQueue.main.async {
                self.framesReceived += 1
                self.framesThisLaunch += 1
                self.lastFrameAt = Date()
                self.onFrame?(frame)
            }
        }
    }

    func stop() {
        watchdog?.invalidate()
        live = false
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        if let configURL { try? FileManager.default.removeItem(at: configURL) }
    }
}

// MARK: - Media feed (WE media integration via media-control)

func boolValue(_ any: Any?) -> Bool {
    if let value = any as? Bool { return value }
    if let value = any as? String { return value.lowercased() == "true" }
    if let value = any as? NSNumber { return value.boolValue }
    return false
}

func doubleValue(_ any: Any?) -> Double {
    if let value = any as? Double { return value }
    if let value = any as? String { return Double(value) ?? 0 }
    if let value = any as? NSNumber { return value.doubleValue }
    return 0
}

func artworkColors(base64: String) -> (String, String, String, String, String) {
    let fallback = ("#888888", "#555555", "#bbbbbb", "#ffffff", "white")
    guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
          let image = NSImage(data: data),
          let rep = NSBitmapImageRep(
              bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return fallback }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
    NSGraphicsContext.restoreGraphicsState()
    guard let color = rep.colorAt(x: 0, y: 0) else { return fallback }
    func hex(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> String {
        String(format: "#%02x%02x%02x",
               Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255),
               Int(max(0, min(1, b)) * 255))
    }
    let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
    let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return (hex(r, g, b),
            hex(r * 0.6, g * 0.6, b * 0.6),
            hex(min(1, r * 1.4 + 0.1), min(1, g * 1.4 + 0.1), min(1, b * 1.4 + 0.1)),
            luminance > 0.6 ? "#111111" : "#ffffff",
            luminance > 0.6 ? "black" : "white")
}

final class MediaFeed {
    private let queue = DispatchQueue(label: "wallpaper.runtime.media", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var timelineTimer: DispatchSourceTimer?
    private var lastTrackKey = ""
    private var lastPlayback = -1
    private var lastEnabled: Bool?
    private var playing = false
    private var rate = 1.0
    private var elapsed = 0.0
    private var duration = 0.0
    private var sampledAt = Date()
    // last payload per kind (main-thread) — replayed into webviews created
    // after the fact, so a fresh cover shows the current track immediately
    private(set) var lastPayloads: [String: [String: Any]] = [:]
    var onEvent: ((String, [String: Any]) -> Void)?

    static var available: Bool { shell(["which", "media-control"]).status == 0 }

    func snapshotJSON() -> String {
        (try? JSONSerialization.data(withJSONObject: lastPayloads))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func start() {
        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now() + 1, repeating: 2)
        poll.setEventHandler { [weak self] in self?.poll() }
        poll.resume()
        pollTimer = poll
        let timeline = DispatchSource.makeTimerSource(queue: queue)
        timeline.schedule(deadline: .now() + 2, repeating: 1)
        timeline.setEventHandler { [weak self] in self?.tickTimeline() }
        timeline.resume()
        timelineTimer = timeline
    }

    func stop() {
        pollTimer?.cancel()
        timelineTimer?.cancel()
    }

    private func emit(_ kind: String, _ payload: [String: Any]) {
        DispatchQueue.main.async {
            self.lastPayloads[kind] = payload
            self.onEvent?(kind, payload)
        }
    }

    private func poll() {
        let result = shell(["media-control", "get"])
        guard result.status == 0, let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String, !title.isEmpty else {
            setEnabled(false)
            return
        }
        setEnabled(true)
        let artist = object["artist"] as? String ?? ""
        let album = object["album"] as? String ?? ""
        playing = boolValue(object["playing"])
        rate = max(doubleValue(object["playbackRate"]), 0)
        elapsed = doubleValue(object["elapsedTime"])
        duration = doubleValue(object["duration"])
        sampledAt = Date()

        let state = playing ? 2 : 1
        if state != lastPlayback {
            lastPlayback = state
            emit("playback", ["state": state])
        }
        let trackKey = "\(title)|\(artist)|\(album)"
        guard trackKey != lastTrackKey else { return }
        lastTrackKey = trackKey
        emit("properties", [
            "title": title, "artist": artist, "subTitle": "",
            "albumTitle": album, "albumArtist": artist, "genres": "",
            "contentType": "music",
        ])
        if let artwork = object["artworkData"] as? String, !artwork.isEmpty {
            let mime = object["artworkMimeType"] as? String ?? "image/jpeg"
            let colors = artworkColors(base64: artwork)
            emit("thumbnail", [
                "thumbnail": "data:\(mime);base64,\(artwork)",
                "primaryColor": colors.0, "secondaryColor": colors.1,
                "tertiaryColor": colors.2, "textColor": colors.3,
                "highContrastColor": colors.4,
            ])
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard enabled != lastEnabled else { return }
        lastEnabled = enabled
        emit("status", ["enabled": enabled])
        if !enabled {
            lastTrackKey = ""
            if lastPlayback != 0 {
                lastPlayback = 0
                emit("playback", ["state": 0])
            }
        }
    }

    private func tickTimeline() {
        guard lastEnabled == true, duration > 0 else { return }
        let position = playing
            ? min(duration, elapsed + Date().timeIntervalSince(sampledAt) * rate)
            : elapsed
        emit("timeline", ["position": position, "duration": duration])
    }
}

// MARK: - Agent-state feed (hook-truth from tmux @agent_state)

struct AgentCounts: Equatable {
    var working: Int
    var waiting: Int
    var done: Int
}

final class AgentFeed {
    private let queue = DispatchQueue(label: "wallpaper.runtime.agents", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastCounts = AgentCounts(working: -1, waiting: -1, done: -1)
    // last pushed counts (main-thread) — seeded into webviews created later
    private(set) var lastProperties: [String: Any] = [:]
    var onChange: (([String: Any]) -> Void)?

    static var available: Bool { shell(["which", "tmux"]).status == 0 }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 4)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel() }

    // Grouped tmux sessions expose the same linked windows once per client
    // session. `list-panes -a` therefore repeats physical panes; pane_id is
    // the server-wide identity and must be folded before counting states.
    static func counts(from listing: String) -> AgentCounts {
        var counts = AgentCounts(working: 0, waiting: 0, done: 0)
        var seenPaneIDs = Set<Substring>()
        for line in listing.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "|") else { continue }
            let paneID = line[..<separator]
            guard !paneID.isEmpty, seenPaneIDs.insert(paneID).inserted else { continue }
            let state = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            switch state {
            case "working": counts.working += 1
            case "waiting": counts.waiting += 1
            case "done": counts.done += 1
            default: break
            }
        }
        return counts
    }

    private func poll() {
        let result = shell(["tmux", "list-panes", "-a", "-F",
                            "#{pane_id}|#{@agent_state}"])
        guard result.status == 0 else { return }
        let counts = Self.counts(from: result.stdout)
        guard counts != lastCounts else { return }
        lastCounts = counts
        let properties: [String: Any] = [
            "agentworking": ["value": counts.working],
            "agentwaiting": ["value": counts.waiting],
            "agentdone": ["value": counts.done],
        ]
        DispatchQueue.main.async {
            self.lastProperties = properties
            self.onChange?(properties)
        }
    }
}

// MARK: - Desktop window

func makeDesktopWindow(for screen: NSScreen) -> NSWindow {
    let window = NSWindow(
        contentRect: screen.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    // Just below the desktop icons: above the static wallpaper, behind
    // everything interactive (Plash precedent).
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.ignoresMouseEvents = true
    window.isOpaque = true
    window.backgroundColor = .black
    window.isReleasedWhenClosed = false
    return window
}

// MARK: - Cover window (repose)

// The repose cover: a non-activating key panel above everything. Spike
// verdict (../repose/SPIKE.md): key status moves but focus is preserved on
// exit, the app never activates, and no Accessibility is needed. Media keys
// pass through because NX_SYSDEFINED events never reach key handling.
final class CoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

func makeCoverPanel(for screen: NSScreen) -> NSWindow {
    let panel = CoverPanel(
        contentRect: screen.frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .fullScreenAuxiliary, .ignoresCycle]
    panel.isOpaque = true
    panel.backgroundColor = .black
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    return panel
}

// MARK: - Per-display hosts

final class VideoHost {
    let window: NSWindow
    let view: NSView
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper

    init(screen: NSScreen, url: URL, attachTo existingWindow: NSWindow? = nil) {
        window = existingWindow ?? makeDesktopWindow(for: screen)
        let item = AVPlayerItem(url: url)
        player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        let view = NSView(frame: existingWindow?.contentView?.bounds ?? screen.frame)
        self.view = view
        view.wantsLayer = true
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        if let container = existingWindow?.contentView {
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        } else {
            window.contentView = view
            window.orderFront(nil)
        }
        player.play()
    }

    func setPaused(_ paused: Bool) { paused ? player.pause() : player.play() }
}

enum WebSurface {
    case desktop
    case cover
}

final class WebHost: NSObject, WKScriptMessageHandler {
    let window: NSWindow
    let webView: WKWebView
    let screen: NSScreen
    let surface: WebSurface
    private(set) var paused = false

    init(screen: NSScreen, index: URL, root: URL, pendingPropertiesJSON: String,
         surface: WebSurface = .desktop, attachTo existingWindow: NSWindow? = nil,
         mediaSnapshotJSON: String = "{}", transparent: Bool = false) {
        self.screen = screen
        self.surface = surface
        if let existingWindow {
            window = existingWindow
        } else {
            window = surface == .desktop ? makeDesktopWindow(for: screen)
                                         : makeCoverPanel(for: screen)
        }

        let configuration = WKWebViewConfiguration()
        // WE web wallpapers load local textures into WebGL; without this
        // the canvas is tainted and drawing fails (the fork's "web fix").
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // WE semantics: user properties are applied when the page registers
        // its listener — whenever that is (some wallpapers register late,
        // after async CDN imports). A setter trap reproduces that exactly.
        let bootstrap = """
        window.__wePendingProps = \(pendingPropertiesJSON);
        window.__weAudio = [];
        window.wallpaperRegisterAudioListener = function (fn) { window.__weAudio.push(fn); };
        window.__wePushAudio = function (frame) {
            if (window.__wePaused) return;
            for (const fn of window.__weAudio) { try { fn(frame); } catch (e) {} }
        };
        window.__weLog = function (message) {
            try { webkit.messageHandlers.weLog.postMessage(String(message)); } catch (e) {}
        };
        window.__wePL = null;
        Object.defineProperty(window, 'wallpaperPropertyListener', {
            configurable: true,
            get: function () { return window.__wePL; },
            set: function (listener) {
                window.__wePL = listener;
                if (listener && listener.applyUserProperties) {
                    setTimeout(function () {
                        try { listener.applyUserProperties(window.__wePendingProps || {}); }
                        catch (e) { window.__weLog('applyUserProperties threw: ' + e.message); }
                    }, 0);
                }
            }
        });
        window.__weApplyProps = function (props) {
            window.__wePendingProps = Object.assign(window.__wePendingProps || {}, props);
            var listener = window.__wePL;
            if (listener && listener.applyUserProperties) {
                try { listener.applyUserProperties(props); }
                catch (e) { window.__weLog('applyUserProperties threw: ' + e.message); }
            }
        };
        window.__weMouse = function (x, y) {
            document.dispatchEvent(new MouseEvent('mousemove', { clientX: x, clientY: y }));
        };
        window.wallpaperMediaIntegration = {
            PLAYBACK_STOPPED: 0, PLAYBACK_PAUSED: 1, PLAYBACK_PLAYING: 2
        };
        window.__weMediaLast = \(mediaSnapshotJSON);
        window.__weMediaFns = { status: [], properties: [], thumbnail: [], playback: [], timeline: [] };
        function __weRegisterMedia(kind) {
            return function (fn) {
                window.__weMediaFns[kind].push(fn);
                if (window.__weMediaLast[kind]) {
                    try { fn(window.__weMediaLast[kind]); } catch (e) {}
                }
            };
        }
        window.wallpaperRegisterMediaStatusListener = __weRegisterMedia('status');
        window.wallpaperRegisterMediaPropertiesListener = __weRegisterMedia('properties');
        window.wallpaperRegisterMediaThumbnailListener = __weRegisterMedia('thumbnail');
        window.wallpaperRegisterMediaPlaybackListener = __weRegisterMedia('playback');
        window.wallpaperRegisterMediaTimelineListener = __weRegisterMedia('timeline');
        window.__wePushMedia = function (kind, payload) {
            window.__weMediaLast[kind] = payload;
            for (const fn of window.__weMediaFns[kind]) { try { fn(payload); } catch (e) {} }
        };
        window.addEventListener('error', function (e) {
            window.__weLog('page error: ' + e.message + ' @ ' + (e.filename || '?') + ':' + (e.lineno || '?'));
        });
        window.addEventListener('unhandledrejection', function (e) {
            window.__weLog('unhandled rejection: ' + ((e.reason && e.reason.message) || e.reason));
        });
        document.addEventListener('DOMContentLoaded', function () {
            // CEF/Chromium hides broken images with empty alt; WebKit shows
            // a placeholder. Match the engine wallpapers were written for.
            var style = document.createElement('style');
            style.textContent = 'img[src=""], img[src="file:///"] { visibility: hidden !important; }';
            document.head.appendChild(style);
        });
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView = WKWebView(frame: screen.frame, configuration: configuration)
        if transparent {
            // composition over a backdrop view: the page body is transparent
            // (reposebackdrop: clear); the web view must not paint beneath it
            webView.setValue(false, forKey: "drawsBackground")
        }
        if let container = existingWindow?.contentView {
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
            // the caller owns ordering of a shared window
        } else {
            window.contentView = webView
            if surface == .cover {
                window.orderFrontRegardless()
            } else {
                window.orderFront(nil)
            }
        }
        super.init()
        webView.configuration.userContentController.add(self, name: "weLog")
        webView.loadFileURL(index, allowingReadAccessTo: root)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        print("page: \(message.body)")
    }

    func push(properties: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: properties),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__weApplyProps(\(json))", completionHandler: nil)
    }

    func push(audio frame: [Double]) {
        guard !paused else { return }
        let samples = frame.map { String(format: "%.3f", $0) }.joined(separator: ",")
        webView.evaluateJavaScript("window.__wePushAudio([\(samples)])", completionHandler: nil)
    }

    func push(mouseAt location: NSPoint) {
        guard screen.frame.contains(location) else { return }
        let x = location.x - screen.frame.origin.x
        let y = screen.frame.height - (location.y - screen.frame.origin.y)
        webView.evaluateJavaScript("window.__weMouse(\(Int(x)), \(Int(y)))", completionHandler: nil)
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        webView.evaluateJavaScript("window.__wePaused = \(paused)", completionHandler: nil)
    }
}

// MARK: - Controller

final class RuntimeController: NSObject, NSApplicationDelegate {
    private let initialWallpaper: Wallpaper?
    private let daemon: Bool
    private struct CoverDisplay {
        let panel: NSWindow
        let screen: NSScreen
        var backdropWeb: WebHost?
        var backdropVideo: VideoHost?
        let composition: WebHost
    }

    private var videoHosts: [VideoHost] = []
    private var webHosts: [WebHost] = []
    private var coverDisplays: [CoverDisplay] = []
    private var coverScene = "desktop"
    private var compositionRoot: URL?
    private var reposeState = ReposeState.load()
    private var coverMonitor: Any?
    private var coverBarHidden = false
    private let audioTap = AudioTap()
    private let mediaFeed = MediaFeed()
    private let agentFeed = AgentFeed()
    private var mouseMonitor: Any?
    private var liveryTimer: Timer?
    private var liveryModified: Date?
    private var projectProperties: [String: Any] = [:]
    private var webServicesStarted = false

    init(wallpaper: Wallpaper?, daemon: Bool) {
        self.initialWallpaper = wallpaper
        self.daemon = daemon
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if daemon {
            try? FileManager.default.createDirectory(at: runtimeDirectory,
                                                     withIntermediateDirectories: true)
            try? "\(ProcessInfo.processInfo.processIdentifier)"
                .write(to: pidFile, atomically: true, encoding: .utf8)
        }
        observeOcclusion()
        observeLock()
        if let wallpaper = initialWallpaper {
            apply(wallpaper)
        } else {
            print("daemon idle — set a wallpaper with: fresco set <path-or-workshop-id>")
        }
    }

    func reloadFromConfig() {
        guard let wallpaper = loadConfiguredWallpaper() else {
            teardownHosts()
            print("cleared — daemon idle")
            return
        }
        apply(wallpaper)
    }

    private func teardownHosts() {
        for host in videoHosts {
            host.setPaused(true)
            host.window.orderOut(nil)
        }
        videoHosts.removeAll()
        for host in webHosts {
            host.webView.configuration.userContentController
                .removeScriptMessageHandler(forName: "weLog")
            host.window.orderOut(nil)
        }
        webHosts.removeAll()
    }

    private func apply(_ wallpaper: Wallpaper) {
        teardownHosts()
        switch wallpaper {
        case .video(let url):
            videoHosts = NSScreen.screens.map { VideoHost(screen: $0, url: url) }
            print("video wallpaper on \(videoHosts.count) display(s): \(url.lastPathComponent)")
        case .web(let index, let root, let properties):
            projectProperties = properties
            let pending = mergedProperties()
            let json = (try? JSONSerialization.data(withJSONObject: pending))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let mediaSnapshot = mediaFeed.snapshotJSON()
            webHosts = NSScreen.screens.map {
                WebHost(screen: $0, index: index, root: root, pendingPropertiesJSON: json,
                        mediaSnapshotJSON: mediaSnapshot)
            }
            print("web wallpaper on \(webHosts.count) display(s): \(root.lastPathComponent)")
            if !webServicesStarted {
                webServicesStarted = true
                startWebServices()
            }
        }
    }

    private var coverWebHosts: [WebHost] {
        coverDisplays.flatMap { [$0.backdropWeb, $0.composition].compactMap { $0 } }
    }
    private var allWebHosts: [WebHost] { webHosts + coverWebHosts }

    // MARK: Repose cover (SIGUSR2; command written by `fresco repose*`)

    func handleReposeCommand() {
        guard let raw = try? String(contentsOf: reposeCommandFile, encoding: .utf8) else { return }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let action = (lines.first ?? "").split(separator: " ").first.map(String.init) ?? "toggle"
        let path = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespaces) : ""
        reposeState = ReposeState.load()

        if !coverDisplays.isEmpty {
            switch action {
            case "exit", "toggle":
                exitCover()
            default:
                // enter-while-covered and refresh both re-apply the record
                applyReposeState()
            }
            return
        }
        guard action == "enter" || action == "toggle" else { return }
        enterCover(path: path)
    }

    // Wallpaper-through: the configured scene (or the desktop wallpaper)
    // renders inside the cover beneath the composition — its own instance;
    // the occluded desktop copy pauses. nil = graded-opaque composition.
    private func resolveBackdrop(_ scene: String) -> Wallpaper? {
        var wallpaper: Wallpaper?
        if scene != "desktop" && !scene.isEmpty {
            wallpaper = resolveWallpaper(scene)
            if wallpaper == nil { print("repose: bad scene '\(scene)', mirroring desktop") }
        }
        if wallpaper == nil { wallpaper = loadConfiguredWallpaper() }
        if case .web(_, let root, _)? = wallpaper, root == compositionRoot {
            return nil   // never stack repose on itself
        }
        return wallpaper
    }

    private func attachBackdrop(_ display: inout CoverDisplay, wallpaper: Wallpaper?,
                                livery: [String: Any], mediaSnapshot: String) {
        switch wallpaper {
        case .video(let url)?:
            display.backdropVideo = VideoHost(screen: display.screen, url: url,
                                              attachTo: display.panel)
        case .web(let index, let root, var properties)?:
            for (key, value) in livery { properties[key] = value }
            display.backdropWeb = WebHost(
                screen: display.screen, index: index, root: root,
                pendingPropertiesJSON: jsonString(properties), surface: .cover,
                attachTo: display.panel, mediaSnapshotJSON: mediaSnapshot)
        case nil:
            break
        }
        // re-adding the composition web view moves it back above the backdrop
        if wallpaper != nil, let container = display.panel.contentView {
            container.addSubview(display.composition.webView)
        }
    }

    private func detachBackdrop(_ display: inout CoverDisplay) {
        if let old = display.backdropWeb {
            old.webView.configuration.userContentController
                .removeScriptMessageHandler(forName: "weLog")
            old.webView.removeFromSuperview()
            display.backdropWeb = nil
        }
        if let old = display.backdropVideo {
            old.setPaused(true)
            old.view.removeFromSuperview()
            display.backdropVideo = nil
        }
    }

    private func enterCover(path: String) {
        guard !path.isEmpty, case .web(let index, let root, var properties)? = resolveWallpaper(path) else {
            print("repose: no web wallpaper at '\(path)'")
            return
        }
        compositionRoot = root
        coverScene = reposeState.scene
        let backdrop = resolveBackdrop(coverScene)
        let livery = liveryProperties()
        for (key, value) in livery { properties[key] = value }
        for (key, value) in sceneThemeProperties(coverScene) { properties[key] = value }
        for (key, value) in agentFeed.lastProperties { properties[key] = value }
        for (key, value) in reposeState.properties { properties[key] = value }
        properties["reposebackdrop"] = ["value": backdrop == nil ? "opaque" : "clear"]
        properties["reposecover"] = ["value": "on"]   // shows the key hint once
        let json = jsonString(properties)
        let mediaSnapshot = mediaFeed.snapshotJSON()

        for screen in NSScreen.screens {
            let panel = makeCoverPanel(for: screen)
            var display = CoverDisplay(
                panel: panel, screen: screen, backdropWeb: nil, backdropVideo: nil,
                composition: WebHost(screen: screen, index: index, root: root,
                                     pendingPropertiesJSON: json, surface: .cover,
                                     attachTo: panel, mediaSnapshotJSON: mediaSnapshot,
                                     transparent: true))
            attachBackdrop(&display, wallpaper: backdrop, livery: livery,
                           mediaSnapshot: mediaSnapshot)
            coverDisplays.append(display)
            panel.orderFrontRegardless()
        }
        (coverDisplays.first?.panel as? NSPanel)?.makeKeyAndOrderFront(nil)

        // Esc is the only way out (fat-finger protection — re-entry costs a
        // chord). Selection keys are carved out (see handleCoverKey); stray
        // keys, clicks, and scrolls are swallowed. Media keys are
        // systemDefined events — never matched, so they pass through.
        coverMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            guard let self, let window = event.window,
                  self.coverDisplays.contains(where: { $0.panel == window }) else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {   // esc
                    DispatchQueue.main.async { self.exitCover() }
                } else {
                    _ = self.handleCoverKey(event)
                }
            }
            return nil
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let hidden = shell(["sketchybar", "--bar", "hidden=on"]).status == 0
            DispatchQueue.main.async { self.coverBarHidden = hidden }
        }
        if !webServicesStarted {
            webServicesStarted = true
            startWebServices()
        }
        let backdropNote = backdrop == nil ? "opaque" : "wallpaper-through"
        print("repose: cover entered (\(reposeState.look), \(reposeState.variant), "
            + "\(backdropNote)) on \(coverDisplays.count) display(s)")
    }

    // MARK: Live selection (in-cover keys — the picker is the config)

    private func handleCoverKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: cycleScene(-1); return true   // ←
        case 124: cycleScene(1); return true    // →
        case 48:                                // tab
            reposeState.look = reposeState.look == "zephyr" ? "pixel" : "zephyr"
            persistAndApply()
            return true
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "b":
            reposeState.viz = reposeState.viz == "strings" ? "spectrum" : "strings"
            persistAndApply()
            return true
        case "x":
            reposeState.pixels = reposeState.pixels == "on" ? "off" : "on"
            persistAndApply()
            return true
        case "v":
            reposeState.variant = reposeState.variant == "quiet" ? "loud" : "quiet"
            persistAndApply()
            return true
        case "g":
            reposeState.grade = reposeState.grade == "on" ? "off" : "on"
            persistAndApply()
            return true
        case "n":
            reposeState.night = reposeState.night == "on" ? "off" : "on"
            persistAndApply()
            return true
        case "l":
            reposeState.label = reposeState.label == "on" ? "off" : "on"
            persistAndApply()
            return true
        default:
            return false
        }
    }

    private func cycleScene(_ step: Int) {
        let library = reposeRotation(reposeState.scenePool)
        let current = library.firstIndex(of: reposeState.scene) ?? 0
        reposeState.scene = library[(current + step + library.count) % library.count]
        persistAndApply()
    }

    private func persistAndApply() {
        reposeState.save()
        applyReposeState()
        let scene = reposeState.scene == "desktop"
            ? "desktop" : (reposeState.scene as NSString).lastPathComponent
        print("repose: \(reposeState.look) · \(scene) · \(reposeState.variant)"
            + " · pixels \(reposeState.pixels) · grade \(reposeState.grade)"
            + " · night \(reposeState.night)")
    }

    private func applyReposeState() {
        guard !coverDisplays.isEmpty else { return }
        var properties = reposeState.properties
        if reposeState.scene != coverScene {
            coverScene = reposeState.scene
            let backdrop = resolveBackdrop(coverScene)
            let livery = liveryProperties()
            let mediaSnapshot = mediaFeed.snapshotJSON()
            for index in coverDisplays.indices {
                detachBackdrop(&coverDisplays[index])
                attachBackdrop(&coverDisplays[index], wallpaper: backdrop,
                               livery: livery, mediaSnapshot: mediaSnapshot)
            }
            // re-push the Look, then the scene's theme over it — moving to an
            // unthemed scene restores Livery colors, a themed one overrides
            for (key, value) in livery { properties[key] = value }
            for (key, value) in sceneThemeProperties(coverScene) { properties[key] = value }
            properties["reposebackdrop"] = ["value": backdrop == nil ? "opaque" : "clear"]
        }
        for display in coverDisplays { display.composition.push(properties: properties) }
    }

    private func exitCover() {
        guard !coverDisplays.isEmpty else { return }
        if let coverMonitor { NSEvent.removeMonitor(coverMonitor) }
        coverMonitor = nil
        let panels = coverDisplays.map { $0.panel }
        let hosts = coverWebHosts
        let videos = coverDisplays.compactMap { $0.backdropVideo }
        coverDisplays.removeAll()
        if coverBarHidden {
            coverBarHidden = false
            DispatchQueue.global(qos: .userInitiated).async {
                shell(["sketchybar", "--bar", "hidden=off"])
            }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panels.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            for host in hosts {
                host.webView.configuration.userContentController
                    .removeScriptMessageHandler(forName: "weLog")
            }
            videos.forEach { $0.setPaused(true) }
            panels.forEach { $0.orderOut(nil) }
        })
        print("repose: cover exited")
    }

    private func startWebServices() {
        // Initial properties ride the document-start script (applied by the
        // listener trap); the watcher re-pushes when the Look changes.
        liveryModified = liveryManifestModificationDate()
        liveryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let modified = liveryManifestModificationDate()
            if modified != self.liveryModified {
                self.liveryModified = modified
                self.pushProperties()
                print("livery look changed — properties re-pushed")
            }
        }

        audioTap.onFrame = { [weak self] frame in
            self?.allWebHosts.forEach { $0.push(audio: frame) }
        }
        audioTap.start()
        if !audioTap.capturePermissionAvailable {
            print("audio: disabled — capture permission unavailable (no prompt requested)")
        } else {
            print(audioTap.live ? "audio: cava launched" : "audio: cava unavailable (no audio response)")
        }
        if audioTap.live {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self else { return }
                if self.audioTap.framesReceived == 0 {
                    print("""
                    audio: cava is running but no frames arrived — likely the \
                    system-audio capture permission. Grant it to your terminal \
                    under System Settings → Privacy & Security → Screen & \
                    System Audio Recording, then relaunch.
                    """)
                } else {
                    print("audio: tap live (\(self.audioTap.framesReceived) frames)")
                }
            }
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            self?.webHosts.forEach { $0.push(mouseAt: location) }
        }

        if AgentFeed.available {
            agentFeed.onChange = { [weak self] properties in
                self?.allWebHosts.forEach { $0.push(properties: properties) }
            }
            agentFeed.start()
            print("agents: tmux @agent_state feed live")
        }

        if MediaFeed.available {
            mediaFeed.onEvent = { [weak self] kind, payload in
                guard let self,
                      let data = try? JSONSerialization.data(withJSONObject: payload),
                      let json = String(data: data, encoding: .utf8) else { return }
                for host in self.allWebHosts {
                    host.webView.evaluateJavaScript(
                        "window.__wePushMedia('\(kind)', \(json))", completionHandler: nil)
                }
            }
            mediaFeed.start()
            print("media: media-control feed live")
        } else {
            print("media: media-control not found (no media integration)")
        }
    }

    private func mergedProperties() -> [String: Any] {
        var merged = projectProperties
        for (key, value) in liveryProperties() { merged[key] = value }
        for (key, value) in agentFeed.lastProperties { merged[key] = value }
        // Empty file/text placeholders break wallpapers (`file:///` srcs);
        // WE's UI never applies an empty value either.
        return merged.filter { _, value in
            if let dict = value as? [String: Any], let text = dict["value"] as? String {
                return !text.isEmpty
            }
            return true
        }
    }

    private func pushProperties() {
        let merged = mergedProperties()
        webHosts.forEach { $0.push(properties: merged) }
        // covers get only the Livery roles — the desktop wallpaper's own
        // project properties must not leak into the repose composition
        let livery = liveryProperties()
        coverWebHosts.forEach { $0.push(properties: livery) }
    }

    private func observeOcclusion() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            let visible = window.occlusionState.contains(.visible)
            for host in self.videoHosts where host.window == window { host.setPaused(!visible) }
            for host in self.webHosts where host.window == window { host.setPaused(!visible) }
        }
    }

    // Lock-screen split: the lock screen shows the desktop surface frozen,
    // which reads as broken for live wallpapers. Hide the desktop windows
    // while locked so the lock screen falls back to the static system
    // wallpaper — that picture (System Settings > Wallpaper) is thereby
    // the separate lock wallpaper. An open cover exits on lock (it's a
    // manually invoked scene; re-enter after unlocking).
    private var screenLocked = false

    private func observeLock() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                           object: nil, queue: .main) { [weak self] _ in self?.setLocked(true) }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                           object: nil, queue: .main) { [weak self] _ in self?.setLocked(false) }
    }

    private func setLocked(_ locked: Bool) {
        guard locked != screenLocked else { return }
        screenLocked = locked
        if locked && !coverDisplays.isEmpty { exitCover() }
        for host in videoHosts {
            host.setPaused(locked)
            locked ? host.window.orderOut(nil) : host.window.orderFront(nil)
        }
        for host in webHosts {
            host.setPaused(locked)
            locked ? host.window.orderOut(nil) : host.window.orderFront(nil)
        }
        print("lock: desktop wallpaper \(locked ? "hidden" : "restored")")
    }

    func shutdown() {
        // never strand a hidden bar if we die while covered
        if coverBarHidden { shell(["sketchybar", "--bar", "hidden=off"]) }
        audioTap.stop()
        mediaFeed.stop()
        agentFeed.stop()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        liveryTimer?.invalidate()
        if daemon { try? FileManager.default.removeItem(at: pidFile) }
        exit(0)
    }
}

// MARK: - Bootstrap

// Line-buffer stdout even when it's a log file, so daemon activity is
// visible as it happens rather than stuck in a full buffer.
setvbuf(stdout, nil, _IOLBF, 0)

let flags = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") }
let positional = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
let daemonMode = flags.contains("--daemon")

if flags.contains("--self-test-agent-counts") {
    let groupedFixture = """
    %1|working
    %2|done
    %3|waiting
    %4|
    %1|working
    %2|done
    %3|waiting
    %4|
    %1|working
    %2|done
    %3|waiting
    %4|
    """
    let expected = AgentCounts(working: 1, waiting: 1, done: 1)
    guard AgentFeed.counts(from: groupedFixture) == expected else {
        fputs("agent-count self-test failed\n", stderr)
        exit(1)
    }
    print("agent-count self-test passed")
    exit(0)
}

var initialWallpaper: Wallpaper?
if daemonMode {
    initialWallpaper = loadConfiguredWallpaper()   // nil = idle until SIGUSR1
} else {
    guard let inputPath = positional.first, let wallpaper = resolveWallpaper(inputPath) else {
        fputs("""
        usage: fresco-worker <wallpaper> | --daemon
          <wallpaper>: a .mp4/.mov file, or a Wallpaper Engine project folder
                       containing project.json (type "video" or "web")
          --daemon:    read \(configFile.path), reload on SIGUSR1,
                       repose cover on SIGUSR2, write a pidfile
                       (managed by fresco)
        """ + "\n", stderr)
        exit(64)
    }
    initialWallpaper = wallpaper
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = RuntimeController(wallpaper: initialWallpaper, daemon: daemonMode)
application.delegate = controller

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { controller.shutdown() }
sigintSource.resume()

signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { controller.shutdown() }
sigtermSource.resume()

signal(SIGUSR1, SIG_IGN)
let sigusr1Source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
sigusr1Source.setEventHandler { controller.reloadFromConfig() }
sigusr1Source.resume()

signal(SIGUSR2, SIG_IGN)
let sigusr2Source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
sigusr2Source.setEventHandler { controller.handleReposeCommand() }
sigusr2Source.resume()

application.run()
