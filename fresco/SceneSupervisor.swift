import AppKit
import Darwin

// The scene renderer runs out of process. This supervisor owns its protocol,
// lifecycle, heartbeat, and bounded restart policy.
struct SceneHelperPolicy {
    let maximumRestarts: Int
    let restartWindow: TimeInterval
    let restartDelay: TimeInterval
    let heartbeatInterval: TimeInterval
    let heartbeatTimeout: TimeInterval

    static let runtime = SceneHelperPolicy(
        maximumRestarts: 3,
        restartWindow: 60,
        restartDelay: 1,
        heartbeatInterval: 5,
        heartbeatTimeout: 15)
}

final class SceneHelperSupervisor {
    let assignmentID: String
    private let executable: URL
    private let project: URL
    private let assetRoot: String?
    private let displayFrame: NSRect
    private let policy: SceneHelperPolicy
    private let inputQueue = DispatchQueue(label: "fresco.scene-helper.stdin")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputBuffer = Data()
    private var desired = false
    private var intentionalExit = false
    private var restartDates: [Date] = []
    private var heartbeatTimer: Timer?
    private var lastEvent = Date()
    private var helloReceived = false
    private var rendererAvailable = false
    private var inspectionAccepted = false
    private var inspectionFinished = false
    private var assetsAccepted = false
    private var assetsFinished = false
    private var loadSent = false
    private var ready = false
    private var desiredPaused = false
    private var desiredMuted = true
    private var desiredVisible = true
    private var desiredFPSCeiling: Int
    private var desiredPolicyRevision: Int
    private var desiredPolicyReasonTokens: [String]
    private var desiredUserProperties: [String: Any]
    private var pendingUserPropertyChanges: [String: Any] = [:]
    private var launchGeneration = 0
    private var pendingMuteCompletions: [(Int, Bool, () -> Void)] = []
    private var exitCompletions: [() -> Void] = []
    private var processLifetimeOwner: SceneHelperSupervisor?
    private var supportsAudioSpectrum = false
    private var supportsMediaSession = false
    private var desiredMediaEvents: [String: [String: Any]] = [:]
    private var acceptedMediaEvents: [String: [String: Any]] = [:]
    private var pendingThumbnailPayloads: [[String: Any]] = []
    private var supportsSoundCursorClick = false
    private var projectionSize: NSSize?
    private var lastCursorMoveAt = Date.distantPast
    private var lastCursorScenePoint: NSPoint?
    private var latestAudioSpectrum: [Double]?
    private var pendingAudioSpectrum: [Double]?
    private var pendingAudioSequence: UInt64 = 0
    private var audioWriteInFlight = false
    private var audioTimer: Timer?
    private var lastAudioSendAt = Date.distantPast
    private let audioInterval: TimeInterval
    // One move per frame at 60 Hz. The renderer reads the pointer once per
    // frame, so anything above this is discarded before a script sees it.
    private let cursorMoveInterval: TimeInterval = 1.0 / 60.0

    // Diagnostics only. The helper answers `metrics` with everything the
    // renderer knows about itself, and nothing outside this process could ask
    // for it, because the supervisor owns the pipe. Requests are answered in
    // arrival order; the helper emits one `metrics` event per request.
    private var pendingMetrics: [([String: Any]?) -> Void] = []

    private(set) var launchCount = 0
    var onEvent: (([String: Any]) -> Void)?
    var onUnavailable: (() -> Void)?
    var onExhausted: (() -> Void)?
    var onAudioSupportChanged: (() -> Void)?

    var audioSpectrumSupported: Bool { supportsAudioSpectrum }

    init(executable: URL, project: URL, assetRoot: String?, assignmentID: String,
         displayFrame: NSRect = NSRect(x: 0, y: 0, width: 1280, height: 720),
         policy: SceneHelperPolicy = .runtime, audioFramesPerSecond: Double = 30,
         fpsCeiling: Int? = nil, policyRevision: Int = 0,
         policyReasonTokens: [String] = [],
         userProperties: [String: Any] = [:]) {
        self.executable = executable
        self.project = project
        self.assetRoot = assetRoot
        self.assignmentID = assignmentID
        self.displayFrame = displayFrame
        self.policy = policy
        self.audioInterval = 1.0 / max(1, audioFramesPerSecond)
        desiredFPSCeiling = fpsCeiling ?? 60
        desiredPolicyRevision = policyRevision
        desiredPolicyReasonTokens = policyReasonTokens
        desiredUserProperties = userProperties
    }

