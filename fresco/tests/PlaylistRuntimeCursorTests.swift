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

private final class TestClock {
    var now: TimeInterval
    init(_ now: TimeInterval = 0) { self.now = now }
}

private func entry(_ id: String, _ duration: Int) -> FrescoPlaylistEntry {
    FrescoPlaylistEntry(
        id: id, wallpaper: .wallpaper(target: "/wallpapers/\(id)"),
        durationSeconds: duration)
}

private func playlist(
    id: String = "playlist", entries: [FrescoPlaylistEntry],
    order: FrescoPlaylist.Order = .sequential, repeat repeats: Bool = true
) -> FrescoPlaylist {
    FrescoPlaylist(id: id, name: id, entries: entries, order: order, repeat: repeats)
}

private func testSequentialCatchUpAndRepeat() throws {
    let clock = TestClock()
    let cursor = try PlaylistRuntimeCursor(
        playlist: playlist(entries: [entry("a", 2), entry("b", 3), entry("c", 5)]),
        seed: 1, clock: { clock.now })
    clock.now = 2.5
    var state = cursor.snapshot()
    try expect(state.entry.id == "b", "sequential catch-up did not enter b")
    try expect(state.elapsedSeconds == 0.5, "sequential catch-up elapsed time changed")
    clock.now = 1_000_000_002.5
    state = cursor.snapshot()
    try expect(state.entry.id == "b", "large repeat catch-up changed phase")
    try expect(state.elapsedSeconds == 0.5, "large repeat catch-up lost phase")
}

private func testNonRepeatingCompletion() throws {
    let clock = TestClock()
    let cursor = try PlaylistRuntimeCursor(
        playlist: playlist(
            entries: [entry("a", 2), entry("b", 3)], repeat: false),
        seed: 1, clock: { clock.now })
    clock.now = 20
    let state = cursor.snapshot()
    try expect(state.entry.id == "b", "non-repeat did not remain on final entry")
    try expect(state.elapsedSeconds == 3, "non-repeat final elapsed time was not clamped")
    try expect(state.finished, "non-repeat did not report completion")
    try cursor.reconcile(with: playlist(
        entries: [entry("a", 2), entry("c", 4)], repeat: false))
    let reconciled = cursor.snapshot()
    try expect(reconciled.entry.id == "a" && reconciled.elapsedSeconds == 0,
               "terminal deletion did not reset to the replacement start")
    try expect(!reconciled.finished, "terminal deletion preserved incompatible completion")
    try cursor.reconcile(with: playlist(
        id: "replacement", entries: [entry("x", 2), entry("y", 2)],
        repeat: false))
    let replaced = cursor.snapshot()
    try expect(replaced.entry.id == "x" && replaced.elapsedSeconds == 0,
               "different playlist ID inherited terminal position")
    try expect(!replaced.finished, "different playlist ID inherited finished state")
}

private func testRestartCheckpoint() throws {
    let firstClock = TestClock()
    let source = playlist(entries: [entry("a", 2), entry("b", 4)])
    let first = try PlaylistRuntimeCursor(
        playlist: source, seed: 9, clock: { firstClock.now })
    firstClock.now = 3.25
    let checkpoint = first.checkpoint()
    try expect(checkpoint.entryId == "b", "checkpoint did not use stable entry ID")
    try expect(checkpoint.elapsedSeconds == 1.25, "checkpoint elapsed time changed")
    let encoded = try JSONEncoder().encode(checkpoint)
    let decoded = try JSONDecoder().decode(PlaylistCursorCheckpoint.self, from: encoded)
    try expect(decoded == checkpoint, "checkpoint did not survive JSON round trip")

    let restartClock = TestClock(500)
    let restarted = try PlaylistRuntimeCursor(
        playlist: source, checkpoint: decoded, seed: 999,
        clock: { restartClock.now })
    var state = restarted.snapshot()
    try expect(state.entry.id == "b", "restart did not restore stable entry ID")
    try expect(state.elapsedSeconds == 1.25, "restart counted inactive process downtime")
    restartClock.now = 501
    state = restarted.snapshot()
    try expect(state.elapsedSeconds == 2.25, "restarted cursor did not resume its clock")
}

