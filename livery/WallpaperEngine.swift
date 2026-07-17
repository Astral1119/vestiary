import AppKit
import Darwin
import Foundation

private let defaultStorePath = NSString(
    string: "~/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
).expandingTildeInPath

private struct ScreenStatus: Codable {
    let displayID: UInt32
    let displayName: String
    let imagePath: String?
}

private struct StoreStatus: Codable {
    let scope: String
    let provider: String?
    let assetID: String?
    let imagePath: String?
    let spaceOverrideCount: Int
    let displayOverrideCount: Int
    let screens: [ScreenStatus]
}

private enum EngineError: LocalizedError {
    case usage
    case missingFile(String)
    case invalidStore(String)
    case unsupportedScope(Int, Int)
    case liveStoreRequired
    case verificationFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: livery-wallpaper-engine status | snapshot <destination> | apply-global <image> | restore <snapshot> | verify-global <image>"
        case .missingFile(let path):
            return "file does not exist: \(path)"
        case .invalidStore(let reason):
            return "invalid wallpaper store: \(reason)"
        case .unsupportedScope(let spaces, let displays):
            return "wallpaper store is not global (\(spaces) Space overrides, \(displays) display overrides); enable Show on all Spaces first"
        case .liveStoreRequired:
            return "this operation requires the live macOS wallpaper store"
        case .verificationFailed(let reason):
            return "wallpaper verification failed: \(reason)"
        case .commandFailed(let command):
            return "command failed: \(command)"
        }
    }
}

private func storeURL() -> URL {
    let path = ProcessInfo.processInfo.environment["LIVERY_WALLPAPER_STORE"] ?? defaultStorePath
    return URL(fileURLWithPath: path).standardizedFileURL
}

private func isLiveStore(_ url: URL) -> Bool {
    url.path == URL(fileURLWithPath: defaultStorePath).standardizedFileURL.path
}

private func loadStore(at url: URL) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw EngineError.missingFile(url.path)
    }
    let data = try Data(contentsOf: url)
    var format = PropertyListSerialization.PropertyListFormat.binary
    guard let value = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: &format
    ) as? [String: Any] else {
        throw EngineError.invalidStore("top level is not a dictionary")
    }
    return value
}

private func dictionary(_ value: Any?) -> [String: Any] {
    value as? [String: Any] ?? [:]
}

private func array(_ value: Any?) -> [Any] {
    value as? [Any] ?? []
}

private func nested(_ root: [String: Any], _ keys: String...) -> Any? {
    var value: Any = root
    for key in keys {
        guard let next = (value as? [String: Any])?[key] else { return nil }
        value = next
    }
    return value
}

private func globalChoice(in store: [String: Any]) -> [String: Any]? {
    let choices = array(nested(
        store,
        "AllSpacesAndDisplays", "Desktop", "Content", "Choices"
    ))
    return choices.first as? [String: Any]
}

private func decodedConfiguration(from choice: [String: Any]) -> [String: Any] {
    guard let data = choice["Configuration"] as? Data,
          let value = try? PropertyListSerialization.propertyList(
              from: data,
              options: [],
              format: nil
          ) as? [String: Any]
    else {
        return [:]
    }
    return value
}

private func configurationImagePath(from configuration: [String: Any]) -> String? {
    let urlDictionary = dictionary(configuration["url"])
    guard let relative = urlDictionary["relative"] as? String,
          let url = URL(string: relative),
          url.isFileURL
    else {
        return nil
    }
    return url.standardizedFileURL.path
}

private func displayID(for screen: NSScreen) -> UInt32? {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
}

