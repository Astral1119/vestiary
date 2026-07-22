import Darwin
import Foundation

enum FrescoStateStoreError: Error, CustomStringConvertible {
    case invalidState(path: String, errors: [String])
    case invalidLastKnownGood(path: String, errors: [String])
    case revisionConflict(expected: Int, actual: Int)
    case writeFailed(path: String, error: String)

    var description: String {
        switch self {
        case let .invalidState(path, errors):
            return "invalid state at \(path):\n" + errors.joined(separator: "\n")
        case let .invalidLastKnownGood(path, errors):
            return "invalid last-known-good state at \(path):\n" + errors.joined(separator: "\n")
        case let .revisionConflict(expected, actual):
            return "state revision conflict: expected \(expected), found \(actual)"
        case let .writeFailed(path, error):
            return "state write failed at \(path): \(error)"
        }
    }
}

struct FrescoStateLoadResult {
    enum Source: Equatable {
        case state
        case migratedLegacy
        case lastKnownGood
    }

    let state: FrescoState
    let source: Source
    let diagnostics: [String]
}

struct FrescoStateStore {
    let directory: URL

    private var stateFile: URL { directory.appendingPathComponent("state.json") }
    private var lastKnownGoodFile: URL {
        directory.appendingPathComponent("state.last-known-good.json")
    }
    private var legacyFile: URL { directory.appendingPathComponent("current") }

    func load() throws -> FrescoStateLoadResult {
        if FileManager.default.fileExists(atPath: stateFile.path) {
            do {
                return FrescoStateLoadResult(
                    state: try decodeState(at: stateFile), source: .state, diagnostics: [])
            } catch let FrescoStateStoreError.invalidState(_, errors) {
                guard FileManager.default.fileExists(atPath: lastKnownGoodFile.path) else {
                    throw FrescoStateStoreError.invalidState(path: stateFile.path, errors: errors)
                }
                let recovered: FrescoState
                do {
                    recovered = try decodeLastKnownGood()
                } catch let FrescoStateStoreError.invalidLastKnownGood(_, backupErrors) {
                    throw FrescoStateStoreError.invalidState(
                        path: stateFile.path,
                        errors: errors + backupErrors.map { "last-known-good: " + $0 })
                }
                return FrescoStateLoadResult(
                    state: recovered, source: .lastKnownGood, diagnostics: errors)
            }
        }

        if FileManager.default.fileExists(atPath: lastKnownGoodFile.path) {
            return FrescoStateLoadResult(
                state: try decodeLastKnownGood(),
                source: .lastKnownGood,
                diagnostics: ["\(stateFile.path): authoritative state is missing"]
            )
        }

        return try migrateLegacy()
    }

    func replace(_ candidate: FrescoState, expectedRevision: Int) throws -> FrescoState {
        guard candidate.schemaVersion == 1 else {
            throw FrescoStateStoreError.invalidState(
                path: stateFile.path,
                errors: ["$.schemaVersion: expected constant 1"])
        }
        let current = try load().state
        guard current.revision == expectedRevision else {
            throw FrescoStateStoreError.revisionConflict(
                expected: expectedRevision, actual: current.revision)
        }
        let replacement = FrescoState(
            schemaVersion: 1,
            revision: current.revision + 1,
            updatedAt: Self.timestamp(),
            displays: candidate.displays,
            playlists: candidate.playlists,
            profiles: candidate.profiles,
            applicationRules: candidate.applicationRules,
            desired: candidate.desired
        )
        let data = try encodedValidatedState(replacement)
        try writeAcceptedState(data)
        return replacement
    }

    func selectClone(
        _ binding: FrescoBinding, expectedRevision: Int
    ) throws -> FrescoState {
        let acceptedBinding: Bool
        switch binding {
        case .wallpaper, .idle: acceptedBinding = true
        case .playlist: acceptedBinding = false
        }
        guard acceptedBinding else {
            throw FrescoStateStoreError.invalidState(
                path: stateFile.path,
                errors: ["$.desired.layout.binding: clone selection accepts wallpaper or idle"])
        }
        let current = try load().state
        guard current.revision == expectedRevision else {
            throw FrescoStateStoreError.revisionConflict(
                expected: expectedRevision, actual: current.revision)
        }
        let selectedProfile = current.desired.profileId.flatMap { profileID in
            current.profiles.first { $0.id == profileID }
        }
        let controls = current.desired.controls
            ?? selectedProfile?.controls
            ?? FrescoControls(paused: false, muted: false)
        let fpsCeiling = current.desired.fpsCeiling ?? selectedProfile?.fpsCeiling
        let candidate = FrescoState(
            schemaVersion: 1,
            revision: current.revision,
            updatedAt: current.updatedAt,
            displays: current.displays,
            playlists: current.playlists,
            profiles: current.profiles,
            applicationRules: current.applicationRules,
            desired: FrescoDesiredState(
                profileId: nil,
                layout: .clone(binding: binding),
                controls: controls,
                fpsCeiling: fpsCeiling))
        return try replace(candidate, expectedRevision: expectedRevision)
    }