private func testDeterministicShuffle() throws {
    let entries = ["a", "b", "c", "d", "e"].map { entry($0, 1) }
    let source = playlist(entries: entries, order: .shuffle)
    let clock = TestClock()
    let first = try PlaylistRuntimeCursor(
        playlist: source, seed: 42, clock: { clock.now })
    let second = try PlaylistRuntimeCursor(playlist: source, seed: 42, clock: { 0 })
    let other = try PlaylistRuntimeCursor(playlist: source, seed: 43, clock: { 0 })
    try expect(first.traversalEntryIDs == second.traversalEntryIDs,
               "same shuffle seed produced different traversal")
    try expect(first.traversalEntryIDs != other.traversalEntryIDs,
               "different shuffle seeds produced the same traversal")
    try expect(Set(first.traversalEntryIDs) == Set(entries.map(\.id)),
               "shuffle traversal lost stable entry IDs")
    let order = first.traversalEntryIDs
    clock.now = 2.5
    var state = first.snapshot()
    try expect(state.entry.id == order[2] && state.elapsedSeconds == 0.5,
               "shuffle cursor did not follow its deterministic traversal")
    let checkpoint = first.checkpoint()
    let restartClock = TestClock(100)
    let restarted = try PlaylistRuntimeCursor(
        playlist: source, checkpoint: checkpoint, seed: 999,
        clock: { restartClock.now })
    state = restarted.snapshot()
    try expect(state.entry.id == order[2] && state.elapsedSeconds == 0.5,
               "shuffle checkpoint did not restore traversal position")
    try expect(restarted.traversalEntryIDs == order,
               "restart did not prefer the checkpoint shuffle seed")
    clock.now = 5
    try expect(first.snapshot().entry.id == order[0],
               "repeating shuffle did not wrap to its deterministic start")
}

private func testStableIDReconciliation() throws {
    let clock = TestClock()
    let initial = playlist(entries: [entry("a", 2), entry("b", 4), entry("c", 3)])
    let cursor = try PlaylistRuntimeCursor(
        playlist: initial, seed: 1, clock: { clock.now })
    clock.now = 3
    try expect(cursor.snapshot().entry.id == "b", "setup did not enter b")
    try cursor.reconcile(with: playlist(
        entries: [entry("c", 3), entry("b", 4), entry("a", 2)]))
    var state = cursor.snapshot()
    try expect(state.entry.id == "b", "reorder replaced the stable current entry")
    try expect(state.elapsedSeconds == 1, "reorder reset current-entry elapsed time")
    clock.now = 6
    state = cursor.snapshot()
    try expect(state.entry.id == "a", "reordered sequential successor was not used")

    try cursor.reconcile(with: playlist(entries: [entry("c", 3), entry("b", 4)]))
    state = cursor.snapshot()
    try expect(state.entry.id == "c", "removing current entry did not retain its successor")

    let durationClock = TestClock()
    let durationCursor = try PlaylistRuntimeCursor(
        playlist: playlist(entries: [entry("a", 2), entry("b", 5), entry("c", 3)]),
        seed: 1, clock: { durationClock.now })
    durationClock.now = 4.5
    try expect(durationCursor.snapshot().entry.id == "b", "duration setup did not enter b")
    try durationCursor.reconcile(with: playlist(
        entries: [entry("a", 2), entry("b", 2), entry("c", 3)]))
    state = durationCursor.snapshot()
    try expect(state.entry.id == "c" && state.elapsedSeconds == 0.5,
               "duration edit did not preserve and normalize elapsed time")
}

