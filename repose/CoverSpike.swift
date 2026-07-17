import AppKit

// Disposable mechanics spike for the repose cover surface. It renders no
// scene — just an instrumented full-screen cover that answers the platform
// questions in SPIKE.md before anything pretty is built.

enum SpikeMode: String {
    case tap // never becomes key; an active CGEventTap consumes keyboard input
    case key // non-activating panel takes key status and receives keys directly
}

func parseMode() -> SpikeMode {
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        if argument == "--mode", let value = arguments.next(), let mode = SpikeMode(rawValue: value) {
            return mode
        }
    }
    return .tap
}

let spikeMode = parseMode()
let autoExitSeconds = Double(ProcessInfo.processInfo.environment["REPOSE_SPIKE_AUTO_EXIT"] ?? "") ?? 120

// MARK: - Shell and yabai helpers

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

struct FocusedWindow: Equatable, CustomStringConvertible {
    let id: Int
    let app: String
    let title: String

    var description: String { "#\(id) \(app) — \(title.prefix(40))" }
}

func queryFocusedWindow() -> FocusedWindow? {
    let result = shell(["yabai", "-m", "query", "--windows", "--window"])
    guard result.status == 0,
          let data = result.stdout.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = object["id"] as? Int else { return nil }
    return FocusedWindow(
        id: id,
        app: object["app"] as? String ?? "?",
        title: object["title"] as? String ?? ""
    )
}

func querySpikeWindowsSeenByYabai() -> String {
    let result = shell(["yabai", "-m", "query", "--windows"])
    guard result.status == 0,
          let data = result.stdout.data(using: .utf8),
          let windows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return "yabai unavailable"
    }
    let pid = Int(ProcessInfo.processInfo.processIdentifier)
    let mine = windows.filter { ($0["pid"] as? Int) == pid }
    if mine.isEmpty { return "cover windows invisible to yabai" }
    let floating = mine.allSatisfy { ($0["is-floating"] as? Bool) == true }
    return "yabai lists \(mine.count) cover window(s), all floating: \(floating)"
}

// MARK: - Keyboard tap (tap mode)

final class KeyTap {
    enum Status: String {
        case inactive
        case active = "active (consuming keys)"
        case unavailable = "UNAVAILABLE — keys pass through to hidden windows"
    }

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var status: Status = .inactive
    private(set) var consumedCount = 0
    var onIntentionalKey: ((Int64) -> Void)?

    // The event mask deliberately excludes NX_SYSDEFINED: media and volume
    // keys never enter the tap, so the carve-out costs nothing.
    func start() -> Bool {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let machPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let keyTap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return keyTap.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            status = .unavailable
            return false
        }
        self.machPort = machPort
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: machPort, enable: true)
        status = .active
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let machPort { CGEvent.tapEnable(tap: machPort, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        consumedCount += 1
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            DispatchQueue.main.async { self.onIntentionalKey?(keyCode) }
        }
        return nil
    }

    func stop() {
        guard let machPort else { return }
        CGEvent.tapEnable(tap: machPort, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.machPort = nil
        runLoopSource = nil
        status = .inactive
    }
}

// MARK: - Cover window

final class CoverPanel: NSPanel {
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

final class CoverView: NSView {
    var onMouseDown: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseDown?() }
    override func rightMouseDown(with event: NSEvent) { onMouseDown?() }
    override func keyDown(with event: NSEvent) { onKeyDown?(event) }
    override func scrollWheel(with event: NSEvent) {}
}

// MARK: - Controller