@MainActor
private func inspectStore(at url: URL) throws -> StoreStatus {
    let store = try loadStore(at: url)
    let spaces = dictionary(store["Spaces"])
    let displays = dictionary(store["Displays"])
    let choice = globalChoice(in: store)
    let configuration = choice.map(decodedConfiguration) ?? [:]
    let scope = choice != nil && spaces.isEmpty && displays.isEmpty ? "global" : "overrides"
    let screens = NSScreen.screens.compactMap { screen -> ScreenStatus? in
        guard let id = displayID(for: screen) else { return nil }
        return ScreenStatus(
            displayID: id,
            displayName: screen.localizedName,
            imagePath: NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL.path
        )
    }
    return StoreStatus(
        scope: scope,
        provider: choice?["Provider"] as? String,
        assetID: configuration["assetID"] as? String,
        imagePath: configurationImagePath(from: configuration),
        spaceOverrideCount: spaces.count,
        displayOverrideCount: displays.count,
        screens: screens
    )
}

private func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data([10]))
}

private func snapshotStore(from source: URL, to destination: URL) throws {
    _ = try loadStore(at: source)
    let data = try Data(contentsOf: source)
    try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: destination, options: .atomic)
    _ = try loadStore(at: destination)
}

private func strippedStoreValue(_ value: Any) -> Any {
    if let dictionary = value as? [String: Any] {
        return dictionary.reduce(into: [String: Any]()) { result, entry in
            if entry.key != "LastSet" && entry.key != "LastUse" {
                result[entry.key] = strippedStoreValue(entry.value)
            }
        }
    }
    if let array = value as? [Any] {
        return array.map(strippedStoreValue)
    }
    return value
}

private func wallpaperSemantics(_ store: [String: Any]) -> NSDictionary {
    let keys = ["AllSpacesAndDisplays", "Displays", "Spaces", "SystemDefault"]
    let selected = keys.reduce(into: [String: Any]()) { result, key in
        if let value = store[key] {
            result[key] = strippedStoreValue(value)
        }
    }
    return selected as NSDictionary
}

private func matchingDesktop(
    in value: Any,
    imagePath expectedPath: String
) -> [String: Any]? {
    if let dictionary = value as? [String: Any] {
        let choices = array(nested(dictionary, "Content", "Choices"))
        if let choice = choices.first as? [String: Any],
           configurationImagePath(from: decodedConfiguration(from: choice)) == expectedPath {
            return dictionary
        }
        for child in dictionary.values {
            if let match = matchingDesktop(in: child, imagePath: expectedPath) {
                return match
            }
        }
    } else if let array = value as? [Any] {
        for child in array {
            if let match = matchingDesktop(in: child, imagePath: expectedPath) {
                return match
            }
        }
    }
    return nil
}

private func writeStore(_ store: [String: Any], to url: URL) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: store,
        format: .binary,
        options: 0
    )
    try data.write(to: url, options: .atomic)
}

private func normalizeGlobalStore(
    _ store: [String: Any],
    imagePath: String
) throws -> [String: Any] {
    guard let desktop = matchingDesktop(in: store, imagePath: imagePath) else {
        throw EngineError.verificationFailed(
            "WallpaperAgent did not generate an image choice for \(imagePath)"
        )
    }

    var normalized = store
    var allSpaces = dictionary(normalized["AllSpacesAndDisplays"])
    allSpaces["Desktop"] = desktop
    allSpaces["Type"] = "individual"
    normalized["AllSpacesAndDisplays"] = allSpaces

    var systemDefault = dictionary(normalized["SystemDefault"])
    systemDefault["Desktop"] = desktop
    systemDefault["Type"] = "individual"
    normalized["SystemDefault"] = systemDefault
    normalized["Spaces"] = [String: Any]()
    normalized["Displays"] = [String: Any]()
    return normalized
}

private func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw EngineError.commandFailed(([executable] + arguments).joined(separator: " "))
    }
}

private func restartWallpaperAgent() throws {
    try run(
        "/bin/launchctl",
        ["kickstart", "-k", "gui/\(getuid())/com.apple.wallpaper.agent"]
    )
}

