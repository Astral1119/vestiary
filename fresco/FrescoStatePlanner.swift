import Foundation

enum FrescoBinding: Equatable, Sendable {
    case wallpaper(target: String)
    case playlist(id: String)
    case idle
}

extension FrescoBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case target
        case playlistId
    }

    private enum Kind: String, Codable {
        case wallpaper
        case playlist
        case idle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .wallpaper:
            self = .wallpaper(target: try container.decode(String.self, forKey: .target))
        case .playlist:
            self = .playlist(id: try container.decode(String.self, forKey: .playlistId))
        case .idle:
            self = .idle
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .wallpaper(target):
            try container.encode(Kind.wallpaper, forKey: .kind)
            try container.encode(target, forKey: .target)
        case let .playlist(id):
            try container.encode(Kind.playlist, forKey: .kind)
            try container.encode(id, forKey: .playlistId)
        case .idle:
            try container.encode(Kind.idle, forKey: .kind)
        }
    }
}

struct FrescoRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }

    static func union(_ rects: [FrescoRect]) -> FrescoRect? {
        guard let first = rects.first else { return nil }
        let minX = rects.dropFirst().reduce(first.x) { min($0, $1.x) }
        let minY = rects.dropFirst().reduce(first.y) { min($0, $1.y) }
        let maxX = rects.dropFirst().reduce(first.maxX) { max($0, $1.maxX) }
        let maxY = rects.dropFirst().reduce(first.maxY) { max($0, $1.maxY) }
        return FrescoRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

struct FrescoDisplayRecord: Codable, Equatable, Sendable {
    let id: String
    let name: String?
}

struct FrescoPlaylistEntry: Codable, Equatable, Sendable {
    let id: String
    let wallpaper: FrescoBinding
    let durationSeconds: Int
}

struct FrescoPlaylist: Codable, Equatable, Sendable {
    enum Order: String, Codable, Sendable {
        case sequential
        case shuffle
    }

    let id: String
    let name: String
    let entries: [FrescoPlaylistEntry]
    let order: Order
    let `repeat`: Bool
}

struct FrescoControls: Codable, Equatable, Sendable {
    let paused: Bool
    let muted: Bool
}

struct FrescoDisplayAssignment: Codable, Equatable, Sendable {
    let displayId: String
    let binding: FrescoBinding
}

enum FrescoLayout: Equatable, Sendable {
    case clone(binding: FrescoBinding)
    case perDisplay(assignments: [FrescoDisplayAssignment], defaultBinding: FrescoBinding?)
    case span(binding: FrescoBinding)

    enum Mode: String, Codable, Sendable {
        case clone
        case perDisplay
        case span
    }

    var mode: Mode {
        switch self {
        case .clone: return .clone
        case .perDisplay: return .perDisplay
        case .span: return .span
        }
    }

    func binding(for displayId: String) -> FrescoBinding {
        switch self {
        case let .clone(binding), let .span(binding):
            return binding
        case let .perDisplay(assignments, defaultBinding):
            return assignments.first(where: { $0.displayId == displayId })?.binding
                ?? defaultBinding
                ?? .idle
        }
    }
}

extension FrescoLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case binding
        case assignments
        case defaultBinding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .clone:
            self = .clone(binding: try container.decode(FrescoBinding.self, forKey: .binding))
        case .perDisplay:
            self = .perDisplay(
                assignments: try container.decode([FrescoDisplayAssignment].self, forKey: .assignments),
                defaultBinding: try container.decodeIfPresent(FrescoBinding.self, forKey: .defaultBinding)
            )
        case .span:
            self = .span(binding: try container.decode(FrescoBinding.self, forKey: .binding))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        switch self {
        case let .clone(binding), let .span(binding):
            try container.encode(binding, forKey: .binding)
        case let .perDisplay(assignments, defaultBinding):
            try container.encode(assignments, forKey: .assignments)
            try container.encodeIfPresent(defaultBinding, forKey: .defaultBinding)
        }
    }
}

struct FrescoProfile: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let layout: FrescoLayout
    let controls: FrescoControls
    let fpsCeiling: Int?
}

enum FrescoRuleCondition: String, Codable, Sendable {
    case ignore
    case require
    case exclude

    func accepts(_ value: Bool) -> Bool {
        switch self {
        case .ignore: return true
        case .require: return value
        case .exclude: return !value
        }
    }
}

struct FrescoRuleMatch: Codable, Equatable, Sendable {
    let bundleIds: [String]
    let running: FrescoRuleCondition
    let frontmost: FrescoRuleCondition
    let fullscreen: FrescoRuleCondition
}

enum FrescoRuleScope: Equatable, Sendable {
    case global
    case affectedDisplays
}

extension FrescoRuleScope: Codable {
    private enum CodingKeys: String, CodingKey { case kind }
    private enum Kind: String, Codable { case global, affectedDisplays }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .global: self = .global
        case .affectedDisplays: self = .affectedDisplays
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let kind: Kind = self == .global ? .global : .affectedDisplays
        try container.encode(kind, forKey: .kind)
    }
}

