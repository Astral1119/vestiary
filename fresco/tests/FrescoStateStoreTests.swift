import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.assertion(message) }
}

private func temporaryDirectory(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fresco-state-store-tests")
        .appendingPathComponent(name + "-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func withTemporaryDirectory(
    _ name: String, body: (URL) throws -> Void
) throws {
    let directory = try temporaryDirectory(name)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func directState(target: String, revision: Int = 99) -> FrescoState {
    FrescoState(
        schemaVersion: 1,
        revision: revision,
        updatedAt: "2000-01-01T00:00:00Z",
        displays: [],
        playlists: [],
        profiles: [],
        applicationRules: [],
        desired: FrescoDesiredState(
            profileId: nil,
            layout: .clone(binding: .wallpaper(target: target)),
            controls: FrescoControls(paused: false, muted: false),
            fpsCeiling: nil
        )
    )
}

private func cloneBinding(_ state: FrescoState) -> FrescoBinding? {
    guard case let .clone(binding)? = state.desired.layout else { return nil }
    return binding
}

private func testLegacyMigrationAndIdempotence() throws {
    try withTemporaryDirectory("legacy") { directory in
        let current = directory.appendingPathComponent("current")
        try Data("workshop:123\n".utf8).write(to: current)
        let store = FrescoStateStore(directory: directory)

        let migrated = try store.load()
        try expect(migrated.source == .migratedLegacy, "legacy state did not report migration")
        try expect(migrated.state.revision == 1, "legacy migration did not start at revision 1")
        try expect(
            cloneBinding(migrated.state) == .wallpaper(target: "workshop:123"),
            "legacy target was not retained")
        let preservedCurrent = try String(contentsOf: current, encoding: .utf8)
        try expect(
            preservedCurrent == "workshop:123\n",
            "legacy evidence was rewritten during migration")

        let stateData = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        let second = try store.load()
        try expect(second.source == .state, "second load repeated legacy migration")
        try expect(second.state == migrated.state, "second load changed accepted state")
        let secondStateData = try Data(contentsOf: directory.appendingPathComponent("state.json"))
        try expect(
            secondStateData == stateData,
            "idempotent load rewrote state")
    }
}

private func testEmptyLegacyMigration() throws {
    try withTemporaryDirectory("empty-legacy") { directory in
        try Data().write(to: directory.appendingPathComponent("current"))
        let loaded = try FrescoStateStore(directory: directory).load()
        try expect(cloneBinding(loaded.state) == .idle, "empty legacy selection did not migrate idle")
    }
}

private func testStrictAndSemanticValidation() throws {
    try withTemporaryDirectory("validation") { directory in
        let invalid = """
        {
          "schemaVersion": 1,
          "revision": 1,
          "updatedAt": "2026-07-20T18:00:00Z",
          "displays": [],
          "playlists": [],
          "profiles": [],
          "applicationRules": [],
          "desired": {
            "layout": {"mode": "clone", "binding": {"kind": "playlist", "playlistId": "missing"}},
            "controls": {"paused": false, "muted": false},
            "fpsCeiling": 241
          },
          "unknown": true
        }
        """
        try Data(invalid.utf8).write(to: directory.appendingPathComponent("state.json"))
        do {
            _ = try FrescoStateStore(directory: directory).load()
            throw TestFailure.assertion("invalid state was accepted")
        } catch let FrescoStateStoreError.invalidState(_, errors) {
            try expect(
                errors.contains(where: { $0.contains("additional property 'unknown'") }),
                "unknown field was not reported")
            try expect(
                errors.contains(where: { $0.contains("unknown playlist ID 'missing'") }),
                "dangling playlist was not reported")
            try expect(
                errors.contains(where: { $0.contains("value is above maximum 240") }),
                "out-of-range FPS ceiling was not reported")
        }
    }
}

private func testLastKnownGoodRecoveryPreservesInvalidState() throws {
    try withTemporaryDirectory("recovery") { directory in
        let current = directory.appendingPathComponent("current")
        try Data("good\n".utf8).write(to: current)
        let store = FrescoStateStore(directory: directory)
        let accepted = try store.load().state
        let invalid = Data("{\"broken\":true}\n".utf8)
        let stateFile = directory.appendingPathComponent("state.json")
        try invalid.write(to: stateFile)

        let recovered = try store.load()
        try expect(recovered.source == .lastKnownGood, "invalid state did not use last-known-good")
        try expect(recovered.state == accepted, "recovery changed last accepted state")
        try expect(!recovered.diagnostics.isEmpty, "recovery omitted invalid-state diagnostics")
        let preservedInvalid = try Data(contentsOf: stateFile)
        try expect(preservedInvalid == invalid, "recovery overwrote invalid state")

        try FileManager.default.removeItem(at: stateFile)
        try Data("different\n".utf8).write(to: current)
        let missingRecovery = try store.load()
        try expect(
            missingRecovery.source == .lastKnownGood,
            "missing versioned state fell back to legacy current")
        try expect(
            missingRecovery.state == accepted,
            "missing versioned state imported a competing legacy target")
    }
}

private func testRevisionedReplacementAndConflict() throws {
    try withTemporaryDirectory("replacement") { directory in
        let store = FrescoStateStore(directory: directory)
        let initial = try store.load().state
        let replacement = try store.replace(
            directState(target: "next", revision: 300), expectedRevision: initial.revision)
        try expect(replacement.revision == initial.revision + 1, "replacement revision did not advance once")
        try expect(
            cloneBinding(replacement) == .wallpaper(target: "next"),
            "replacement payload was not accepted")
        try expect(replacement.updatedAt != "2000-01-01T00:00:00Z", "caller timestamp was trusted")

        let stateFile = directory.appendingPathComponent("state.json")
        let acceptedData = try Data(contentsOf: stateFile)
        do {
            _ = try store.replace(directState(target: "stale"), expectedRevision: initial.revision)
            throw TestFailure.assertion("stale replacement was accepted")
        } catch let FrescoStateStoreError.revisionConflict(expected, actual) {
            try expect(expected == initial.revision, "conflict lost expected revision")
            try expect(actual == replacement.revision, "conflict lost actual revision")
        }
        let postConflictData = try Data(contentsOf: stateFile)
        try expect(
            postConflictData == acceptedData,
            "revision conflict changed accepted state")
    }
}

private func testInvalidReplacementPreservesAcceptedFiles() throws {
    try withTemporaryDirectory("invalid-replacement") { directory in
        let store = FrescoStateStore(directory: directory)
        let initial = try store.load().state
        let invalid = FrescoState(
            schemaVersion: 1,
            revision: 1,
            updatedAt: "2026-07-20T18:00:00Z",
            displays: [],
            playlists: [],
            profiles: [],
            applicationRules: [],
            desired: FrescoDesiredState(
                profileId: nil,
                layout: .clone(binding: .playlist(id: "missing")),
                controls: FrescoControls(paused: false, muted: false),
                fpsCeiling: nil
            )
        )
        let stateFile = directory.appendingPathComponent("state.json")
        let goodFile = directory.appendingPathComponent("state.last-known-good.json")
        let stateData = try Data(contentsOf: stateFile)
        let goodData = try Data(contentsOf: goodFile)
        do {
            _ = try store.replace(invalid, expectedRevision: initial.revision)
            throw TestFailure.assertion("semantically invalid replacement was accepted")
        } catch let FrescoStateStoreError.invalidState(_, errors) {
            try expect(
                errors.contains(where: { $0.contains("unknown playlist ID 'missing'") }),
                "invalid replacement did not report dangling playlist")
        }
        let postInvalidStateData = try Data(contentsOf: stateFile)
        let postInvalidGoodData = try Data(contentsOf: goodFile)
        try expect(postInvalidStateData == stateData, "invalid replacement changed state")
        try expect(postInvalidGoodData == goodData, "invalid replacement changed last-known-good")
    }
}

private func testLegacyProjection() throws {
    try withTemporaryDirectory("projection") { directory in
        let store = FrescoStateStore(directory: directory)
        try store.writeLegacyProjection(.wallpaper(target: "/tmp/live"))
        let current = directory.appendingPathComponent("current")
        let projected = try String(contentsOf: current, encoding: .utf8)
        try expect(
            projected == "/tmp/live\n",
            "wallpaper projection was wrong")
        try store.writeLegacyProjection(nil)
        let clearedProjection = try Data(contentsOf: current)
        try expect(clearedProjection.isEmpty, "absent clone projection stayed stale")
        let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        try expect(temporaryFiles.isEmpty, "atomic projection left temporary files")
    }
}

private func testWriteFailureOrdering() throws {
    try withTemporaryDirectory("write-order") { directory in
        let store = FrescoStateStore(directory: directory)
        let initial = try store.load().state
        let stateFile = directory.appendingPathComponent("state.json")
        let goodFile = directory.appendingPathComponent("state.last-known-good.json")
        let initialGoodData = try Data(contentsOf: goodFile)

        try FileManager.default.removeItem(at: stateFile)
        try FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)
        do {
            _ = try store.replace(
                directState(target: "not-accepted"), expectedRevision: initial.revision)
            throw TestFailure.assertion("authoritative rename failure was reported accepted")
        } catch let FrescoStateStoreError.writeFailed(path, _) {
            try expect(path == stateFile.path, "write failure named the wrong destination")
        }
        let postFailureGoodData = try Data(contentsOf: goodFile)
        try expect(
            postFailureGoodData == initialGoodData,
            "failed authoritative write advanced last-known-good")

        try FileManager.default.removeItem(at: stateFile)
        try initialGoodData.write(to: stateFile)
        try FileManager.default.removeItem(at: goodFile)
        try FileManager.default.createDirectory(at: goodFile, withIntermediateDirectories: false)
        let accepted = try store.replace(
            directState(target: "accepted-with-stale-backup"),
            expectedRevision: initial.revision)
        try expect(
            cloneBinding(accepted) == .wallpaper(target: "accepted-with-stale-backup"),
            "backup failure rejected authoritative state")
        let reloaded = try store.load().state
        try expect(reloaded == accepted, "accepted state was not authoritative")
    }
}

private func testMuteControlPersistence() throws {
    try withTemporaryDirectory("mute") { directory in
        let store = FrescoStateStore(directory: directory)
        let initial = try store.load().state
        let selected = try store.selectClone(
            .wallpaper(target: "fixture"), expectedRevision: initial.revision)

        let muted = try store.setMuted(true, expectedRevision: selected.revision)
        try expect(muted.desired.controls?.muted == true, "explicit mute was not accepted")
        try expect(
            cloneBinding(muted) == .wallpaper(target: "fixture"),
            "mute changed the selected wallpaper")

        let toggled = try store.setMuted(nil, expectedRevision: muted.revision)
        try expect(toggled.desired.controls?.muted == false, "mute toggle did not invert state")
        let reloaded = try store.load().state
        try expect(
            reloaded == toggled,
            "mute toggle was not durable")
    }
}

@main
private enum FrescoStateStoreTestRunner {
    static func main() {
        do {
            try testLegacyMigrationAndIdempotence()
            try testEmptyLegacyMigration()
            try testStrictAndSemanticValidation()
            try testLastKnownGoodRecoveryPreservesInvalidState()
            try testRevisionedReplacementAndConflict()
            try testInvalidReplacementPreservesAcceptedFiles()
            try testLegacyProjection()
            try testWriteFailureOrdering()
            try testMuteControlPersistence()
            print("Fresco state store tests passed: 9")
        } catch {
            fputs("Fresco state store test failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
