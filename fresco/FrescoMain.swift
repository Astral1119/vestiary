import AppKit
import Carbon
import Darwin

@main
enum FrescoMain {
    static func main() {
    // Line-buffer stdout even when it's a log file, so daemon activity is
    // visible as it happens rather than stuck in a full buffer.
    setvbuf(stdout, nil, _IOLBF, 0)

    let flags = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") }
    let positional = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
    let daemonMode = flags.contains("--daemon")

    if flags.contains("--self-test-per-display-properties") {
        let left: [String: Any] = [
            "shared": ["type": "slider", "value": 0.2],
            "leftOnly": ["type": "textinput", "value": "left"],
            "scope": ["type": "directory", "value": "/left/old"],
        ]
        let right: [String: Any] = [
            "shared": ["type": "slider", "value": 0.8],
            "rightOnly": ["type": "textinput", "value": "right"],
        ]
        let overlay: [String: Any] = [
            "shared": ["type": "slider", "value": 1.0],
        ]
        let leftMerged = mergedWallpaperProperties(project: left, overlays: [overlay])
        let rightMerged = mergedWallpaperProperties(project: right, overlays: [overlay])
        var changedLeft = left
        changedLeft["shared"] = ["type": "slider", "value": 0.4]
        changedLeft["scope"] = ["type": "directory", "value": "/left/new"]
        let rawChanges = changedWebProperties(from: left, to: changedLeft)
        let effectiveChanges = changedWebProperties(
            from: leftMerged,
            to: mergedWallpaperProperties(project: changedLeft, overlays: [overlay]))
        let scoped = rawChanges.values.contains {
            (($0 as? [String: Any])?["type"] as? String)?.lowercased() == "directory"
        }
        guard leftMerged["leftOnly"] != nil,
              leftMerged["rightOnly"] == nil,
              rightMerged["rightOnly"] != nil,
              rightMerged["leftOnly"] == nil,
              ((leftMerged["shared"] as? [String: Any])?["value"] as? NSNumber) == 1,
              ((rightMerged["shared"] as? [String: Any])?["value"] as? NSNumber) == 1,
              rawChanges.keys.contains("shared"),
              effectiveChanges["shared"] == nil,
              scoped else {
            fputs("per-display property self-test failed\n", stderr)
            exit(1)
        }
        print("per-display property self-test passed")
        exit(0)
    }

    if flags.contains("--self-test-project-entry-resolution") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresco-missing-entry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            for type in ["web", "video"] {
                let project = root.appendingPathComponent(type)
                try FileManager.default.createDirectory(
                    at: project, withIntermediateDirectories: true)
                let document: [String: Any] = [
                    "type": type,
                    "file": type == "web" ? "missing.html" : "missing.mp4",
                ]
                try JSONSerialization.data(withJSONObject: document).write(
                    to: project.appendingPathComponent("project.json"))
                guard resolveWallpaper(project.path) == nil else {
                    fputs("project entry resolution self-test failed: \(type)\n", stderr)
                    exit(1)
                }
            }
        } catch {
            fputs("project entry resolution self-test failed: fixture\n", stderr)
            exit(1)
        }
        print("project entry resolution self-test passed")
        exit(0)
    }

    if flags.contains("--state-select") || flags.contains("--state-clear")
        || flags.contains("--state-muted") {
        let selecting = flags.contains("--state-select")
        let settingMuted = flags.contains("--state-muted")
        guard selecting ? positional.count == 2
                : settingMuted ? positional.count == 1
                : positional.isEmpty else {
            fputs("usage: fresco-worker --state-select <target> <legacy-path> "
                    + "| --state-clear | --state-muted <true|false|toggle>\n",
                  stderr)
            exit(64)
        }
        let muted: Bool?
        if settingMuted {
            switch positional[0] {
            case "true": muted = true
            case "false": muted = false
            case "toggle": muted = nil
            default:
                fputs("--state-muted expects true, false, or toggle\n", stderr)
                exit(64)
            }
        } else {
            muted = nil
        }
        let store = FrescoStateStore(directory: runtimeDirectory)
        let binding: FrescoBinding = selecting
            ? .wallpaper(target: positional[0])
            : .idle
        do {
            var accepted: FrescoState?
            for _ in 0..<3 {
                let revision = try store.load().state.revision
                do {
                    accepted = if settingMuted {
                        try store.setMuted(muted, expectedRevision: revision)
                    } else {
                        try store.selectClone(binding, expectedRevision: revision)
                    }
                    break
                } catch FrescoStateStoreError.revisionConflict {
                    continue
                }
            }
            guard let accepted else {
                throw FrescoStateStoreError.writeFailed(
                    path: runtimeDirectory.appendingPathComponent("state.json").path,
                    error: "state changed during three transaction attempts")
            }
            if !settingMuted {
                try store.writeLegacyProjectionTarget(selecting ? positional[1] : nil)
            }
            let response: [String: Any] = [
                "schemaVersion": 1,
                "revision": accepted.revision,
                "kind": settingMuted ? "controls" : selecting ? "wallpaper" : "idle",
                "muted": accepted.desired.controls?.muted ?? false,
            ]
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(0)
        } catch {
            fputs("state transaction failed: \(error)\n", stderr)
            exit(1)
        }
    }

    if flags.contains("--describe-web") {
        guard positional.count == 1, let description = webProjectDescription(positional[0]),
              let data = try? JSONSerialization.data(
                withJSONObject: description, options: [.sortedKeys]) else {
            fputs("wallpaper did not resolve to a web project\n", stderr)
            exit(1)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(0)
    }

    if flags.contains("--describe-project") {
        guard positional.count == 1, let description = wallpaperProjectDescription(positional[0]),
              let data = try? JSONSerialization.data(
                withJSONObject: description, options: [.sortedKeys]) else {
            fputs("wallpaper did not resolve to a property-bearing project\n", stderr)
            exit(1)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(0)
    }

    if flags.contains("--audit-web") {
        NSApplication.shared.setActivationPolicy(.accessory)
        guard positional.count == 3 else {
            fputs("usage: fresco-worker --audit-web <wallpaper> <report.json> <snapshot.png>\n",
                  stderr)
            exit(64)
        }
        let audit = WebWallpaperAudit(
            wallpaperPath: positional[0], reportPath: positional[1], snapshotPath: positional[2]
        )
        audit.run()
    }

    if flags.contains("--self-test-web-bridge") {
        NSApplication.shared.setActivationPolicy(.accessory)
        WebBridgeContractTest().run()
    }

    if flags.contains("--self-test-property-model") {
        guard let path = positional.first, let description = webProjectDescription(path),
              description["locale"] as? String == "en-us",
              let presentation = description["presentation"] as? [[String: Any]] else {
            fputs("property model self-test failed: description\n", stderr)
            exit(1)
        }
        let byName = Dictionary(uniqueKeysWithValues: presentation.compactMap { item
            -> (String, [String: Any])? in
            guard let name = item["name"] as? String else { return nil }
            return (name, item)
        })
        let speed = byName["speed"]
        let caption = byName["caption"]
        let modeOptions = byName["mode"]?["options"] as? [[String: Any]]
        guard speed?["label"] as? String == "Animation speed",
              speed?["active"] as? Bool == true,
              caption?["label"] as? String == "Caption",
              caption?["active"] as? Bool == false,
              modeOptions?.first?["label"] as? String == "First mode",
              (description["statePath"] as? String)?.hasPrefix(propertyStateDirectory.path) == true
        else {
            fputs("property model self-test failed: presentation\n", stderr)
            exit(1)
        }

        let old: [String: Any] = [
            "speed": ["type": "slider", "value": 3],
            "caption": ["type": "textinput", "value": "fixture"],
            "enabled": ["type": "bool", "value": false],
        ]
        let new: [String: Any] = [
            "speed": ["type": "slider", "value": 7],
            "caption": ["type": "textinput"],
            "enabled": ["type": "bool", "value": false],
        ]
        let changed = changedWebProperties(from: old, to: new)
        let event = webUserProperties(from: changed, includeEmptyText: true)
        guard Set(changed.keys) == Set(["speed", "caption"]),
              (event["speed"] as? [String: Any])?["value"] as? Int == 7,
              (event["caption"] as? [String: Any])?["value"] as? String == "" else {
            fputs("property model self-test failed: changed-only event\n", stderr)
            exit(1)
        }
        print("property model self-test passed")
        exit(0)
    }

    if flags.contains("--self-test-web-properties") {
        guard let path = positional.first,
              case .web(let projectIndex, let root, var properties)? = resolveWallpaper(path),
              let slideshow = properties["slideshow"] as? [String: Any],
              slideshow["type"] as? String == "directory",
              slideshow["mode"] as? String == "fetchall",
              slideshow["value"] as? String == "slides",
              let randomSlides = properties["randomslides"] as? [String: Any],
              randomSlides["type"] as? String == "directory",
              randomSlides["mode"] as? String == "ondemand",
              randomSlides["value"] as? String == "slides",
              let speed = properties["speed"] as? [String: Any],
              speed["type"] as? String == "slider",
              (speed["value"] as? NSNumber)?.intValue == 7 else {
            fputs("web property self-test failed: schema merge\n", stderr)
            exit(1)
        }
        let slidesPath = root.appendingPathComponent("slides").path
        overlayProperty(slidesPath, forKey: "slideshow", in: &properties)
        overlayProperty(slidesPath, forKey: "randomslides", in: &properties)
        let userProperties = webUserProperties(from: properties)
        let inventory = webDirectoryInventory(for: properties)
        let expectedFiles = ["one.png", "two.jpg"]
        let allNames = inventory.allFiles["randomslides"]?.map {
            ($0 as NSString).lastPathComponent
        }.sorted()
        let fetchAllNames = inventory.fetchAllFiles["slideshow"]?.map {
            ($0 as NSString).lastPathComponent
        }.sorted()
        guard userProperties["slideshow"] == nil,
              userProperties["optionalimage"] == nil,
              userProperties["randomslides"] != nil,
              allNames == expectedFiles, fetchAllNames == expectedFiles,
              inventory.fetchAllFiles["randomslides"] == nil else {
            fputs("web property self-test failed: runtime projection\n", stderr)
            exit(1)
        }
        let externalSlides = root.deletingLastPathComponent()
            .appendingPathComponent("external-slides")
        overlayProperty(externalSlides.path, forKey: "randomslides", in: &properties)
        var stagedRootPath = ""
        do {
            let accessScope = WebAccessScope(
                index: projectIndex, root: root, properties: properties)
            stagedRootPath = accessScope.root.path
            let stagedRandom = (accessScope.properties["randomslides"]
                as? [String: Any])?["value"] as? String ?? ""
            let stagedInventory = webDirectoryInventory(for: accessScope.properties)
            let stagedNames = stagedInventory.allFiles["randomslides"]?.map {
                ($0 as NSString).lastPathComponent
            }
            guard accessScope.root != root,
                  stagedRootPath.hasPrefix(runtimeDirectory.path + "/web-access-"),
                  FileManager.default.fileExists(atPath: accessScope.index.path),
                  stagedRandom.hasPrefix(stagedRootPath + "/"),
                  stagedNames == ["three.png"] else {
                fputs("web property self-test failed: scoped file access\n", stderr)
                exit(1)
            }
        }
        guard !FileManager.default.fileExists(atPath: stagedRootPath) else {
            fputs("web property self-test failed: scoped file cleanup\n", stderr)
            exit(1)
        }
        let presetPath = root.deletingLastPathComponent()
            .appendingPathComponent("web-properties-preset").path
        guard case .web(let presetIndex, let presetRoot, let presetProperties)? = resolveWallpaper(presetPath),
              let presetSpeed = presetProperties["speed"] as? [String: Any],
              presetSpeed["type"] as? String == "slider",
              (presetSpeed["value"] as? NSNumber)?.intValue == 9,
              let presetImage = presetProperties["optionalimage"] as? [String: Any],
              presetImage["type"] as? String == "file",
              let presetImagePath = presetImage["value"] as? String,
              presetImagePath == URL(fileURLWithPath: presetPath)
                .appendingPathComponent("files/preset.png").path,
              webUserProperties(from: presetProperties)["optionalimage"] != nil else {
            fputs("web property self-test failed: preset schema merge\n", stderr)
            exit(1)
        }
        var presetStagingPath = ""
        do {
            let accessScope = WebAccessScope(
                index: presetIndex, root: presetRoot, properties: presetProperties)
            presetStagingPath = accessScope.root.path
            let stagedImage = (accessScope.properties["optionalimage"]
                as? [String: Any])?["value"] as? String ?? ""
            let refreshedProperties = scopedWebProperties(
                presetProperties, using: accessScope.properties)
            let refreshedImage = ((webUserProperties(from: refreshedProperties)["optionalimage"]
                as? [String: Any])?["value"] as? String) ?? ""
            guard accessScope.root != presetRoot,
                  stagedImage.hasPrefix(presetStagingPath + "/"),
                  FileManager.default.fileExists(atPath: stagedImage),
                  refreshedImage == stagedImage else {
                fputs("web property self-test failed: preset asset access\n", stderr)
                exit(1)
            }
        }
        guard !FileManager.default.fileExists(atPath: presetStagingPath) else {
            fputs("web property self-test failed: preset asset cleanup\n", stderr)
            exit(1)
        }
        print("web property self-test passed")
        exit(0)
    }

    if flags.contains("--self-test-audio-layout") {
        let cava = (0..<128).map(Double.init)
        guard let frame = wallpaperAudioFrame(fromCava: cava), frame.count == 128,
              frame[0] == 63, frame[63] == 0, frame[64] == 64, frame[127] == 127,
              wallpaperAudioFrame(fromCava: [0]) == nil else {
            fputs("audio layout self-test failed\n", stderr)
            exit(1)
        }
        print("audio layout self-test passed")
        exit(0)
    }

    if flags.contains("--self-test-image-resolution") {
        guard let path = positional.first, case .image(let url)? = resolveWallpaper(path) else {
            fputs("image-resolution self-test failed\n", stderr)
            exit(1)
        }
        print("image-resolution self-test passed: \(url.lastPathComponent)")
        exit(0)
    }

    if flags.contains("--self-test-agent-counts") {
        let fixtures = [
            ("working", "%1", 9001), // pane wins even when its pid is dead
            ("waiting", nil, 9002),
            ("done", "%3", 9003),
            ("done", nil, 9004),      // dead pane-less task is evicted
            ("working", "%gone", 9002), // missing pane wins over a live pid
        ].map { state, pane, pid -> Data in
            var task: [String: Any] = [
                "kind": "codex", "state": state, "codex": ["pid": pid]
            ]
            if let pane { task["focus"] = ["tmux": ["pane": pane]] }
            return try! JSONSerialization.data(withJSONObject: ["data": task])
        }
        let tasks = AgentFeed.tasks(from: fixtures)
        let expected = AgentCounts(working: 1, waiting: 1, done: 1)
        guard AgentFeed.counts(from: tasks, livePaneIDs: ["%1", "%3"],
                               livePIDs: [9002]) == expected else {
            fputs("agent-count self-test failed\n", stderr)
            exit(1)
        }
        print("agent-count self-test passed")
        exit(0)
    }

    if flags.contains("--self-test-scene-supervisor") {
        let policy = SceneHelperPolicy(
            maximumRestarts: 3,
            restartWindow: 60,
            restartDelay: 0.01,
            heartbeatInterval: 1,
            heartbeatTimeout: 2)
        let crashing = SceneHelperSupervisor(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            project: URL(fileURLWithPath: "/tmp"),
            assetRoot: nil,
            assignmentID: "crash-test",
            policy: policy)
        var exhausted = false
        crashing.onExhausted = { exhausted = true }
        crashing.start()
        let crashDeadline = Date().addingTimeInterval(3)
        while !exhausted && Date() < crashDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        guard exhausted, crashing.launchCount == 4 else {
            fputs("scene supervisor self-test failed: restart limit\n", stderr)
            exit(1)
        }

        var clean: SceneHelperSupervisor? = SceneHelperSupervisor(
            executable: URL(fileURLWithPath: "/bin/cat"),
            project: URL(fileURLWithPath: "/tmp"),
            assetRoot: nil,
            assignmentID: "clean-test",
            policy: policy)
        weak let releasedClean = clean
        var cleanCompleted = false
        clean?.start()
        clean?.stop { cleanCompleted = true }
        guard !cleanCompleted else {
            fputs("scene supervisor self-test failed: stop completed before exit\n", stderr)
            exit(1)
        }
        clean = nil
        let cleanDeadline = Date().addingTimeInterval(1)
        while !cleanCompleted && Date() < cleanDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard cleanCompleted, releasedClean == nil else {
            fputs("scene supervisor self-test failed: exit-confirmed clean stop\n", stderr)
            exit(1)
        }

        let forceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresco-force-stop-\(UUID().uuidString)")
        let forceHelper = forceRoot.appendingPathComponent("ignore-term")
        let forceReady = forceRoot.appendingPathComponent("ready")
        do {
            try FileManager.default.createDirectory(
                at: forceRoot, withIntermediateDirectories: true)
            try "#!/bin/sh\ntrap '' TERM\ntouch '\(forceReady.path)'\nwhile :; do sleep 1; done\n"
                .write(to: forceHelper, atomically: true, encoding: .utf8)
            guard chmod(forceHelper.path, 0o700) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } catch {
            fputs("scene supervisor self-test failed: force-stop helper\n", stderr)
            exit(1)
        }
        defer { try? FileManager.default.removeItem(at: forceRoot) }
        var forced: SceneHelperSupervisor? = SceneHelperSupervisor(
            executable: forceHelper,
            project: forceRoot,
            assetRoot: nil,
            assignmentID: "force-stop-test",
            policy: policy)
        weak let releasedForced = forced
        forced?.start()
        let launchDeadline = Date().addingTimeInterval(1)
        while !FileManager.default.fileExists(atPath: forceReady.path),
              Date() < launchDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard FileManager.default.fileExists(atPath: forceReady.path) else {
            fputs("scene supervisor self-test failed: force-stop helper readiness\n", stderr)
            exit(1)
        }
        let forceStarted = Date()
        var forceCompleted = false
        forced?.forceStop { forceCompleted = true }
        forced = nil
        let forceDeadline = Date().addingTimeInterval(1.5)
        while !forceCompleted && Date() < forceDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let forceDuration = Date().timeIntervalSince(forceStarted)
        guard forceCompleted, forceDuration >= 0.45, forceDuration < 1.5,
              releasedForced == nil else {
            fputs("scene supervisor self-test failed: bounded force stop\n", stderr)
            exit(1)
        }
        print("scene supervisor self-test passed")
        exit(0)
    }

    if flags.contains("--self-test-scene-audio") {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresco-scene-audio-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: testRoot, withIntermediateDirectories: true)
        } catch {
            fputs("scene audio self-test failed: temporary directory\n", stderr)
            exit(1)
        }
        defer { try? FileManager.default.removeItem(at: testRoot) }

        func makeHelper(
            name: String, capabilities: String, stopReadingAfterLoad: Bool = false,
            exitAfterAudio: Bool = false, readyDelay: TimeInterval = 0
        ) -> (URL, URL)? {
            let executable = testRoot.appendingPathComponent(name)
            let capture = testRoot.appendingPathComponent("\(name).jsonl")
            let readyAction = readyDelay > 0
                ? "sleep \(readyDelay); printf '%s\\n' '{\"protocolVersion\":1,\"type\":\"ready\",\"assignmentID\":\"audio-test\",\"projection\":{\"width\":3840,\"height\":2160}}'"
                : "printf '%s\\n' '{\"protocolVersion\":1,\"type\":\"ready\",\"assignmentID\":\"audio-test\",\"projection\":{\"width\":3840,\"height\":2160}}'"
            let loadAction = stopReadingAfterLoad
                ? "printf '%s\\n' '{\"protocolVersion\":1,\"type\":\"ready\",\"assignmentID\":\"audio-test\",\"projection\":{\"width\":3840,\"height\":2160}}'; sleep 1; exit 0"
                : readyAction
            let audioAction = exitAfterAudio ? "exit 1" : ":"
            let source = """
            #!/bin/sh
            printf '%s' "${FRESCO_SCENE_SOUND_EXPERIMENTAL:-}" > '\(capture.path).env'
            while IFS= read -r line; do
              printf '%s\n' "$line" >> '\(capture.path)'
              case "$line" in
                *'"type":"hello"'*) printf '%s\n' '{"protocolVersion":1,"type":"hello","assignmentID":"audio-test","renderer":"fake","capabilities":\(capabilities)}' ;;
                *'"type":"inspect"'*) printf '%s\n' '{"protocolVersion":1,"type":"inspected","assignmentID":"audio-test","supported2D":true}' ;;
                *'"type":"validate-assets"'*) printf '%s\n' '{"protocolVersion":1,"type":"assets-validated","assignmentID":"audio-test"}' ;;
                *'"type":"load"'*) \(loadAction) ;;
                *'"type":"pause"'*) printf '%s\n' '{"protocolVersion":1,"type":"paused","assignmentID":"audio-test"}' ;;
                *'"type":"resume"'*) printf '%s\n' '{"protocolVersion":1,"type":"resumed","assignmentID":"audio-test"}' ;;
                *'"type":"unmute"'*) printf '%s\n' '{"protocolVersion":1,"type":"unmuted","assignmentID":"audio-test"}' ;;
                *'"type":"mute"'*) printf '%s\n' '{"protocolVersion":1,"type":"muted","assignmentID":"audio-test"}' ;;
                *'"type":"scheduling-policy"'*) printf '%s\n' '{"protocolVersion":1,"type":"scheduling-policy-applied","assignmentID":"audio-test"}' ;;
                *'"type":"ping"'*) printf '%s\n' '{"protocolVersion":1,"type":"heartbeat","assignmentID":"audio-test"}' ;;
                *'rejected-artwork'*) printf '%s\n' '{"protocolVersion":1,"type":"media-session-applied","assignmentID":"audio-test","kind":"thumbnail","artworkError":"decode-failed"}' ;;
                *'"kind":"thumbnail"'*) printf '%s\n' '{"protocolVersion":1,"type":"media-session-applied","assignmentID":"audio-test","kind":"thumbnail","artworkError":"none"}' ;;
                *'"type":"audio-spectrum"'*) \(audioAction) ;;
                *'"type":"stop"'*) printf '%s\n' '{"protocolVersion":1,"type":"stopped","assignmentID":"audio-test"}'; exit 0 ;;
              esac
            done
            """
            do {
                try source.write(to: executable, atomically: true, encoding: .utf8)
                guard chmod(executable.path, 0o700) == 0 else { return nil }
                return (executable, capture)
            } catch {
                return nil
            }
        }

        func runLoop(for interval: TimeInterval) {
            let deadline = Date().addingTimeInterval(interval)
            while Date() < deadline {
                _ = RunLoop.current.run(
                    mode: .default, before: Date().addingTimeInterval(0.005))
            }
        }

        func allMessages(at url: URL) -> [[String: Any]] {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard let data = String(line).data(using: .utf8),
                      let message = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else { return nil }
                return message
            }
        }

        func messages(at url: URL, type: String) -> [[String: Any]] {
            allMessages(at: url).filter { $0["type"] as? String == type }
        }

        guard let (helper, capture) = makeHelper(
            name: "helper",
            capabilities: "[\"audio-spectrum\",\"sound-cursor-click\"]") else {
            fputs("scene audio self-test failed: fake helper\n", stderr)
            exit(1)
        }
        let supervisor = SceneHelperSupervisor(
            executable: helper,
            project: testRoot,
            assetRoot: testRoot.path,
            assignmentID: "audio-test",
            fpsCeiling: 24,
            policyRevision: 7,
            policyReasonTokens: ["profile:battery"])
        var ready = false
        supervisor.onEvent = { event in
            if event["type"] as? String == "ready" { ready = true }
        }
        supervisor.pushAudioSpectrum(Array(repeating: 0.25, count: 128))
        supervisor.start()
        let readyDeadline = Date().addingTimeInterval(2)
        while !ready && Date() < readyDeadline { runLoop(for: 0.01) }
        runLoop(for: 0.06)
        supervisor.setSchedulingPolicy(
            fpsCeiling: 15,
            policyRevision: 8,
            reasonTokens: ["rule:low-power"])
        runLoop(for: 0.03)
        supervisor.cursorClick(at: NSPoint(x: 100, y: 100))
        supervisor.cursorClick(at: NSPoint(x: 2_000, y: 2_000))
        // The 1280x720 display maps onto the fake helper's 3840x2160 projection,
        // so (100, 100) is scene (300, 300). Off-display positions send nothing.
        supervisor.cursorDown(at: NSPoint(x: 100, y: 100))
        supervisor.cursorUp(at: NSPoint(x: 100, y: 100))
        supervisor.cursorMoved(to: NSPoint(x: 2_000, y: 2_000))
        runLoop(for: 0.03)
        let preReady = messages(at: capture, type: "audio-spectrum")
        let cursorClicks = messages(at: capture, type: "cursor-click")
        let cursorDowns = messages(at: capture, type: "cursor-down")
        let cursorUps = messages(at: capture, type: "cursor-up")
        let cursorMoves = messages(at: capture, type: "cursor-move")
        guard cursorDowns.count == 1, cursorUps.count == 1, cursorMoves.isEmpty,
              cursorDowns.first?["x"] as? Double == 300,
              cursorDowns.first?["y"] as? Double == 300,
              cursorUps.first?["x"] as? Double == 300 else {
            fputs("scene audio self-test failed: cursor events\n", stderr)
            exit(1)
        }
        let schedulingPolicies = messages(at: capture, type: "scheduling-policy")
        let loadPolicy = messages(at: capture, type: "load").first
        guard ready, supervisor.audioSpectrumSupported, preReady.count == 1,
              let cached = preReady.first?["values"] as? [NSNumber],
              cached.first?.doubleValue == 0.25,
              cursorClicks.count == 1,
              cursorClicks.first?["objectID"] as? Int == 289,
              loadPolicy?["muted"] as? Bool == true,
              loadPolicy?["fps"] as? Int == 24,
              loadPolicy?["policyRevision"] as? Int == 7,
              loadPolicy?["reasonTokens"] as? [String] == ["profile:battery"],
              schedulingPolicies.count == 2,
              schedulingPolicies.first?["fpsCeiling"] as? Int == 24,
              schedulingPolicies.first?["policyRevision"] as? Int == 7,
              schedulingPolicies.last?["fpsCeiling"] as? Int == 15,
              schedulingPolicies.last?["policyRevision"] as? Int == 8,
              schedulingPolicies.last?["reasonTokens"] as? [String]
                == ["rule:low-power"],
              (try? String(contentsOfFile: capture.path + ".env", encoding: .utf8)) == "1" else {
            fputs("scene audio self-test failed: capability handshake\n", stderr)
            exit(1)
        }

        guard let (delayedHelper, delayedCapture) = makeHelper(
            name: "delayed-helper", capabilities: "[]", readyDelay: 0.15) else {
            fputs("scene audio self-test failed: delayed fake helper\n", stderr)
            exit(1)
        }
        let delayed = SceneHelperSupervisor(
            executable: delayedHelper,
            project: testRoot,
            assetRoot: testRoot.path,
            assignmentID: "audio-test",
            fpsCeiling: 30,
            policyRevision: 10,
            policyReasonTokens: ["profile:initial"])
        delayed.setPaused(true)
        delayed.setMuted(false)
        delayed.start()
        runLoop(for: 0.05)
        guard messages(at: delayedCapture, type: "load").first?["muted"] as? Bool == true,
              messages(at: delayedCapture, type: "unmute").isEmpty else {
            fputs("scene audio self-test failed: pre-ready hard mute\n", stderr)
            exit(1)
        }
        delayed.setSchedulingPolicy(
            fpsCeiling: 12,
            policyRevision: 11,
            reasonTokens: ["rule:changed-before-ready"])
        let delayedProjection = sceneUserProperties(from: [
            "musicvolume": ["value": 0.4, "text": "Music volume", "type": "slider"]
        ])
        delayed.setUserProperties(delayedProjection, changed: delayedProjection)
        let delayedDeadline = Date().addingTimeInterval(2)
        while messages(at: delayedCapture, type: "unmute").isEmpty,
              Date() < delayedDeadline { runLoop(for: 0.01) }
        delayed.stop()
        let delayedTypes = allMessages(at: delayedCapture).compactMap { $0["type"] as? String }
        let delayedLoad = delayedTypes.firstIndex(of: "load")
        let readyCommands = delayedLoad.map {
            Array(delayedTypes[delayedTypes.index(after: $0)...].prefix(4))
        } ?? []
        let delayedDelta = messages(
            at: delayedCapture, type: "user-properties"
        ).first?["properties"] as? [String: Any]
        let delayedLoadPolicy = messages(at: delayedCapture, type: "load").first
        let delayedAppliedPolicy = messages(
            at: delayedCapture, type: "scheduling-policy"
        ).first
        guard messages(at: delayedCapture, type: "unmute").count == 1,
              readyCommands == [
                  "scheduling-policy", "pause", "user-properties", "unmute"
              ],
              delayedLoadPolicy?["fps"] as? Int == 30,
              delayedLoadPolicy?["policyRevision"] as? Int == 10,
              delayedLoadPolicy?["reasonTokens"] as? [String] == ["profile:initial"],
              delayedAppliedPolicy?["fpsCeiling"] as? Int == 12,
              delayedAppliedPolicy?["policyRevision"] as? Int == 11,
              delayedAppliedPolicy?["reasonTokens"] as? [String]
                == ["rule:changed-before-ready"],
              let delayedValue = delayedDelta?["musicvolume"] as? [String: Any],
              Set(delayedValue.keys) == Set(["value"]),
              (delayedValue["value"] as? NSNumber)?.doubleValue == 0.4 else {
            fputs("scene audio self-test failed: post-ready command ordering "
                + "(commands=\(readyCommands))\n", stderr)
            exit(1)
        }

        supervisor.setMuted(false)
        supervisor.setPaused(true)
        supervisor.setMuted(true)
        supervisor.setPaused(false)
        runLoop(for: 0.06)
        guard messages(at: capture, type: "unmute").count == 1,
              messages(at: capture, type: "mute").count >= 2,
              messages(at: capture, type: "pause").count == 1,
              messages(at: capture, type: "resume").count == 1 else {
            fputs("scene audio self-test failed: pause and mute independence\n", stderr)
            exit(1)
        }

        for value in 0..<20 {
            supervisor.pushAudioSpectrum(Array(repeating: Double(value) / 20, count: 128))
        }
        runLoop(for: 0.3)
        let initial = messages(at: capture, type: "audio-spectrum")
        guard initial.count == preReady.count + 2,
              initial.allSatisfy({ ($0["protocolVersion"] as? Int) == 1
                && ($0["assignmentID"] as? String) == "audio-test"
                && ($0["values"] as? [NSNumber])?.count == 128 }),
              let latest = initial.last?["values"] as? [NSNumber],
              latest.first?.doubleValue == 0.95 else {
            fputs("scene audio self-test failed: envelope or cadence "
                + "(messages=\(initial.count))\n", stderr)
            exit(1)
        }

        supervisor.setPaused(true)
        supervisor.pushAudioSpectrum(Array(repeating: 0.5, count: 128))
        runLoop(for: 0.06)
        guard messages(at: capture, type: "audio-spectrum").count == initial.count else {
            fputs("scene audio self-test failed: pause gate\n", stderr)
            exit(1)
        }
        supervisor.setPaused(false)
        runLoop(for: 0.06)
        supervisor.stop()
        runLoop(for: 0.06)
        let resumed = messages(at: capture, type: "audio-spectrum")
        guard resumed.count == initial.count + 1,
              let resumedValues = resumed.last?["values"] as? [NSNumber],
              resumedValues.first?.doubleValue == 0.5 else {
            fputs("scene audio self-test failed: resume gate\n", stderr)
            exit(1)
        }

        guard let (unsupportedHelper, unsupportedCapture) = makeHelper(
            name: "unsupported-helper", capabilities: "[]") else {
            fputs("scene audio self-test failed: unsupported fake helper\n", stderr)
            exit(1)
        }
        let unsupported = SceneHelperSupervisor(
            executable: unsupportedHelper,
            project: testRoot,
            assetRoot: testRoot.path,
            assignmentID: "audio-test")
        var unsupportedReady = false
        unsupported.onEvent = { event in
            if event["type"] as? String == "ready" { unsupportedReady = true }
        }
        unsupported.start()
        let unsupportedDeadline = Date().addingTimeInterval(2)
        while !unsupportedReady && Date() < unsupportedDeadline { runLoop(for: 0.01) }
        unsupported.pushAudioSpectrum(Array(repeating: 1, count: 128))
        runLoop(for: 0.06)
        unsupported.stop()
        runLoop(for: 0.06)
        guard unsupportedReady,
              messages(at: unsupportedCapture, type: "audio-spectrum").isEmpty else {
            fputs("scene audio self-test failed: unsupported capability gate\n", stderr)
            exit(1)
        }

        guard let (restartingHelper, restartingCapture) = makeHelper(
            name: "restarting-helper",
            capabilities: "[\"audio-spectrum\",\"media-session-v1\"]",
            exitAfterAudio: true) else {
            fputs("scene audio self-test failed: restarting fake helper\n", stderr)
            exit(1)
        }
        let restartPolicy = SceneHelperPolicy(
            maximumRestarts: 3,
            restartWindow: 60,
            restartDelay: 0.01,
            heartbeatInterval: 1,
            heartbeatTimeout: 2)
        let restarting = SceneHelperSupervisor(
            executable: restartingHelper,
            project: testRoot,
            assetRoot: testRoot.path,
            assignmentID: "audio-test",
            policy: restartPolicy,
            userProperties: ["musicvolume": ["value": 0.5]])
        var firstReady = false
        restarting.onEvent = { event in
            if event["type"] as? String == "ready" { firstReady = true }
        }
        let acceptedArtwork = "data:image/png;base64," +
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8A" +
            "AQUBAScY42YAAAAASUVORK5CYII="
        restarting.setMediaEvents([
            "status": ["enabled": true],
            "properties": ["title": "Full Moon Full Life"],
            "playback": ["state": 1],
            "timeline": ["position": 12.5, "duration": 240.0],
            "thumbnail": ["thumbnail": acceptedArtwork],
        ])
        restarting.setMuted(false)
        restarting.start()
        let firstReadyDeadline = Date().addingTimeInterval(2)
        while !firstReady && Date() < firstReadyDeadline { runLoop(for: 0.01) }
        restarting.setUserProperties(
            ["musicvolume": ["value": 0.25], "trainvolume": ["value": 0.75]],
            changed: ["musicvolume": ["value": 0.25]])
        let propertyDeadline = Date().addingTimeInterval(2)
        while messages(at: restartingCapture, type: "user-properties").isEmpty,
              Date() < propertyDeadline { runLoop(for: 0.01) }
        restarting.pushMediaEvent(
            kind: "thumbnail",
            payload: ["thumbnail": "data:image/png;base64,rejected-artwork"])
        restarting.pushAudioSpectrum(Array(repeating: 0.4, count: 128))
        restarting.setPaused(true)
        let replayDeadline = Date().addingTimeInterval(2)
        while (restarting.launchCount < 2
                || messages(at: restartingCapture, type: "unmute").count < 2
                || messages(at: restartingCapture, type: "pause").isEmpty),
              Date() < replayDeadline { runLoop(for: 0.01) }
        restarting.stop()
        let restartTypes = allMessages(at: restartingCapture).compactMap {
            $0["type"] as? String
        }
        let secondLoad = restartTypes.indices.filter { restartTypes[$0] == "load" }.dropFirst().first
        let replayControls = secondLoad.map {
            restartTypes[restartTypes.index(after: $0)...].filter {
                $0 == "pause" || $0 == "unmute"
            }
        } ?? []
        let loads = messages(at: restartingCapture, type: "load")
        let firstProperties = loads.first?["userProperties"] as? [String: Any]
        let replayProperties = loads.dropFirst().first?["userProperties"] as? [String: Any]
        let liveProperties = messages(
            at: restartingCapture, type: "user-properties"
        ).first?["properties"] as? [String: Any]
        let mediaMessages = messages(at: restartingCapture, type: "media-session")
        let mediaKinds = mediaMessages.compactMap { $0["kind"] as? String }
        let replayMedia = secondLoad.map { loadIndex in
            allMessages(at: restartingCapture).dropFirst(loadIndex + 1).filter {
                $0["type"] as? String == "media-session"
            }
        } ?? []
        let replayMediaKinds = replayMedia.compactMap { $0["kind"] as? String }
        let replayThumbnail = replayMedia.first {
            $0["kind"] as? String == "thumbnail"
        }?["payload"] as? [String: Any]
        let rejectedThumbnailSent = mediaMessages.contains {
            guard $0["kind"] as? String == "thumbnail",
                  let payload = $0["payload"] as? [String: Any] else { return false }
            return payload["thumbnail"] as? String
                == "data:image/png;base64,rejected-artwork"
        }
        guard restarting.launchCount >= 2,
              messages(at: restartingCapture, type: "audio-spectrum").count >= 1,
              messages(at: restartingCapture, type: "unmute").count >= 2,
              messages(at: restartingCapture, type: "pause").count >= 1,
              Array(replayControls.prefix(2)) == ["pause", "unmute"],
              (firstProperties?["musicvolume"] as? [String: Any])?["value"]
                as? Double == 0.5,
              Set(liveProperties?.keys.map { $0 } ?? []) == Set(["musicvolume"]),
              (liveProperties?["musicvolume"] as? [String: Any])?["value"]
                as? Double == 0.25,
              (replayProperties?["musicvolume"] as? [String: Any])?["value"]
                as? Double == 0.25,
              (replayProperties?["trainvolume"] as? [String: Any])?["value"]
                as? Double == 0.75,
              Array(mediaKinds.prefix(5))
                == ["status", "properties", "playback", "timeline", "thumbnail"],
              Array(replayMediaKinds.prefix(5))
                == ["status", "properties", "playback", "timeline", "thumbnail"],
              rejectedThumbnailSent,
              replayThumbnail?["thumbnail"] as? String
                == acceptedArtwork else {
            fputs("scene audio self-test failed: restart replay\n", stderr)
            exit(1)
        }

        guard let (blockedHelper, _) = makeHelper(
            name: "blocked-helper", capabilities: "[\"audio-spectrum\"]",
            stopReadingAfterLoad: true) else {
            fputs("scene audio self-test failed: blocked fake helper\n", stderr)
            exit(1)
        }
        let blocked = SceneHelperSupervisor(
            executable: blockedHelper,
            project: testRoot,
            assetRoot: testRoot.path,
            assignmentID: "audio-test",
            audioFramesPerSecond: 100_000)
        var blockedReady = false
        blocked.onEvent = { event in
            if event["type"] as? String == "ready" { blockedReady = true }
        }
        blocked.start()
        let blockedDeadline = Date().addingTimeInterval(2)
        while !blockedReady && Date() < blockedDeadline { runLoop(for: 0.01) }
        let pushStarted = Date()
        for value in 0..<2_000 {
            blocked.pushAudioSpectrum(Array(repeating: Double(value), count: 128))
        }
        let pushDuration = Date().timeIntervalSince(pushStarted)
        blocked.stop()
        guard blockedReady, pushDuration < 0.75 else {
            fputs("scene audio self-test failed: blocked helper stalled producer "
                + "(duration=\(pushDuration))\n", stderr)
            exit(1)
        }

        print("scene audio self-test passed")
        exit(0)
    }

    if flags.contains("--self-test-scene-resolution") {
        guard let path = positional.first,
              case .scene(let root, let package, let preview, _)? = resolveWallpaper(path),
              root.lastPathComponent == "scene-project",
              package.lastPathComponent == "scene.pkg",
              preview == nil else {
            fputs("scene resolution self-test failed\n", stderr)
            exit(1)
        }
        print("scene resolution self-test passed")
        exit(0)
    }

    if flags.contains("--self-test-scene-properties") {
        guard let path = positional.first else {
            fputs("scene property self-test failed: missing temporary path\n", stderr)
            exit(1)
        }
        let root = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let project: [String: Any] = [
            "title": "Scene properties",
            "type": "scene",
            "general": ["properties": [
                "musicvolume": [
                    "type": "slider", "value": 0.5, "min": 0, "max": 1,
                    "text": "<b>Music volume</b>", "order": 4,
                ],
                "tint": ["type": "COLOR", "value": "1 1 1"],
                "texture": ["type": "scenetexture", "value": "foreground"],
            ]],
        ]
        let local: [String: Any] = ["musicvolume": 0.75, "unknown": 4]
        try? JSONSerialization.data(withJSONObject: project).write(
            to: root.appendingPathComponent("project.json"))
        try? JSONSerialization.data(withJSONObject: local).write(
            to: root.appendingPathComponent("properties.local.json"))

        try? Data().write(to: root.appendingPathComponent("scene.pkg"))

        try? FileManager.default.createDirectory(
            at: propertyStateDirectory, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "schemaVersion": 1,
            "values": ["musicvolume": 0.25, "unknown": 9],
        ]
        try? JSONSerialization.data(withJSONObject: record).write(
            to: propertyStateURL(for: root.path))

        let sceneProjection = sceneEditableUserProperties(from: [
            "enabled": ["type": "bool", "value": true],
            "mode": ["type": "combo", "value": "calm"],
            "musicvolume": [
                "type": "slider", "value": 0.25, "text": "Music volume",
                "min": 0, "max": 1, "order": 4,
            ],
            "tint": ["type": "COLOR", "value": "1 1 1"],
            "caption": ["type": "textinput", "value": "hello"],
            "label": ["type": "text", "value": "Label"],
            "section": ["type": "group", "value": "Section"],
            "texture": ["type": "scenetexture", "value": "foreground"],
            "asset": ["type": "file", "value": "image.png"],
            "folder": ["type": "directory", "value": "assets"],
        ])
        let projectedMusic = sceneProjection["musicvolume"] as? [String: Any]

        let presetRoot = root.deletingLastPathComponent().appendingPathComponent("scene-preset")
        try? FileManager.default.createDirectory(
            at: presetRoot, withIntermediateDirectories: true)
        let preset: [String: Any] = [
            "title": "Unsupported scene preset",
            "type": "scene",
            "dependency": root.lastPathComponent,
            "preset": ["musicvolume": 0.1],
        ]
        try? JSONSerialization.data(withJSONObject: preset).write(
            to: presetRoot.appendingPathComponent("project.json"))

        guard case let .scene(_, _, _, properties)? = resolveWallpaper(root.path),
              let music = properties["musicvolume"] as? [String: Any],
              (music["value"] as? NSNumber)?.doubleValue == 0.25,
              properties["unknown"] == nil,
              let description = wallpaperProjectDescription(root.path),
              description["kind"] as? String == "scene",
              let presentation = description["presentation"] as? [[String: Any]],
              let supported = presentation.first(where: {
                  $0["name"] as? String == "tint"
              }),
              supported["runtimeSupported"] as? Bool == true,
              let unsupported = presentation.first(where: {
                  $0["name"] as? String == "texture"
              }),
              unsupported["runtimeSupported"] as? Bool == false,
              sceneProjection["texture"] == nil,
              Set(sceneProjection.keys) == Set([
                  "enabled", "mode", "musicvolume", "tint", "caption",
              ]),
              Set(projectedMusic?.keys.map { $0 } ?? []) == Set(["value"]),
              (projectedMusic?["value"] as? NSNumber)?.doubleValue == 0.25,
              wallpaperProjectDescription(presetRoot.path) == nil else {
            fputs("scene property self-test failed\n", stderr)
            exit(1)
        }
        print("scene property self-test passed")
        exit(0)
    }

    var initialWallpaper: Wallpaper?
    if daemonMode {
        initialWallpaper = nil
    } else {
        guard let inputPath = positional.first, let wallpaper = resolveWallpaper(inputPath) else {
            fputs("""
            usage: fresco-worker <wallpaper> | --daemon
              <wallpaper>: an image, a .mp4/.mov file, or a Wallpaper Engine
                           project folder containing project.json
                           (type "video", "web", or "scene")
              --daemon:    read \(runtimeDirectory.appendingPathComponent("state.json").path),
                           reconcile on SIGUSR1,
                           live property refresh on SIGHUP, repose cover on SIGUSR2,
                           scene metrics dump on SIGINFO,
                           write a pidfile
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

    signal(SIGHUP, SIG_IGN)
    let sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
    sighupSource.setEventHandler { controller.reloadUserProperties() }
    sighupSource.resume()

    signal(SIGUSR1, SIG_IGN)
    let sigusr1Source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    sigusr1Source.setEventHandler { controller.reloadFromConfig() }
    sigusr1Source.resume()

    signal(SIGUSR2, SIG_IGN)
    let sigusr2Source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
    sigusr2Source.setEventHandler { controller.handleReposeCommand() }
    sigusr2Source.resume()

    signal(SIGINFO, SIG_IGN)
    let siginfoSource = DispatchSource.makeSignalSource(signal: SIGINFO, queue: .main)
    siginfoSource.setEventHandler { controller.dumpSceneMetrics() }
    siginfoSource.resume()

    application.run()
    }
}
