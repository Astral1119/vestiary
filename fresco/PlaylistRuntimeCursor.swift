import Foundation

enum PlaylistRuntimeCursorError: Error, Equatable {
    case emptyPlaylist
    case invalidEntryID
    case duplicateEntryID(String)
    case invalidDuration(entryID: String)
    case invalidClock
}

struct PlaylistCursorCheckpoint: Codable, Equatable, Sendable {
    let playlistId: String
    let entryId: String
    let elapsedSeconds: TimeInterval
    let shuffleSeed: UInt64
    let finished: Bool
}

struct PlaylistCursorSnapshot: Equatable, Sendable {
    let playlistId: String
    let entry: FrescoPlaylistEntry
    let elapsedSeconds: TimeInterval
    let finished: Bool
}

struct PlaylistCursorConsumerState: Equatable, Sendable {
    let displayId: String
    let active: Bool
    let connected: Bool
}

/// One cursor is shared by every display consuming the same playlist ID.
/// Shuffle builds one fixed permutation from its checkpointed seed and reuses
/// that permutation on every repeating cycle.
final class PlaylistRuntimeCursor {
    typealias Clock = () -> TimeInterval

    private var playlist: FrescoPlaylist
    private var traversal: [String]
    private var currentIndex: Int
    private var elapsedSeconds: TimeInterval
    private var lastClockSeconds: TimeInterval
    private var consumers: [String: PlaylistCursorConsumerState]
    private var finished: Bool
    private let seed: UInt64
    private let clock: Clock

    init(
        playlist: FrescoPlaylist,
        checkpoint: PlaylistCursorCheckpoint? = nil,
        seed: UInt64,
        clock: @escaping Clock,
        consumers: [PlaylistCursorConsumerState] = [
            PlaylistCursorConsumerState(
                displayId: "default", active: true, connected: true)
        ]
    ) throws {
        try Self.validate(playlist)
        let initialClock = clock()
        guard initialClock.isFinite else { throw PlaylistRuntimeCursorError.invalidClock }
        self.playlist = playlist
        let acceptedCheckpoint = checkpoint.flatMap {
            Self.compatibleCheckpoint($0, for: playlist) ? $0 : nil
        }
        self.seed = acceptedCheckpoint?.shuffleSeed ?? seed
        self.clock = clock
        self.consumers = Dictionary(
            consumers.map { ($0.displayId, $0) }, uniquingKeysWith: { _, last in last })
        traversal = Self.traversal(for: playlist, seed: self.seed)
        currentIndex = 0
        elapsedSeconds = 0
        finished = false
        lastClockSeconds = initialClock

        if let checkpoint = acceptedCheckpoint {
            if checkpoint.finished {
                if !playlist.repeat, checkpoint.entryId == traversal.last,
                   let index = traversal.firstIndex(of: checkpoint.entryId) {
                    currentIndex = index
                    elapsedSeconds = duration(for: checkpoint.entryId)
                    finished = true
                }
            } else if let index = traversal.firstIndex(of: checkpoint.entryId) {
                currentIndex = index
                elapsedSeconds = checkpoint.elapsedSeconds
                normalizeElapsed()
            }
        }
    }

    var traversalEntryIDs: [String] { traversal }

    func snapshot() -> PlaylistCursorSnapshot {
        settle()
        return PlaylistCursorSnapshot(
            playlistId: playlist.id,
            entry: currentEntry,
            elapsedSeconds: elapsedSeconds,
            finished: finished)
    }

    func checkpoint() -> PlaylistCursorCheckpoint {
        let state = snapshot()
        return PlaylistCursorCheckpoint(
            playlistId: state.playlistId,
            entryId: state.entry.id,
            elapsedSeconds: state.elapsedSeconds,
            shuffleSeed: seed,
            finished: state.finished)
    }

    func setConsumers(_ consumers: [PlaylistCursorConsumerState]) {
        settle()
        self.consumers = Dictionary(
            consumers.map { ($0.displayId, $0) }, uniquingKeysWith: { _, last in last })
    }

