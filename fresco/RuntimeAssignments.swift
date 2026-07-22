import Foundation

enum RuntimeAssignmentStatus: String, Codable, Equatable {
    case idle
    case starting
    case running
    case degraded
    case stopping
}

struct RuntimeAssignmentEvidence: Codable, Equatable {
    let displayID: String
    let status: RuntimeAssignmentStatus
    let target: String?
    let firstFrameAt: String?
    let error: String?
}

protocol RuntimeDisplayAssignment: AnyObject {
    var displayID: String { get }
    var binding: FrescoBinding { get }
    var evidence: RuntimeAssignmentEvidence { get }
    var isOccluded: Bool { get }

    func setPaused(_ paused: Bool)
    func setMuted(_ muted: Bool)
    func setVisible(_ visible: Bool)
    func setSchedulingPolicy(
        fpsCeiling: Int?, policyRevision: Int, reasonTokens: [String]
    )
    func stop()
}

struct RuntimeAssignmentRequest: Equatable {
    let displayID: String
    let binding: FrescoBinding
    let configurationToken: String?

    init(
        displayID: String,
        binding: FrescoBinding,
        configurationToken: String? = nil
    ) {
        self.displayID = displayID
        self.binding = binding
        self.configurationToken = configurationToken
    }
}

extension RuntimeDisplayAssignment {
    var isOccluded: Bool { false }
    func setMuted(_ muted: Bool) {}
    func setSchedulingPolicy(
        fpsCeiling: Int?, policyRevision: Int, reasonTokens: [String]
    ) {}
}

struct RuntimeSceneAudioCandidate: Equatable {
    let displayID: String
    let binding: FrescoBinding
    let eligible: Bool

    init(displayID: String, binding: FrescoBinding, eligible: Bool = true) {
        self.displayID = displayID
        self.binding = binding
        self.eligible = eligible
    }
}

enum RuntimeSceneAudioOwnership {
    static func ownerDisplayIDs(
        for candidates: [RuntimeSceneAudioCandidate]
    ) -> Set<String> {
        var groups: [(FrescoBinding, String)] = []
        for candidate in candidates.filter(\.eligible).sorted(by: { $0.displayID < $1.displayID }) {
            if groups.contains(where: { $0.0 == candidate.binding }) { continue }
            groups.append((candidate.binding, candidate.displayID))
        }
        return Set(groups.map(\.1))
    }
}

protocol RuntimeSceneAudioEndpoint: AnyObject {
    var displayID: String { get }
    var binding: FrescoBinding { get }
    func setMuted(_ muted: Bool, completion: (() -> Void)?)
}

final class RuntimeSceneAudioCoordinator {
    private final class Group {
        let binding: FrescoBinding
        var endpoints: [any RuntimeSceneAudioEndpoint] = []
        var desiredOwner: (any RuntimeSceneAudioEndpoint)?
        var audible: (any RuntimeSceneAudioEndpoint)?
        var muting: (any RuntimeSceneAudioEndpoint)?
        var unmuting: (any RuntimeSceneAudioEndpoint)?

        init(binding: FrescoBinding) { self.binding = binding }
    }

    private var groups: [Group] = []

    func reconcile(
        endpoints: [any RuntimeSceneAudioEndpoint],
        policyMutedDisplayIDs: Set<String>
    ) {
        for endpoint in endpoints where !groups.contains(where: { $0.binding == endpoint.binding }) {
            groups.append(Group(binding: endpoint.binding))
        }
        for group in groups {
            group.endpoints = endpoints.filter { $0.binding == group.binding }
            group.desiredOwner = group.endpoints
                .filter { !policyMutedDisplayIDs.contains($0.displayID) }
                .min { $0.displayID < $1.displayID }
            for endpoint in group.endpoints where !same(endpoint, group.desiredOwner)
                && !same(endpoint, group.audible)
                && !same(endpoint, group.muting)
                && !same(endpoint, group.unmuting) {
                endpoint.setMuted(true, completion: nil)
            }
            advance(group)
        }
        groups.removeAll {
            $0.endpoints.isEmpty && $0.audible == nil
                && $0.muting == nil && $0.unmuting == nil
        }
    }

    private func advance(_ group: Group) {
        if group.muting != nil || group.unmuting != nil { return }
        if let audible = group.audible {
            guard !same(audible, group.desiredOwner) else { return }
            group.audible = nil
            group.muting = audible
            audible.setMuted(true) { [weak self, weak group, weak audible] in
                guard let self, let group else { return }
                if same(group.muting, audible) { group.muting = nil }
                self.advanceAll()
            }
            return
        }
        guard let desired = group.desiredOwner else { return }
        guard !groups.contains(where: {
            $0 !== group && $0.binding != group.binding
                && [ $0.audible, $0.muting, $0.unmuting ].contains(where: {
                    $0?.displayID == desired.displayID
                })
        }) else { return }
        group.unmuting = desired
        desired.setMuted(false) { [weak self, weak group, weak desired] in
            guard let self, let group else { return }
            if same(group.unmuting, desired) { group.unmuting = nil }
            if same(group.desiredOwner, desired) {
                group.audible = desired
                self.advanceAll()
            } else if let desired {
                group.muting = desired
                desired.setMuted(true) { [weak self, weak group, weak desired] in
                    guard let self, let group else { return }
                    if same(group.muting, desired) { group.muting = nil }
                    self.advanceAll()
                }
            }
        }
    }