private func testSharedConsumerActivityAndDisconnect() throws {
    let clock = TestClock()
    let cursor = try PlaylistRuntimeCursor(
        playlist: playlist(entries: [entry("a", 2), entry("b", 3)]),
        seed: 1, clock: { clock.now },
        consumers: [
            PlaylistCursorConsumerState(displayId: "left", active: true, connected: true),
            PlaylistCursorConsumerState(displayId: "right", active: false, connected: true),
        ])
    clock.now = 1
    cursor.setConsumers([
        PlaylistCursorConsumerState(displayId: "left", active: false, connected: false),
        PlaylistCursorConsumerState(displayId: "right", active: false, connected: true),
    ])
    clock.now = 20
    try expect(cursor.snapshot().elapsedSeconds == 1,
               "no-active-consumer wall-clock time advanced the shared cursor")
    cursor.setConsumers([
        PlaylistCursorConsumerState(displayId: "left", active: false, connected: false),
        PlaylistCursorConsumerState(displayId: "right", active: true, connected: true),
    ])
    clock.now = 21
    try expect(cursor.snapshot().entry.id == "b",
               "active sibling did not advance the shared cursor")

    cursor.setConsumers([
        PlaylistCursorConsumerState(displayId: "left", active: true, connected: false),
        PlaylistCursorConsumerState(displayId: "right", active: false, connected: true),
    ])
    clock.now = 40
    let disconnected = cursor.snapshot()
    try expect(disconnected.entry.id == "b" && disconnected.elapsedSeconds == 0,
               "disconnected and paused consumers advanced the shared cursor")
    cursor.setConsumers([
        PlaylistCursorConsumerState(displayId: "left", active: true, connected: true),
        PlaylistCursorConsumerState(displayId: "right", active: false, connected: true),
    ])
    clock.now = 41
    try expect(cursor.snapshot().elapsedSeconds == 1,
               "reconnected consumer did not resume the shared cursor")
}

private func testCompletionCompatibilityEquivalence() throws {
    let source = playlist(
        entries: [entry("a", 2), entry("b", 3)], repeat: false)
    let sourceClock = TestClock()
    let sourceCursor = try PlaylistRuntimeCursor(
        playlist: source, seed: 41, clock: { sourceClock.now })
    sourceClock.now = 20
    try expect(sourceCursor.snapshot().finished, "completion setup did not finish")
    let checkpoint = sourceCursor.checkpoint()
    try expect(checkpoint.finished, "finished state was absent from checkpoint")

    let replacements = [
        playlist(entries: [entry("a", 2), entry("b", 7)], repeat: false),
        playlist(entries: [entry("c", 1), entry("a", 2), entry("b", 4)], repeat: false),
        playlist(entries: [entry("a", 2), entry("c", 4)], repeat: false),
        playlist(entries: [entry("b", 3), entry("a", 2)], repeat: false),
        playlist(entries: [entry("a", 2), entry("b", 3)], repeat: true),
        playlist(
            id: "replacement", entries: [entry("x", 2), entry("y", 2)],
            repeat: false),
    ]

    for replacement in replacements {
        let liveClock = TestClock()
        let live = try PlaylistRuntimeCursor(
            playlist: source, checkpoint: checkpoint, seed: 999,
            clock: { liveClock.now })
        try live.reconcile(with: replacement)
        let liveState = live.snapshot()
        let restarted = try PlaylistRuntimeCursor(
            playlist: replacement, checkpoint: checkpoint, seed: 999,
            clock: { 0 })
        let restartedState = restarted.snapshot()
        try expect(liveState == restartedState,
                   "restart and in-process completion compatibility diverged")
    }

    let retained = replacements[0]
    let retainedRestart = try PlaylistRuntimeCursor(
        playlist: retained, checkpoint: checkpoint, seed: 999, clock: { 0 })
    let retainedState = retainedRestart.snapshot()
    try expect(retainedState.entry.id == "b" && retainedState.elapsedSeconds == 7,
               "compatible completion did not clamp to replacement duration")
    try expect(retainedState.finished, "compatible completion was not preserved")

    for incompatible in replacements[2...] {
        let restarted = try PlaylistRuntimeCursor(
            playlist: incompatible, checkpoint: checkpoint, seed: 999,
            clock: { 0 })
        let state = restarted.snapshot()
        try expect(state.entry.id == restarted.traversalEntryIDs[0],
                   "incompatible completion did not reset to traversal start")
        try expect(state.elapsedSeconds == 0 && !state.finished,
                   "incompatible completion retained terminal state")
    }
}

