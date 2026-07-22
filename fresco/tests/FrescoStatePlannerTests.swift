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

private let wallpaper = FrescoBinding.wallpaper(target: "base")

private func display(_ id: String, x: Double, width: Double = 100, connected: Bool = true, occluded: Bool = false) -> FrescoObservedDisplay {
    FrescoObservedDisplay(
        id: id,
        connected: connected,
        frame: FrescoRect(x: x, y: 0, width: width, height: 80),
        scale: 2,
        occluded: occluded
    )
}

private func context(
    displays: [FrescoObservedDisplay],
    applications: [FrescoObservedApplication] = [],
    locked: Bool = false,
    reasons: [FrescoReasonContribution] = [],
    generation: String = "generation:test"
) -> FrescoObservedContext {
    FrescoObservedContext(
        generation: generation,
        locked: locked,
        sleeping: false,
        onBattery: false,
        pauseWhenOccluded: true,
        displays: displays,
        applications: applications,
        reasons: reasons
    )
}

private func state(
    displays: [String] = ["left", "right"],
    profiles: [FrescoProfile] = [],
    rules: [FrescoApplicationRule] = [],
    desired: FrescoDesiredState? = nil,
    revision: Int = 7
) -> FrescoState {
    FrescoState(
        schemaVersion: 1,
        revision: revision,
        updatedAt: "2026-07-20T18:00:00Z",
        displays: displays.map { FrescoDisplayRecord(id: $0, name: nil) },
        playlists: [],
        profiles: profiles,
        applicationRules: rules,
        desired: desired ?? FrescoDesiredState(
            profileId: nil,
            layout: .clone(binding: wallpaper),
            controls: FrescoControls(paused: false, muted: false),
            fpsCeiling: nil
        )
    )
}

private func app(_ bundleId: String, displays: [String], frontmost: Bool = true) -> FrescoObservedApplication {
    FrescoObservedApplication(
        bundleId: bundleId,
        running: true,
        frontmost: frontmost,
        fullscreen: false,
        displayIds: displays
    )
}

private func rule(
    id: String,
    priority: Int,
    scope: FrescoRuleScope = .global,
    profileId: String? = nil,
    paused: Bool? = nil,
    muted: Bool? = nil,
    fps: Int? = nil
) -> FrescoApplicationRule {
    FrescoApplicationRule(
        id: id,
        enabled: true,
        priority: priority,
        match: FrescoRuleMatch(
            bundleIds: ["test.app"],
            running: .require,
            frontmost: .ignore,
            fullscreen: .ignore
        ),
        scope: scope,
        effect: FrescoRuleEffect(profileId: profileId, paused: paused, muted: muted, fpsCeiling: fps)
    )
}

private func testDisplayNormalizationAndReconnect() throws {
    let desired = FrescoDesiredState(
        profileId: nil,
        layout: .perDisplay(
            assignments: [FrescoDisplayAssignment(displayId: "right", binding: .wallpaper(target: "right"))],
            defaultBinding: .wallpaper(target: "default")
        ),
        controls: FrescoControls(paused: false, muted: false),
        fpsCeiling: nil
    )
    let input = state(desired: desired)
    let disconnected = FrescoStatePlanner.plan(
        state: input,
        observed: context(displays: [display("right", x: 100, connected: false), display("left", x: 0)])
    )
    try expect(disconnected.displays.map(\.displayId) == ["left"], "disconnected display entered the plan")
    try expect(disconnected.displays[0].binding == .wallpaper(target: "default"), "default binding was not resolved")

    let reconnected = FrescoStatePlanner.plan(
        state: input,
        observed: context(displays: [
            display("right", x: 100), display("left", x: 0),
            display("new", x: 260)
        ])
    )
    try expect(reconnected.displays.map(\.displayId) == ["left", "new", "right"],
               "connected displays were not stably sorted")
    try expect(reconnected.displays[1].binding == .wallpaper(target: "default"),
               "new display did not receive the default binding")
    try expect(reconnected.displays[2].binding == .wallpaper(target: "right"),
               "durable assignment did not survive reconnect")
}

private func testMissingPerDisplayDefaultIsIdle() throws {
    let desired = FrescoDesiredState(
        profileId: nil,
        layout: .perDisplay(assignments: [], defaultBinding: nil),
        controls: FrescoControls(paused: false, muted: false),
        fpsCeiling: nil
    )
    let plan = FrescoStatePlanner.plan(state: state(desired: desired), observed: context(displays: [display("left", x: 0)]))
    try expect(plan.displays[0].binding == .idle, "missing per-display default did not resolve idle")
}

