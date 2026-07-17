import AppKit
import WebKit
import AVFoundation

// Phase-1 live-wallpaper runtime (see FEASIBILITY.md): desktop-level
// per-display windows playing Wallpaper Engine video and web wallpapers,
// with the WE JavaScript API shimmed natively — audio via a Cava system
// tap, cursor forwarding, occlusion-pause, and Livery Look colors pushed
// as WE user properties.

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
          let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let file = project["file"] as? String else { return nil }
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
    private let wallpaper: Wallpaper
    private var videoHosts: [VideoHost] = []
    private var webHosts: [WebHost] = []
    private let audioTap = AudioTap()
    private var mouseMonitor: Any?
    private var liveryTimer: Timer?
    private var liveryModified: Date?
    private var projectProperties: [String: Any] = [:]

    init(wallpaper: Wallpaper) {
        self.wallpaper = wallpaper
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            startWebServices()
        }
        observeOcclusion()
        print("occlusion-pause armed; Ctrl-C to quit")
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
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        liveryTimer?.invalidate()
        exit(0)
    }
}

// MARK: - Bootstrap

let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
guard let inputPath = arguments.first, let wallpaper = resolveWallpaper(inputPath) else {
    fputs("""
    usage: wallpaper-runtime <wallpaper>
      <wallpaper>: a .mp4/.mov file, or a Wallpaper Engine project folder
                   containing project.json (type "video" or "web")
    """ + "\n", stderr)
    exit(64)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = RuntimeController(wallpaper: wallpaper)
application.delegate = controller

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { controller.shutdown() }
sigintSource.resume()

application.run()