private func testValidationAndIncompatibleCheckpoint() throws {
    do {
        _ = try PlaylistRuntimeCursor(
            playlist: playlist(entries: []), seed: 1, clock: { 0 })
        throw TestFailure.assertion("empty playlist was accepted")
    } catch PlaylistRuntimeCursorError.emptyPlaylist {}
    do {
        _ = try PlaylistRuntimeCursor(
            playlist: playlist(entries: [entry("", 1)]), seed: 1, clock: { 0 })
        throw TestFailure.assertion("empty entry ID was accepted")
    } catch PlaylistRuntimeCursorError.invalidEntryID {}
    do {
        _ = try PlaylistRuntimeCursor(
            playlist: playlist(entries: [entry("a", 1), entry("a", 2)]),
            seed: 1, clock: { 0 })
        throw TestFailure.assertion("duplicate entry ID was accepted")
    } catch PlaylistRuntimeCursorError.duplicateEntryID("a") {}
    do {
        _ = try PlaylistRuntimeCursor(
            playlist: playlist(entries: [entry("a", 0)]), seed: 1, clock: { 0 })
        throw TestFailure.assertion("nonpositive duration was accepted")
    } catch PlaylistRuntimeCursorError.invalidDuration(entryID: "a") {}

    let cursor = try PlaylistRuntimeCursor(
        playlist: playlist(entries: [entry("a", 2)]),
        checkpoint: PlaylistCursorCheckpoint(
            playlistId: "other", entryId: "missing", elapsedSeconds: 8,
            shuffleSeed: 99, finished: false),
        seed: 1, clock: { 0 })
    let state = cursor.snapshot()
    try expect(state.entry.id == "a" && state.elapsedSeconds == 0,
               "incompatible checkpoint was not discarded")

    let shuffled = playlist(
        entries: ["a", "b", "c", "d", "e"].map { entry($0, 1) },
        order: .shuffle)
    let expectedTraversal = try PlaylistRuntimeCursor(
        playlist: shuffled, seed: 43, clock: { 0 }).traversalEntryIDs
    let rejectedSeedTraversal = try PlaylistRuntimeCursor(
        playlist: shuffled,
        checkpoint: PlaylistCursorCheckpoint(
            playlistId: shuffled.id, entryId: "missing", elapsedSeconds: 0,
            shuffleSeed: 42, finished: false),
        seed: 43, clock: { 0 }).traversalEntryIDs
    try expect(rejectedSeedTraversal == expectedTraversal,
               "rejected same-ID checkpoint changed shuffle traversal")

    let clock = TestClock()
    let nonfinite = try PlaylistRuntimeCursor(
        playlist: playlist(entries: [entry("a", 2), entry("b", 2)]),
        seed: 1, clock: { clock.now })
    clock.now = .infinity
    try expect(nonfinite.snapshot().elapsedSeconds == 0,
               "infinite clock advanced the cursor")
    clock.now = .nan
    try expect(nonfinite.snapshot().elapsedSeconds == 0,
               "NaN clock advanced the cursor")
    clock.now = 1
    try expect(nonfinite.snapshot().elapsedSeconds == 1,
               "cursor did not recover after a non-finite clock sample")
    do {
        _ = try PlaylistRuntimeCursor(
            playlist: playlist(entries: [entry("a", 1)]),
            seed: 1, clock: { .infinity })
        throw TestFailure.assertion("non-finite initial clock was accepted")
    } catch PlaylistRuntimeCursorError.invalidClock {}
}

@main
private enum PlaylistRuntimeCursorTestRunner {
    static func main() {
        do {
            try testSequentialCatchUpAndRepeat()
            try testNonRepeatingCompletion()
            try testRestartCheckpoint()
            try testDeterministicShuffle()
            try testStableIDReconciliation()
            try testSharedConsumerActivityAndDisconnect()
            try testCompletionCompatibilityEquivalence()
            try testValidationAndIncompatibleCheckpoint()
            print("Fresco playlist runtime cursor tests passed: 8")
        } catch {
            fputs("Fresco playlist runtime cursor tests failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
