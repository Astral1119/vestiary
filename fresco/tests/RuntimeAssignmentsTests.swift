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

private struct Display {
    let id: String
}

private final class MockAssignment: RuntimeDisplayAssignment {
    let displayID: String
    let binding: FrescoBinding
    let fallbackID: String
    let supervisorID: String
    private(set) var stopped = false
    private(set) var ready = false
    private(set) var visible = true
    private(set) var muted = true

    init(displayID: String, binding: FrescoBinding? = nil) {
        self.displayID = displayID
        self.binding = binding ?? .wallpaper(target: "mock:" + displayID)
        fallbackID = "fallback:" + displayID
        supervisorID = "supervisor:" + displayID
    }

    var evidence: RuntimeAssignmentEvidence {
        RuntimeAssignmentEvidence(
            displayID: displayID,
            status: ready ? .running : .starting,
            target: bindingTarget,
            firstFrameAt: nil,
            error: nil)
    }

    private var bindingTarget: String? {
        guard case let .wallpaper(target) = binding else { return nil }
        return target
    }

    func setPaused(_ paused: Bool) {}
    func setMuted(_ muted: Bool) { self.muted = muted }
    func setVisible(_ visible: Bool) { self.visible = visible }
    func stop() { stopped = true }
    func markReady() { ready = true }

    var fallbackVisible: Bool { visible && !ready }
}

private final class MockAudioEndpoint: RuntimeSceneAudioEndpoint {
    let displayID: String
    let binding: FrescoBinding
    private(set) var commands: [Bool] = []
    private var completions: [(() -> Void)?] = []

    init(_ displayID: String, _ binding: FrescoBinding) {
        self.displayID = displayID
        self.binding = binding
    }

    func setMuted(_ muted: Bool, completion: (() -> Void)?) {
        commands.append(muted)
        completions.append(completion)
    }

    func acknowledge(_ index: Int) {
        let completion = completions[index]
        completions[index] = nil
        completion?()
    }
}

private final class MockRetiringSceneAssignment:
    RuntimeDisplayAssignment, RuntimeSceneAudioEndpoint {
    let displayID: String
    let binding: FrescoBinding
    private(set) var commands: [Bool] = []
    private(set) var stopped = false
    private var retiring = false
    private var retirementMuted = false
    private var commandCompletions: [(() -> Void)?] = []
    private var retirementCompletions: [() -> Void] = []

    init(displayID: String, binding: FrescoBinding) {
        self.displayID = displayID
        self.binding = binding
    }

    var evidence: RuntimeAssignmentEvidence {
        RuntimeAssignmentEvidence(
            displayID: displayID, status: .running,
            target: binding.wallpaperTargetForTest, firstFrameAt: nil, error: nil)
    }

    func setPaused(_ paused: Bool) {}
    func setMuted(_ muted: Bool) { setMuted(muted, completion: nil) }
    func setVisible(_ visible: Bool) {}
    func setMuted(_ muted: Bool, completion: (() -> Void)?) {
        if retiring {
            guard muted else {
                completion?()
                return
            }
            if retirementMuted {
                completion?()
            } else if let completion {
                retirementCompletions.append(completion)
            }
            return
        }
        commands.append(muted)
        commandCompletions.append(completion)
    }

    func stop() {
        guard !retiring else { return }
        stopped = true
        retiring = true
        commands.append(true)
        commandCompletions.append(nil)
    }

    func acknowledge(_ index: Int) {
        let completion = commandCompletions[index]
        commandCompletions[index] = nil
        completion?()
    }

    func confirmTermination() {
        guard !retirementMuted else { return }
        retirementMuted = true
        let completions = retirementCompletions
        retirementCompletions.removeAll()
        completions.forEach { $0() }
    }
}

private extension FrescoBinding {
    var wallpaperTargetForTest: String? {
        guard case let .wallpaper(target) = self else { return nil }
        return target
    }
}

private func assignment(
    _ registry: RuntimeAssignmentRegistry, _ displayID: String
) throws -> MockAssignment {
    guard let assignment = registry[displayID] as? MockAssignment else {
        throw TestFailure.assertion("missing assignment for \(displayID)")
    }
    return assignment
}