    func setMuted(_ requested: Bool?, expectedRevision: Int) throws -> FrescoState {
        let current = try load().state
        guard current.revision == expectedRevision else {
            throw FrescoStateStoreError.revisionConflict(
                expected: expectedRevision, actual: current.revision)
        }
        let selectedProfile = current.desired.profileId.flatMap { profileID in
            current.profiles.first { $0.id == profileID }
        }
        let controls = current.desired.controls
            ?? selectedProfile?.controls
            ?? FrescoControls(paused: false, muted: false)
        let muted = requested ?? !controls.muted
        let candidate = FrescoState(
            schemaVersion: 1,
            revision: current.revision,
            updatedAt: current.updatedAt,
            displays: current.displays,
            playlists: current.playlists,
            profiles: current.profiles,
            applicationRules: current.applicationRules,
            desired: FrescoDesiredState(
                profileId: current.desired.profileId,
                layout: current.desired.layout,
                controls: FrescoControls(paused: controls.paused, muted: muted),
                fpsCeiling: current.desired.fpsCeiling))
        return try replace(candidate, expectedRevision: expectedRevision)
    }

    func writeLegacyProjection(_ binding: FrescoBinding?) throws {
        let value: String
        if case let .wallpaper(target)? = binding {
            value = target + "\n"
        } else {
            value = ""
        }
        try atomicWrite(Data(value.utf8), to: legacyFile)
    }

    func writeLegacyProjectionTarget(_ target: String?) throws {
        let value = target.map { $0 + "\n" } ?? ""
        try atomicWrite(Data(value.utf8), to: legacyFile)
    }

    private func migrateLegacy() throws -> FrescoStateLoadResult {
        let target = (try? String(contentsOf: legacyFile, encoding: .utf8))?
            .trimmingCharacters(in: .newlines) ?? ""
        let binding: FrescoBinding = target.isEmpty ? .idle : .wallpaper(target: target)
        let state = FrescoState(
            schemaVersion: 1,
            revision: 1,
            updatedAt: Self.timestamp(),
            displays: [],
            playlists: [],
            profiles: [],
            applicationRules: [],
            desired: FrescoDesiredState(
                profileId: nil,
                layout: .clone(binding: binding),
                controls: FrescoControls(paused: false, muted: false),
                fpsCeiling: nil
            )
        )
        let data = try encodedValidatedState(state)
        try writeAcceptedState(data)
        return FrescoStateLoadResult(
            state: state, source: .migratedLegacy, diagnostics: [])
    }

    private func decodeState(at url: URL) throws -> FrescoState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FrescoStateStoreError.invalidState(
                path: url.path, errors: ["$: unreadable JSON: \(error)"])
        }
        let errors = FrescoStateValidator.errors(in: data)
        guard errors.isEmpty else {
            throw FrescoStateStoreError.invalidState(path: url.path, errors: errors)
        }
        do {
            return try JSONDecoder().decode(FrescoState.self, from: data)
        } catch {
            throw FrescoStateStoreError.invalidState(
                path: url.path, errors: ["$: decoding failed: \(error)"])
        }
    }

    private func decodeLastKnownGood() throws -> FrescoState {
        do {
            return try decodeState(at: lastKnownGoodFile)
        } catch let FrescoStateStoreError.invalidState(_, errors) {
            throw FrescoStateStoreError.invalidLastKnownGood(
                path: lastKnownGoodFile.path, errors: errors)
        }
    }

    private func encodedValidatedState(_ state: FrescoState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(state)
        let errors = FrescoStateValidator.errors(in: data)
        guard errors.isEmpty else {
            throw FrescoStateStoreError.invalidState(path: stateFile.path, errors: errors)
        }
        return data + Data("\n".utf8)
    }

    private func writeAcceptedState(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try atomicWrite(data, to: stateFile)
        // The backup may lag, but it must never lead the authoritative file.
        // A backup refresh failure does not undo an accepted state transaction.
        try? atomicWrite(data, to: lastKnownGoodFile)
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(
                ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)

            let fileDescriptor = Darwin.open(temporary.path, O_RDONLY)
            guard fileDescriptor >= 0 else { throw POSIXFailure(operation: "open") }
            defer { Darwin.close(fileDescriptor) }
            guard Darwin.fsync(fileDescriptor) == 0 else {
                throw POSIXFailure(operation: "fsync")
            }
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw POSIXFailure(operation: "rename")
            }

            let directoryDescriptor = Darwin.open(
                destination.deletingLastPathComponent().path, O_RDONLY)
            guard directoryDescriptor >= 0 else {
                throw POSIXFailure(operation: "open directory")
            }
            defer { Darwin.close(directoryDescriptor) }
            guard Darwin.fsync(directoryDescriptor) == 0 else {
                throw POSIXFailure(operation: "fsync directory")
            }
        } catch {
            throw FrescoStateStoreError.writeFailed(
                path: destination.path, error: String(describing: error))
        }
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private struct POSIXFailure: Error, CustomStringConvertible {
    let operation: String
    let code = errno

    var description: String {
        "\(operation): \(String(cString: strerror(code)))"
    }
}