private func testDisconnectedAndDuplicatePerDisplayIdentity() throws {
    let desired = FrescoDesiredState(
        profileId: nil,
        layout: .perDisplay(assignments: [], defaultBinding: .idle),
        controls: FrescoControls(paused: false, muted: false),
        fpsCeiling: nil)
    let input = state(desired: desired)
    let disconnected = FrescoStatePlanner.plan(
        state: input,
        observed: context(displays: [display("left", x: 0, connected: false)]))
    try expect(disconnected.displays.isEmpty, "disconnected display entered empty plan")
    try expect(disconnected.layoutMode == .perDisplay,
               "empty per-display plan lost its durable layout mode")

    let duplicate = FrescoStatePlanner.plan(
        state: input,
        observed: context(displays: [display("left", x: 0), display("left", x: 200)]))
    let reversed = FrescoStatePlanner.plan(
        state: input,
        observed: context(displays: [display("left", x: 200), display("left", x: 0)]))
    try expect(duplicate.displays.count == 1, "duplicate display ID produced duplicate rows")
    try expect(duplicate.displays[0].displayId == "left", "duplicate display identity changed")
    try expect(duplicate == reversed, "duplicate display normalization depended on input order")
}

private func testGlobalRuleProfileSurvivesEmptyDisplayPlan() throws {
    let selected = FrescoProfile(
        id: "selected",
        name: "Selected",
        layout: .perDisplay(
            assignments: [], defaultBinding: .wallpaper(target: "selected")),
        controls: FrescoControls(paused: false, muted: false),
        fpsCeiling: nil)
    let input = state(
        profiles: [selected],
        rules: [rule(id: "select", priority: 1, profileId: "selected")],
        desired: FrescoDesiredState(
            profileId: nil, layout: nil, controls: nil, fpsCeiling: nil))
    let observed = context(
        displays: [], applications: [app("test.app", displays: [])])
    let plan = FrescoStatePlanner.plan(state: input, observed: observed)
    try expect(plan.displays.isEmpty, "empty observed display set produced plan rows")
    try expect(plan.layoutMode == .perDisplay,
               "global rule profile layout was lost without connected displays")
    try expect(plan.profileId == "selected", "global rule profile was lost from empty plan")
    try expect(plan.profileReasons == ["rule:select"],
               "global rule provenance was lost from empty plan")
}

private func testSpanViewports() throws {
    let desired = FrescoDesiredState(
        profileId: nil,
        layout: .span(binding: .wallpaper(target: "panorama")),
        controls: FrescoControls(paused: false, muted: false),
        fpsCeiling: nil
    )
    let plan = FrescoStatePlanner.plan(
        state: state(desired: desired),
        observed: context(displays: [display("right", x: 100, width: 160), display("left", x: -20, width: 120)])
    )
    let left = try XCTUnwrap(plan.displays[0].spanViewport, "left span viewport missing")
    let right = try XCTUnwrap(plan.displays[1].spanViewport, "right span viewport missing")
    try expect(left.canvas == FrescoRect(x: -20, y: 0, width: 280, height: 80), "span canvas union is wrong")
    try expect(left.relativeFrame.x == 0 && right.relativeFrame.x == 120, "span viewport offsets are wrong")
}

private func testAdditiveIndependentReasonsAndMinimumFPS() throws {
    let extra = FrescoReasonContribution(
        displayId: "left",
        paused: ["producer:pause"],
        muted: [],
        hidden: ["producer:hidden"],
        fpsCeilings: [FrescoFPSContribution(ceiling: 30, reason: "producer:fps")]
    )
    let input = state(
        rules: [rule(id: "slow", priority: 1, paused: true, muted: true, fps: 30)],
        desired: FrescoDesiredState(
            profileId: nil,
            layout: .clone(binding: wallpaper),
            controls: FrescoControls(paused: false, muted: true),
            fpsCeiling: 60
        )
    )
    let plan = FrescoStatePlanner.plan(
        state: input,
        observed: context(
            displays: [display("left", x: 0, occluded: true)],
            applications: [app("test.app", displays: ["left"])],
            locked: true,
            reasons: [extra]
        )
    )
    let output = plan.displays[0]
    try expect(output.reasons.paused == ["locked", "occluded", "producer:pause", "rule:slow"], "pause reasons were not additive")
    try expect(output.reasons.muted == ["locked", "rule:slow", "user"], "mute reasons were not independent")
    try expect(output.reasons.hidden == ["locked", "producer:hidden"], "hidden reasons were not independent")
    try expect(output.fpsCeiling == 30, "minimum FPS ceiling was not selected")
    try expect(output.reasons.fpsCeiling == ["producer:fps", "rule:slow"], "tied minimum FPS reasons were lost")
}