struct FrescoRuleEffect: Codable, Equatable, Sendable {
    let profileId: String?
    let paused: Bool?
    let muted: Bool?
    let fpsCeiling: Int?
}

struct FrescoApplicationRule: Codable, Equatable, Sendable {
    let id: String
    let enabled: Bool
    let priority: Int
    let match: FrescoRuleMatch
    let scope: FrescoRuleScope
    let effect: FrescoRuleEffect
}

struct FrescoDesiredState: Codable, Equatable, Sendable {
    let profileId: String?
    let layout: FrescoLayout?
    let controls: FrescoControls?
    let fpsCeiling: Int?
}

struct FrescoState: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let revision: Int
    let updatedAt: String
    let displays: [FrescoDisplayRecord]
    let playlists: [FrescoPlaylist]
    let profiles: [FrescoProfile]
    let applicationRules: [FrescoApplicationRule]
    let desired: FrescoDesiredState
}

struct FrescoObservedDisplay: Codable, Equatable, Sendable {
    let id: String
    let connected: Bool
    let frame: FrescoRect
    let scale: Double
    let occluded: Bool
}

struct FrescoObservedApplication: Codable, Equatable, Sendable {
    let bundleId: String
    let running: Bool
    let frontmost: Bool
    let fullscreen: Bool
    let displayIds: [String]
}

struct FrescoReasonContribution: Codable, Equatable, Sendable {
    let displayId: String?
    let paused: [String]
    let muted: [String]
    let hidden: [String]
    let fpsCeilings: [FrescoFPSContribution]
}

struct FrescoFPSContribution: Codable, Equatable, Sendable {
    let ceiling: Int
    let reason: String
}

struct FrescoObservedContext: Codable, Equatable, Sendable {
    let generation: String
    let locked: Bool
    let sleeping: Bool
    let onBattery: Bool
    let pauseWhenOccluded: Bool
    let displays: [FrescoObservedDisplay]
    let applications: [FrescoObservedApplication]
    let reasons: [FrescoReasonContribution]
}

struct FrescoEffectiveReasons: Codable, Equatable, Sendable {
    let paused: [String]
    let muted: [String]
    let hidden: [String]
    let fpsCeiling: [String]

    var isPaused: Bool { !paused.isEmpty }
    var isMuted: Bool { !muted.isEmpty }
    var isHidden: Bool { !hidden.isEmpty }
}

struct FrescoSpanViewport: Equatable, Sendable {
    let canvas: FrescoRect
    let display: FrescoRect
    let scale: Double

    var relativeFrame: FrescoRect {
        FrescoRect(
            x: display.x - canvas.x,
            y: display.y - canvas.y,
            width: display.width,
            height: display.height
        )
    }
}

struct FrescoEffectiveDisplay: Equatable, Sendable {
    let displayId: String
    let binding: FrescoBinding
    let layoutMode: FrescoLayout.Mode
    let profileId: String?
    let profileReasons: [String]
    let fpsCeiling: Int?
    let reasons: FrescoEffectiveReasons
    let spanViewport: FrescoSpanViewport?
}

struct FrescoEffectivePlan: Equatable, Sendable {
    let desiredRevision: Int
    let generation: String
    let layoutMode: FrescoLayout.Mode
    let profileId: String?
    let profileReasons: [String]
    let displays: [FrescoEffectiveDisplay]
}