    func start() {
        guard !desired else { return }
        desired = true
        launch()
    }

    func stop(completion: (() -> Void)? = nil) {
        desired = false
        clearPendingAudio()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        guard let process else {
            completion?()
            return
        }
        if let completion { exitCompletions.append(completion) }
        intentionalExit = true
        if let input {
            send(type: "stop")
            inputQueue.async { try? input.close() }
        } else if process.isRunning {
            process.terminate()
        }
    }

    func forceStop(completion: @escaping () -> Void) {
        desired = false
        clearPendingAudio()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        guard let process else {
            completion()
            return
        }
        exitCompletions.append(completion)
        intentionalExit = true
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak process] in
            guard process?.isRunning == true else { return }
            Darwin.kill(pid, SIGKILL)
        }
    }

    func setPaused(_ paused: Bool) {
        desiredPaused = paused
        guard ready else { return }
        send(type: paused ? "pause" : "resume")
        if paused {
            suspendAudioTimer()
        } else {
            flushAudioSpectrum()
        }
    }

    func setMuted(_ muted: Bool, completion: (() -> Void)? = nil) {
        desiredMuted = muted
        guard ready else {
            if muted {
                let cancelled = pendingMuteCompletions.filter { !$0.1 }
                pendingMuteCompletions.removeAll { !$0.1 }
                cancelled.forEach { $0.2() }
                completion?()
            } else if let completion {
                let generation = process == nil ? launchGeneration + 1 : launchGeneration
                pendingMuteCompletions.append((generation, muted, completion))
            }
            return
        }
        if let completion {
            pendingMuteCompletions.append((launchGeneration, muted, completion))
        }
        send(type: muted ? "mute" : "unmute")
    }

    func setVisible(_ visible: Bool) {
        desiredVisible = visible
        guard ready else { return }
        send(type: visible ? "show" : "hide")
        if visible {
            flushAudioSpectrum()
        } else {
            suspendAudioTimer()
        }
    }

    func setSchedulingPolicy(
        fpsCeiling: Int?, policyRevision: Int, reasonTokens: [String]
    ) {
        desiredFPSCeiling = fpsCeiling ?? 60
        desiredPolicyRevision = policyRevision
        desiredPolicyReasonTokens = reasonTokens
        flushSchedulingPolicy()
    }

    func setUserProperties(_ properties: [String: Any], changed: [String: Any]) {
        desiredUserProperties = properties
        for (name, value) in changed { pendingUserPropertyChanges[name] = value }
        flushUserProperties()
    }

    func pushAudioSpectrum(_ values: [Double]) {
        guard values.count == 128, values.allSatisfy(\.isFinite) else { return }
        latestAudioSpectrum = values
        pendingAudioSpectrum = values
        pendingAudioSequence &+= 1
        scheduleAudioSpectrum()
    }

    func setMediaEvents(_ events: [String: [String: Any]]) {
        for (kind, payload) in events { desiredMediaEvents[kind] = payload }
        flushMediaEvents()
    }

    func pushMediaEvent(kind: String, payload: [String: Any]) {
        guard ["status", "properties", "playback", "timeline", "thumbnail"]
            .contains(kind) else { return }
        desiredMediaEvents[kind] = payload
        guard ready, supportsMediaSession else { return }
        sendMediaEvent(kind: kind, payload: payload)
    }

    private func flushMediaEvents(replayingAcceptedThumbnail: Bool = false) {
        guard ready, supportsMediaSession else { return }
        for kind in ["status", "properties", "playback", "timeline", "thumbnail"] {
            let payload = kind == "thumbnail" && replayingAcceptedThumbnail
                ? acceptedMediaEvents[kind] ?? desiredMediaEvents[kind]
                : desiredMediaEvents[kind]
            guard let payload else { continue }
            sendMediaEvent(kind: kind, payload: payload)
        }
    }

    private func sendMediaEvent(kind: String, payload: [String: Any]) {
        if kind == "thumbnail" { pendingThumbnailPayloads.append(payload) }
        send(type: "media-session", values: ["kind": kind, "payload": payload])
    }

    func cursorClick(at location: NSPoint) {
        guard desired, ready, desiredVisible, !desiredPaused,
              supportsSoundCursorClick, displayFrame.contains(location) else { return }
        send(type: "cursor-click", values: ["objectID": 289])
    }

    // Scene coordinates are absolute and bottom-up over the authored projection,
    // which is the same sense as NSEvent.mouseLocation, so this is a rescale of
    // the position within the display this scene occupies.
    private func scenePoint(for location: NSPoint) -> NSPoint? {
        guard let projectionSize, displayFrame.width > 0, displayFrame.height > 0,
              displayFrame.contains(location) else { return nil }
        return NSPoint(
            x: (location.x - displayFrame.minX) / displayFrame.width
                * projectionSize.width,
            y: (location.y - displayFrame.minY) / displayFrame.height
                * projectionSize.height
        )
    }

    private var acceptsCursor: Bool {
        desired && ready && desiredVisible && !desiredPaused
    }

    func cursorMoved(to location: NSPoint) {
        // A move per event would outrun the helper on a fast drag; the scripts
        // that read this interpolate anyway.
        guard Date().timeIntervalSince(lastCursorMoveAt) >= cursorMoveInterval else {
            return
        }
        sendCursor(phase: "move", at: location)
    }

    func cursorDown(at location: NSPoint) { sendCursor(phase: "down", at: location) }

    func cursorUp(at location: NSPoint) { sendCursor(phase: "up", at: location) }

    private func sendCursor(phase: String, at location: NSPoint) {
        guard acceptsCursor, let point = scenePoint(for: location) else { return }
        lastCursorMoveAt = Date()
        lastCursorScenePoint = point
        send(type: "cursor-\(phase)", values: ["x": point.x, "y": point.y])
    }

    private func scheduleAudioSpectrum() {
        guard acceptsAudioSpectrum, pendingAudioSpectrum != nil,
              !audioWriteInFlight else { return }
        let remaining = audioInterval - Date().timeIntervalSince(lastAudioSendAt)
        if remaining <= 0 {
            flushAudioSpectrum()
        } else if audioTimer == nil {
            audioTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) {
                [weak self] _ in self?.flushAudioSpectrum()
            }
        }
    }

    private var acceptsAudioSpectrum: Bool {
        desired && ready && supportsAudioSpectrum && !desiredPaused && desiredVisible
    }

    private func flushAudioSpectrum() {
        audioTimer?.invalidate()
        audioTimer = nil
        guard acceptsAudioSpectrum, let values = pendingAudioSpectrum,
              !audioWriteInFlight else { return }
        let sequence = pendingAudioSequence
        audioWriteInFlight = true
        lastAudioSendAt = Date()
        send(type: "audio-spectrum", values: ["values": values]) { [weak self] written in
            guard let self else { return }
            self.audioWriteInFlight = false
            if written && self.pendingAudioSequence == sequence {
                self.pendingAudioSpectrum = nil
            }
            if written { self.scheduleAudioSpectrum() }
        }
    }

    private func clearPendingAudio() {
        suspendAudioTimer()
        latestAudioSpectrum = nil
        pendingAudioSpectrum = nil
    }

    private func flushUserProperties() {
        guard ready, !pendingUserPropertyChanges.isEmpty else { return }
        let changed = pendingUserPropertyChanges
        pendingUserPropertyChanges.removeAll()
        send(type: "user-properties", values: ["properties": changed])
    }

    private func flushSchedulingPolicy() {
        guard ready else { return }
        send(type: "scheduling-policy", values: [
            "fpsCeiling": desiredFPSCeiling,
            "policyRevision": desiredPolicyRevision,
            "reasonTokens": desiredPolicyReasonTokens,
        ])
    }

    private func suspendAudioTimer() {
        audioTimer?.invalidate()
        audioTimer = nil
    }

    private func resetLaunchState() {
        let hadAudioSupport = supportsAudioSpectrum
        suspendAudioTimer()
        let abandoned = pendingMetrics
        pendingMetrics.removeAll()
        abandoned.forEach { $0(nil) }
        outputBuffer.removeAll(keepingCapacity: true)
        helloReceived = false
        rendererAvailable = false
        inspectionAccepted = false
        inspectionFinished = false
        assetsAccepted = false
        assetsFinished = assetRoot == nil
        loadSent = false
        ready = false
        supportsAudioSpectrum = false
        supportsMediaSession = false
        pendingThumbnailPayloads.removeAll(keepingCapacity: true)
        lastAudioSendAt = .distantPast
        lastEvent = Date()
        if hadAudioSupport { onAudioSupportChanged?() }
    }

    private func launch() {
        guard desired, process == nil else { return }
        launchGeneration += 1
        resetLaunchState()
        intentionalExit = false

        let launched = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        launched.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["FRESCO_SCENE_SOUND_EXPERIMENTAL"] = "1"
        launched.environment = environment
        launched.standardInput = inputPipe
        launched.standardOutput = outputPipe
        launched.standardError = FileHandle.standardError
        process = launched
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading

        output?.readabilityHandler = { [weak self, weak launched] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self, let launched, self.process === launched else { return }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    self.consume(data)
                }
            }
        }
        launched.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.terminated(ended) }
        }

        do {
            try launched.run()
            processLifetimeOwner = self
            launchCount += 1
            send(type: "hello")
            send(type: "inspect", values: ["path": project.path])
            if let assetRoot {
                send(type: "validate-assets", values: ["path": assetRoot])
            }
        } catch {
            output?.readabilityHandler = nil
            process = nil
            input = nil
            output = nil
            handleUnexpectedExit()
        }
    }

    private func send(
        type: String, values: [String: Any] = [:], completion: ((Bool) -> Void)? = nil
    ) {
        guard let input, let launched = process else {
            completion?(false)
            return
        }
        var message = values
        message["protocolVersion"] = 1
        message["type"] = type
        message["assignmentID"] = assignmentID
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            completion?(false)
            return
        }
        var line = data
        line.append(0x0a)
        inputQueue.async { [weak self, weak launched] in
            do {
                try input.write(contentsOf: line)
                DispatchQueue.main.async {
                    guard let self, let launched, self.process === launched else { return }
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, let launched, self.process === launched,
                          launched.isRunning else { return }
                    completion?(false)
                    launched.terminate()
                }
            }
        }
    }

    /// Ask the running helper for its metrics. Answers nil if the helper is not
    /// up, if the write fails, or if it does not reply within the timeout —
    /// a diagnostic must not hang the daemon's main queue waiting on a wedged
    /// renderer, which is one of the states worth diagnosing.
    func requestMetrics(
        timeout: TimeInterval = 2.0, completion: @escaping ([String: Any]?) -> Void
    ) {
        guard ready else {
            completion(nil)
            return
        }
        pendingMetrics.append(completion)
        let generation = launchGeneration
        send(type: "metrics") { [weak self] delivered in
            guard let self else { return }
            if !delivered { self.resolveMetrics(nil, generation: generation) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.resolveMetrics(nil, generation: generation)
        }
    }

    private func resolveMetrics(_ event: [String: Any]?, generation: Int? = nil) {
        if let generation, generation != launchGeneration { return }
        guard !pendingMetrics.isEmpty else { return }
        pendingMetrics.removeFirst()(event)
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0a) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let event = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                  event["protocolVersion"] as? Int == 1,
                  event["assignmentID"] as? String == assignmentID else { continue }
            handle(event)
        }
    }

    private func handle(_ event: [String: Any]) {
        lastEvent = Date()
        onEvent?(event)
        switch event["type"] as? String {
        case "hello":
            helloReceived = true
            rendererAvailable = event["renderer"] as? String != "unavailable"
                && event["renderer"] as? String != nil
            let capabilities = event["capabilities"] as? [String] ?? []
            supportsMediaSession = capabilities.contains("media-session-v1")
            supportsSoundCursorClick = capabilities.contains("sound-cursor-click")
            let audioSupport = capabilities.contains("audio-spectrum")
            if audioSupport != supportsAudioSpectrum {
                supportsAudioSpectrum = audioSupport
                onAudioSupportChanged?()
            }
        case "inspected":
            inspectionFinished = true
            inspectionAccepted = event["supported2D"] as? Bool == true
        case "unsupported":
            inspectionFinished = true
            inspectionAccepted = false
        case "assets-validated":
            assetsFinished = true
            assetsAccepted = true
        case "assets-invalid":
            assetsFinished = true
            assetsAccepted = false
        case "ready":
            ready = true
            if let projection = event["projection"] as? [String: Any],
               let width = projection["width"] as? Double,
               let height = projection["height"] as? Double,
               width > 0, height > 0 {
                projectionSize = NSSize(width: width, height: height)
            }
            startHeartbeat()
            flushSchedulingPolicy()
            if desiredPaused {
                send(type: "pause")
            }
            flushUserProperties()
            send(type: desiredMuted ? "mute" : "unmute")
            if !desiredPaused { flushAudioSpectrum() }
            flushMediaEvents(replayingAcceptedThumbnail: launchCount > 1)
        case "muted", "unmuted":
            let acknowledgedMuted = event["type"] as? String == "muted"
            if let index = pendingMuteCompletions.firstIndex(where: {
                $0.0 == launchGeneration && $0.1 == acknowledgedMuted
            }) {
                let completion = pendingMuteCompletions.remove(at: index).2
                completion()
            }
        case "metrics":
            resolveMetrics(event)
        case "media-session-applied":
            if event["kind"] as? String == "thumbnail",
               !pendingThumbnailPayloads.isEmpty {
                let payload = pendingThumbnailPayloads.removeFirst()
                if event["artworkError"] as? String == "none" {
                    acceptedMediaEvents["thumbnail"] = payload
                }
            }
        case "fatal":
            if event["scope"] as? String == "process" {
                if process?.isRunning == true { process?.terminate() }
            }
        default:
            break
        }
        advance()
    }

    private func advance() {
        guard helloReceived, inspectionFinished, assetsFinished else { return }
        guard inspectionAccepted, rendererAvailable, assetRoot != nil, assetsAccepted else {
            stop()
            return
        }
        guard !loadSent else { return }
        loadSent = true
        pendingUserPropertyChanges.removeAll()
        send(type: "load", values: [
            "path": project.path,
            "assetRoot": assetRoot as Any,
            "x": displayFrame.origin.x,
            "y": displayFrame.origin.y,
            "width": displayFrame.size.width,
            "height": displayFrame.size.height,
            "fps": desiredFPSCeiling,
            "policyRevision": desiredPolicyRevision,
            "reasonTokens": desiredPolicyReasonTokens,
            "visible": desiredVisible,
            "muted": true,
            "realtimeClock": true,
            "userProperties": desiredUserProperties,
        ])
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: policy.heartbeatInterval, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastEvent) > self.policy.heartbeatTimeout {
                if self.process?.isRunning == true { self.process?.terminate() }
            } else {
                self.send(type: "ping")
            }
        }
    }

    private func terminated(_ ended: Process) {
        guard process === ended else { return }
        let hadAudioSupport = supportsAudioSpectrum
        suspendAudioTimer()
        audioWriteInFlight = false
        pendingAudioSpectrum = latestAudioSpectrum
        pendingAudioSequence &+= 1
        output?.readabilityHandler = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        process = nil
        input = nil
        output = nil
        ready = false
        supportsAudioSpectrum = false
        supportsSoundCursorClick = false
        projectionSize = nil
        let completedGeneration = launchGeneration
        let completions = pendingMuteCompletions.filter { $0.0 == completedGeneration }
        pendingMuteCompletions.removeAll { $0.0 == completedGeneration }
        completions.forEach { $0.2() }
        let stopCompletions = exitCompletions
        exitCompletions.removeAll()
        processLifetimeOwner = nil
        stopCompletions.forEach { $0() }
        if hadAudioSupport { onAudioSupportChanged?() }
        let expected = intentionalExit || !desired
        intentionalExit = false
        if !expected { handleUnexpectedExit() }
    }

    private func handleUnexpectedExit() {
        guard desired else { return }
        onUnavailable?()
        let now = Date()
        restartDates = restartDates.filter {
            now.timeIntervalSince($0) <= policy.restartWindow
        }
        guard restartDates.count < policy.maximumRestarts else {
            desired = false
            onExhausted?()
            return
        }
        restartDates.append(now)
        DispatchQueue.main.asyncAfter(deadline: .now() + policy.restartDelay) { [weak self] in
            self?.launch()
        }
    }
}
