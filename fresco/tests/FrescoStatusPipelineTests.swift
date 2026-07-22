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

private func display(_ id: String, x: Double, occluded: Bool = false) -> FrescoObservedDisplay {
    FrescoObservedDisplay(
        id: id,
        connected: true,
        frame: FrescoRect(x: x, y: 0, width: 100, height: 80),
        scale: 2,
        occluded: occluded)
}

private func state() -> FrescoState {
    FrescoState(
        schemaVersion: 1,
        revision: 42,
        updatedAt: "2026-07-20T18:00:00Z",
        displays: [],
        playlists: [],
        profiles: [],
        applicationRules: [],
        desired: FrescoDesiredState(
            profileId: nil,
            layout: .clone(binding: .wallpaper(target: "fixture")),
            controls: FrescoControls(paused: false, muted: false),
            fpsCeiling: 60))
}

private func testHardwareIdentity() throws {
    let serial = FrescoDisplayHardwareIdentity(
        vendor: 0x0610, model: 0x1234, serial: 0x9988, unit: 1)
    let reordered = FrescoDisplayHardwareIdentity(
        vendor: 0x0610, model: 0x1234, serial: 0x9988, unit: 9)
    let localA = FrescoDisplayHardwareIdentity(
        vendor: 0x0610, model: 0x1234, serial: 0, unit: 1)
    let localB = FrescoDisplayHardwareIdentity(
        vendor: 0x0610, model: 0x1234, serial: 0, unit: 2)
    try expect(serial.stableID == reordered.stableID, "serial identity depended on display order")
    try expect(localA.stableID != localB.stableID, "serial-less displays collided")
    try expect(!serial.stableID.contains(" "), "display identity contained whitespace")
}

private func testStatusAssemblyAndPublication(outputDirectory: URL) throws {
    let durable = state()
    let observed = FrescoObservedContext(
        generation: "generation:test",
        locked: true,
        sleeping: false,
        onBattery: false,
        pauseWhenOccluded: true,
        displays: [display("left", x: 0), display("right", x: 100, occluded: true)],
        applications: [],
        reasons: [])
    let plan = FrescoStatePlanner.plan(state: durable, observed: observed)
    let evidence = [
        RuntimeAssignmentEvidence(
            displayID: "left", status: .running, target: "runtime-left",
            firstFrameAt: "2026-07-20T18:00:01Z", error: nil),
        RuntimeAssignmentEvidence(
            displayID: "right", status: .degraded, target: "runtime-right",
            firstFrameAt: nil, error: "fixture failure"),
        RuntimeAssignmentEvidence(
            displayID: "disconnected", status: .running, target: "ignored",
            firstFrameAt: nil, error: nil),
    ]
    let snapshot = FrescoStatusAssembler.snapshot(
        plan: plan,
        observed: observed,
        assignmentEvidence: evidence,
        updatedAt: "2026-07-20T18:00:02Z")
    try expect(snapshot.desiredRevision == 42, "status lost desired revision")
    try expect(snapshot.runtime.generation == "generation:test", "status lost generation")
    try expect(snapshot.runtime.status == .degraded, "runtime aggregate lost degraded evidence")
    try expect(snapshot.runtime.displays.count == 2, "disconnected evidence entered runtime status")
    try expect(snapshot.effective.displays.allSatisfy(\.paused), "locked status was not paused")
    try expect(snapshot.effective.displays.allSatisfy(\.hidden), "locked status was not hidden")
    try expect(snapshot.observed.applications.isEmpty, "application observation was not empty")

    try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)
    let statusFile = outputDirectory.appendingPathComponent("status.json")
    let publisher = FrescoStatusPublisher(file: statusFile)
    try publisher.publish(snapshot)
    let firstData = try Data(contentsOf: statusFile)
    try publisher.publish(snapshot)
    let repeatedData = try Data(contentsOf: statusFile)
    try expect(repeatedData == firstData, "repeat publish changed snapshot bytes")
    let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
        .filter { $0.hasSuffix(".tmp") }
    try expect(temporaryFiles.isEmpty, "status publish left a temporary file")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try (try encoder.encode(durable) + Data("\n".utf8)).write(
        to: outputDirectory.appendingPathComponent("state.json"))

    let removalFile = outputDirectory.appendingPathComponent("removed-status.json")
    let removalPublisher = FrescoStatusPublisher(file: removalFile)
    try removalPublisher.publish(snapshot)
    removalPublisher.remove()
    try expect(
        !FileManager.default.fileExists(atPath: removalFile.path),
        "status removal left stale evidence")
}

@main
private enum FrescoStatusPipelineTestRunner {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw TestFailure.assertion("missing output directory")
            }
            try testHardwareIdentity()
            try testStatusAssemblyAndPublication(
                outputDirectory: URL(fileURLWithPath: CommandLine.arguments[1]))
            print("Fresco observation and status tests passed: 2")
        } catch {
            fputs("Fresco observation/status test failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