private func testScreenReorderingPreservesIdentity() throws {
    let registry = RuntimeAssignmentRegistry()
    registry.reconcile(
        displays: [Display(id: "left"), Display(id: "right")],
        identify: { $0.id },
        create: { displayID, _ in MockAssignment(displayID: displayID) })
    let left = try assignment(registry, "left")
    let right = try assignment(registry, "right")

    registry.reconcile(
        displays: [Display(id: "right"), Display(id: "left")],
        identify: { $0.id },
        create: { displayID, _ in MockAssignment(displayID: displayID) })
    let reorderedLeft = try assignment(registry, "left")
    let reorderedRight = try assignment(registry, "right")
    try expect(reorderedLeft === left, "left assignment changed after reorder")
    try expect(reorderedRight === right, "right assignment changed after reorder")
    try expect(registry.displayIDs == ["left", "right"], "registry identity order was unstable")
}

private func testSceneFallbackAssociationSurvivesReorder() throws {
    let registry = RuntimeAssignmentRegistry()
    registry.reconcile(
        displays: [Display(id: "left"), Display(id: "right")],
        identify: { $0.id },
        create: { displayID, _ in MockAssignment(displayID: displayID) })
    let right = try assignment(registry, "right")
    right.markReady()

    registry.reconcile(
        displays: [Display(id: "right"), Display(id: "left")],
        identify: { $0.id },
        create: { displayID, _ in MockAssignment(displayID: displayID) })
    let reorderedRight = try assignment(registry, "right")
    let reorderedLeft = try assignment(registry, "left")
    try expect(reorderedRight === right, "ready event detached from its scene assignment")
    try expect(reorderedRight.supervisorID == "supervisor:right", "right supervisor was misassociated")
    try expect(reorderedRight.fallbackID == "fallback:right", "right fallback was misassociated")
    try expect(!reorderedRight.fallbackVisible, "right ready event did not hide right fallback")
    try expect(reorderedLeft.fallbackVisible, "right ready event hid left fallback")
}

private func testRemovalStopsOnlyRemovedDisplay() throws {
    let registry = RuntimeAssignmentRegistry()
    registry.reconcile(
        displays: [Display(id: "left"), Display(id: "right")],
        identify: { $0.id },
        create: { displayID, _ in MockAssignment(displayID: displayID) })
    let left = try assignment(registry, "left")
    let right = try assignment(registry, "right")
    registry.reconcile(
        displays: [Display(id: "right")],
        identify: { $0.id },
        create: { displayID, _ in MockAssignment(displayID: displayID) })
    try expect(left.stopped, "removed display assignment was not stopped")
    try expect(!right.stopped, "retained display assignment was stopped")
    let retainedRight = try assignment(registry, "right")
    try expect(retainedRight === right, "retained display identity changed")
}

private func testPlanDiffRestartsOnlyChangedTarget() throws {
    let registry = RuntimeAssignmentRegistry()
    let initial = [
        RuntimeAssignmentRequest(displayID: "left", binding: .wallpaper(target: "one")),
        RuntimeAssignmentRequest(displayID: "right", binding: .wallpaper(target: "one")),
    ]
    registry.reconcile(requests: initial) {
        MockAssignment(displayID: $0.displayID, binding: $0.binding)
    }
    let left = try assignment(registry, "left")
    let right = try assignment(registry, "right")
    registry.reconcile(requests: [
        RuntimeAssignmentRequest(displayID: "left", binding: .wallpaper(target: "one")),
        RuntimeAssignmentRequest(displayID: "right", binding: .wallpaper(target: "two")),
    ]) {
        MockAssignment(displayID: $0.displayID, binding: $0.binding)
    }
    let retainedLeft = try assignment(registry, "left")
    let replacedRight = try assignment(registry, "right")
    try expect(retainedLeft === left, "unchanged target restarted")
    try expect(!left.stopped, "unchanged target was stopped")
    try expect(replacedRight !== right, "changed target was retained")
    try expect(right.stopped, "changed target was not stopped")
}