private func waitForStore(
    at url: URL,
    timeout: TimeInterval = 8,
    predicate: ([String: Any]) throws -> Bool
) throws {
    let deadline = Date().addingTimeInterval(timeout)
    var lastError: Error?
    repeat {
        do {
            if try predicate(loadStore(at: url)) { return }
        } catch {
            lastError = error
        }
        Thread.sleep(forTimeInterval: 0.2)
    } while Date() < deadline
    if let lastError {
        throw EngineError.verificationFailed(lastError.localizedDescription)
    }
    throw EngineError.verificationFailed("timed out waiting for WallpaperAgent")
}

@MainActor
private func applyGlobal(imagePath: String, store: URL) throws {
    guard isLiveStore(store) else { throw EngineError.liveStoreRequired }
    guard FileManager.default.fileExists(atPath: imagePath) else {
        throw EngineError.missingFile(imagePath)
    }
    let originalData = try Data(contentsOf: store)
    let imageURL = URL(fileURLWithPath: imagePath).standardizedFileURL
    do {
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: [:])
        }

        try waitForStore(at: store) { value in
            matchingDesktop(in: value, imagePath: imageURL.path) != nil
        }
        let generated = try loadStore(at: store)
        let normalized = try normalizeGlobalStore(generated, imagePath: imageURL.path)
        try writeStore(normalized, to: store)
        try restartWallpaperAgent()
        try waitForStore(at: store) { value in
            let spaces = dictionary(value["Spaces"])
            let displays = dictionary(value["Displays"])
            guard spaces.isEmpty, displays.isEmpty,
                  let choice = globalChoice(in: value)
            else {
                return false
            }
            return configurationImagePath(from: decodedConfiguration(from: choice)) == imageURL.path
        }
    } catch {
        try? originalData.write(to: store, options: .atomic)
        try? restartWallpaperAgent()
        throw error
    }
}

private func restoreStore(from snapshot: URL, to store: URL) throws {
    let expected = try loadStore(at: snapshot)
    let data = try Data(contentsOf: snapshot)
    try data.write(to: store, options: .atomic)
    if isLiveStore(store) {
        try restartWallpaperAgent()
        try waitForStore(at: store) { value in
            wallpaperSemantics(value).isEqual(wallpaperSemantics(expected))
        }
    } else {
        let restored = try loadStore(at: store)
        guard wallpaperSemantics(restored).isEqual(wallpaperSemantics(expected)) else {
            throw EngineError.verificationFailed("restored fixture differs from its snapshot")
        }
    }
}

@MainActor
private func verifyGlobal(imagePath: String, store: URL) throws {
    let status = try inspectStore(at: store)
    let expected = URL(fileURLWithPath: imagePath).standardizedFileURL.path
    guard status.scope == "global" else {
        throw EngineError.unsupportedScope(
            status.spaceOverrideCount,
            status.displayOverrideCount
        )
    }
    guard status.imagePath == expected else {
        throw EngineError.verificationFailed(
            "expected \(expected), found \(status.imagePath ?? "no image path")"
        )
    }
}

@main
private enum LiveryWallpaperEngine {
    @MainActor
    static func main() {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count >= 2 else { throw EngineError.usage }
            let store = storeURL()
            switch arguments[1] {
            case "status" where arguments.count == 2:
                try writeJSON(inspectStore(at: store))
            case "snapshot" where arguments.count == 3:
                try snapshotStore(
                    from: store,
                    to: URL(fileURLWithPath: arguments[2]).standardizedFileURL
                )
            case "apply-global" where arguments.count == 3:
                try applyGlobal(imagePath: arguments[2], store: store)
            case "restore" where arguments.count == 3:
                try restoreStore(
                    from: URL(fileURLWithPath: arguments[2]).standardizedFileURL,
                    to: store
                )
            case "verify-global" where arguments.count == 3:
                try verifyGlobal(imagePath: arguments[2], store: store)
            default:
                throw EngineError.usage
            }
        } catch {
            fputs("livery-wallpaper-engine: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