    private func advanceAll() {
        for group in groups { advance(group) }
    }
}

private func same(
    _ lhs: (any RuntimeSceneAudioEndpoint)?,
    _ rhs: (any RuntimeSceneAudioEndpoint)?
) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
}

final class RuntimeAssignmentRegistry {
    private var assignments: [String: any RuntimeDisplayAssignment] = [:]
    private var assignmentConfigurations: [String: String] = [:]
    private var degradedEvidence: [String: RuntimeAssignmentEvidence] = [:]

    var count: Int { assignments.count }
    var displayIDs: [String] { assignments.keys.sorted() }
    var values: [any RuntimeDisplayAssignment] {
        displayIDs.compactMap { assignments[$0] }
    }
    var evidence: [RuntimeAssignmentEvidence] {
        let assignmentEvidence = Dictionary(
            values.map { ($0.displayID, $0.evidence) },
            uniquingKeysWith: { _, latest in latest })
        return Set(assignmentEvidence.keys).union(degradedEvidence.keys).sorted().compactMap {
            degradedEvidence[$0] ?? assignmentEvidence[$0]
        }
    }
    var occludedDisplayIDs: Set<String> {
        Set(values.filter(\.isOccluded).map(\.displayID))
    }

    subscript(displayID: String) -> (any RuntimeDisplayAssignment)? {
        assignments[displayID]
    }

    func reconcile<Display>(
        displays: [Display],
        identify: (Display) -> String,
        create: (String, Display) -> any RuntimeDisplayAssignment
    ) {
        var displaysByID: [String: Display] = [:]
        for display in displays {
            let displayID = identify(display)
            if displaysByID[displayID] == nil { displaysByID[displayID] = display }
        }
        let desiredIDs = Set(displaysByID.keys)
        for displayID in assignments.keys where !desiredIDs.contains(displayID) {
            assignments.removeValue(forKey: displayID)?.stop()
            assignmentConfigurations.removeValue(forKey: displayID)
        }
        degradedEvidence = degradedEvidence.filter { desiredIDs.contains($0.key) }
        for displayID in desiredIDs.sorted() where assignments[displayID] == nil {
            guard let display = displaysByID[displayID] else { continue }
            let assignment = create(displayID, display)
            precondition(
                assignment.displayID == displayID,
                "runtime assignment returned a mismatched display ID")
            assignments[displayID] = assignment
        }
    }

    func reconcile(
        requests: [RuntimeAssignmentRequest],
        unresolved: [String: String] = [:],
        create: (RuntimeAssignmentRequest) -> any RuntimeDisplayAssignment
    ) {
        let requestsByID = Dictionary(
            requests.map { ($0.displayID, $0) },
            uniquingKeysWith: { first, _ in first })
        let desiredIDs = Set(requestsByID.keys)
        for displayID in assignments.keys where !desiredIDs.contains(displayID) {
            assignments.removeValue(forKey: displayID)?.stop()
            assignmentConfigurations.removeValue(forKey: displayID)
        }
        degradedEvidence = degradedEvidence.filter { desiredIDs.contains($0.key) }
        for displayID in desiredIDs.sorted() {
            guard let request = requestsByID[displayID] else { continue }
            if let error = unresolved[displayID] {
                degradedEvidence[displayID] = RuntimeAssignmentEvidence(
                    displayID: displayID,
                    status: .degraded,
                    target: assignments[displayID]?.evidence.target
                        ?? request.binding.wallpaperTarget,
                    firstFrameAt: assignments[displayID]?.evidence.firstFrameAt,
                    error: error)
                continue
            }
            degradedEvidence.removeValue(forKey: displayID)
            if let existing = assignments[displayID],
               existing.binding == request.binding,
               assignmentConfigurations[displayID] == request.configurationToken {
                continue
            }
            let previous = assignments[displayID]
            let assignment = create(request)
            precondition(
                assignment.displayID == displayID && assignment.binding == request.binding,
                "runtime assignment returned a mismatched request")
            assignments[displayID] = assignment
            if let token = request.configurationToken {
                assignmentConfigurations[displayID] = token
            } else {
                assignmentConfigurations.removeValue(forKey: displayID)
            }
            previous?.stop()
        }
    }

    func removeAll() {
        let removed = values
        assignments.removeAll()
        assignmentConfigurations.removeAll()
        degradedEvidence.removeAll()
        removed.forEach { $0.stop() }
    }

    func remove(displayID: String) {
        degradedEvidence.removeValue(forKey: displayID)
        assignmentConfigurations.removeValue(forKey: displayID)
        assignments.removeValue(forKey: displayID)?.stop()
    }

    func invalidateConfiguration(displayID: String) {
        assignmentConfigurations.removeValue(forKey: displayID)
    }
}

private extension FrescoBinding {
    var wallpaperTarget: String? {
        guard case let .wallpaper(target) = self else { return nil }
        return target
    }
}