private func testUnresolvedTargetPreservesOnlyAffectedDisplay() throws {
    let registry = RuntimeAssignmentRegistry()
    registry.reconcile(requests: [
        RuntimeAssignmentRequest(displayID: "left", binding: .wallpaper(target: "one")),
        RuntimeAssignmentRequest(displayID: "right", binding: .wallpaper(target: "one")),
    ]) { MockAssignment(displayID: $0.displayID, binding: $0.binding) }
    let left = try assignment(registry, "left")
    let right = try assignment(registry, "right")
    let desired = [
        RuntimeAssignmentRequest(displayID: "left", binding: .wallpaper(target: "missing")),
        RuntimeAssignmentRequest(displayID: "right", binding: .wallpaper(target: "two")),
    ]
    registry.reconcile(
        requests: desired,
        unresolved: ["left": "wallpaper target did not resolve: missing"]
    ) { MockAssignment(displayID: $0.displayID, binding: $0.binding) }

    let retainedLeft = try assignment(registry, "left")
    let replacedRight = try assignment(registry, "right")
    try expect(retainedLeft === left, "unresolved display was replaced")
    try expect(!left.stopped, "unresolved display was stopped")
    try expect(replacedRight !== right, "resolved sibling was retained")
    try expect(right.stopped, "resolved sibling replacement did not stop the old assignment")
    let degraded = registry.evidence.first { $0.displayID == "left" }
    try expect(degraded?.status == .degraded, "unresolved display did not report degraded")
    try expect(degraded?.target == "one", "degraded evidence lost the retained visible target")
    try expect(degraded?.error?.contains("missing") == true, "degraded evidence lost desired target")

    registry.reconcile(requests: desired) {
        MockAssignment(displayID: $0.displayID, binding: $0.binding)
    }
    let resolvedLeft = try assignment(registry, "left")
    try expect(resolvedLeft !== left, "resolved target did not replace retained output")
    try expect(left.stopped, "resolved target did not stop retained output after staging")
    try expect(registry.evidence.first { $0.displayID == "left" }?.status != .degraded,
               "successful reconcile did not clear degraded evidence")

    registry.reconcile(requests: [desired[1]]) {
        MockAssignment(displayID: $0.displayID, binding: $0.binding)
    }
    try expect(resolvedLeft.stopped, "idle display did not stop its assignment")
    try expect(registry.evidence.allSatisfy { $0.displayID != "left" },
               "idle display retained degraded evidence")
}

private func testConfigurationChangeStagesReplacement() throws {
    let registry = RuntimeAssignmentRegistry()
    let binding = FrescoBinding.wallpaper(target: "one")
    registry.reconcile(requests: [RuntimeAssignmentRequest(
        displayID: "left", binding: binding, configurationToken: "0,0,100,100@2"),
        RuntimeAssignmentRequest(
            displayID: "right", binding: binding, configurationToken: "100,0,100,100@2"),
    ]) { MockAssignment(displayID: $0.displayID, binding: $0.binding) }
    let original = try assignment(registry, "left")
    let right = try assignment(registry, "right")

    let unchangedRequests = [
        RuntimeAssignmentRequest(
            displayID: "left", binding: binding, configurationToken: "0,0,100,100@2"),
        RuntimeAssignmentRequest(
            displayID: "right", binding: binding, configurationToken: "100,0,100,100@2"),
    ]
    var unchangedCreations = 0
    registry.reconcile(requests: unchangedRequests) {
        unchangedCreations += 1
        return MockAssignment(displayID: $0.displayID, binding: $0.binding)
    }
    try expect(unchangedCreations == 0, "unchanged display configuration recreated assignment")
    let unchanged = try assignment(registry, "left")
    try expect(unchanged === original, "unchanged geometry lost identity")

    var stagedBeforeStop = false
    registry.reconcile(requests: [
        RuntimeAssignmentRequest(
            displayID: "left", binding: binding, configurationToken: "0,0,200,100@2"),
        unchangedRequests[1],
    ]) {
        stagedBeforeStop = !original.stopped
        return MockAssignment(displayID: $0.displayID, binding: $0.binding)
    }
    try expect(stagedBeforeStop, "old assignment stopped before replacement was staged")
    try expect(original.stopped, "geometry replacement did not stop old assignment")
    let resized = try assignment(registry, "left")
    let unchangedRight = try assignment(registry, "right")
    try expect(resized !== original, "geometry change retained stale screen")
    try expect(unchangedRight === right, "geometry change rebuilt unaffected display")
}

private func testInvalidatedScopedReloadPreservesOnFailure() throws {
    let registry = RuntimeAssignmentRegistry()
    let request = RuntimeAssignmentRequest(
        displayID: "left",
        binding: .wallpaper(target: "web-left"),
        configurationToken: "0,0,100,100@2")
    registry.reconcile(requests: [request]) {
        MockAssignment(displayID: $0.displayID, binding: $0.binding)
    }
    let original = try assignment(registry, "left")
    registry.invalidateConfiguration(displayID: "left")
    registry.reconcile(
        requests: [request],
        unresolved: ["left": "wallpaper target did not resolve: web-left"]
    ) { MockAssignment(displayID: $0.displayID, binding: $0.binding) }
    let retained = try assignment(registry, "left")
    try expect(retained === original, "failed scoped reload discarded visible assignment")
    try expect(!original.stopped, "failed scoped reload stopped visible assignment")
    try expect(registry.evidence.first?.status == .degraded,
               "failed scoped reload did not report degraded")

    registry.reconcile(requests: [request]) {
        MockAssignment(displayID: $0.displayID, binding: $0.binding)
    }
    let replacement = try assignment(registry, "left")
    try expect(replacement !== original, "successful scoped reload did not rebuild assignment")
    try expect(original.stopped, "successful scoped reload did not retire old assignment")
}

