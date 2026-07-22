import Darwin
import Foundation

struct FrescoStatusSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let desiredRevision: Int
    let updatedAt: String
    let observed: FrescoStatusObserved
    let effective: FrescoStatusEffective
    let runtime: FrescoStatusRuntime
}

struct FrescoStatusObserved: Codable, Equatable {
    let locked: Bool
    let sleeping: Bool
    let onBattery: Bool
    let displays: [FrescoObservedDisplay]
    let applications: [FrescoObservedApplication]
}

struct FrescoStatusEffective: Codable, Equatable {
    let activeProfile: FrescoStatusActiveProfile?
    let layoutMode: FrescoLayout.Mode
    let displays: [FrescoStatusEffectiveDisplay]
}

struct FrescoStatusActiveProfile: Codable, Equatable {
    let profileId: String
    let reasons: [String]
}

struct FrescoStatusEffectiveDisplay: Codable, Equatable {
    let displayId: String
    let binding: FrescoBinding
    let paused: Bool
    let muted: Bool
    let hidden: Bool
    let fpsCeiling: Int?
    let reasons: FrescoEffectiveReasons
}

struct FrescoStatusRuntime: Codable, Equatable {
    let generation: String
    let status: RuntimeAssignmentStatus
    let playlistCheckpoints: [FrescoStatusPlaylistCheckpoint]
    let displays: [FrescoStatusRuntimeDisplay]
}

struct FrescoStatusPlaylistCheckpoint: Codable, Equatable {
    let playlistId: String
    let entryId: String
    let elapsedSeconds: Double
}

struct FrescoStatusRuntimeDisplay: Codable, Equatable {
    let displayId: String
    let status: RuntimeAssignmentStatus
    let target: String?
    let firstFrameAt: String?
    let error: String?
}

enum FrescoStatusAssembler {
    static func snapshot(
        plan: FrescoEffectivePlan,
        observed: FrescoObservedContext,
        assignmentEvidence: [RuntimeAssignmentEvidence],
        updatedAt: String = ISO8601DateFormatter().string(from: Date())
    ) -> FrescoStatusSnapshot {
        let evidence = Dictionary(
            assignmentEvidence.map { ($0.displayID, $0) },
            uniquingKeysWith: { _, latest in latest })
        let effectiveDisplays = plan.displays.map { display in
            FrescoStatusEffectiveDisplay(
                displayId: display.displayId,
                binding: display.binding,
                paused: display.reasons.isPaused,
                muted: display.reasons.isMuted,
                hidden: display.reasons.isHidden,
                fpsCeiling: display.fpsCeiling,
                reasons: display.reasons)
        }
        let runtimeDisplays = plan.displays.map { display -> FrescoStatusRuntimeDisplay in
            guard let assignment = evidence[display.displayId] else {
                return FrescoStatusRuntimeDisplay(
                    displayId: display.displayId,
                    status: .idle,
                    target: nil,
                    firstFrameAt: nil,
                    error: nil)
            }
            return FrescoStatusRuntimeDisplay(
                displayId: display.displayId,
                status: assignment.status,
                target: assignment.target,
                firstFrameAt: assignment.firstFrameAt,
                error: assignment.error)
        }
        let activeProfile = plan.profileId.map {
            FrescoStatusActiveProfile(profileId: $0, reasons: plan.profileReasons)
        }
        return FrescoStatusSnapshot(
            schemaVersion: 1,
            desiredRevision: plan.desiredRevision,
            updatedAt: updatedAt,
            observed: FrescoStatusObserved(
                locked: observed.locked,
                sleeping: observed.sleeping,
                onBattery: observed.onBattery,
                displays: observed.displays,
                applications: observed.applications),
            effective: FrescoStatusEffective(
                activeProfile: activeProfile,
                layoutMode: plan.layoutMode,
                displays: effectiveDisplays),
            runtime: FrescoStatusRuntime(
                generation: plan.generation,
                status: aggregateStatus(runtimeDisplays.map(\.status)),
                playlistCheckpoints: [],
                displays: runtimeDisplays))
    }

    private static func aggregateStatus(
        _ statuses: [RuntimeAssignmentStatus]
    ) -> RuntimeAssignmentStatus {
        if statuses.contains(.degraded) { return .degraded }
        if statuses.contains(.stopping) { return .stopping }
        if statuses.contains(.starting) { return .starting }
        if statuses.contains(.running) { return .running }
        return .idle
    }
}

struct FrescoStatusPublisher {
    let file: URL

    func publish(_ snapshot: FrescoStatusSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot) + Data("\n".utf8)
        try atomicWrite(data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: file)
    }

    private func atomicWrite(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(
            ".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)

        let descriptor = Darwin.open(temporary.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXStatusFailure(operation: "open") }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXStatusFailure(operation: "fsync")
        }
        guard Darwin.rename(temporary.path, file.path) == 0 else {
            throw POSIXStatusFailure(operation: "rename")
        }

        let directoryDescriptor = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY)
        guard directoryDescriptor >= 0 else {
            throw POSIXStatusFailure(operation: "open directory")
        }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw POSIXStatusFailure(operation: "fsync directory")
        }
    }
}

private struct POSIXStatusFailure: Error, CustomStringConvertible {
    let operation: String
    let code = errno

    var description: String {
        "\(operation): \(String(cString: strerror(code)))"
    }
}