enum FrescoStatePlanner {
    static func plan(state: FrescoState, observed: FrescoObservedContext) -> FrescoEffectivePlan {
        let canonicalConnected = observed.displays.filter(\.connected).sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            if $0.frame.x != $1.frame.x { return $0.frame.x < $1.frame.x }
            if $0.frame.y != $1.frame.y { return $0.frame.y < $1.frame.y }
            if $0.frame.width != $1.frame.width { return $0.frame.width < $1.frame.width }
            if $0.frame.height != $1.frame.height { return $0.frame.height < $1.frame.height }
            if $0.scale != $1.scale { return $0.scale < $1.scale }
            return !$0.occluded && $1.occluded
        }
        let connectedByID = Dictionary(
            canonicalConnected.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        let connected = connectedByID.values.sorted { $0.id < $1.id }
        let canvas = FrescoRect.union(connected.map(\.frame))
        let profiles = Dictionary(uniqueKeysWithValues: state.profiles.map { ($0.id, $0) })
        let matches = matchingRules(state.applicationRules, applications: observed.applications)
        let globalProfileRule = matches.last {
            $0.rule.scope == .global && $0.rule.effect.profileId != nil
                && $0.displayIds == nil
        }
        let planProfileId = globalProfileRule?.rule.effect.profileId ?? state.desired.profileId
        let planProfile = planProfileId.flatMap { profiles[$0] }
        let planProfileReason = globalProfileRule.map { "rule:\($0.rule.id)" }
            ?? (planProfileId == nil ? nil : "user")

        let displays = connected.map { display -> FrescoEffectiveDisplay in
            let applicable = matches.filter { $0.displayIds == nil || $0.displayIds?.contains(display.id) == true }
            let profileRule = applicable.last {
                $0.rule.scope == .global && $0.rule.effect.profileId != nil
            }
            let profileId = profileRule?.rule.effect.profileId ?? state.desired.profileId
            let profile = profileId.flatMap { profiles[$0] }
            let layout = state.desired.layout ?? profile?.layout ?? .clone(binding: .idle)
            let controls = state.desired.controls ?? profile?.controls ?? FrescoControls(paused: false, muted: false)
            let profileReason = profileRule.map { "rule:\($0.rule.id)" }
            let policyReason = profileReason ?? "user"
            let controlsReason = state.desired.controls == nil ? policyReason : "user"
            let fpsReason = state.desired.fpsCeiling == nil ? policyReason : "user"

            var paused = Set<String>()
            var muted = Set<String>()
            var hidden = Set<String>()
            var ceilings = [FrescoFPSContribution]()

            if controls.paused { paused.insert(controlsReason) }
            if controls.muted { muted.insert(controlsReason) }
            if let ceiling = state.desired.fpsCeiling ?? profile?.fpsCeiling {
                ceilings.append(FrescoFPSContribution(ceiling: ceiling, reason: fpsReason))
            }

            for match in applicable {
                let token = "rule:\(match.rule.id)"
                if match.rule.effect.paused == true { paused.insert(token) }
                if match.rule.effect.muted == true { muted.insert(token) }
                if let ceiling = match.rule.effect.fpsCeiling {
                    ceilings.append(FrescoFPSContribution(ceiling: ceiling, reason: token))
                }
            }

            if observed.locked {
                paused.insert("locked")
                muted.insert("locked")
                hidden.insert("locked")
            }
            if observed.sleeping {
                paused.insert("sleeping")
                muted.insert("sleeping")
                hidden.insert("sleeping")
            }
            if observed.pauseWhenOccluded && display.occluded { paused.insert("occluded") }

            for contribution in observed.reasons where contribution.displayId == nil || contribution.displayId == display.id {
                paused.formUnion(contribution.paused)
                muted.formUnion(contribution.muted)
                hidden.formUnion(contribution.hidden)
                ceilings.append(contentsOf: contribution.fpsCeilings)
            }

            let minimumCeiling = ceilings.map(\.ceiling).min()
            let ceilingReasons = minimumCeiling.map { minimum in
                Set(ceilings.filter { $0.ceiling == minimum }.map(\.reason)).sorted()
            } ?? []
            let viewport = layout.mode == .span
                ? canvas.map { FrescoSpanViewport(canvas: $0, display: display.frame, scale: display.scale) }
                : nil

            return FrescoEffectiveDisplay(
                displayId: display.id,
                binding: layout.binding(for: display.id),
                layoutMode: layout.mode,
                profileId: profileId,
                profileReasons: profileId == nil ? [] : [policyReason],
                fpsCeiling: minimumCeiling,
                reasons: FrescoEffectiveReasons(
                    paused: paused.sorted(),
                    muted: muted.sorted(),
                    hidden: hidden.sorted(),
                    fpsCeiling: ceilingReasons
                ),
                spanViewport: viewport
            )
        }

        return FrescoEffectivePlan(
            desiredRevision: state.revision,
            generation: observed.generation,
            layoutMode: displays.first?.layoutMode
                ?? state.desired.layout?.mode
                ?? planProfile?.layout.mode
                ?? .clone,
            profileId: displays.first?.profileId ?? planProfileId,
            profileReasons: displays.first?.profileReasons
                ?? planProfileReason.map { [$0] }
                ?? [],
            displays: displays
        )
    }

    private struct MatchingRule {
        let rule: FrescoApplicationRule
        let displayIds: Set<String>?
    }

    private static func matchingRules(
        _ rules: [FrescoApplicationRule],
        applications: [FrescoObservedApplication]
    ) -> [MatchingRule] {
        rules
            .filter(\.enabled)
            .sorted { lhs, rhs in
                lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority < rhs.priority
            }
            .compactMap { rule in
                let named = applications.filter { rule.match.bundleIds.contains($0.bundleId) }
                guard rule.match.running.accepts(named.contains(where: \.running)),
                      rule.match.frontmost.accepts(named.contains(where: \.frontmost)),
                      rule.match.fullscreen.accepts(named.contains(where: \.fullscreen)) else {
                    return nil
                }
                switch rule.scope {
                case .global:
                    return MatchingRule(rule: rule, displayIds: nil)
                case .affectedDisplays:
                    let affected = named.filter {
                        rule.match.running.accepts($0.running)
                            && rule.match.frontmost.accepts($0.frontmost)
                            && rule.match.fullscreen.accepts($0.fullscreen)
                    }
                    let displayIds = Set(affected.flatMap(\.displayIds))
                    return displayIds.isEmpty ? nil : MatchingRule(rule: rule, displayIds: displayIds)
                }
            }
    }
}