private func testSceneAudioOwnershipIsPerBindingAndStable() throws {
    let one = FrescoBinding.wallpaper(target: "one")
    let two = FrescoBinding.wallpaper(target: "two")
    let candidates = [
        RuntimeSceneAudioCandidate(displayID: "display-20", binding: one),
        RuntimeSceneAudioCandidate(displayID: "display-10", binding: one),
        RuntimeSceneAudioCandidate(displayID: "display-30", binding: two),
    ]
    let owners = RuntimeSceneAudioOwnership.ownerDisplayIDs(for: candidates)
    let reordered = RuntimeSceneAudioOwnership.ownerDisplayIDs(for: candidates.reversed())
    try expect(owners == ["display-10", "display-30"], "audio owner was not per binding")
    try expect(reordered == owners, "audio owner depended on assignment order")

    let removed = RuntimeSceneAudioOwnership.ownerDisplayIDs(for: [candidates[0]])
    try expect(removed == ["display-20"], "owner removal did not elect the next display")

    let changed = RuntimeSceneAudioOwnership.ownerDisplayIDs(for: [
        RuntimeSceneAudioCandidate(displayID: "display-10", binding: two),
        candidates[0],
    ])
    try expect(changed == ["display-10", "display-20"], "binding change did not split ownership")

    let policyMuted = RuntimeSceneAudioOwnership.ownerDisplayIDs(for: [
        RuntimeSceneAudioCandidate(displayID: "display-10", binding: one, eligible: false),
        RuntimeSceneAudioCandidate(displayID: "display-20", binding: one),
    ])
    try expect(policyMuted == ["display-20"], "muted owner did not transfer to an eligible sibling")
}

private func testSceneAudioCoordinatorAcknowledgedTransfers() throws {
    let binding = FrescoBinding.wallpaper(target: "one")
    let otherBinding = FrescoBinding.wallpaper(target: "two")
    let a = MockAudioEndpoint("a", binding)
    let b = MockAudioEndpoint("b", binding)
    let c = MockAudioEndpoint("c", binding)
    let other = MockAudioEndpoint("x", otherBinding)
    let coordinator = RuntimeSceneAudioCoordinator()

    coordinator.reconcile(endpoints: [b, a, other], policyMutedDisplayIDs: [])
    try expect(a.commands == [false], "initial owner was not selected")
    try expect(b.commands == [true], "initial sibling was not muted")
    try expect(other.commands == [false], "unrelated binding did not elect independently")
    a.acknowledge(0)
    other.acknowledge(0)

    coordinator.reconcile(endpoints: [b, c, other], policyMutedDisplayIDs: [])
    try expect(a.commands == [false, true], "removed owner was not muted first")
    try expect(b.commands == [true], "successor unmuted before mute acknowledgement")
    try expect(other.commands == [false], "unrelated group was blocked by transfer")

    coordinator.reconcile(endpoints: [c, other], policyMutedDisplayIDs: [])
    a.acknowledge(1)
    try expect(c.commands.last == false, "rapid reconcile did not choose latest successor")
    try expect(!b.commands.contains(false), "stale successor was unmuted")
    c.acknowledge(c.commands.count - 1)

    let replacement = MockAudioEndpoint("c", binding)
    coordinator.reconcile(endpoints: [replacement, other], policyMutedDisplayIDs: [])
    try expect(c.commands.last == true, "replacement did not mute old endpoint")
    try expect(!replacement.commands.contains(false), "replacement unmuted before termination")
    c.acknowledge(c.commands.count - 1)
    try expect(replacement.commands.last == false, "termination did not release replacement")
    replacement.acknowledge(replacement.commands.count - 1)

    coordinator.reconcile(
        endpoints: [replacement, b, other], policyMutedDisplayIDs: ["c"])
    try expect(replacement.commands.last == true, "policy-muted owner was not muted")
    replacement.acknowledge(replacement.commands.count - 1)
    try expect(b.commands.last == false, "eligible sibling did not receive ownership")

    let staleCoordinator = RuntimeSceneAudioCoordinator()
    let d = MockAudioEndpoint("d", binding)
    let e = MockAudioEndpoint("e", binding)
    staleCoordinator.reconcile(endpoints: [d, e], policyMutedDisplayIDs: [])
    staleCoordinator.reconcile(endpoints: [d, e], policyMutedDisplayIDs: ["d"])
    d.acknowledge(0)
    try expect(d.commands == [false, true], "stale unmute was not reversed")
    try expect(!e.commands.contains(false), "stale callback released successor early")
    d.acknowledge(1)
    try expect(e.commands.last == false, "stale unmute recovery did not elect successor")

    let replacementCoordinator = RuntimeSceneAudioCoordinator()
    let oldBinding = MockAudioEndpoint("same-display", binding)
    let newBinding = MockAudioEndpoint("same-display", otherBinding)
    replacementCoordinator.reconcile(endpoints: [oldBinding], policyMutedDisplayIDs: [])
    oldBinding.acknowledge(0)
    replacementCoordinator.reconcile(endpoints: [newBinding], policyMutedDisplayIDs: [])
    try expect(oldBinding.commands.last == true, "cross-binding replacement did not mute old owner")
    try expect(!newBinding.commands.contains(false), "cross-binding replacement overlapped owners")
    oldBinding.acknowledge(oldBinding.commands.count - 1)
    try expect(newBinding.commands.last == false, "cross-binding replacement did not release successor")

    let pendingCoordinator = RuntimeSceneAudioCoordinator()
    let pendingOld = MockAudioEndpoint("pending-display", binding)
    let pendingNew = MockAudioEndpoint("pending-display", otherBinding)
    pendingCoordinator.reconcile(endpoints: [pendingOld], policyMutedDisplayIDs: [])
    pendingCoordinator.reconcile(endpoints: [pendingNew], policyMutedDisplayIDs: [])
    try expect(!pendingNew.commands.contains(false), "pending old unmute did not block replacement")
    pendingOld.acknowledge(0)
    try expect(pendingOld.commands == [false, true], "pending old unmute was not reversed")
    try expect(!pendingNew.commands.contains(false), "replacement released before stale reversal")
    pendingOld.acknowledge(1)
    try expect(pendingNew.commands.last == false, "stale reversal did not release replacement")
}

