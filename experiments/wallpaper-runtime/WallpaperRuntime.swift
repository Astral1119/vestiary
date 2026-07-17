import AppKit
import WebKit
import AVFoundation

// Phase-1 live-wallpaper runtime (see FEASIBILITY.md): desktop-level
// per-display windows playing Wallpaper Engine video and web wallpapers,
// with the WE JavaScript API shimmed natively — audio via a Cava system
// tap, cursor forwarding, occlusion-pause, and Livery Look colors pushed
// as WE user properties.

// MARK: - Runtime paths (daemon mode)

let runtimeDirectory = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent(".config/wallpaper-runtime")
let configFile = runtimeDirectory.appendingPathComponent("current")
let pidFile = runtimeDirectory.appendingPathComponent("pid")

func loadConfiguredWallpaper() -> Wallpaper? {
    guard let path = try? String(contentsOf: configFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
    return resolveWallpaper(path)
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

func liveryProperties() -> [String: Any] {
    let manifest = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/livery/current/manifest.json")
    guard let data = try? Data(contentsOf: manifest),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ui = object["ui"] as? [String: Any] else { return [:] }

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

    var properties: [String: Any] = [:]
    if let color = weColor(ui["primary"] as? String) { properties["schemecolor"] = color }
    for role in ["primary", "secondary", "tertiary", "surface", "text"] {
        if let color = weColor(ui[role] as? String) { properties["livery" + role] = color }
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
    private let process = Process()
    private let pipe = Pipe()
    private var buffer = Data()
    private var configURL: URL?
    var onFrame: (([Double]) -> Void)?
    private(set) var live = false
    private(set) var framesReceived = 0

    func start() {
        guard let cava = findCava() else { return }
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
            .appendingPathComponent("wallpaper-runtime-cava-\(getuid()).conf")
        try? config.write(to: configURL, atomically: true, encoding: .utf8)
        self.configURL = configURL

        process.executableURL = URL(fileURLWithPath: cava)
        process.arguments = ["-p", configURL.path]
        process.standardOutput = pipe
        process.standardError = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        do { try process.run(); live = true } catch { live = false }
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
                self.onFrame?(frame)
            }
        }
    }

    func stop() {
        if process.isRunning { process.terminate() }
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
    var onEvent: ((String, [String: Any]) -> Void)?

    static var available: Bool { shell(["which", "media-control"]).status == 0 }

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
        DispatchQueue.main.async { self.onEvent?(kind, payload) }
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

// MARK: - Per-display hosts

final class VideoHost {
    let window: NSWindow
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper

    init(screen: NSScreen, url: URL) {
        window = makeDesktopWindow(for: screen)
        let item = AVPlayerItem(url: url)
        player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        let view = NSView(frame: screen.frame)
        view.wantsLayer = true
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        window.contentView = view
        window.orderFront(nil)
        player.play()
    }

    func setPaused(_ paused: Bool) { paused ? player.pause() : player.play() }
}

final class WebHost: NSObject, WKScriptMessageHandler {
    let window: NSWindow
    let webView: WKWebView
    let screen: NSScreen
    private(set) var paused = false

    init(screen: NSScreen, index: URL, root: URL, pendingPropertiesJSON: String) {
        self.screen = screen
        window = makeDesktopWindow(for: screen)

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
        window.__weMediaLast = {};
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
        window.contentView = webView
        window.orderFront(nil)
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
    private var videoHosts: [VideoHost] = []
    private var webHosts: [WebHost] = []
    private let audioTap = AudioTap()
    private let mediaFeed = MediaFeed()
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
        if let wallpaper = initialWallpaper {
            apply(wallpaper)
        } else {
            print("daemon idle — set a wallpaper with: wallpaperctl set <path-or-workshop-id>")
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
            webHosts = NSScreen.screens.map {
                WebHost(screen: $0, index: index, root: root, pendingPropertiesJSON: json)
            }
            print("web wallpaper on \(webHosts.count) display(s): \(root.lastPathComponent)")
            if !webServicesStarted {
                webServicesStarted = true
                startWebServices()
            }
        }
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
            self?.webHosts.forEach { $0.push(audio: frame) }
        }
        audioTap.start()
        print(audioTap.live ? "audio: cava launched" : "audio: cava unavailable (no audio response)")
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

        if MediaFeed.available {
            mediaFeed.onEvent = { [weak self] kind, payload in
                guard let self,
                      let data = try? JSONSerialization.data(withJSONObject: payload),
                      let json = String(data: data, encoding: .utf8) else { return }
                for host in self.webHosts {
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

    func shutdown() {
        audioTap.stop()
        mediaFeed.stop()
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

var initialWallpaper: Wallpaper?
if daemonMode {
    initialWallpaper = loadConfiguredWallpaper()   // nil = idle until SIGUSR1
} else {
    guard let inputPath = positional.first, let wallpaper = resolveWallpaper(inputPath) else {
        fputs("""
        usage: wallpaper-runtime <wallpaper> | --daemon
          <wallpaper>: a .mp4/.mov file, or a Wallpaper Engine project folder
                       containing project.json (type "video" or "web")
          --daemon:    read \(configFile.path), reload on SIGUSR1,
                       write a pidfile (managed by wallpaperctl)
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

application.run()