final class SpikeController: NSObject, NSApplicationDelegate {
    private var panels: [CoverPanel] = []
    private let keyTap = KeyTap()
    private var covering = false
    private var barHidden = false
    private var appEverActivated = false
    private var focusBefore: FocusedWindow?
    private var focusDriftLogged = false
    private var pollTimer: DispatchSourceTimer?
    private var autoExitWork: DispatchWorkItem?
    private var enteredAt = Date()
    private var logLines: [String] = []
    private var diagnosticsField: NSTextField?
    private let pollQueue = DispatchQueue(label: "repose.spike.poll", qos: .utility)

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.appEverActivated = true
            self?.log("APP BECAME ACTIVE (should not happen)")
        }
        print("repose cover spike — mode: \(spikeMode.rawValue)")
        print("Entering in 2s. Exit: any key or click. Auto-exit after \(Int(autoExitSeconds))s.")
        print("While covered: play music + try media keys, wave the mouse, try ctrl+N space keys.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.enter() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreBar()
    }

    func handleCommand(_ line: String) {
        let command = line.trimmingCharacters(in: .whitespaces)
        if command == "q" {
            NSApp.terminate(nil)
        } else if command.isEmpty, !covering {
            enter()
        }
    }

    func shutdown() {
        restoreBar()
        exit(0)
    }

    // MARK: Enter / exit

    private func enter() {
        guard !covering else { return }
        covering = true
        enteredAt = Date()
        focusDriftLogged = false
        logLines.removeAll()
        pollQueue.async {
            let focus = queryFocusedWindow()
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            let hidden = shell(["sketchybar", "--bar", "hidden=on"]).status == 0
            DispatchQueue.main.async {
                self.focusBefore = focus
                self.barHidden = hidden
                self.log("focus before: \(focus?.description ?? "yabai unavailable") (front app: \(front))")
                if !hidden { self.log("sketchybar unavailable; bar not hidden") }
                self.showCovers()
            }
        }
    }

    private func showCovers() {
        panels = NSScreen.screens.map { screen in
            let panel = CoverPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1.0)
            panel.isOpaque = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.allowKey = spikeMode == .key
            panel.contentView = makeCoverContent(isPrimary: screen == NSScreen.screens.first)
            return panel
        }
        for panel in panels { panel.orderFrontRegardless() }

        switch spikeMode {
        case .tap:
            if !keyTap.start() {
                log("EVENT TAP \(KeyTap.Status.unavailable.rawValue)")
                log("grant Accessibility to the launching terminal, or use --mode key")
            }
            keyTap.onIntentionalKey = { [weak self] keyCode in
                self?.exitCover(reason: "keyDown (code \(keyCode), consumed)")
            }
        case .key:
            if let primary = panels.first {
                primary.makeKeyAndOrderFront(nil)
                primary.contentView?.window?.makeFirstResponder(primary.contentView)
                log("panel key: \(primary.isKeyWindow)")
            }
        }

        startPolling()
        let work = DispatchWorkItem { [weak self] in self?.exitCover(reason: "auto-exit safety timeout") }
        autoExitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoExitSeconds, execute: work)
        pollQueue.async {
            let seen = querySpikeWindowsSeenByYabai()
            DispatchQueue.main.async { self.log(seen) }
        }
        log("covered — mode \(spikeMode.rawValue), tap \(keyTap.status.rawValue)")
        updateDiagnostics()
    }

    private func exitCover(reason: String) {
        guard covering else { return }
        covering = false
        autoExitWork?.cancel()
        pollTimer?.cancel()
        pollTimer = nil
        let consumed = keyTap.consumedCount
        // Delay the tap teardown so the trailing keyUp of the exit key is
        // swallowed rather than delivered to the refocused window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.keyTap.stop() }
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        diagnosticsField = nil
        restoreBar()
        let before = focusBefore
        let ever = appEverActivated
        pollQueue.async {
            let after = queryFocusedWindow()
            DispatchQueue.main.async {
                print("\n--- exit report (\(reason)) ---")
                print("duration: \(Int(Date().timeIntervalSince(self.enteredAt)))s")
                print("focus before: \(before?.description ?? "yabai unavailable")")
                print("focus after:  \(after?.description ?? "yabai unavailable")")
                print("focus preserved: \(before == after ? "YES" : "NO")")
                print("app ever activated: \(ever ? "YES (bad)" : "no")")
                print("key events consumed: \(consumed)")
                print("focus drift under cover: \(self.focusDriftLogged ? "YES (ffm reached beneath)" : "none observed")")
                print("---")
                print("Enter = re-enter, q = quit")
            }
        }
    }

    private func restoreBar() {
        guard barHidden else { return }
        barHidden = false
        pollQueue.async { shell(["sketchybar", "--bar", "hidden=off"]) }
    }

    // MARK: Focus polling (detects focus-follows-mouse reaching beneath the cover)

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, let current = queryFocusedWindow() else { return }
            DispatchQueue.main.async {
                guard self.covering else { return }
                if let baseline = self.focusBefore, current != baseline, !self.focusDriftLogged {
                    self.focusDriftLogged = true
                    self.log("FOCUS DRIFT under cover → \(current)")
                }
                self.updateDiagnostics()
            }
        }
        timer.resume()
        pollTimer = timer
    }

    // MARK: HUD

    private func makeCoverContent(isPrimary: Bool) -> NSView {
        let view = CoverView()
        view.onMouseDown = { [weak self] in self?.exitCover(reason: "mouse click") }
        view.onKeyDown = { [weak self] event in
            self?.exitCover(reason: "keyDown (code \(event.keyCode), via key window)")
        }
        guard isPrimary else { return view }

        let title = NSTextField(labelWithString: "repose cover spike")
        title.font = .systemFont(ofSize: 40, weight: .light)
        title.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)

        let hint = NSTextField(labelWithString: "any key or click exits · media keys should pass through")
        hint.font = .systemFont(ofSize: 15, weight: .regular)
        hint.textColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)

        let diagnostics = NSTextField(labelWithString: "")
        diagnostics.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        diagnostics.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
        diagnostics.maximumNumberOfLines = 16
        diagnosticsField = diagnostics

        let stack = NSStackView(views: [title, hint, diagnostics])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    private func log(_ message: String) {
        let line = "\(timeFormatter.string(from: Date()))  \(message)"
        print(line)
        logLines.append(line)
        if logLines.count > 10 { logLines.removeFirst() }
        updateDiagnostics()
    }

    private func updateDiagnostics() {
        guard let diagnosticsField else { return }
        let header = [
            "mode: \(spikeMode.rawValue)   tap: \(keyTap.status.rawValue)   consumed: \(keyTap.consumedCount)",
            "app active: \(NSApp.isActive ? "YES" : "no")   ever: \(appEverActivated ? "YES" : "no")   key window: \(panels.first?.isKeyWindow == true ? "yes" : "no")",
        ]
        diagnosticsField.stringValue = (header + logLines).joined(separator: "\n")
    }
}

// MARK: - Bootstrap

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = SpikeController()
application.delegate = controller

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { controller.shutdown() }
sigintSource.resume()

Thread.detachNewThread {
    while let line = readLine(strippingNewline: true) {
        DispatchQueue.main.async { controller.handleCommand(line) }
    }
}

application.run()