private func testStagedSceneReplacementWaitsForConfirmedSilence() throws {
    let registry = RuntimeAssignmentRegistry()
    let coordinator = RuntimeSceneAudioCoordinator()
    let first = FrescoBinding.wallpaper(target: "first")
    let second = FrescoBinding.wallpaper(target: "second")
    registry.reconcile(requests: [
        RuntimeAssignmentRequest(displayID: "display", binding: first),
    ]) {
        MockRetiringSceneAssignment(displayID: $0.displayID, binding: $0.binding)
    }
    guard let old = registry["display"] as? MockRetiringSceneAssignment else {
        throw TestFailure.assertion("initial scene assignment missing")
    }
    coordinator.reconcile(endpoints: [old], policyMutedDisplayIDs: [])
    try expect(old.commands == [false], "initial scene owner did not unmute")
    old.acknowledge(0)

    registry.reconcile(requests: [
        RuntimeAssignmentRequest(displayID: "display", binding: second),
    ]) {
        MockRetiringSceneAssignment(displayID: $0.displayID, binding: $0.binding)
    }
    guard let replacement = registry["display"] as? MockRetiringSceneAssignment else {
        throw TestFailure.assertion("replacement scene assignment missing")
    }
    try expect(old.stopped, "staged replacement did not begin old-scene retirement")
    try expect(old.commands == [false, true], "retirement did not request old-scene mute")

    coordinator.reconcile(endpoints: [replacement], policyMutedDisplayIDs: [])
    try expect(!replacement.commands.contains(false),
               "replacement unmuted before old-scene silence was confirmed")
    old.confirmTermination()
    try expect(replacement.commands.last == false,
               "confirmed old-scene termination did not release replacement")
}

@main
private enum RuntimeAssignmentsTestRunner {
    static func main() {
        do {
            try testScreenReorderingPreservesIdentity()
            try testSceneFallbackAssociationSurvivesReorder()
            try testRemovalStopsOnlyRemovedDisplay()
            try testPlanDiffRestartsOnlyChangedTarget()
            try testUnresolvedTargetPreservesOnlyAffectedDisplay()
            try testConfigurationChangeStagesReplacement()
            try testInvalidatedScopedReloadPreservesOnFailure()
            try testSceneAudioOwnershipIsPerBindingAndStable()
            try testSceneAudioCoordinatorAcknowledgedTransfers()
            try testStagedSceneReplacementWaitsForConfirmedSilence()
            print("Fresco runtime assignment tests passed: 10")
        } catch {
            fputs("Fresco runtime assignment test failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