private func testGlobalProfilePriorityTiesAndScopedEffects() throws {
    let base = FrescoProfile(
        id: "base",
        name: "Base",
        layout: .clone(binding: .wallpaper(target: "base")),
        controls: FrescoControls(paused: false, muted: false),
        fpsCeiling: 60
    )
    let alpha = FrescoProfile(
        id: "alpha",
        name: "Alpha",
        layout: .clone(binding: .wallpaper(target: "alpha")),
        controls: FrescoControls(paused: false, muted: false),
        fpsCeiling: nil
    )
    let omega = FrescoProfile(
        id: "omega",
        name: "Omega",
        layout: .clone(binding: .wallpaper(target: "omega")),
        controls: FrescoControls(paused: false, muted: true),
        fpsCeiling: nil
    )
    let rules = [
        rule(id: "z-last", priority: 10, profileId: "omega", fps: 24),
        rule(id: "a-first", priority: 10, profileId: "alpha", fps: 30),
        rule(id: "earlier", priority: 1, scope: .affectedDisplays, paused: true)
    ]
    let input = state(
        profiles: [base, alpha, omega],
        rules: rules,
        desired: FrescoDesiredState(profileId: "base", layout: nil, controls: nil, fpsCeiling: nil)
    )
    let plan = FrescoStatePlanner.plan(
        state: input,
        observed: context(
            displays: [display("left", x: 0), display("right", x: 100)],
            applications: [app("test.app", displays: ["left"])]
        )
    )
    let left = plan.displays[0]
    let right = plan.displays[1]
    try expect(left.profileId == "omega" && left.binding == .wallpaper(target: "omega"), "lexically later tied rule did not win")
    try expect(left.reasons.muted == ["rule:z-last"], "rule-selected profile controls have wrong provenance")
    try expect(left.reasons.paused == ["rule:earlier"], "lower-priority additive effect was discarded")
    try expect(left.fpsCeiling == 24, "scoped minimum FPS did not apply")
    try expect(right.profileId == "omega" && right.binding == .wallpaper(target: "omega"), "global profile rule did not reach every display")
    try expect(right.reasons.paused.isEmpty, "affected-display pause escaped its scope")
    try expect(right.fpsCeiling == 24, "global FPS rule did not reach every display")
}

private func testAffectedDisplayProfileIsIgnoredDefensively() throws {
    let base = FrescoProfile(
        id: "base",
        name: "Base",
        layout: .clone(binding: .wallpaper(target: "base")),
        controls: FrescoControls(paused: false, muted: false),
        fpsCeiling: 60
    )
    let alternate = FrescoProfile(
        id: "alternate",
        name: "Alternate",
        layout: .span(binding: .wallpaper(target: "alternate")),
        controls: FrescoControls(paused: false, muted: true),
        fpsCeiling: 15
    )
    let scoped = rule(
        id: "scoped", priority: 1, scope: .affectedDisplays,
        profileId: "alternate", paused: true, fps: 30
    )
    let input = state(
        profiles: [base, alternate],
        rules: [scoped],
        desired: FrescoDesiredState(
            profileId: "base", layout: nil, controls: nil, fpsCeiling: nil)
    )
    let plan = FrescoStatePlanner.plan(
        state: input,
        observed: context(
            displays: [display("left", x: 0), display("right", x: 100)],
            applications: [app("test.app", displays: ["left"])]
        )
    )
    let left = plan.displays[0]
    let right = plan.displays[1]
    try expect(left.profileId == "base" && left.binding == .wallpaper(target: "base"),
               "affected-display rule selected a profile")
    try expect(left.layoutMode == .clone && left.spanViewport == nil,
               "affected-display rule changed layout semantics")
    try expect(left.reasons.paused == ["rule:scoped"] && left.fpsCeiling == 30,
               "valid affected-display effects were discarded")
    try expect(right.profileId == "base" && right.reasons.paused.isEmpty,
               "affected-display effects escaped their scope")
    try expect(right.fpsCeiling == 60, "unaffected display lost its profile ceiling")
}

private func testTopLevelOverridesRuleProfile() throws {
    let alternate = FrescoProfile(
        id: "alternate",
        name: "Alternate",
        layout: .clone(binding: .wallpaper(target: "profile")),
        controls: FrescoControls(paused: true, muted: true),
        fpsCeiling: 15
    )
    let input = state(
        profiles: [alternate],
        rules: [rule(id: "profile", priority: 1, profileId: "alternate")],
        desired: FrescoDesiredState(
            profileId: nil,
            layout: .clone(binding: .wallpaper(target: "override")),
            controls: FrescoControls(paused: false, muted: false),
            fpsCeiling: 50
        )
    )
    let plan = FrescoStatePlanner.plan(
        state: input,
        observed: context(displays: [display("left", x: 0)], applications: [app("test.app", displays: ["left"])])
    )
    try expect(plan.displays[0].profileId == "alternate", "rule profile was not selected")
    try expect(plan.displays[0].binding == .wallpaper(target: "override"), "top-level layout did not override selected profile")
    try expect(!plan.displays[0].reasons.isPaused && !plan.displays[0].reasons.isMuted, "top-level controls did not override selected profile")
    try expect(plan.displays[0].fpsCeiling == 50, "top-level FPS did not override selected profile")
}