    func reconcile(with replacement: FrescoPlaylist) throws {
        settle()
        try Self.validate(replacement)
        let oldTraversal = traversal
        let oldIndex = currentIndex
        let currentID = currentEntry.id
        let oldPlaylistID = playlist.id
        let wasFinished = finished
        let replacementIDs = Set(replacement.entries.map(\.id))

        playlist = replacement
        traversal = Self.traversal(for: replacement, seed: seed)
        finished = false
        if wasFinished {
            guard replacement.id == oldPlaylistID, !replacement.repeat,
                  currentID == traversal.last,
                  let index = traversal.firstIndex(of: currentID) else {
                currentIndex = 0
                elapsedSeconds = 0
                return
            }
            currentIndex = index
            elapsedSeconds = duration(for: traversal[currentIndex])
            finished = true
            return
        }
        if replacement.id == oldPlaylistID,
           let index = traversal.firstIndex(of: currentID) {
            currentIndex = index
        } else if replacement.id == oldPlaylistID,
                  let successor = Self.successor(
                    after: oldIndex, in: oldTraversal, retainedBy: replacementIDs),
                  let index = traversal.firstIndex(of: successor) {
            currentIndex = index
            elapsedSeconds = 0
        } else {
            currentIndex = 0
            elapsedSeconds = 0
        }
        normalizeElapsed()
    }

    private var currentEntry: FrescoPlaylistEntry {
        let id = traversal[currentIndex]
        return playlist.entries.first { $0.id == id }!
    }

    private var isAdvancing: Bool {
        !finished && consumers.values.contains { $0.connected && $0.active }
    }

    private func settle() {
        let now = clock()
        guard now.isFinite, now > lastClockSeconds else { return }
        let delta = now - lastClockSeconds
        lastClockSeconds = now
        guard isAdvancing else { return }
        elapsedSeconds += delta
        normalizeElapsed()
    }

    private func normalizeElapsed() {
        if playlist.repeat {
            let cycleDuration = traversal.reduce(0.0) { partial, id in
                partial + duration(for: id)
            }
            if elapsedSeconds >= cycleDuration {
                elapsedSeconds.formTruncatingRemainder(dividingBy: cycleDuration)
            }
        }

        while elapsedSeconds >= duration(for: traversal[currentIndex]) {
            let duration = duration(for: traversal[currentIndex])
            if currentIndex + 1 < traversal.count {
                elapsedSeconds -= duration
                currentIndex += 1
            } else if playlist.repeat {
                elapsedSeconds -= duration
                currentIndex = 0
            } else {
                elapsedSeconds = duration
                finished = true
                return
            }
        }
    }

    private func duration(for entryID: String) -> TimeInterval {
        let entry = playlist.entries.first { $0.id == entryID }!
        return TimeInterval(entry.durationSeconds)
    }

    private static func validate(_ playlist: FrescoPlaylist) throws {
        guard !playlist.entries.isEmpty else { throw PlaylistRuntimeCursorError.emptyPlaylist }
        var ids = Set<String>()
        for entry in playlist.entries {
            guard !entry.id.isEmpty else { throw PlaylistRuntimeCursorError.invalidEntryID }
            guard ids.insert(entry.id).inserted else {
                throw PlaylistRuntimeCursorError.duplicateEntryID(entry.id)
            }
            guard entry.durationSeconds > 0 else {
                throw PlaylistRuntimeCursorError.invalidDuration(entryID: entry.id)
            }
        }
    }

    private static func traversal(for playlist: FrescoPlaylist, seed: UInt64) -> [String] {
        var ids = playlist.entries.map(\.id)
        guard playlist.order == .shuffle, ids.count > 1 else { return ids }
        var generator = SplitMix64(state: seed)
        for index in stride(from: ids.count - 1, through: 1, by: -1) {
            let other = Int(generator.next() % UInt64(index + 1))
            ids.swapAt(index, other)
        }
        return ids
    }

    private static func compatibleCheckpoint(
        _ checkpoint: PlaylistCursorCheckpoint, for playlist: FrescoPlaylist
    ) -> Bool {
        guard checkpoint.playlistId == playlist.id,
              checkpoint.elapsedSeconds.isFinite,
              checkpoint.elapsedSeconds >= 0 else { return false }
        let checkpointTraversal = traversal(for: playlist, seed: checkpoint.shuffleSeed)
        if checkpoint.finished {
            return !playlist.repeat && checkpoint.entryId == checkpointTraversal.last
        }
        return checkpointTraversal.contains(checkpoint.entryId)
    }

    private static func successor(
        after index: Int, in traversal: [String], retainedBy retained: Set<String>
    ) -> String? {
        guard !traversal.isEmpty else { return nil }
        for offset in 1...traversal.count {
            let candidate = traversal[(index + offset) % traversal.count]
            if retained.contains(candidate) { return candidate }
        }
        return nil
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