private enum FrescoStateValidator {
    static func errors(in data: Data) -> [String] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            return ["$: invalid JSON: \(error)"]
        }
        var validator = Validator()
        validator.validateState(value)
        return validator.errors
    }

    private struct Validator {
        var errors: [String] = []

        mutating func validateState(_ value: Any) {
            guard let state = object(
                value, path: "$",
                required: ["schemaVersion", "revision", "updatedAt", "displays",
                           "playlists", "profiles", "applicationRules", "desired"],
                allowed: ["schemaVersion", "revision", "updatedAt", "displays",
                          "playlists", "profiles", "applicationRules", "desired"])
            else { return }
            integer(state["schemaVersion"], path: "$.schemaVersion", minimum: 1, exact: 1)
            integer(state["revision"], path: "$.revision", minimum: 1)
            date(state["updatedAt"], path: "$.updatedAt")

            let displays = array(state["displays"], path: "$.displays") ?? []
            for (index, item) in displays.enumerated() {
                validateDisplay(item, path: "$.displays[\(index)]")
            }
            duplicateIDs(displays, label: "display", path: "$.displays")

            let playlists = array(state["playlists"], path: "$.playlists") ?? []
            for (index, item) in playlists.enumerated() {
                validatePlaylist(item, path: "$.playlists[\(index)]")
            }
            duplicateIDs(playlists, label: "playlist", path: "$.playlists")

            let profiles = array(state["profiles"], path: "$.profiles") ?? []
            for (index, item) in profiles.enumerated() {
                validateProfile(item, path: "$.profiles[\(index)]")
            }
            duplicateIDs(profiles, label: "profile", path: "$.profiles")

            let rules = array(state["applicationRules"], path: "$.applicationRules") ?? []
            for (index, item) in rules.enumerated() {
                validateRule(item, path: "$.applicationRules[\(index)]")
            }
            duplicateIDs(rules, label: "rule", path: "$.applicationRules")
            validateDesired(state["desired"], path: "$.desired")
            validateReferences(state)
        }

        mutating func validateDisplay(_ value: Any, path: String) {
            guard let item = object(value, path: path, required: ["id"], allowed: ["id", "name"])
            else { return }
            identifier(item["id"], path: path + ".id")
            if item["name"] != nil { nonemptyString(item["name"], path: path + ".name") }
        }

        mutating func validatePlaylist(_ value: Any, path: String) {
            guard let item = object(
                value, path: path,
                required: ["id", "name", "entries", "order", "repeat"],
                allowed: ["id", "name", "entries", "order", "repeat"])
            else { return }
            identifier(item["id"], path: path + ".id")
            nonemptyString(item["name"], path: path + ".name")
            oneOfString(item["order"], values: ["sequential", "shuffle"], path: path + ".order")
            boolean(item["repeat"], path: path + ".repeat")
            guard let entries = array(item["entries"], path: path + ".entries") else { return }
            if entries.isEmpty { errors.append(path + ".entries: expected at least one item") }
            for (index, entryValue) in entries.enumerated() {
                let entryPath = path + ".entries[\(index)]"
                guard let entry = object(
                    entryValue, path: entryPath,
                    required: ["id", "wallpaper", "durationSeconds"],
                    allowed: ["id", "wallpaper", "durationSeconds"])
                else { continue }
                identifier(entry["id"], path: entryPath + ".id")
                validateBinding(entry["wallpaper"], path: entryPath + ".wallpaper", wallpaperOnly: true)
                integer(entry["durationSeconds"], path: entryPath + ".durationSeconds", minimum: 1)
            }
            duplicateIDs(entries, label: "entry", path: path + ".entries")
        }

        mutating func validateProfile(_ value: Any, path: String) {
            guard let item = object(
                value, path: path,
                required: ["id", "name", "layout", "controls"],
                allowed: ["id", "name", "layout", "controls", "fpsCeiling"])
            else { return }
            identifier(item["id"], path: path + ".id")
            nonemptyString(item["name"], path: path + ".name")
            validateLayout(item["layout"], path: path + ".layout")
            validateControls(item["controls"], path: path + ".controls")
            if item["fpsCeiling"] != nil {
                integer(
                    item["fpsCeiling"], path: path + ".fpsCeiling",
                    minimum: 1, maximum: 240)
            }
        }

        mutating func validateRule(_ value: Any, path: String) {
            guard let item = object(
                value, path: path,
                required: ["id", "enabled", "priority", "match", "scope", "effect"],
                allowed: ["id", "enabled", "priority", "match", "scope", "effect"])
            else { return }
            identifier(item["id"], path: path + ".id")
            boolean(item["enabled"], path: path + ".enabled")
            integer(item["priority"], path: path + ".priority")

            if let match = object(
                item["match"], path: path + ".match",
                required: ["bundleIds", "running", "frontmost", "fullscreen"],
                allowed: ["bundleIds", "running", "frontmost", "fullscreen"])
            {
                if let bundleIDs = array(match["bundleIds"], path: path + ".match.bundleIds") {
                    if bundleIDs.isEmpty {
                        errors.append(path + ".match.bundleIds: expected at least one item")
                    }
                    for (index, bundleID) in bundleIDs.enumerated() {
                        identifier(bundleID, path: path + ".match.bundleIds[\(index)]")
                    }
                    duplicateStrings(bundleIDs, path: path + ".match.bundleIds")
                }
                for key in ["running", "frontmost", "fullscreen"] {
                    oneOfString(
                        match[key], values: ["ignore", "require", "exclude"],
                        path: path + ".match." + key)
                }
            }

            var affected = false
            if let scope = object(
                item["scope"], path: path + ".scope",
                required: ["kind"], allowed: ["kind"])
            {
                oneOfString(
                    scope["kind"], values: ["global", "affectedDisplays"],
                    path: path + ".scope.kind")
                affected = scope["kind"] as? String == "affectedDisplays"
            }
            let effectAllowed = affected
                ? ["paused", "muted", "fpsCeiling"]
                : ["profileId", "paused", "muted", "fpsCeiling"]
            if let effect = object(
                item["effect"], path: path + ".effect",
                required: [], allowed: Set(effectAllowed))
            {
                if effect.isEmpty { errors.append(path + ".effect: expected at least one property") }
                if effect["profileId"] != nil {
                    identifier(effect["profileId"], path: path + ".effect.profileId")
                }
                for key in ["paused", "muted"] where effect[key] != nil {
                    constantTrue(effect[key], path: path + ".effect." + key)
                }
                if effect["fpsCeiling"] != nil {
                    integer(
                        effect["fpsCeiling"], path: path + ".effect.fpsCeiling",
                        minimum: 1, maximum: 240)
                }
            }
        }

        mutating func validateDesired(_ value: Any?, path: String) {
            guard let item = object(
                value, path: path, required: [],
                allowed: ["profileId", "layout", "controls", "fpsCeiling"])
            else { return }
            let hasProfile = item["profileId"] != nil
            let hasDirect = item["layout"] != nil && item["controls"] != nil
            if !hasProfile && !hasDirect {
                errors.append(path + ": expected profileId or layout and controls")
            }
            if item["profileId"] != nil {
                identifier(item["profileId"], path: path + ".profileId")
            }
            if item["layout"] != nil { validateLayout(item["layout"], path: path + ".layout") }
            if item["controls"] != nil { validateControls(item["controls"], path: path + ".controls") }
            if item["fpsCeiling"] != nil {
                integer(
                    item["fpsCeiling"], path: path + ".fpsCeiling",
                    minimum: 1, maximum: 240)
            }
        }

        mutating func validateControls(_ value: Any?, path: String) {
            guard let item = object(
                value, path: path, required: ["paused", "muted"], allowed: ["paused", "muted"])
            else { return }
            boolean(item["paused"], path: path + ".paused")
            boolean(item["muted"], path: path + ".muted")
        }

        mutating func validateLayout(_ value: Any?, path: String) {
            guard let untyped = value as? [String: Any], let mode = untyped["mode"] as? String else {
                _ = object(value, path: path, required: ["mode"], allowed: ["mode"])
                return
            }
            switch mode {
            case "clone", "span":
                guard let item = object(
                    value, path: path, required: ["mode", "binding"],
                    allowed: ["mode", "binding"])
                else { return }
                validateBinding(item["binding"], path: path + ".binding")
            case "perDisplay":
                guard let item = object(
                    value, path: path, required: ["mode", "assignments"],
                    allowed: ["mode", "assignments", "defaultBinding"])
                else { return }
                if let assignments = array(item["assignments"], path: path + ".assignments") {
                    for (index, value) in assignments.enumerated() {
                        let assignmentPath = path + ".assignments[\(index)]"
                        guard let assignment = object(
                            value, path: assignmentPath,
                            required: ["displayId", "binding"],
                            allowed: ["displayId", "binding"])
                        else { continue }
                        identifier(assignment["displayId"], path: assignmentPath + ".displayId")
                        validateBinding(assignment["binding"], path: assignmentPath + ".binding")
                    }
                    duplicateField(
                        assignments, field: "displayId", label: "display",
                        path: path + ".assignments")
                }
                if item["defaultBinding"] != nil {
                    validateBinding(item["defaultBinding"], path: path + ".defaultBinding")
                }
            default:
                errors.append(path + ".mode: value is outside the enum")
            }
        }

        mutating func validateBinding(
            _ value: Any?, path: String, wallpaperOnly: Bool = false
        ) {
            guard let untyped = value as? [String: Any], let kind = untyped["kind"] as? String else {
                _ = object(value, path: path, required: ["kind"], allowed: ["kind"])
                return
            }
            switch kind {
            case "wallpaper":
                guard let item = object(
                    value, path: path, required: ["kind", "target"],
                    allowed: ["kind", "target"])
                else { return }
                nonemptyString(item["target"], path: path + ".target")
            case "playlist" where !wallpaperOnly:
                guard let item = object(
                    value, path: path, required: ["kind", "playlistId"],
                    allowed: ["kind", "playlistId"])
                else { return }
                identifier(item["playlistId"], path: path + ".playlistId")
            case "idle" where !wallpaperOnly:
                _ = object(value, path: path, required: ["kind"], allowed: ["kind"])
            default:
                errors.append(path + ".kind: value is outside the supported binding kinds")
            }
        }

        mutating func validateReferences(_ state: [String: Any]) {
            let displays = (state["displays"] as? [[String: Any]]) ?? []
            let playlists = (state["playlists"] as? [[String: Any]]) ?? []
            let profiles = (state["profiles"] as? [[String: Any]]) ?? []
            let rules = (state["applicationRules"] as? [[String: Any]]) ?? []
            let displayIDs = Set(displays.compactMap { $0["id"] as? String })
            let playlistIDs = Set(playlists.compactMap { $0["id"] as? String })
            let profileIDs = Set(profiles.compactMap { $0["id"] as? String })

            for (index, profile) in profiles.enumerated() {
                validateLayoutReferences(
                    profile["layout"], path: "$.profiles[\(index)].layout",
                    displayIDs: displayIDs, playlistIDs: playlistIDs)
            }
            for (index, rule) in rules.enumerated() {
                if let profileID = (rule["effect"] as? [String: Any])?["profileId"] as? String,
                   !profileIDs.contains(profileID) {
                    errors.append("$.applicationRules[\(index)]: unknown profile ID '\(profileID)'")
                }
            }
            if let desired = state["desired"] as? [String: Any] {
                if let profileID = desired["profileId"] as? String,
                   !profileIDs.contains(profileID) {
                    errors.append("$.desired: unknown profile ID '\(profileID)'")
                }
                if let layout = desired["layout"] {
                    validateLayoutReferences(
                        layout, path: "$.desired.layout",
                        displayIDs: displayIDs, playlistIDs: playlistIDs)
                }
            }
        }

        mutating func validateLayoutReferences(
            _ value: Any?, path: String, displayIDs: Set<String>, playlistIDs: Set<String>
        ) {
            guard let layout = value as? [String: Any] else { return }
            if layout["mode"] as? String == "perDisplay" {
                for (index, assignment) in ((layout["assignments"] as? [[String: Any]]) ?? []).enumerated() {
                    if let displayID = assignment["displayId"] as? String,
                       !displayIDs.contains(displayID) {
                        errors.append("\(path).assignments[\(index)]: unknown display ID '\(displayID)'")
                    }
                    validateBindingReference(
                        assignment["binding"], path: "\(path).assignments[\(index)].binding",
                        playlistIDs: playlistIDs)
                }
                validateBindingReference(
                    layout["defaultBinding"], path: path + ".defaultBinding",
                    playlistIDs: playlistIDs)
            } else {
                validateBindingReference(
                    layout["binding"], path: path + ".binding", playlistIDs: playlistIDs)
            }
        }

        mutating func validateBindingReference(
            _ value: Any?, path: String, playlistIDs: Set<String>
        ) {
            guard let binding = value as? [String: Any],
                  binding["kind"] as? String == "playlist",
                  let playlistID = binding["playlistId"] as? String,
                  !playlistIDs.contains(playlistID) else { return }
            errors.append("\(path): unknown playlist ID '\(playlistID)'")
        }

        mutating func object(
            _ value: Any?, path: String, required: Set<String>, allowed: Set<String>
        ) -> [String: Any]? {
            guard let value = value as? [String: Any] else {
                errors.append(path + ": expected object")
                return nil
            }
            for key in required.sorted() where value[key] == nil {
                errors.append(path + ": missing required property '\(key)'")
            }
            for key in value.keys.sorted() where !allowed.contains(key) {
                errors.append(path + ": additional property '\(key)'")
            }
            return value
        }

        mutating func array(_ value: Any?, path: String) -> [Any]? {
            guard let value = value as? [Any] else {
                errors.append(path + ": expected array")
                return nil
            }
            return value
        }

        mutating func identifier(_ value: Any?, path: String) {
            guard let value = value as? String, !value.isEmpty,
                  value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                errors.append(path + ": expected nonempty ID without whitespace")
                return
            }
        }

        mutating func nonemptyString(_ value: Any?, path: String) {
            guard let value = value as? String, !value.isEmpty else {
                errors.append(path + ": expected nonempty string")
                return
            }
        }

        mutating func date(_ value: Any?, path: String) {
            guard let value = value as? String else {
                errors.append(path + ": expected ISO 8601 date-time")
                return
            }
            let standard = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard standard.date(from: value) != nil || fractional.date(from: value) != nil else {
                errors.append(path + ": expected ISO 8601 date-time")
                return
            }
        }

        mutating func integer(
            _ value: Any?, path: String, minimum: Int? = nil,
            maximum: Int? = nil, exact: Int? = nil
        ) {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !CFNumberIsFloatType(number) else {
                errors.append(path + ": expected integer")
                return
            }
            let integer = number.intValue
            if let exact, integer != exact { errors.append(path + ": expected constant \(exact)") }
            if let minimum, integer < minimum { errors.append(path + ": value is below minimum \(minimum)") }
            if let maximum, integer > maximum { errors.append(path + ": value is above maximum \(maximum)") }
        }

        mutating func boolean(_ value: Any?, path: String) {
            guard let value = value as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else {
                errors.append(path + ": expected boolean")
                return
            }
        }

        mutating func constantTrue(_ value: Any?, path: String) {
            boolean(value, path: path)
            if let value = value as? NSNumber,
               CFGetTypeID(value) == CFBooleanGetTypeID(), !value.boolValue {
                errors.append(path + ": expected constant true")
            }
        }

        mutating func oneOfString(_ value: Any?, values: Set<String>, path: String) {
            guard let value = value as? String, values.contains(value) else {
                errors.append(path + ": value is outside the enum")
                return
            }
        }

        mutating func duplicateIDs(_ values: [Any], label: String, path: String) {
            duplicateField(values, field: "id", label: label, path: path)
        }

        mutating func duplicateField(
            _ values: [Any], field: String, label: String, path: String
        ) {
            let identities = values.compactMap { ($0 as? [String: Any])?[field] as? String }
            for identity in Set(identities).sorted()
                where identities.filter({ $0 == identity }).count > 1 {
                errors.append("\(path): duplicate \(label) ID '\(identity)'")
            }
        }

        mutating func duplicateStrings(_ values: [Any], path: String) {
            let strings = values.compactMap { $0 as? String }
            if strings.count != Set(strings).count {
                errors.append(path + ": duplicate items")
            }
        }
    }
}