private func testAffectedDisplayConditionScope() throws {
    let fullscreenRule = FrescoApplicationRule(
        id: "fullscreen",
        enabled: true,
        priority: 1,
        match: FrescoRuleMatch(
            bundleIds: ["test.app"],
            running: .require,
            frontmost: .ignore,
            fullscreen: .require
        ),
        scope: .affectedDisplays,
        effect: FrescoRuleEffect(
            profileId: nil, paused: true, muted: nil, fpsCeiling: nil)
    )
    let applications = [
        FrescoObservedApplication(
            bundleId: "test.app", running: true, frontmost: false,
            fullscreen: true, displayIds: ["left"]),
        FrescoObservedApplication(
            bundleId: "test.app", running: true, frontmost: true,
            fullscreen: false, displayIds: ["right"]),
    ]
    let plan = FrescoStatePlanner.plan(
        state: state(rules: [fullscreenRule]),
        observed: context(
            displays: [display("left", x: 0), display("right", x: 100)],
            applications: applications)
    )
    try expect(plan.displays[0].reasons.paused == ["rule:fullscreen"],
               "fullscreen rule did not reach its affected display")
    try expect(plan.displays[1].reasons.paused.isEmpty,
               "fullscreen rule escaped to a non-fullscreen display")
}

private func testRevisionGenerationAndStatusIndependence() throws {
    let input = state(revision: 42)
    let first = FrescoStatePlanner.plan(
        state: input,
        observed: context(displays: [display("left", x: 0)], generation: "generation:new")
    )
    let repeated = FrescoStatePlanner.plan(
        state: input,
        observed: context(displays: [display("left", x: 0)], generation: "generation:new")
    )
    try expect(first == repeated, "pure planner depended on prior runtime status")
    try expect(first.desiredRevision == 42 && first.generation == "generation:new", "revision or generation was not propagated")
}

private func testJSONBoundary() throws {
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.count == 2 else { throw TestFailure.assertion("fixture root argument missing") }
    let root = URL(fileURLWithPath: arguments[1])
    let decoder = JSONDecoder()
    let durable = try decoder.decode(
        FrescoState.self,
        from: Data(contentsOf: root.appendingPathComponent("state/valid/per-display.json"))
    )
    let observed = try decoder.decode(
        FrescoObservedContext.self,
        from: Data(contentsOf: root.appendingPathComponent("state-planner/observed.json"))
    )
    let plan = FrescoStatePlanner.plan(state: durable, observed: observed)
    try expect(plan.desiredRevision == 12 && plan.generation == "generation:fixture", "JSON revision inputs were not preserved")
    try expect(plan.displays.map(\.displayId) == ["display:left", "display:right"], "JSON displays were not normalized")
    try expect(plan.displays[0].reasons.paused == ["rule:focus"], "JSON application rule was not resolved")
    try expect(plan.displays[0].fpsCeiling == 30, "JSON FPS policy was not resolved")
}

private func XCTUnwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure.assertion(message) }
    return value
}

@main
private enum FrescoStatePlannerTestRunner {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("display normalization and reconnect", testDisplayNormalizationAndReconnect),
            ("missing per-display default", testMissingPerDisplayDefaultIsIdle),
            ("disconnected and duplicate per-display identity",
             testDisconnectedAndDuplicatePerDisplayIdentity),
            ("empty-plan global profile", testGlobalRuleProfileSurvivesEmptyDisplayPlan),
            ("span viewports", testSpanViewports),
            ("additive independent reasons", testAdditiveIndependentReasonsAndMinimumFPS),
            ("global profile ordering and scoped effects", testGlobalProfilePriorityTiesAndScopedEffects),
            ("affected display profile defense", testAffectedDisplayProfileIsIgnoredDefensively),
            ("top-level overrides", testTopLevelOverridesRuleProfile),
            ("affected display conditions", testAffectedDisplayConditionScope),
            ("status independence", testRevisionGenerationAndStatusIndependence),
            ("JSON boundary", testJSONBoundary)
        ]

        do {
            for (name, test) in tests {
                do {
                    try test()
                } catch {
                    throw TestFailure.assertion("\(name): \(error)")
                }
            }
            print("fresco state planner: \(tests.count) tests passed")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
