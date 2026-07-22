import AppKit
import Carbon
import WebKit
import AVFoundation
import CryptoKit
import JavaScriptCore
import Darwin
import notify

// Phase-1 live-wallpaper runtime: desktop-level
// per-display windows playing Wallpaper Engine video and web wallpapers,
// with the WE JavaScript API shimmed natively — audio via a Cava system
// tap, cursor forwarding, occlusion-pause, and Livery Look colors pushed
// as WE user properties.

// MARK: - Runtime paths (daemon mode)

let runtimeDirectory = URL(fileURLWithPath:
    ProcessInfo.processInfo.environment["FRESCO_STATE_DIR"]
        ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config/fresco"))
let configFile = runtimeDirectory.appendingPathComponent("current")
let pidFile = runtimeDirectory.appendingPathComponent("pid")
let reposeCommandFile = runtimeDirectory.appendingPathComponent("repose-command")
let reposeStateFile = runtimeDirectory.appendingPathComponent("repose.json")
let scenesDirectory = runtimeDirectory.appendingPathComponent("scenes")
let propertyStateDirectory = runtimeDirectory.appendingPathComponent("properties")
let sceneHelperFile = runtimeDirectory.appendingPathComponent("bin/fresco-scene")
let sceneAssetsFile = runtimeDirectory.appendingPathComponent("scene-assets")
let workshopContentDirectory = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/Steam/steamapps/workshop/content/431960")

func configuredWallpaperPath() -> String? {
    guard let path = try? String(contentsOf: configFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
    return path
}

func configuredSceneAssetPath() -> String? {
    guard let path = try? String(contentsOf: sceneAssetsFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
    return path
}

func loadConfiguredWallpaper() -> Wallpaper? {
    configuredWallpaperPath().flatMap(resolveWallpaper)
}

func resolveStateWallpaper(_ target: String) -> Wallpaper? {
    if let wallpaper = resolveStateWallpaperExact(target) { return wallpaper }
    guard !(target as NSString).isAbsolutePath,
          let projection = configuredWallpaperPath() else { return nil }
    return resolveWallpaper(projection)
}

func resolveStateWallpaperExact(_ target: String) -> Wallpaper? {
    if target.allSatisfy(\.isNumber) && !target.isEmpty {
        return resolveWallpaper(workshopContentDirectory.appendingPathComponent(target).path)
    }
    return resolveWallpaper(target)
}

// MARK: - Repose state (the single selection record — see HANDOFF
// "Selection model": every picker is a thin writer over this file)

struct ReposeState {
    var look = "zephyr"
    var scene = "desktop"
    var viz = "strings"
    var variant = "quiet"
    var grade = "on"
    var night = "off"
    var pixels = "on"
    var label = "on"
    var scenePool: [String] = []

    static func load() -> ReposeState {
        var state = ReposeState()
        guard let data = try? Data(contentsOf: reposeStateFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return state }
        if let value = object["look"] as? String { state.look = value }
        if let value = object["scene"] as? String { state.scene = value }
        if let value = object["viz"] as? String { state.viz = value }
        if let value = object["variant"] as? String { state.variant = value }
        if let value = object["grade"] as? String { state.grade = value }
        if let value = object["night"] as? String { state.night = value }
        if let value = object["pixels"] as? String { state.pixels = value }
        if let value = object["label"] as? String { state.label = value }
        if let value = object["scenePool"] as? [String] { state.scenePool = value }
        state.reconcileScene()
        return state
    }

    func save() {
        let object: [String: Any] = ["look": look, "scene": scene, "viz": viz,
                                     "variant": variant,
                                     "grade": grade, "night": night, "pixels": pixels,
                                     "label": label, "scenePool": scenePool]
        if let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reposeStateFile)
        }
    }

    // the scene's display name (the backdrop itself is runtime-side)
    var sceneName: String {
        scene == "desktop" ? "desktop"
            : ((scene as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    mutating func reconcileScene() {
        let rotation = reposeRotation(scenePool)
        if !rotation.contains(scene), let first = rotation.first {
            scene = first
        }
    }

    // the record as WE user properties
    var properties: [String: Any] {
        ["reposelook": ["value": look],
         "reposeviz": ["value": viz],
         "reposevariant": ["value": variant],
         "reposegrade": ["value": grade],
         "reposenight": ["value": night],
         "reposepixels": ["value": pixels],
         "reposescene": ["value": sceneName],
         "reposelabel": ["value": label]]
    }
}

// The scene library both pickers iterate: the implicit desktop mirror plus
// everything in scenes/ (videos, WE project dirs, or symlinks to either).
func sceneLibrary() -> [String] {
    var library = ["desktop"]
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: scenesDirectory.path)) ?? []
    for entry in entries.sorted() where !entry.hasPrefix(".") {
        let path = scenesDirectory.appendingPathComponent(entry).path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
        if isDirectory.boolValue {
            if FileManager.default.fileExists(atPath: path + "/project.json") {
                library.append(path)
            }
        } else if ["mp4", "mov", "m4v"].contains((entry as NSString).pathExtension.lowercased()) {
            library.append(path)
        }
    }
    return library
}

func reposeSceneID(_ scene: String) -> String {
    scene == "desktop" ? "desktop" : (scene as NSString).lastPathComponent
}

// An absent pool preserves the pre-pool behavior (all catalog scenes in
// deterministic order). Explicit pools are ordered, de-duplicated, and
// filtered against the current catalog without mutating that catalog.
func reposeRotation(_ scenePool: [String]) -> [String] {
    let library = sceneLibrary()
    guard !scenePool.isEmpty else { return library }
    let byID = Dictionary(uniqueKeysWithValues: library.map { (reposeSceneID($0), $0) })
    var seen = Set<String>()
    let rotation = scenePool.compactMap { sceneID -> String? in
        guard seen.insert(sceneID).inserted else { return nil }
        return byID[sceneID]
    }
    return rotation.isEmpty ? ["desktop"] : rotation
}

func jsonString(_ object: [String: Any]) -> String {
    (try? JSONSerialization.data(withJSONObject: object))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

func jsonFragmentString(_ object: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
}

// Per-scene theme sidecar (qylock precedent: each scene carries its own
// palette). `<scene minus extension>.theme.json` holds hex roles that
// override the Livery Look while that scene is up.
func sceneThemeProperties(_ scene: String) -> [String: Any] {
    guard scene != "desktop", !scene.isEmpty else { return [:] }
    let base = (scene as NSString).deletingPathExtension
    let sidecar = URL(fileURLWithPath: base + ".theme.json")
    guard let data = try? Data(contentsOf: sidecar),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    var properties: [String: Any] = [:]
    for role in ["primary", "secondary", "tertiary", "surface", "background",
                 "text", "textmuted", "attention", "success", "viz1", "viz2"] {
        if let color = weColor(hexString(object[role])) {
            properties["livery" + role] = color
        }
    }
    if let color = weColor(hexString(object["primary"])) {
        properties["schemecolor"] = color
    }
    return properties
}

// MARK: - Shell helper

@discardableResult
func shell(_ arguments: [String]) -> (status: Int32, stdout: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    // launchd agents get a bare PATH; brew-installed helpers (media-control,
    // tmux, sketchybar) must still resolve.
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
    process.environment = environment
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()
    do { try process.run() } catch { return (127, "") }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Wallpaper resolution

enum Wallpaper {
    case image(URL)
    case video(URL)
    case web(index: URL, root: URL, properties: [String: Any])
    case scene(
        root: URL,
        package: URL,
        preview: URL?,
        properties: [String: Any],
        runtimePropertyNames: Set<String>
    )
}

func overlayProperty(_ value: Any, forKey key: String,
                     in properties: inout [String: Any]) {
    var definition = properties[key] as? [String: Any] ?? [:]
    if let override = value as? [String: Any] {
        for (field, fieldValue) in override { definition[field] = fieldValue }
    } else {
        definition["value"] = value
    }
    properties[key] = definition
}

func resolvePresetAsset(_ value: Any, definition: [String: Any]?, root: URL) -> Any {
    guard let definition,
          let type = (definition["type"] as? String)?.lowercased(),
          type == "file" || type == "directory" else { return value }

    if var override = value as? [String: Any] {
        if let nestedValue = override["value"] {
            override["value"] = resolvePresetAsset(
                nestedValue, definition: definition, root: root)
        }
        return override
    }

    guard let rawPath = value as? String, !rawPath.isEmpty else { return value }
    let expanded = (rawPath as NSString).expandingTildeInPath
    guard !(expanded as NSString).isAbsolutePath else { return value }
    let candidate = root.appendingPathComponent(
        expanded.replacingOccurrences(of: "\\", with: "/")
    ).standardizedFileURL
    guard FileManager.default.fileExists(atPath: candidate.path) else { return value }
    return candidate.path
}

func standardizedWallpaperURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

func propertyStateID(for path: String) -> String {
    let standardizedPath = standardizedWallpaperURL(path).path
    let basename = (standardizedPath as NSString).lastPathComponent
    if !basename.isEmpty && basename.allSatisfy({ $0.isNumber }) { return basename }
    var hash: UInt64 = 14695981039346656037
    for byte in standardizedPath.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1099511628211
    }
    return String(format: "path-%016llx", hash)
}

func propertyStateURL(for path: String) -> URL {
    propertyStateDirectory.appendingPathComponent(propertyStateID(for: path) + ".json")
}

func persistedPropertyValues(for path: String) -> [String: Any] {
    let url = propertyStateURL(for: path)
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object["values"] as? [String: Any] ?? [:]
}

func webPropertyStateID(for path: String) -> String { propertyStateID(for: path) }
func webPropertyStateURL(for path: String) -> URL { propertyStateURL(for: path) }
func persistedWebPropertyValues(for path: String) -> [String: Any] {
    persistedPropertyValues(for: path)
}

func propertyKey(_ requestedKey: String, in properties: [String: Any]) -> String {
    if properties[requestedKey] != nil { return requestedKey }
    let lowercaseKey = requestedKey.lowercased()
    return properties.keys.first { $0.lowercased() == lowercaseKey } ?? requestedKey
}

func applyPropertyValues(_ values: [String: Any], to properties: inout [String: Any]) {
    for (key, value) in values {
        let resolvedKey = propertyKey(key, in: properties)
        guard properties[resolvedKey] != nil else { continue }
        overlayProperty(value, forKey: resolvedKey, in: &properties)
    }
}

func projectDocument(at root: URL) -> [String: Any]? {
    let projectURL = root.appendingPathComponent("project.json")
    guard let data = try? Data(contentsOf: projectURL) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func effectiveProjectProperties(
    project: [String: Any], root: URL, includePersisted: Bool = true
) -> [String: Any] {
    let general = project["general"] as? [String: Any]
    var properties = general?["properties"] as? [String: Any] ?? [:]
    let localURL = root.appendingPathComponent("properties.local.json")
    if let data = try? Data(contentsOf: localURL),
       let overrides = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        applyPropertyValues(overrides, to: &properties)
    }
    if includePersisted {
        applyPropertyValues(persistedPropertyValues(for: root.path), to: &properties)
    }
    return properties
}

private func packageUInt32(_ handle: FileHandle, fileSize: UInt64) -> UInt32? {
    guard handle.offsetInFile <= fileSize, fileSize - handle.offsetInFile >= 4 else { return nil }
    let data = handle.readData(ofLength: 4)
    guard data.count == 4 else { return nil }
    return data.enumerated().reduce(UInt32(0)) {
        $0 | UInt32($1.element) << UInt32($1.offset * 8)
    }
}

private func packageString(_ handle: FileHandle, fileSize: UInt64) -> String? {
    guard let length = packageUInt32(handle, fileSize: fileSize),
          UInt64(length) <= fileSize - handle.offsetInFile else { return nil }
    let data = handle.readData(ofLength: Int(length))
    guard data.count == Int(length) else { return nil }
    return String(data: data, encoding: .utf8)
}

private final class ScenePropertyNameCacheEntry: NSObject {
    let names: Set<String>
    init(_ names: Set<String>) { self.names = names }
}

private let scenePropertyNameCache = NSCache<NSString, ScenePropertyNameCacheEntry>()

func sceneRuntimePropertyNames(package: URL) -> Set<String> {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: package.path),
          let size = attributes[.size] as? NSNumber else { return [] }
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let cacheKey = "\(package.standardizedFileURL.path)|\(size.uint64Value)|\(modified)" as NSString
    if let cached = scenePropertyNameCache.object(forKey: cacheKey) { return cached.names }
    guard let handle = try? FileHandle(forReadingFrom: package) else { return [] }
    defer { try? handle.close() }
    let fileSize = size.uint64Value
    guard packageString(handle, fileSize: fileSize) != nil,
          let count = packageUInt32(handle, fileSize: fileSize), count <= 1_000_000 else {
        return []
    }
    struct Entry { let name: String; let offset: UInt32; let length: UInt32 }
    var entries: [Entry] = []
    for _ in 0..<count {
        guard let name = packageString(handle, fileSize: fileSize),
              let entryOffset = packageUInt32(handle, fileSize: fileSize),
              let length = packageUInt32(handle, fileSize: fileSize) else { return [] }
        entries.append(Entry(name: name, offset: entryOffset, length: length))
    }
    let base = handle.offsetInFile
    guard let entry = entries.first(where: { $0.name == "scene.json" }),
          entry.length <= 64 * 1024 * 1024 else { return [] }
    let lower = base + UInt64(entry.offset)
    let upper = lower + UInt64(entry.length)
    guard lower >= base, upper >= lower, upper <= fileSize else { return [] }
    handle.seek(toFileOffset: lower)
    let data = handle.readData(ofLength: Int(entry.length))
    guard data.count == Int(entry.length),
          let scene = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let objects = scene["objects"] as? [[String: Any]] else { return [] }
    var names = Set<String>(objects.compactMap { object in
        guard object["sound"] is [Any],
              let volume = object["volume"] as? [String: Any],
              let name = volume["user"] as? String, !name.isEmpty else { return nil }
        return name
    })
    let propertyScriptProfiles: [(objectID: Int, bytes: Int, sha256: String)] = [
        (95, 3900, "43803a4cc38a86451269dbab6737616b114680d24daa4ee2c0240d1691334cbf"),
        (460, 1774, "cef79c36a0edddf40c2633723541c659007e4d5c4065053de837c817ecd6d4d5"),
    ]
    for profile in propertyScriptProfiles {
        guard let object = objects.first(where: {
                  ($0["id"] as? NSNumber)?.intValue == profile.objectID
              }),
              let visible = object["visible"] as? [String: Any],
              visible["value"] is Bool,
              let source = visible["script"] as? String,
              source.utf8.count == profile.bytes,
              source.contains("export function init()"),
              source.contains("export function applyUserProperties("),
              source.contains("thisScene.getLayer("),
              !source.contains("export function cursorClick(") else { continue }
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        if digest == profile.sha256 { names.insert("music") }
    }
    scenePropertyNameCache.setObject(ScenePropertyNameCacheEntry(names), forKey: cacheKey)
    return names
}

func dependencyID(from project: [String: Any]) -> String? {
    if let dependency = project["dependency"] as? String, !dependency.isEmpty {
        return dependency
    }
    if let dependency = project["dependency"] as? NSNumber {
        return dependency.stringValue
    }
    return nil
}

private func resolveWallpaperManifest(at url: URL, includePersisted: Bool = true) -> Wallpaper? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

    if !isDirectory.boolValue {
        let fileType = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(fileType) { return .video(url) }
        if ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(fileType),
           NSImage(contentsOf: url) != nil {
            return .image(url)
        }
        return nil
    }

    guard let project = projectDocument(at: url) else { return nil }

    // Preset items configure another wallpaper: resolve the dependency and
    // overlay the preset's property values (WE downloads deps the same way).
    if let dependency = dependencyID(from: project) {
        let baseURL = url.deletingLastPathComponent().appendingPathComponent(dependency)
        guard FileManager.default.fileExists(
            atPath: baseURL.appendingPathComponent("project.json").path) else {
            print("preset depends on workshop item \(dependency), which is not "
                + "downloaded — run: workshop get \(dependency)")
            return nil
        }
        guard let base = resolveWallpaperManifest(at: baseURL, includePersisted: false) else {
            return nil
        }
        guard case .web(let index, let root, var properties) = base else { return base }
        if let preset = project["preset"] as? [String: Any] {
            for (key, value) in preset {
                let resolvedKey = propertyKey(key, in: properties)
                let definition = properties[resolvedKey] as? [String: Any]
                let resolvedValue = resolvePresetAsset(
                    value, definition: definition, root: url)
                overlayProperty(resolvedValue, forKey: resolvedKey, in: &properties)
            }
        }
        if includePersisted {
            applyPropertyValues(persistedPropertyValues(for: url.path), to: &properties)
        }
        return .web(index: index, root: root, properties: properties)
    }

    let type = (project["type"] as? String ?? "").lowercased()
    if type.contains("scene") {
        let package = url.appendingPathComponent("scene.pkg")
        guard FileManager.default.fileExists(atPath: package.path) else { return nil }
        let preview = (project["preview"] as? String).flatMap { relative -> URL? in
            let candidate = url.appendingPathComponent(relative).standardizedFileURL
            return NSImage(contentsOf: candidate) != nil ? candidate : nil
        }
        return .scene(
            root: url,
            package: package,
            preview: preview,
            properties: effectiveProjectProperties(
                project: project, root: url, includePersisted: includePersisted
            ),
            runtimePropertyNames: sceneRuntimePropertyNames(package: package)
        )
    }

    guard let file = project["file"] as? String else { return nil }
    let target = url.appendingPathComponent(file)

    if type.contains("video") || type.contains("web") {
        var targetIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
                atPath: target.path, isDirectory: &targetIsDirectory),
              !targetIsDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: target.path) else { return nil }
    }
    if type.contains("video") { return .video(target) }
    if type.contains("web") {
        return .web(
            index: target,
            root: url,
            properties: effectiveProjectProperties(
                project: project, root: url, includePersisted: includePersisted
            )
        )
    }
    return nil
}

func resolveWallpaper(_ path: String) -> Wallpaper? {
    let url = standardizedWallpaperURL(path)
    return resolveWallpaperManifest(at: url)
}

func baseWebProjectDocument(for target: URL) -> [String: Any]? {
    var root = target
    var seen = Set<String>()
    while let project = projectDocument(at: root) {
        guard let dependency = dependencyID(from: project), seen.insert(dependency).inserted
        else { return project }
        root = root.deletingLastPathComponent().appendingPathComponent(dependency)
    }
    return nil
}

func selectedLocalization(from localization: [String: Any])
    -> (locale: String?, strings: [String: Any]) {
    let localesByLowercase = Dictionary(
        uniqueKeysWithValues: localization.keys.map { ($0.lowercased(), $0) })
    var candidates: [String] = []
    for language in Locale.preferredLanguages {
        let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()
        candidates.append(normalized)
        if let base = normalized.split(separator: "-").first { candidates.append(String(base)) }
    }
    candidates += ["en-us", "en"]
    for candidate in candidates {
        guard let locale = localesByLowercase[candidate],
              let strings = localization[locale] as? [String: Any] else { continue }
        return (locale, strings)
    }
    guard let locale = localization.keys.sorted().first,
          let strings = localization[locale] as? [String: Any] else { return (nil, [:]) }
    return (locale, strings)
}

func localizedWebText(_ raw: Any?, strings: [String: Any]) -> Any? {
    guard let key = raw as? String else { return raw }
    return strings[key] ?? raw
}

func webPropertyPresentation(
    properties: [String: Any],
    strings: [String: Any],
    runtimePropertyNames: Set<String>? = nil
) -> [[String: Any]] {
    let context = JSContext()!
    let identifierPattern = "^[A-Za-z_$][A-Za-z0-9_$]*$"
    for (name, rawDefinition) in properties {
        guard name.range(of: identifierPattern, options: .regularExpression) != nil,
              let definition = rawDefinition as? [String: Any] else { continue }
        context.setObject(definition, forKeyedSubscript: name as NSString)
    }

    let editableTypes = Set(["bool", "color", "combo", "directory", "file",
                             "slider", "textinput"])
    var presentation: [[String: Any]] = []
    for (name, rawDefinition) in properties {
        guard let definition = rawDefinition as? [String: Any] else { continue }
        var item = definition
        let type = (definition["type"] as? String ?? "").lowercased()
        let runtimeSupported = runtimePropertyNames?.contains(name) ?? true
        item["name"] = name
        item["type"] = type
        item["runtimeSupported"] = runtimeSupported
        item["editable"] = editableTypes.contains(type)
        item["label"] = localizedWebText(definition["text"], strings: strings) ?? name
        if let options = definition["options"] as? [[String: Any]] {
            item["options"] = options.map { option in
                var localized = option
                localized["label"] = localizedWebText(option["label"], strings: strings)
                    ?? String(describing: option["value"] ?? "")
                return localized
            }
        }
        if let condition = definition["condition"] as? String, !condition.isEmpty {
            if let result = context.evaluateScript("Boolean(\(condition))"),
               !result.isUndefined && !result.isNull {
                item["active"] = result.toBool()
            } else {
                item["active"] = NSNull()
            }
        } else {
            item["active"] = true
        }
        presentation.append(item)
    }
    return presentation.sorted {
        let leftOrder = ($0["order"] as? NSNumber)?.doubleValue ?? Double.greatestFiniteMagnitude
        let rightOrder = ($1["order"] as? NSNumber)?.doubleValue ?? Double.greatestFiniteMagnitude
        if leftOrder != rightOrder { return leftOrder < rightOrder }
        return ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "")
    }
}

func wallpaperProjectDescription(_ path: String) -> [String: Any]? {
    let target = standardizedWallpaperURL(path)
    guard let wallpaper = resolveWallpaper(target.path),
          let targetProject = projectDocument(at: target) else { return nil }
    let root: URL
    let index: URL
    let properties: [String: Any]
    let runtimePropertyNames: Set<String>?
    let kind: String
    switch wallpaper {
    case let .web(webIndex, webRoot, webProperties):
        root = webRoot
        index = webIndex
        properties = webProperties
        runtimePropertyNames = nil
        kind = "web"
    case let .scene(sceneRoot, package, _, sceneProperties, supportedNames):
        guard dependencyID(from: targetProject) == nil else { return nil }
        root = sceneRoot
        index = package
        properties = sceneProperties
        runtimePropertyNames = supportedNames
        kind = "scene"
    default:
        return nil
    }
    let baseProject = baseWebProjectDocument(for: target) ?? targetProject
    let general = baseProject["general"] as? [String: Any]
    let localization = general?["localization"] as? [String: Any] ?? [:]
    let selected = selectedLocalization(from: localization)
    return [
        "schemaVersion": 1,
        "wallpaperPath": target.path,
        "title": targetProject["title"] as? String ?? target.lastPathComponent,
        "kind": kind,
        "projectRoot": root.path,
        "indexPath": index.path,
        "stateID": propertyStateID(for: target.path),
        "statePath": propertyStateURL(for: target.path).path,
        "locale": selected.locale ?? NSNull(),
        "properties": properties,
        "presentation": webPropertyPresentation(
            properties: properties,
            strings: selected.strings,
            runtimePropertyNames: runtimePropertyNames),
        "overrides": persistedPropertyValues(for: target.path),
    ]
}

func webProjectDescription(_ path: String) -> [String: Any]? {
    guard let description = wallpaperProjectDescription(path),
          description["kind"] as? String == "web" else { return nil }
    return description
}

func propertyValuesEqual(_ left: Any?, _ right: Any?) -> Bool {
    switch (left, right) {
    case (nil, nil):
        return true
    case (let left as NSObject, let right as NSObject):
        return left.isEqual(right)
    default:
        return false
    }
}

func changedWebProperties(from old: [String: Any], to new: [String: Any]) -> [String: Any] {
    var changed: [String: Any] = [:]
    for (name, rawNewDefinition) in new {
        guard var newDefinition = rawNewDefinition as? [String: Any] else { continue }
        let oldDefinition = old[name] as? [String: Any]
        if propertyValuesEqual(oldDefinition?["value"], newDefinition["value"]) { continue }
        let type = (newDefinition["type"] as? String ?? "").lowercased()
        if newDefinition["value"] == nil && type == "textinput" {
            newDefinition["value"] = ""
        }
        changed[name] = newDefinition
    }
    return changed
}

func mergedWallpaperProperties(
    project: [String: Any], overlays: [[String: Any]]
) -> [String: Any] {
    var merged = project
    for overlay in overlays {
        for (key, value) in overlay { merged[key] = value }
    }
    return merged.filter { _, value in
        guard let definition = value as? [String: Any],
              let text = definition["value"] as? String else { return true }
        return !text.isEmpty
    }
}

struct WebDirectoryInventory {
    let allFiles: [String: [String]]
    let fetchAllFiles: [String: [String]]
}

func webDirectoryInventory(for properties: [String: Any]) -> WebDirectoryInventory {
    let imageExtensions = Set(["jpeg", "jpg", "png", "pnga", "bmp", "gif", "svg", "webp"])
    let videoExtensions = Set(["webm", "ogg", "ogv", "mp4", "mov", "m4v"])
    var allFiles: [String: [String]] = [:]
    var fetchAllFiles: [String: [String]] = [:]

    for (name, rawDefinition) in properties {
        guard let definition = rawDefinition as? [String: Any],
              (definition["type"] as? String)?.lowercased() == "directory",
              let rawPath = definition["value"] as? String, !rawPath.isEmpty
        else { continue }
        let path = (rawPath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { continue }

        let fileType = (definition["fileType"] as? String ?? "image").lowercased()
        let allowed = fileType.contains("video") ? videoExtensions : imageExtensions
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var files: [String] = []
        while let file = enumerator?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  allowed.contains(file.pathExtension.lowercased()) else { continue }
            files.append(file.path)
        }
        files.sort()
        allFiles[name] = files
        if (definition["mode"] as? String)?.lowercased() == "fetchall" {
            fetchAllFiles[name] = files
        }
    }
    return WebDirectoryInventory(allFiles: allFiles, fetchAllFiles: fetchAllFiles)
}

func userProperties(from properties: [String: Any], includeEmptyText: Bool = false)
    -> [String: Any] {
    var result: [String: Any] = [:]
    for (name, rawDefinition) in properties {
        guard let definition = rawDefinition as? [String: Any],
              let value = definition["value"], !(value is NSNull) else { continue }
        if let text = value as? String, text.isEmpty {
            let type = (definition["type"] as? String ?? "").lowercased()
            if !(includeEmptyText && type == "textinput") { continue }
        }
        if (definition["type"] as? String)?.lowercased() == "directory",
           (definition["mode"] as? String)?.lowercased() == "fetchall" {
            continue
        }
        var event = ["value": value]
        if let text = definition["text"] { event["text"] = text }
        result[name] = event
    }
    return result
}

func webUserProperties(from properties: [String: Any], includeEmptyText: Bool = false)
    -> [String: Any] {
    userProperties(from: properties, includeEmptyText: includeEmptyText)
}

func sceneUserProperties(from properties: [String: Any]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (name, rawDefinition) in properties {
        guard let definition = rawDefinition as? [String: Any],
              let value = definition["value"], !(value is NSNull),
              value is String || value is NSNumber else { continue }
        result[name] = ["value": value]
    }
    return result
}

func scopedWebProperties(_ properties: [String: Any],
                         using scopedProperties: [String: Any]) -> [String: Any] {
    var result = properties
    for (name, rawDefinition) in properties {
        guard let scopedDefinition = scopedProperties[name] as? [String: Any],
              let type = (scopedDefinition["type"] as? String)?.lowercased(),
              type == "file" || type == "directory",
              let scopedValue = scopedDefinition["value"] else { continue }
        var definition = rawDefinition as? [String: Any] ?? [:]
        definition["value"] = scopedValue
        result[name] = definition
    }
    return result
}

final class WebAccessScope {
    let index: URL
    let root: URL
    let properties: [String: Any]
    private var stagingRoot: URL?

    init(index originalIndex: URL, root originalRoot: URL,
         properties originalProperties: [String: Any]) {
        let projectRoot = originalRoot.standardizedFileURL
        var normalizedProperties = originalProperties
        var propertySources: [String: URL] = [:]
        var hasExternalSource = false

        for (name, rawDefinition) in originalProperties {
            guard var definition = rawDefinition as? [String: Any],
                  let type = (definition["type"] as? String)?.lowercased(),
                  type == "file" || type == "directory",
                  let rawPath = definition["value"] as? String, !rawPath.isEmpty
            else { continue }
            let expanded = (rawPath as NSString).expandingTildeInPath
            let source = (expanded as NSString).isAbsolutePath
                ? URL(fileURLWithPath: expanded).standardizedFileURL
                : projectRoot.appendingPathComponent(expanded).standardizedFileURL
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            definition["value"] = source.path
            normalizedProperties[name] = definition
            propertySources[name] = source
            if !Self.contains(source, within: projectRoot) { hasExternalSource = true }
        }

        guard hasExternalSource else {
            index = originalIndex
            root = projectRoot
            properties = normalizedProperties
            stagingRoot = nil
            return
        }
        do {
            let staged = try Self.stage(
                index: originalIndex, root: projectRoot,
                properties: normalizedProperties, propertySources: propertySources)
            index = staged.index
            root = staged.root
            properties = staged.properties
            stagingRoot = staged.root
        } catch {
            print("web access: could not stage selected files: \(error)")
            index = originalIndex
            root = projectRoot
            properties = normalizedProperties
            stagingRoot = nil
        }
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        guard let stagingRoot else { return }
        self.stagingRoot = nil
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    static func removeStaleDirectories() {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: runtimeDirectory, includingPropertiesForKeys: nil) else { return }
        for child in children where child.lastPathComponent.hasPrefix("web-access-") {
            try? FileManager.default.removeItem(at: child)
        }
    }

    private static func stage(index: URL, root: URL, properties: [String: Any],
                              propertySources: [String: URL]) throws
        -> (index: URL, root: URL, properties: [String: Any]) {
        try FileManager.default.createDirectory(at: runtimeDirectory,
                                                withIntermediateDirectories: true)
        let stagingRoot = runtimeDirectory.appendingPathComponent(
            "web-access-\(UUID().uuidString)", isDirectory: true)
        let stagedProject = stagingRoot.appendingPathComponent("project", isDirectory: true)
        do {
            try mirrorDirectory(root, to: stagedProject)
            var stagedProperties = properties
            for (name, source) in propertySources {
                guard var definition = stagedProperties[name] as? [String: Any] else { continue }
                let destination: URL
                if contains(source, within: root) {
                    destination = stagedProject.appendingPathComponent(relativePath(of: source, in: root))
                } else {
                    let safeName = name.replacingOccurrences(of: "/", with: "_")
                    let propertyRoot = stagingRoot.appendingPathComponent("properties")
                        .appendingPathComponent(safeName, isDirectory: true)
                    var isDirectory: ObjCBool = false
                    FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
                    if isDirectory.boolValue {
                        try mirrorDirectory(source, to: propertyRoot)
                        destination = propertyRoot
                    } else {
                        try FileManager.default.createDirectory(
                            at: propertyRoot, withIntermediateDirectories: true)
                        destination = propertyRoot.appendingPathComponent(source.lastPathComponent)
                        try linkOrCopy(source, to: destination)
                    }
                }
                definition["value"] = destination.path
                stagedProperties[name] = definition
            }
            let stagedIndex = stagedProject.appendingPathComponent(relativePath(of: index, in: root))
            return (stagedIndex, stagingRoot, stagedProperties)
        } catch {
            try? FileManager.default.removeItem(at: stagingRoot)
            throw error
        }
    }

    private static func mirrorDirectory(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
        ) else { return }
        while let item = enumerator.nextObject() as? URL {
            let target = destination.appendingPathComponent(relativePath(of: item, in: source))
            let values = try item.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                let resolved = item.resolvingSymlinksInPath()
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: resolved.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    enumerator.skipDescendants()
                    try mirrorDirectory(resolved, to: target)
                } else {
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try linkOrCopy(resolved, to: target)
                }
            } else if values.isDirectory == true {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try linkOrCopy(item, to: target)
            }
        }
    }

    private static func linkOrCopy(_ source: URL, to destination: URL) throws {
        do {
            try FileManager.default.linkItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private static func contains(_ candidate: URL, within directory: URL) -> Bool {
        let path = candidate.standardizedFileURL.path
        let rootPath = directory.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private static func relativePath(of candidate: URL, in directory: URL) -> String {
        let path = candidate.standardizedFileURL.path
        let rootPath = directory.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return candidate.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

// MARK: - Livery Look → WE user properties

// Livery v3 manifests wrap colors as {hex, rgb} objects; v2 carried bare hex
// strings. Accept both so the bridge never silently drops theme colors.
func hexString(_ value: Any?) -> String? {
    if let hex = value as? String { return hex }
    if let object = value as? [String: Any] { return object["hex"] as? String }
    return nil
}

func weColor(_ hex: String?) -> [String: Any]? {
    guard let hex, hex.hasPrefix("#"), hex.count == 7 else { return nil }
    let components = [1, 3, 5].compactMap { start -> Double? in
        let index = hex.index(hex.startIndex, offsetBy: start)
        guard let value = UInt8(hex[index...hex.index(index, offsetBy: 1)], radix: 16) else { return nil }
        return Double(value) / 255.0
    }
    guard components.count == 3 else { return nil }
    return ["value": components.map { String(format: "%.4f", $0) }.joined(separator: " ")]
}

func liveryProperties() -> [String: Any] {
    let manifest = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/livery/current/manifest.json")
    guard let data = try? Data(contentsOf: manifest),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let ui = object["ui"] as? [String: Any] else { return [:] }

    var properties: [String: Any] = [:]
    if let color = weColor(hexString(ui["primary"])) { properties["schemecolor"] = color }
    for role in ["primary", "secondary", "tertiary", "surface", "surfaceElevated",
                 "background", "text", "textMuted"] {
        if let color = weColor(hexString(ui[role])) {
            properties["livery" + role.lowercased()] = color
        }
    }
    if let signals = object["signals"] as? [String: Any] {
        for role in ["attention", "success", "warning", "error", "info"] {
            if let color = weColor(hexString(signals[role])) {
                properties["livery" + role] = color
            }
        }
    }
    // fonts domain (contract §2.4): pushed as text props so a composition
    // MAY consume them. repose deliberately does not — its faces are the
    // composition's identity (13-font trial verdict, repose/index.html).
    if let fonts = object["fonts"] as? [String: Any] {
        for role in ["mono", "ui", "display"] {
            if let font = fonts[role] as? [String: Any],
               let family = font["family"] as? String, !family.isEmpty {
                properties["liveryfont" + role] = ["value": family]
            }
        }
    }
    if let presentation = object["presentation"] as? [String: Any],
       let rawGradient = presentation["visualizerGradient"] as? [Any] {
        let gradient = rawGradient.compactMap(hexString)
        if gradient.count == 2 {
            if let color = weColor(gradient[0]) { properties["liveryviz1"] = color }
            if let color = weColor(gradient[1]) { properties["liveryviz2"] = color }
        }
    }
    return properties
}

func liveryManifestModificationDate() -> Date? {
    let manifest = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/livery/current/manifest.json")
    return (try? FileManager.default.attributesOfItem(atPath: manifest.path))?[.modificationDate] as? Date
}

// MARK: - Cava audio tap (64 bands/channel → 128-sample WE frames)

func wallpaperAudioFrame(fromCava bands: [Double]) -> [Double]? {
    guard bands.count >= 128 else { return nil }
    // Cava's stereo display mirrors the left channel (treble → bass) and
    // leaves the right channel bass → treble. WE wants both bass → treble.
    return Array(bands[0..<64].reversed()) + Array(bands[64..<128])
}

final class AudioTap {
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var configURL: URL?
    private var cavaPath: String?
    private var watchdog: Timer?
    private var silenceTimer: Timer?
    private var consecutiveFailures = 0
    private var lastFrameAt = Date.distantPast
    private var framesThisLaunch = 0
    var onFrame: (([Double]) -> Void)?
    private(set) var live = false
    private(set) var framesReceived = 0
    private(set) var capturePermissionAvailable = true

    func start() {
        guard silenceTimer == nil else { return }
        capturePermissionAvailable = true
        lastFrameAt = .distantPast
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            guard let self, Date().timeIntervalSince(self.lastFrameAt) > 0.2 else { return }
            self.onFrame?(Array(repeating: 0, count: 128))
        }
        // Never let a background wallpaper process initiate macOS's capture
        // permission flow. Rebuilding this ad-hoc-signed binary can invalidate
        // its old TCC grant; launching cava's system-output tap in that state
        // repeatedly opens System Settings as the watchdog retries it.
        guard CGPreflightScreenCaptureAccess() else {
            capturePermissionAvailable = false
            return
        }
        guard let cava = findCava() else { return }
        cavaPath = cava
        // Mirrors the proven zephyr-strings tap config (Core Audio system
        // output tap); without the [input] section cava reads the default
        // device and delivers silence.
        let config = """
        [general]
        bars = 128
        framerate = 30
        lower_cutoff_freq = 40
        higher_cutoff_freq = 16000
        [input]
        method = coreaudio
        source = tap
        channels = 2
        [output]
        method = raw
        raw_target = /dev/stdout
        data_format = ascii
        ascii_max_range = 1000
        bar_delimiter = 59
        frame_delimiter = 10
        channels = stereo
        [smoothing]
        integral = 0
        waves = 0
        gravity = 8000000
        noise_reduction = 25
        """
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresco-cava-\(getuid()).conf")
        try? config.write(to: configURL, atomically: true, encoding: .utf8)
        self.configURL = configURL
        launch()

        // Cava emits frames continuously (zeros in silence), so a stall means
        // the tap died — commonly an output-device switch (AirPods) breaking
        // the CoreAudio tap while the process keeps running. Relaunch heals it.
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    private func launch() {
        guard let cavaPath, let configURL else { return }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: cavaPath)
        process.arguments = ["-p", configURL.path]
        process.standardOutput = pipe
        process.standardError = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        framesThisLaunch = 0
        lastFrameAt = Date()
        do { try process.run(); live = true } catch { live = false }
        self.process = process
        self.pipe = pipe
    }

    private func checkHealth() {
        guard live, let process else { return }
        let stalled = framesThisLaunch > 0 && Date().timeIntervalSince(lastFrameAt) > 15
        guard !process.isRunning || stalled else { return }
        // A launch that never delivered a frame is a hard failure — most
        // often TCC denying the system-audio tap (a rebuild changes the
        // daemon's ad-hoc signature and invalidates the old grant), and
        // every retry re-triggers the permission flow, popping System
        // Settings. Cap it; frames arriving resets the count.
        if framesThisLaunch == 0 {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                print("audio: cava failed \(consecutiveFailures)x with no frames — giving up. "
                    + "Grant System Audio Recording to Fresco "
                    + "(System Settings > Privacy & Security), then fresco restart.")
                pipe?.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                live = false
                watchdog?.invalidate()
                watchdog = nil
                return
            }
        } else {
            consecutiveFailures = 0
        }
        print("audio: cava \(process.isRunning ? "stalled" : "exited") — restarting tap")
        pipe?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        launch()
    }

    private func findCava() -> String? {
        for candidate in ["/opt/homebrew/bin/cava", "/usr/local/bin/cava"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let text = String(data: line, encoding: .utf8) else { continue }
            let bands = text.split(separator: ";").compactMap { Double($0) }.map { $0 / 1000.0 }
            guard let frame = wallpaperAudioFrame(fromCava: bands) else { continue }
            DispatchQueue.main.async {
                self.framesReceived += 1
                self.framesThisLaunch += 1
                self.lastFrameAt = Date()
                self.onFrame?(frame)
            }
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        live = false
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        if let configURL { try? FileManager.default.removeItem(at: configURL) }
        process = nil
        pipe = nil
        configURL = nil
        cavaPath = nil
        buffer.removeAll(keepingCapacity: true)
    }
}

// MARK: - Media feed (WE media integration via media-control)

func boolValue(_ any: Any?) -> Bool {
    if let value = any as? Bool { return value }
    if let value = any as? String { return value.lowercased() == "true" }
    if let value = any as? NSNumber { return value.boolValue }
    return false
}

func doubleValue(_ any: Any?) -> Double {
    if let value = any as? Double { return value }
    if let value = any as? String { return Double(value) ?? 0 }
    if let value = any as? NSNumber { return value.doubleValue }
    return 0
}

func artworkColors(base64: String) -> (String, String, String, String, String) {
    let fallback = ("#888888", "#555555", "#bbbbbb", "#ffffff", "white")
    guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
          let image = NSImage(data: data),
          let rep = NSBitmapImageRep(
              bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return fallback }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
    NSGraphicsContext.restoreGraphicsState()
    guard let color = rep.colorAt(x: 0, y: 0) else { return fallback }
    func hex(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> String {
        String(format: "#%02x%02x%02x",
               Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255),
               Int(max(0, min(1, b)) * 255))
    }
    let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
    let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return (hex(r, g, b),
            hex(r * 0.6, g * 0.6, b * 0.6),
            hex(min(1, r * 1.4 + 0.1), min(1, g * 1.4 + 0.1), min(1, b * 1.4 + 0.1)),
            luminance > 0.6 ? "#111111" : "#ffffff",
            luminance > 0.6 ? "black" : "white")
}

final class MediaFeed {
    private let queue = DispatchQueue(label: "wallpaper.runtime.media", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var timelineTimer: DispatchSourceTimer?
    private var lastTrackKey = ""
    private var lastArtworkKey = ""
    private var lastPlayback = -1
    private var lastEnabled: Bool?
    private var playing = false
    private var rate = 1.0
    private var elapsed = 0.0
    private var duration = 0.0
    private var sampledAt = Date()
    // last payload per kind (main-thread) — replayed into webviews created
    // after the fact, so a fresh cover shows the current track immediately
    private(set) var lastPayloads: [String: [String: Any]] = [:]
    var onEvent: ((String, [String: Any]) -> Void)?

    static var available: Bool { shell(["which", "media-control"]).status == 0 }

    func snapshotJSON() -> String {
        (try? JSONSerialization.data(withJSONObject: lastPayloads))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    func start() {
        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now() + 1, repeating: 2)
        poll.setEventHandler { [weak self] in self?.poll() }
        poll.resume()
        pollTimer = poll
        let timeline = DispatchSource.makeTimerSource(queue: queue)
        timeline.schedule(deadline: .now() + 2, repeating: 1)
        timeline.setEventHandler { [weak self] in self?.tickTimeline() }
        timeline.resume()
        timelineTimer = timeline
    }

    func stop() {
        pollTimer?.cancel()
        timelineTimer?.cancel()
        pollTimer = nil
        timelineTimer = nil
    }

    private func emit(_ kind: String, _ payload: [String: Any]) {
        DispatchQueue.main.async {
            self.lastPayloads[kind] = payload
            self.onEvent?(kind, payload)
        }
    }

    private func poll() {
        let result = shell(["media-control", "get"])
        guard result.status == 0, let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String, !title.isEmpty else {
            setEnabled(false)
            return
        }
        setEnabled(true)
        let artist = object["artist"] as? String ?? ""
        let album = object["album"] as? String ?? ""
        playing = boolValue(object["playing"])
        rate = max(doubleValue(object["playbackRate"]), 0)
        elapsed = doubleValue(object["elapsedTime"])
        duration = doubleValue(object["duration"])
        sampledAt = Date()

        let state = playing ? 1 : 2
        if state != lastPlayback {
            lastPlayback = state
            emit("playback", ["state": state])
        }
        let trackKey = "\(title)|\(artist)|\(album)"
        if trackKey != lastTrackKey {
            lastTrackKey = trackKey
            emit("properties", [
                "title": title, "artist": artist, "subTitle": "",
                "albumTitle": album, "albumArtist": artist, "genres": "",
                "contentType": "music",
            ])
        }
        if let artwork = object["artworkData"] as? String, !artwork.isEmpty {
            let mime = object["artworkMimeType"] as? String ?? "image/jpeg"
            let artworkKey = "\(mime)|\(artwork.hashValue)"
            if artworkKey != lastArtworkKey {
                lastArtworkKey = artworkKey
                let colors = artworkColors(base64: artwork)
                emit("thumbnail", [
                    "thumbnail": "data:\(mime);base64,\(artwork)",
                    "primaryColor": colors.0, "secondaryColor": colors.1,
                    "tertiaryColor": colors.2, "textColor": colors.3,
                    "highContrastColor": colors.4,
                ])
            }
        } else if !lastArtworkKey.isEmpty {
            lastArtworkKey = ""
            emit("thumbnail", ["thumbnail": ""])
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard enabled != lastEnabled else { return }
        lastEnabled = enabled
        emit("status", ["enabled": enabled])
        if !enabled {
            lastTrackKey = ""
            lastArtworkKey = ""
            emit("thumbnail", ["thumbnail": ""])
            if lastPlayback != 0 {
                lastPlayback = 0
                emit("playback", ["state": 0])
            }
        }
    }

    private func tickTimeline() {
        guard lastEnabled == true, duration > 0 else { return }
        let position = playing
            ? min(duration, elapsed + Date().timeIntervalSince(sampledAt) * rate)
            : elapsed
        emit("timeline", ["position": position, "duration": duration])
    }
}

// MARK: - Agent-state feed (Herald tasks channel)

struct AgentCounts: Equatable {
    var working: Int
    var waiting: Int
    var done: Int
}

struct HeraldTask {
    let state: String
    let paneID: String?
    let pid: pid_t?
}

final class AgentFeed {
    private static let heraldRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/herald")
    private static let channelDirectory = heraldRoot.appendingPathComponent("tasks.d")
    private let queue = DispatchQueue(label: "wallpaper.runtime.agents", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var notifyToken: Int32?
    private var debounceWorkItem: DispatchWorkItem?
    private var lastCounts = AgentCounts(working: -1, waiting: -1, done: -1)
    // last pushed counts (main-thread) — seeded into webviews created later
    private(set) var lastProperties: [String: Any] = [:]
    var onChange: (([String: Any]) -> Void)?

    static var available: Bool {
        FileManager.default.fileExists(atPath: heraldRoot.path)
            || shell(["which", "tmux"]).status == 0
    }

    func start() {
        var token: Int32 = 0
        let status = notify_register_dispatch(
            "vestiary.herald.tasks", &token, queue
        ) { [weak self] _ in
            self?.scheduleDoorbellReconcile()
        }
        if status == 0 { notifyToken = token }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.reconcile() }
        timer.resume()
        self.timer = timer

        // No notification replay exists, so always seed from the channel.
        queue.async { [weak self] in self?.reconcile() }
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        timer?.cancel()
        timer = nil
        if let notifyToken {
            notify_cancel(notifyToken)
            self.notifyToken = nil
        }
    }

    // Parse the channel independently of I/O so fixtures can exercise the
    // merge contract with synthetic task envelopes.
    static func tasks(from documents: [Data]) -> [HeraldTask] {
        documents.compactMap { document in
            guard let envelope = try? JSONSerialization.jsonObject(with: document)
                    as? [String: Any],
                  let data = envelope["data"] as? [String: Any],
                  let state = data["state"] as? String,
                  let kind = data["kind"] as? String,
                  !kind.isEmpty
            else { return nil }

            let rawPane = ((data["focus"] as? [String: Any])?["tmux"]
                as? [String: Any])?["pane"] as? String
            let paneID = rawPane.flatMap {
                $0.isEmpty ? nil : $0
            }

            var pid: pid_t?
            if let number = (data[kind] as? [String: Any])?["pid"] as? NSNumber {
                let value = number.int64Value
                if value > 0, value <= Int64(Int32.max) { pid = pid_t(value) }
            }
            return HeraldTask(state: state, paneID: paneID, pid: pid)
        }
    }

    // A pane anchor is authoritative when tmux answered. Without one, pid
    // liveness is mandatory. Supplying both snapshots keeps merge/count logic
    // pure and directly testable.
    static func counts(from tasks: [HeraldTask], livePaneIDs: Set<String>?,
                       livePIDs: Set<pid_t>) -> AgentCounts {
        var counts = AgentCounts(working: 0, waiting: 0, done: 0)
        for task in tasks {
            if let paneID = task.paneID {
                if let livePaneIDs, !livePaneIDs.contains(paneID) { continue }
            } else {
                guard let pid = task.pid, livePIDs.contains(pid) else { continue }
            }
            switch task.state {
            case "working": counts.working += 1
            case "waiting": counts.waiting += 1
            case "done": counts.done += 1
            default: break
            }
        }
        return counts
    }

    private static func readTasks() -> [HeraldTask] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: channelDirectory, includingPropertiesForKeys: nil
        )) ?? []
        let documents = urls.compactMap { url -> Data? in
            guard !url.lastPathComponent.hasPrefix("."), url.pathExtension == "json"
            else { return nil }
            return try? Data(contentsOf: url)
        }
        return tasks(from: documents)
    }

    private func scheduleDoorbellReconcile() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.reconcile() }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: workItem)
    }

    private func reconcile() {
        // One pane snapshot per merge. A failed call means tmux is unavailable,
        // so pane-anchored tasks survive without falling back to transient pids.
        let paneResult = shell(["tmux", "list-panes", "-a", "-F", "#{pane_id}"])
        let livePaneIDs: Set<String>? = paneResult.status == 0
            ? Set(paneResult.stdout.split(whereSeparator: { $0.isWhitespace }).map(String.init))
            : nil
        let tasks = Self.readTasks()
        let livePIDs = Set(tasks.compactMap { task -> pid_t? in
            guard task.paneID == nil, let pid = task.pid, Darwin.kill(pid, 0) == 0
            else { return nil }
            return pid
        })
        let counts = Self.counts(
            from: tasks, livePaneIDs: livePaneIDs, livePIDs: livePIDs
        )
        guard counts != lastCounts else { return }
        lastCounts = counts
        let properties: [String: Any] = [
            "agentworking": ["value": counts.working],
            "agentwaiting": ["value": counts.waiting],
            "agentdone": ["value": counts.done],
        ]
        DispatchQueue.main.async {
            self.lastProperties = properties
            self.onChange?(properties)
        }
    }
}

// MARK: - Desktop window

func makeDesktopWindow(for screen: NSScreen) -> NSWindow {
    let window = NSWindow(
        contentRect: screen.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    // Just below the desktop icons: above the static wallpaper, behind
    // everything interactive (Plash precedent).
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.ignoresMouseEvents = true
    window.isOpaque = true
    window.backgroundColor = .black
    window.isReleasedWhenClosed = false
    return window
}

// MARK: - Cover window (repose)

// The repose cover: a non-activating key panel above everything. Spike
// verdict (../repose/SPIKE.md): key status moves but focus is preserved on
// exit, the app never activates, and no Accessibility is needed. Media keys
// pass through because NX_SYSDEFINED events never reach key handling.
final class CoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

func makeCoverPanel(for screen: NSScreen) -> NSWindow {
    let panel = CoverPanel(
        contentRect: screen.frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                .fullScreenAuxiliary, .ignoresCycle]
    panel.isOpaque = true
    panel.backgroundColor = .black
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    return panel
}

// MARK: - Per-display hosts


final class VideoHost {
    let window: NSWindow
    let view: NSView
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper

    init(screen: NSScreen, url: URL, attachTo existingWindow: NSWindow? = nil) {
        window = existingWindow ?? makeDesktopWindow(for: screen)
        let item = AVPlayerItem(url: url)
        player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item)
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        let view = NSView(frame: existingWindow?.contentView?.bounds ?? screen.frame)
        self.view = view
        view.wantsLayer = true
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        if let container = existingWindow?.contentView {
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        } else {
            window.contentView = view
            window.orderFront(nil)
        }
        player.play()
    }

    func setPaused(_ paused: Bool) { paused ? player.pause() : player.play() }
}

final class ImageHost {
    let window: NSWindow
    let view: NSView

    init(screen: NSScreen, url: URL, attachTo existingWindow: NSWindow? = nil) {
        window = existingWindow ?? makeDesktopWindow(for: screen)
        view = NSView(frame: existingWindow?.contentView?.bounds ?? screen.frame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.contentsScale = screen.backingScaleFactor
        if let image = NSImage(contentsOf: url) {
            var proposed = NSRect(origin: .zero, size: image.size)
            view.layer?.contents = image.cgImage(
                forProposedRect: &proposed,
                context: nil,
                hints: nil
            )
        }
        if let container = existingWindow?.contentView {
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        } else {
            window.contentView = view
            window.orderFront(nil)
        }
    }
}

enum WebSurface {
    case desktop
    case cover
}

func webBridgeBootstrap(pendingPropertiesJSON: String,
                        generalPropertiesJSON: String,
                        directoryFilesJSON: String,
                        mediaSnapshotJSON: String) -> String {
    """
    window.__wePendingProps = \(pendingPropertiesJSON);
    window.__weGeneralProps = \(generalPropertiesJSON);
    window.__weDirectoryFiles = \(directoryFilesJSON);
    window.__wePaused = false;
    window.__weDocumentReady = document.readyState !== 'loading';
    window.__weLog = function (message) {
        try { webkit.messageHandlers.weLog.postMessage(String(message)); } catch (e) {}
    };
    window.__weErrorText = function (error) {
        if (!error) return String(error);
        const message = String(error.message || error);
        const name = String(error.name || 'Error');
        const stack = error.stack ? String(error.stack) : '';
        if (!stack) return name + ': ' + message;
        return stack.includes(message) ? stack : name + ': ' + message + '\\n' + stack;
    };
    window.__weReportedErrors = {};
    window.__weReportOnce = function (category, error) {
        const text = window.__weErrorText(error);
        const key = category + '\\n' + text;
        if (window.__weReportedErrors[key]) return;
        window.__weReportedErrors[key] = true;
        window.__weLog(category + ': ' + text);
    };

    window.__weAudio = [];
    window.__weAnnounceAudioReady = function () {
        try { webkit.messageHandlers.weAudioReady.postMessage(true); } catch (e) {}
    };
    window.wallpaperRegisterAudioListener = function (fn) {
        if (typeof fn !== 'function') return;
        window.__weAudio.push(fn);
        if (window.__weDocumentReady) {
            window.__weAnnounceAudioReady();
        } else {
            document.addEventListener('DOMContentLoaded', function () {
                setTimeout(window.__weAnnounceAudioReady, 0);
            }, { once: true });
        }
    };
    window.__wePushAudio = function (frame) {
        if (window.__wePaused) return;
        for (const fn of window.__weAudio) {
            try { fn(frame); } catch (e) { window.__weReportOnce('audio listener threw', e); }
        }
    };

    window.__wePL = null;
    window.__weDeliverInitialState = function (listener) {
        if (!listener) return;
        if (typeof listener.applyUserProperties === 'function') {
            try { listener.applyUserProperties(window.__wePendingProps || {}); }
            catch (e) { window.__weReportOnce('applyUserProperties threw', e); }
        }
        if (typeof listener.applyGeneralProperties === 'function') {
            try { listener.applyGeneralProperties(window.__weGeneralProps || {}); }
            catch (e) { window.__weReportOnce('applyGeneralProperties threw', e); }
        }
        if (window.__wePaused && typeof listener.setPaused === 'function') {
            try { listener.setPaused(true); }
            catch (e) { window.__weReportOnce('setPaused threw', e); }
        }
        if (typeof listener.userDirectoryFilesAddedOrChanged === 'function') {
            for (const propertyName of Object.keys(window.__weDirectoryFiles || {})) {
                try {
                    listener.userDirectoryFilesAddedOrChanged(
                        propertyName, window.__weDirectoryFiles[propertyName].slice());
                } catch (e) {
                    window.__weReportOnce('directory listener threw', e);
                }
            }
        }
    };
    window.__weInitialListener = null;
    window.__weScheduleInitialState = function () {
        if (!window.__weDocumentReady) return;
        const listener = window.__wePL;
        setTimeout(function () {
            if (!listener || listener !== window.__wePL || listener === window.__weInitialListener) return;
            window.__weInitialListener = listener;
            window.__weDeliverInitialState(listener);
        }, 0);
    };
    Object.defineProperty(window, 'wallpaperPropertyListener', {
        configurable: true,
        get: function () { return window.__wePL; },
        set: function (listener) {
            window.__wePL = listener;
            window.__weScheduleInitialState();
        }
    });
    window.__weApplyProps = function (props) {
        window.__wePendingProps = Object.assign(window.__wePendingProps || {}, props);
        const listener = window.__wePL;
        if (listener && typeof listener.applyUserProperties === 'function') {
            try { listener.applyUserProperties(props); }
            catch (e) { window.__weReportOnce('applyUserProperties threw', e); }
        }
    };
    window.__weApplyGeneralProperties = function (props) {
        window.__weGeneralProps = Object.assign(window.__weGeneralProps || {}, props);
        const listener = window.__wePL;
        if (listener && typeof listener.applyGeneralProperties === 'function') {
            try { listener.applyGeneralProperties(props); }
            catch (e) { window.__weReportOnce('applyGeneralProperties threw', e); }
        }
    };
    window.__weSetPaused = function (paused) {
        paused = Boolean(paused);
        if (window.__wePaused === paused) return;
        window.__wePaused = paused;
        const listener = window.__wePL;
        if (listener && typeof listener.setPaused === 'function') {
            try { listener.setPaused(paused); }
            catch (e) { window.__weReportOnce('setPaused threw', e); }
        }
    };

    window.__weRandomRequestID = 0;
    window.__weRandomCallbacks = {};
    window.wallpaperRequestRandomFileForProperty = function (propertyName, callback) {
        if (typeof callback !== 'function') return;
        const requestID = ++window.__weRandomRequestID;
        window.__weRandomCallbacks[requestID] = callback;
        try {
            webkit.messageHandlers.weRandomFile.postMessage({
                requestId: requestID, propertyName: String(propertyName)
            });
        } catch (e) {
            delete window.__weRandomCallbacks[requestID];
            setTimeout(function () { callback(String(propertyName), ''); }, 0);
        }
    };
    window.__weResolveRandomFile = function (requestID, propertyName, filePath) {
        const callback = window.__weRandomCallbacks[requestID];
        delete window.__weRandomCallbacks[requestID];
        if (callback) {
            try { callback(propertyName, filePath || ''); }
            catch (e) { window.__weReportOnce('random file callback threw', e); }
        }
    };
    window.__weUpdateDirectoryFiles = function (propertyName, files) {
        const previous = window.__weDirectoryFiles[propertyName] || [];
        const next = Array.isArray(files) ? files.slice() : [];
        const added = next.filter(function (path) { return !previous.includes(path); });
        const removed = previous.filter(function (path) { return !next.includes(path); });
        window.__weDirectoryFiles[propertyName] = next;
        const listener = window.__wePL;
        if (listener && added.length &&
            typeof listener.userDirectoryFilesAddedOrChanged === 'function') {
            try { listener.userDirectoryFilesAddedOrChanged(propertyName, added); }
            catch (e) { window.__weReportOnce('directory listener threw', e); }
        }
        if (listener && removed.length && typeof listener.userDirectoryFilesRemoved === 'function') {
            try { listener.userDirectoryFilesRemoved(propertyName, removed); }
            catch (e) { window.__weReportOnce('directory listener threw', e); }
        }
    };

    window.__weInput = function (type, payload) {
        payload = payload || {};
        const common = {
            bubbles: true, cancelable: true, clientX: payload.x || 0, clientY: payload.y || 0,
            button: payload.button || 0, buttons: payload.buttons || 0,
            ctrlKey: Boolean(payload.ctrlKey), shiftKey: Boolean(payload.shiftKey),
            altKey: Boolean(payload.altKey), metaKey: Boolean(payload.metaKey)
        };
        let event;
        if (type === 'wheel') {
            event = new WheelEvent(type, Object.assign(common, {
                deltaX: payload.deltaX || 0, deltaY: payload.deltaY || 0,
                deltaMode: WheelEvent.DOM_DELTA_PIXEL
            }));
        } else {
            event = new MouseEvent(type, common);
        }
        const target = document.elementFromPoint(common.clientX, common.clientY) || document;
        target.dispatchEvent(event);
    };
    window.__weMouse = function (x, y) {
        window.__weInput('mousemove', { x: x, y: y });
    };

    window.wallpaperMediaIntegration = {
        PLAYBACK_STOPPED: 0, PLAYBACK_PAUSED: 1, PLAYBACK_PLAYING: 2,
        playback: { STOPPED: 0, PAUSED: 1, PLAYING: 2 }
    };
    window.__weMediaLast = \(mediaSnapshotJSON);
    window.__weMediaFns = { status: [], properties: [], thumbnail: [], playback: [], timeline: [] };
    window.__weRegisterMedia = function (kind) {
        return function (fn) {
            if (typeof fn !== 'function') return;
            window.__weMediaFns[kind].push(fn);
            if (window.__weMediaLast[kind]) {
                try { fn(window.__weMediaLast[kind]); }
                catch (e) { window.__weReportOnce('media listener threw', e); }
            }
        };
    };
    window.wallpaperRegisterMediaStatusListener = window.__weRegisterMedia('status');
    window.wallpaperRegisterMediaPropertiesListener = window.__weRegisterMedia('properties');
    window.wallpaperRegisterMediaThumbnailListener = window.__weRegisterMedia('thumbnail');
    window.wallpaperRegisterMediaPlaybackListener = window.__weRegisterMedia('playback');
    window.wallpaperRegisterMediaTimelineListener = window.__weRegisterMedia('timeline');
    window.__wePushMedia = function (kind, payload) {
        window.__weMediaLast[kind] = payload;
        for (const fn of window.__weMediaFns[kind] || []) {
            try { fn(payload); }
            catch (e) { window.__weReportOnce('media listener threw', e); }
        }
    };
    window.wallpaperReady = window.wallpaperReady || function () {};

    window.__weResourceFailures = [];
    window.addEventListener('error', function (event) {
        const target = event.target;
        if (target && target !== window) {
            const url = String(target.currentSrc || target.src || target.href || '');
            const failure = {
                tag: String(target.tagName || '').toLowerCase(),
                parentTag: String(target.parentElement && target.parentElement.tagName || '')
                    .toLowerCase(),
                rel: String(target.rel || '').toLowerCase(),
                url: url
            };
            window.__weResourceFailures.push(failure);
            window.__weReportOnce('resource failed',
                new Error((failure.tag || 'resource') + ': ' + (url || '(unknown URL)')));
            return;
        }
        const location = (event.filename || '?') + ':' + (event.lineno || '?')
            + ':' + (event.colno || '?');
        window.__weReportOnce('page error @ ' + location,
            event.error || new Error(event.message));
    }, true);
    window.addEventListener('unhandledrejection', function (event) {
        window.__weReportOnce('unhandled rejection', event.reason);
    });
    document.addEventListener('DOMContentLoaded', function () {
        window.__weDocumentReady = true;
        window.__weScheduleInitialState();
        const style = document.createElement('style');
        style.textContent = 'img[src=""], img[src="file:///"] { visibility: hidden !important; }';
        document.head.appendChild(style);
    });
    """
}

final class WebHost: NSObject, WKScriptMessageHandler {
    let window: NSWindow
    let webView: WKWebView
    let screen: NSScreen
    let surface: WebSurface
    private(set) var paused = false
    private(set) var hasAudioListener = false
    var onPageLog: ((String) -> Void)?
    private let randomFiles: [String: [String]]
    private let accessScope: WebAccessScope
    var scopedRoot: URL { accessScope.root }
    var scopedProperties: [String: Any] { accessScope.properties }

    init(screen: NSScreen, index: URL, root: URL, properties: [String: Any],
         surface: WebSurface = .desktop, attachTo existingWindow: NSWindow? = nil,
         mediaSnapshotJSON: String = "{}", transparent: Bool = false,
         accessScope providedAccessScope: WebAccessScope? = nil,
         auditDiagnostics: Bool = false) {
        self.screen = screen
        self.surface = surface
        let accessScope = providedAccessScope
            ?? WebAccessScope(index: index, root: root, properties: properties)
        self.accessScope = accessScope
        let index = accessScope.index
        let root = accessScope.root
        let properties = accessScope.properties
        let directories = webDirectoryInventory(for: properties)
        randomFiles = directories.allFiles
        if let existingWindow {
            window = existingWindow
        } else {
            window = surface == .desktop ? makeDesktopWindow(for: screen)
                                         : makeCoverPanel(for: screen)
        }

        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // WE web wallpapers load local textures into WebGL; without this
        // the canvas is tainted and drawing fails (the fork's "web fix").
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // WE semantics: listeners receive their initial state whenever the
        // page registers, including wallpapers that register after async work.
        let fps = max(1, min(240,
            Int(ProcessInfo.processInfo.environment["FRESCO_FPS"] ?? "") ?? 30))
        let bootstrap = webBridgeBootstrap(
            pendingPropertiesJSON: jsonString(webUserProperties(from: properties)),
            generalPropertiesJSON: jsonString(["fps": fps]),
            directoryFilesJSON: jsonString(directories.fetchAllFiles),
            mediaSnapshotJSON: mediaSnapshotJSON
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if auditDiagnostics {
            configuration.userContentController.addUserScript(WKUserScript(
                source: webAuditDiagnosticsBootstrap(), injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        }

        webView = WKWebView(frame: screen.frame, configuration: configuration)
        if transparent {
            // composition over a backdrop view: the page body is transparent
            // (reposebackdrop: clear); the web view must not paint beneath it
            webView.setValue(false, forKey: "drawsBackground")
        }
        if let container = existingWindow?.contentView {
            webView.frame = container.bounds
            webView.autoresizingMask = [.width, .height]
            container.addSubview(webView)
            // the caller owns ordering of a shared window
        } else {
            window.contentView = webView
            if surface == .cover {
                window.orderFrontRegardless()
            } else {
                window.orderFront(nil)
            }
        }
        super.init()
        for name in ["weLog", "weRandomFile", "weAudioReady"] {
            webView.configuration.userContentController.add(self, name: name)
        }
        webView.loadFileURL(index, allowingReadAccessTo: root)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case "weLog":
            let text = String(describing: message.body)
            onPageLog?(text)
            print("page: \(text)")
        case "weAudioReady":
            hasAudioListener = true
        case "weRandomFile":
            guard let request = message.body as? [String: Any],
                  let requestID = request["requestId"] as? NSNumber,
                  let propertyName = request["propertyName"] as? String else { return }
            let candidates = randomFiles[propertyName]
                ?? randomFiles[propertyName.lowercased()] ?? []
            let path = candidates.randomElement() ?? ""
            let source = "window.__weResolveRandomFile(\(requestID.intValue), "
                + "\(jsonFragmentString(propertyName)), \(jsonFragmentString(path)))"
            webView.evaluateJavaScript(source, completionHandler: nil)
        default:
            break
        }
    }

    func invalidate() {
        webView.stopLoading()
        for name in ["weLog", "weRandomFile", "weAudioReady"] {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        accessScope.invalidate()
    }

    func push(properties: [String: Any], includeEmptyText: Bool = false) {
        let eventProperties = webUserProperties(
            from: scopedWebProperties(properties, using: accessScope.properties),
            includeEmptyText: includeEmptyText)
        guard !eventProperties.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: eventProperties),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__weApplyProps(\(json))", completionHandler: nil)
    }

    func push(audio frame: [Double]) {
        guard !paused, hasAudioListener else { return }
        let samples = frame.map { String(format: "%.3f", $0) }.joined(separator: ",")
        webView.evaluateJavaScript("window.__wePushAudio([\(samples)])", completionHandler: nil)
    }

    func push(mouseAt location: NSPoint) {
        pushInput(type: "mousemove", location: location, button: 0,
                  buttons: NSEvent.pressedMouseButtons, deltaX: 0, deltaY: 0,
                  modifiers: [])
    }

    func push(event: NSEvent) {
        let location = NSEvent.mouseLocation
        let type: String
        let button: Int
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            type = "mousemove"
            button = 0
        case .leftMouseDown:
            type = "mousedown"
            button = 0
        case .leftMouseUp:
            type = "mouseup"
            button = 0
        case .rightMouseDown:
            type = "mousedown"
            button = 2
        case .rightMouseUp:
            type = "mouseup"
            button = 2
        case .otherMouseDown:
            type = "mousedown"
            button = event.buttonNumber == 2 ? 1 : event.buttonNumber
        case .otherMouseUp:
            type = "mouseup"
            button = event.buttonNumber == 2 ? 1 : event.buttonNumber
        case .scrollWheel:
            type = "wheel"
            button = 0
        default:
            return
        }
        pushInput(type: type, location: location, button: button,
                  buttons: NSEvent.pressedMouseButtons,
                  deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                  modifiers: event.modifierFlags)
        if event.type == .leftMouseUp {
            pushInput(type: "click", location: location, button: 0,
                      buttons: NSEvent.pressedMouseButtons, deltaX: 0, deltaY: 0,
                      modifiers: event.modifierFlags)
        } else if event.type == .rightMouseUp {
            pushInput(type: "contextmenu", location: location, button: 2,
                      buttons: NSEvent.pressedMouseButtons, deltaX: 0, deltaY: 0,
                      modifiers: event.modifierFlags)
        }
    }

    private func pushInput(type: String, location: NSPoint, button: Int,
                           buttons: Int, deltaX: CGFloat, deltaY: CGFloat,
                           modifiers: NSEvent.ModifierFlags) {
        guard !paused, screen.frame.contains(location) else { return }
        let x = location.x - screen.frame.origin.x
        let y = screen.frame.height - (location.y - screen.frame.origin.y)
        let payload: [String: Any] = [
            "x": Int(x), "y": Int(y), "button": button, "buttons": buttons,
            "deltaX": deltaX, "deltaY": deltaY,
            "ctrlKey": modifiers.contains(.control), "shiftKey": modifiers.contains(.shift),
            "altKey": modifiers.contains(.option), "metaKey": modifiers.contains(.command),
        ]
        let source = "window.__weInput(\(jsonFragmentString(type)), \(jsonString(payload)))"
        webView.evaluateJavaScript(source, completionHandler: nil)
    }

    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        if !paused { webView.isHidden = false }
        webView.evaluateJavaScript("window.__weSetPaused(\(paused))") { [weak webView] _, _ in
            if paused { webView?.isHidden = true }
        }
    }
}

final class WebBridgeContractTest: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var audioReady = false
    private var pageLogs: [String] = []

    func run() -> Never {
        let configuration = WKWebViewConfiguration()
        let source = webBridgeBootstrap(
            pendingPropertiesJSON: jsonString(["accent": ["value": "blue"]]),
            generalPropertiesJSON: jsonString(["fps": 30]),
            directoryFilesJSON: jsonString(["slides": ["/tmp/slide.png"]]),
            mediaSnapshotJSON: jsonString(["status": ["enabled": true]])
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for name in ["weLog", "weRandomFile", "weAudioReady"] {
            configuration.userContentController.add(self, name: name)
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200),
                                configuration: configuration)
        self.webView = webView
        webView.navigationDelegate = self
        webView.loadHTMLString("<html><body><div id='target'>test</div></body></html>", baseURL: nil)
        Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
            fputs("web bridge self-test timed out\n", stderr)
            exit(1)
        }
        NSApplication.shared.run()
        fatalError("application run loop returned")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let exercise = """
        window.__test = {
            user: [], general: [], paused: [], directories: [], removed: [], random: null,
            audioLength: 0, mediaEnabled: false, inputs: [], constants: false
        };
        for (const type of ['mousemove', 'mousedown', 'mouseup', 'click', 'contextmenu', 'wheel']) {
            document.addEventListener(type, function (event) {
                window.__test.inputs.push({ type: event.type, x: event.clientX, y: event.clientY });
            });
        }
        window.wallpaperPropertyListener = {
            applyUserProperties: function (properties) { window.__test.user.push(properties); },
            applyGeneralProperties: function (properties) { window.__test.general.push(properties); },
            setPaused: function (paused) { window.__test.paused.push(paused); },
            userDirectoryFilesAddedOrChanged: function (name, files) {
                window.__test.directories.push({ name: name, files: files });
            },
            userDirectoryFilesRemoved: function (name, files) {
                window.__test.removed.push({ name: name, files: files });
            }
        };
        window.__weDeliverInitialState(window.wallpaperPropertyListener);
        window.wallpaperRegisterAudioListener(function (frame) {
            window.__test.audioLength = frame.length;
        });
        window.__wePushAudio(new Array(128).fill(0.5));
        window.wallpaperRegisterMediaStatusListener(function (status) {
            window.__test.mediaEnabled = status.enabled;
        });
        window.wallpaperRequestRandomFileForProperty('slides', function (name, path) {
            window.__test.random = { name: name, path: path };
        });
        setTimeout(function () {
            window.__weApplyProps({ speed: { value: 7 } });
            window.__weApplyGeneralProperties({ fps: 24 });
            window.__weSetPaused(true);
        }, 100);
        window.__weInput('mousemove', { x: 10, y: 11 });
        window.__weInput('mousedown', { x: 12, y: 13, button: 0, buttons: 1 });
        window.__weInput('mouseup', { x: 12, y: 13, button: 0 });
        window.__weInput('click', { x: 12, y: 13, button: 0 });
        window.__weInput('contextmenu', { x: 12, y: 13, button: 2 });
        window.__weInput('wheel', { x: 14, y: 15, deltaY: 3 });
        window.__weUpdateDirectoryFiles('slides', ['/tmp/new-slide.png']);
        window.__test.constants =
            window.wallpaperMediaIntegration.PLAYBACK_PLAYING === 2 &&
            window.wallpaperMediaIntegration.playback.PLAYING === 2;
        """
        webView.evaluateJavaScript(exercise) { [weak self] _, error in
            guard error == nil else {
                fputs("web bridge self-test setup failed: \(error!)\n", stderr)
                exit(1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self?.verify()
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case "weAudioReady":
            audioReady = true
        case "weLog":
            pageLogs.append(String(describing: message.body))
        case "weRandomFile":
            guard let request = message.body as? [String: Any],
                  let requestID = request["requestId"] as? NSNumber,
                  let propertyName = request["propertyName"] as? String else { return }
            let response = "window.__weResolveRandomFile(\(requestID.intValue), "
                + "\(jsonFragmentString(propertyName)), '/tmp/random.png')"
            webView?.evaluateJavaScript(response, completionHandler: nil)
        default:
            break
        }
    }

    private func verify() {
        webView?.evaluateJavaScript("JSON.stringify(window.__test)") { [weak self] value, error in
            guard let self, error == nil, let json = value as? String,
                  let data = json.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                fputs("web bridge self-test result unavailable\n", stderr)
                exit(1)
            }
            let user = result["user"] as? [[String: Any]] ?? []
            let sawAccent = user.contains {
                (($0["accent"] as? [String: Any])?["value"] as? String) == "blue"
            }
            let sawSpeed = user.contains {
                (($0["speed"] as? [String: Any])?["value"] as? NSNumber)?.intValue == 7
            }
            let general = result["general"] as? [[String: Any]] ?? []
            let fpsValues = Set(general.compactMap { ($0["fps"] as? NSNumber)?.intValue })
            let paused = result["paused"] as? [Bool] ?? []
            let directories = result["directories"] as? [[String: Any]] ?? []
            let directoryOK = directories.contains {
                $0["name"] as? String == "slides"
                    && ($0["files"] as? [String]) == ["/tmp/slide.png"]
            }
            let random = result["random"] as? [String: Any]
            let randomOK = random?["name"] as? String == "slides"
                && random?["path"] as? String == "/tmp/random.png"
            let inputTypes = Set((result["inputs"] as? [[String: Any]] ?? [])
                .compactMap { $0["type"] as? String })
            let removed = result["removed"] as? [[String: Any]] ?? []
            let removalOK = removed.contains {
                $0["name"] as? String == "slides"
                    && ($0["files"] as? [String]) == ["/tmp/slide.png"]
            }
            let passed = audioReady && pageLogs.isEmpty && sawAccent && sawSpeed
                && fpsValues.contains(24) && paused.contains(true)
                && directoryOK && removalOK && randomOK
                && (result["audioLength"] as? NSNumber)?.intValue == 128
                && result["mediaEnabled"] as? Bool == true
                && inputTypes == Set([
                    "mousemove", "mousedown", "mouseup", "click", "contextmenu", "wheel",
                ])
                && result["constants"] as? Bool == true
            guard passed else {
                fputs("web bridge self-test failed: \(json); logs=\(pageLogs)\n", stderr)
                exit(1)
            }
            print("web bridge self-test passed")
            exit(0)
        }
    }
}


func desktopReceives(_ event: NSEvent) -> Bool {
    guard let cgEvent = event.cgEvent else { return false }
    let rawWindowID = cgEvent.getIntegerValueField(
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
    guard rawWindowID > 0 else { return true }
    let windowID = CGWindowID(rawWindowID)
    guard let window = (CGWindowListCopyWindowInfo(
        .optionIncludingWindow, windowID
    ) as? [[String: Any]])?.first else { return false }
    let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? 0
    if ownerPID == ProcessInfo.processInfo.processIdentifier { return true }
    let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    return layer < 0
}

private protocol WebRuntimeDisplayAssignment: RuntimeDisplayAssignment {
    var webHost: WebHost { get }
    var webRoot: URL { get }
    var properties: [String: Any] { get }
    func setUserProperties(_ properties: [String: Any], changed: [String: Any])
}

private protocol SceneRuntimeDisplayAssignment:
    RuntimeDisplayAssignment, RuntimeSceneAudioEndpoint {
    var sceneSupervisor: SceneHelperSupervisor? { get }
    var sceneRoot: URL { get }
    var properties: [String: Any] { get }
    func setMuted(_ muted: Bool, completion: (() -> Void)?)
    func setUserProperties(_ properties: [String: Any], changed: [String: Any])
}

private protocol OcclusionRuntimeDisplayAssignment: RuntimeDisplayAssignment {
    func updateOcclusion(window: NSWindow, visible: Bool)
}

private final class ImageRuntimeAssignment: OcclusionRuntimeDisplayAssignment {
    let displayID: String
    let binding: FrescoBinding
    private let host: ImageHost
    private let target: String
    private let startedAt = ISO8601DateFormatter().string(from: Date())
    private(set) var isOccluded = false

    init(displayID: String, binding: FrescoBinding, screen: NSScreen, url: URL) {
        self.displayID = displayID
        self.binding = binding
        target = url.path
        host = ImageHost(screen: screen, url: url)
    }

    var evidence: RuntimeAssignmentEvidence {
        RuntimeAssignmentEvidence(
            displayID: displayID, status: .running, target: target,
            firstFrameAt: startedAt, error: nil)
    }
    func setPaused(_ paused: Bool) {}
    func updateOcclusion(window: NSWindow, visible: Bool) {
        if host.window == window { isOccluded = !visible }
    }
    func setVisible(_ visible: Bool) {
        visible ? host.window.orderFront(nil) : host.window.orderOut(nil)
    }
    func stop() { host.window.orderOut(nil) }
}

private final class VideoRuntimeAssignment: OcclusionRuntimeDisplayAssignment {
    let displayID: String
    let binding: FrescoBinding
    private let host: VideoHost
    private let target: String
    private let startedAt = ISO8601DateFormatter().string(from: Date())
    private(set) var isOccluded = false

    init(displayID: String, binding: FrescoBinding, screen: NSScreen, url: URL) {
        self.displayID = displayID
        self.binding = binding
        target = url.path
        host = VideoHost(screen: screen, url: url)
    }

    var evidence: RuntimeAssignmentEvidence {
        RuntimeAssignmentEvidence(
            displayID: displayID, status: .running, target: target,
            firstFrameAt: startedAt, error: nil)
    }
    func setPaused(_ paused: Bool) { host.setPaused(paused) }
    func updateOcclusion(window: NSWindow, visible: Bool) {
        if host.window == window {
            isOccluded = !visible
            host.setPaused(!visible)
        }
    }
    func setVisible(_ visible: Bool) {
        visible ? host.window.orderFront(nil) : host.window.orderOut(nil)
    }
    func stop() {
        host.setPaused(true)
        host.window.orderOut(nil)
    }
}

private final class DesktopWebRuntimeAssignment:
    WebRuntimeDisplayAssignment, OcclusionRuntimeDisplayAssignment {
    let displayID: String
    let binding: FrescoBinding
    let webHost: WebHost
    let webRoot: URL
    private(set) var properties: [String: Any]
    private let target: String
    private let startedAt = ISO8601DateFormatter().string(from: Date())
    private(set) var isOccluded = false

    init(displayID: String, binding: FrescoBinding, screen: NSScreen, index: URL, root: URL,
         properties: [String: Any], effectiveProperties: [String: Any],
         mediaSnapshotJSON: String,
         accessScope: WebAccessScope) {
        self.displayID = displayID
        self.binding = binding
        webRoot = root.standardizedFileURL
        self.properties = properties
        target = root.path
        webHost = WebHost(
            screen: screen, index: index, root: root, properties: effectiveProperties,
            mediaSnapshotJSON: mediaSnapshotJSON, accessScope: accessScope)
    }

    var evidence: RuntimeAssignmentEvidence {
        RuntimeAssignmentEvidence(
            displayID: displayID, status: .running, target: target,
            firstFrameAt: startedAt, error: nil)
    }
    func setPaused(_ paused: Bool) { webHost.setPaused(paused) }
    func updateOcclusion(window: NSWindow, visible: Bool) {
        if webHost.window == window {
            isOccluded = !visible
            webHost.setPaused(!visible)
        }
    }
    func setVisible(_ visible: Bool) {
        visible ? webHost.window.orderFront(nil) : webHost.window.orderOut(nil)
    }
    func setUserProperties(_ properties: [String: Any], changed: [String: Any]) {
        self.properties = properties
        webHost.push(properties: changed, includeEmptyText: true)
    }
    func stop() {
        webHost.invalidate()
        webHost.window.orderOut(nil)
    }
}

private final class DesktopSceneRuntimeAssignment: SceneRuntimeDisplayAssignment {
    let displayID: String
    let binding: FrescoBinding
    let sceneSupervisor: SceneHelperSupervisor?
    let sceneRoot: URL
    private(set) var properties: [String: Any]
    private let runtimePropertyNames: Set<String>
    private let fallback: ImageHost?
    private let target: String
    private var ready = false
    private var visible = true
    private var firstFrameAt: String?
    private var evidenceError: String?
    private var retiring = false
    private var retirementMuted = false
    private var retirementMuteCompletions: [() -> Void] = []
    private var retirementTimer: Timer?
    private let onEvidenceChanged: () -> Void

    init(displayID: String, binding: FrescoBinding, screen: NSScreen, root: URL, preview: URL?,
         properties: [String: Any], runtimePropertyNames: Set<String>,
         executable: URL?, assetRoot: String?, fpsCeiling: Int? = nil,
         policyRevision: Int = 0, policyReasonTokens: [String] = [],
         onAudioSupportChanged: @escaping () -> Void,
         onEvidenceChanged: @escaping () -> Void) {
        self.displayID = displayID
        self.binding = binding
        sceneRoot = root.standardizedFileURL
        self.properties = properties
        self.runtimePropertyNames = runtimePropertyNames
        target = root.path
        self.onEvidenceChanged = onEvidenceChanged
        fallback = preview.map { ImageHost(screen: screen, url: $0) }
        guard let executable else {
            sceneSupervisor = nil
            evidenceError = "scene helper unavailable"
            return
        }
        let supervisor = SceneHelperSupervisor(
            executable: executable,
            project: root,
            assetRoot: assetRoot,
            assignmentID: displayID,
            displayFrame: screen.frame,
            fpsCeiling: fpsCeiling,
            policyRevision: policyRevision,
            policyReasonTokens: policyReasonTokens,
            userProperties: Self.supportedUserProperties(
                from: properties, names: runtimePropertyNames))
        sceneSupervisor = supervisor
        supervisor.setMuted(true)
        supervisor.onEvent = { [weak self, weak supervisor] event in
            guard let self, let type = event["type"] as? String,
                  ["unsupported", "fatal", "ready"].contains(type) else { return }
            let code = event["code"] as? String
            print("scene \(supervisor?.assignmentID ?? self.displayID): \(type)"
                + (code.map { " (\($0))" } ?? ""))
            if type == "ready" {
                self.ready = true
                self.firstFrameAt = ISO8601DateFormatter().string(from: Date())
                self.evidenceError = nil
                self.updateFallbackVisibility()
                self.onEvidenceChanged()
            } else {
                self.evidenceError = code ?? type
                self.onEvidenceChanged()
            }
        }
        supervisor.onUnavailable = { [weak self] in
            guard let self else { return }
            if self.retiring {
                self.finishRetirement()
                return
            }
            self.ready = false
            self.evidenceError = "scene helper unavailable"
            self.updateFallbackVisibility()
            self.onEvidenceChanged()
        }
        supervisor.onExhausted = { [weak supervisor] in
            print("scene \(supervisor?.assignmentID ?? displayID): "
                + "restart limit reached; preview retained")
        }
        supervisor.onAudioSupportChanged = onAudioSupportChanged
        supervisor.start()
    }

    var evidence: RuntimeAssignmentEvidence {
        RuntimeAssignmentEvidence(
            displayID: displayID,
            status: ready ? .running : evidenceError == nil ? .starting : .degraded,
            target: target,
            firstFrameAt: firstFrameAt,
            error: evidenceError)
    }
    func setPaused(_ paused: Bool) { sceneSupervisor?.setPaused(paused) }
    func setMuted(_ muted: Bool) { setMuted(muted, completion: nil) }
    func setMuted(_ muted: Bool, completion: (() -> Void)?) {
        if retiring {
            guard muted else {
                completion?()
                return
            }
            if retirementMuted {
                completion?()
            } else if let completion {
                retirementMuteCompletions.append(completion)
            }
            return
        }
        guard let sceneSupervisor else {
            completion?()
            return
        }
        sceneSupervisor.setMuted(muted, completion: completion)
    }
    func setUserProperties(_ properties: [String: Any], changed: [String: Any]) {
        self.properties = properties
        sceneSupervisor?.setUserProperties(
            Self.supportedUserProperties(from: properties, names: runtimePropertyNames),
            changed: Self.supportedUserProperties(
                from: changed, names: runtimePropertyNames))
    }
    func setVisible(_ visible: Bool) {
        self.visible = visible
        sceneSupervisor?.setVisible(visible)
        updateFallbackVisibility()
    }
    func setSchedulingPolicy(
        fpsCeiling: Int?, policyRevision: Int, reasonTokens: [String]
    ) {
        sceneSupervisor?.setSchedulingPolicy(
            fpsCeiling: fpsCeiling,
            policyRevision: policyRevision,
            reasonTokens: reasonTokens)
    }
    func stop() {
        guard !retiring else { return }
        retiring = true
        fallback?.window.orderOut(nil)
        guard let sceneSupervisor else {
            finishRetirement()
            return
        }
        retirementTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) {
            [weak self, weak sceneSupervisor] _ in
            guard let self else { return }
            guard let sceneSupervisor else {
                self.finishRetirement()
                return
            }
            sceneSupervisor.forceStop { [weak self] in self?.finishRetirement() }
        }
        sceneSupervisor.setMuted(true) { [sceneSupervisor, self] in
            sceneSupervisor.stop { self.finishRetirement() }
        }
    }

    private func finishRetirement() {
        guard !retirementMuted else { return }
        retirementMuted = true
        retirementTimer?.invalidate()
        retirementTimer = nil
        let completions = retirementMuteCompletions
        retirementMuteCompletions.removeAll()
        completions.forEach { $0() }
    }

    private func updateFallbackVisibility() {
        guard let fallback else { return }
        visible && !ready ? fallback.window.orderFront(nil) : fallback.window.orderOut(nil)
    }

    private static func supportedUserProperties(
        from source: [String: Any], names: Set<String>
    ) -> [String: Any] {
        sceneUserProperties(from: source.filter { names.contains($0.key) })
    }
}

// MARK: - Controller

final class RuntimeController: NSObject, NSApplicationDelegate {
    private static let muteHotKeyID = EventHotKeyID(
        signature: OSType(0x46525343), id: 1) // FRSC
    private var sceneSchedulingPolicyRevision = 0
    private static let muteHotKeyHandler: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard status == noErr, hotKeyID.id == RuntimeController.muteHotKeyID.id,
              hotKeyID.signature == RuntimeController.muteHotKeyID.signature else {
            return OSStatus(eventNotHandledErr)
        }
        let controller = Unmanaged<RuntimeController>.fromOpaque(context)
            .takeUnretainedValue()
        DispatchQueue.main.async { controller.toggleMuteFromHotKey() }
        return noErr
    }

    private let initialWallpaper: Wallpaper?
    private let sceneAudioCoordinator = RuntimeSceneAudioCoordinator()
    private let daemon: Bool
    private struct CoverDisplay {
        let panel: NSWindow
        let screen: NSScreen
        var backdropImage: ImageHost?
        var backdropWeb: WebHost?
        var backdropVideo: VideoHost?
        let composition: WebHost
    }

    private let desktopAssignments = RuntimeAssignmentRegistry()
    private var coverDisplays: [CoverDisplay] = []
    private var coverScene = "desktop"
    private var compositionRoot: URL?
    private var reposeState = ReposeState.load()
    private var coverMonitor: Any?
    private var coverBarHidden = false
    private let audioTap = AudioTap()
    private let mediaFeed = MediaFeed()
    private let agentFeed = AgentFeed()
    private var mouseMonitor: Any?
    private var muteHotKey: EventHotKeyRef?
    private var muteHotKeyEventHandler: EventHandlerRef?
    private var liveryTimer: Timer?
    private var liveryModified: Date?
    private var projectProperties: [String: Any] = [:]
    private var webServicesStarted = false
    private var audioTapStarted = false
    private let stateStore = FrescoStateStore(directory: runtimeDirectory)
    private let statusPublisher = FrescoStatusPublisher(
        file: runtimeDirectory.appendingPathComponent("status.json"))
    private let runtimeGeneration = "generation:" + UUID().uuidString.lowercased()
    private var sleeping = false
    private var lastStateDiagnostics: [String] = []
    private var cloneCompatibilityDisplayIDs: Set<String> = []

    init(wallpaper: Wallpaper?, daemon: Bool) {
        self.initialWallpaper = wallpaper
        self.daemon = daemon
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if daemon {
            try? FileManager.default.createDirectory(at: runtimeDirectory,
                                                     withIntermediateDirectories: true)
            WebAccessScope.removeStaleDirectories()
            try? "\(ProcessInfo.processInfo.processIdentifier)"
                .write(to: pidFile, atomically: true, encoding: .utf8)
        }
        observeOcclusion()
        observeLock()
        observeSystemState()
        if daemon {
            installMuteHotKey()
            reloadFromState()
        } else if let wallpaper = initialWallpaper {
            apply(wallpaper)
        } else {
            print("daemon idle — set a wallpaper with: fresco set <path-or-workshop-id>")
        }
    }

    func reloadFromConfig() {
        reloadFromState()
    }

    private func installMuteHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), Self.muteHotKeyHandler, 1, &eventType,
            context, &muteHotKeyEventHandler)
        guard handlerStatus == noErr else {
            print("audio: global mute shortcut unavailable (handler \(handlerStatus))")
            return
        }
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), Self.muteHotKeyID,
            GetApplicationEventTarget(), 0, &muteHotKey)
        guard hotKeyStatus == noErr else {
            if let muteHotKeyEventHandler { RemoveEventHandler(muteHotKeyEventHandler) }
            muteHotKeyEventHandler = nil
            print("audio: global mute shortcut unavailable (registration \(hotKeyStatus))")
            return
        }
        print("audio: global mute shortcut registered (control-option-M)")
    }

    private func toggleMuteFromHotKey() {
        do {
            var accepted: FrescoState?
            for _ in 0..<3 {
                let revision = try stateStore.load().state.revision
                do {
                    accepted = try stateStore.setMuted(nil, expectedRevision: revision)
                    break
                } catch FrescoStateStoreError.revisionConflict {
                    continue
                }
            }
            guard let accepted else {
                throw FrescoStateStoreError.writeFailed(
                    path: runtimeDirectory.appendingPathComponent("state.json").path,
                    error: "state changed during three mute-toggle attempts")
            }
            reloadFromState()
            let state = accepted.desired.controls?.muted == true ? "muted" : "unmuted"
            print("fresco audio: \(state)")
        } catch {
            print("audio: mute shortcut failed: \(error)")
        }
    }

    func reloadUserProperties() {
        let sceneAssignments = desktopAssignments.values.compactMap {
            $0 as? any SceneRuntimeDisplayAssignment
        }
        var scenePushes = 0
        for assignment in sceneAssignments {
            guard case let .wallpaper(target) = assignment.binding,
                  case let .scene(root, _, _, newProperties, _)?
                    = resolveAssignmentWallpaper(target, displayID: assignment.displayID),
                  root.standardizedFileURL == assignment.sceneRoot else { continue }
            let changes = changedWebProperties(from: assignment.properties, to: newProperties)
            guard !changes.isEmpty else { continue }
            assignment.setUserProperties(newProperties, changed: changes)
            scenePushes += changes.count
        }

        if daemon {
            let webAssignments = desktopAssignments.values.compactMap {
                $0 as? any WebRuntimeDisplayAssignment
            }
            var webPushes = 0
            var webReloads: [String] = []
            for assignment in webAssignments {
                guard case let .wallpaper(target) = assignment.binding,
                      case let .web(_, root, newProperties)?
                        = resolveAssignmentWallpaper(target, displayID: assignment.displayID),
                      root.standardizedFileURL == assignment.webRoot else { continue }
                let rawChanges = changedWebProperties(
                    from: assignment.properties, to: newProperties)
                guard !rawChanges.isEmpty else { continue }
                let effectiveChanges = changedWebProperties(
                    from: mergedProperties(project: assignment.properties),
                    to: mergedProperties(project: newProperties))
                let scoped = rawChanges.values.contains { rawDefinition in
                    guard let definition = rawDefinition as? [String: Any] else { return false }
                    let type = (definition["type"] as? String ?? "").lowercased()
                    return type == "file" || type == "directory"
                }
                if scoped {
                    webReloads.append(assignment.displayID)
                } else {
                    assignment.setUserProperties(newProperties, changed: effectiveChanges)
                    webPushes += effectiveChanges.count
                }
            }
            if !webReloads.isEmpty {
                for displayID in webReloads {
                    desktopAssignments.invalidateConfiguration(displayID: displayID)
                }
                reloadFromState()
            }
            if scenePushes + webPushes == 0 && webReloads.isEmpty {
                print("properties: no effective state change")
            } else {
                print("properties: pushed \(scenePushes + webPushes) changed value(s)"
                    + (webReloads.isEmpty ? "" : "; reloaded \(webReloads.count) display(s)"))
            }
            return
        }

        guard !desktopWebHosts.isEmpty, let path = configuredWallpaperPath(),
              case .web(_, _, let newProperties)? = resolveWallpaper(path) else {
            if scenePushes == 0 && !sceneAssignments.isEmpty {
                print("properties: no effective state change")
            } else if scenePushes > 0 {
                print("properties: pushed \(scenePushes) changed scene value(s)")
            }
            return
        }
        let rawChanges = changedWebProperties(from: projectProperties, to: newProperties)
        guard !rawChanges.isEmpty else {
            print("properties: no effective state change")
            if scenePushes > 0 {
                print("properties: pushed \(scenePushes) changed scene value(s)")
            }
            return
        }
        let scopedChange = rawChanges.values.contains { rawDefinition in
            guard let definition = rawDefinition as? [String: Any] else { return false }
            let type = (definition["type"] as? String ?? "").lowercased()
            return type == "file" || type == "directory"
        }
        if scopedChange, let wallpaper = resolveWallpaper(path) {
            if daemon {
                desktopAssignments.removeAll()
                reloadFromState()
            } else {
                apply(wallpaper)
            }
            print("properties: scoped selection changed — web hosts reloaded")
            return
        }

        let previousEffective = mergedProperties()
        projectProperties = newProperties
        let effectiveChanges = changedWebProperties(
            from: previousEffective, to: mergedProperties())
        guard !effectiveChanges.isEmpty else {
            print("properties: state changed behind a higher-priority runtime value")
            return
        }
        desktopWebHosts.forEach { $0.push(properties: effectiveChanges, includeEmptyText: true) }
        print("properties: pushed \(effectiveChanges.count) changed web value(s)"
            + (scenePushes > 0 ? " and \(scenePushes) changed scene value(s)" : ""))
    }

    private func teardownHosts(reconcileServices: Bool = true) {
        desktopAssignments.removeAll()
        if reconcileServices { reconcileWebServices() }
    }

    private func apply(_ wallpaper: Wallpaper) {
        teardownHosts(reconcileServices: false)
        switch wallpaper {
        case .image(let url):
            projectProperties = [:]
            desktopAssignments.reconcile(
                displays: NSScreen.screens,
                identify: FrescoMacObservation.displayID,
                create: {
                    ImageRuntimeAssignment(
                        displayID: $0, binding: .wallpaper(target: url.path),
                        screen: $1, url: url)
                })
            print("image wallpaper on \(desktopAssignments.count) display(s): \(url.lastPathComponent)")
        case .video(let url):
            projectProperties = [:]
            desktopAssignments.reconcile(
                displays: NSScreen.screens,
                identify: FrescoMacObservation.displayID,
                create: {
                    VideoRuntimeAssignment(
                        displayID: $0, binding: .wallpaper(target: url.path),
                        screen: $1, url: url)
                })
            print("video wallpaper on \(desktopAssignments.count) display(s): \(url.lastPathComponent)")
        case .web(let index, let root, let properties):
            projectProperties = properties
            let pending = mergedProperties()
            let mediaSnapshot = mediaFeed.snapshotJSON()
            let accessScope = WebAccessScope(index: index, root: root, properties: pending)
            desktopAssignments.reconcile(
                displays: NSScreen.screens,
                identify: FrescoMacObservation.displayID,
                create: {
                    DesktopWebRuntimeAssignment(
                        displayID: $0, binding: .wallpaper(target: root.path),
                        screen: $1, index: index, root: root,
                        properties: properties, effectiveProperties: pending,
                        mediaSnapshotJSON: mediaSnapshot,
                        accessScope: accessScope)
                })
            print("web wallpaper on \(desktopAssignments.count) display(s): \(root.lastPathComponent)")
        case .scene(let root, _, let preview, let properties, let runtimePropertyNames):
            projectProperties = [:]
            startSceneAssignments(
                root: root, preview: preview, properties: properties,
                runtimePropertyNames: runtimePropertyNames,
                binding: .wallpaper(target: root.path))
            let fallback = preview == nil ? "system wallpaper" : "Workshop preview"
            print("scene fallback on \(desktopAssignments.count) display(s): "
                + "\(root.lastPathComponent) (\(fallback))")
        }
        reconcileWebServices()
        publishStatus()
    }

    private func reloadFromState() {
        guard daemon else { return }
        do {
            let loaded = try stateStore.load()
            reportStateDiagnostics(loaded.diagnostics)
            let observed = observedContext()
            let plan = FrescoStatePlanner.plan(state: loaded.state, observed: observed)
            sceneSchedulingPolicyRevision += 1
            let schedulingPolicyRevision = sceneSchedulingPolicyRevision
            reconcileStatePlan(
                plan,
                observed: observed,
                schedulingPolicyRevision: schedulingPolicyRevision)
            print("state: \(plan.displays.first?.layoutMode.rawValue ?? "clone") "
                + "revision \(loaded.state.revision) reconciled")
            applyEffectivePolicy(
                plan, schedulingPolicyRevision: schedulingPolicyRevision)
            try publishStatus(observed: observedContext(), plan: plan)
        } catch {
            print("state: reconciliation failed (\(error))")
            publishStatus()
        }
    }

    private func reconcileStatePlan(
        _ plan: FrescoEffectivePlan,
        observed: FrescoObservedContext,
        schedulingPolicyRevision: Int
    ) {
        cloneCompatibilityDisplayIDs = Set(plan.displays.compactMap {
            $0.layoutMode == .clone ? $0.displayId : nil
        })
        let screens = Dictionary(
            NSScreen.screens.map { (FrescoMacObservation.displayID(for: $0), $0) },
            uniquingKeysWith: { first, _ in first })
        let observedDisplays = Dictionary(
            observed.displays.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var requests: [RuntimeAssignmentRequest] = []
        var wallpapers: [String: Wallpaper] = [:]
        var unresolved: [String: String] = [:]
        let spanDeferred = plan.displays.contains { $0.layoutMode == .span }

        for display in plan.displays {
            let configuration = observedDisplays[display.displayId].map {
                "\($0.frame.x),\($0.frame.y),\($0.frame.width),\($0.frame.height)@\($0.scale)"
            }
            switch display.binding {
            case .idle where !spanDeferred:
                continue
            case .idle:
                requests.append(RuntimeAssignmentRequest(
                    displayID: display.displayId,
                    binding: display.binding,
                    configurationToken: configuration))
                unresolved[display.displayId] = "span layout is deferred"
            case .playlist:
                requests.append(RuntimeAssignmentRequest(
                    displayID: display.displayId,
                    binding: display.binding,
                    configurationToken: configuration))
                unresolved[display.displayId] = "playlist binding is deferred"
            case let .wallpaper(target):
                let request = RuntimeAssignmentRequest(
                    displayID: display.displayId,
                    binding: display.binding,
                    configurationToken: configuration)
                requests.append(request)
                if spanDeferred {
                    unresolved[display.displayId] = "span layout is deferred"
                } else if let wallpaper = display.layoutMode == .clone
                    ? resolveStateWallpaper(target)
                    : resolveStateWallpaperExact(target) {
                    wallpapers[display.displayId] = wallpaper
                } else {
                    unresolved[display.displayId]
                        = "wallpaper target did not resolve: \(target)"
                }
            }
        }

        projectProperties = [:]
        desktopAssignments.reconcile(requests: requests, unresolved: unresolved) {
            [weak self] request in
            guard let self,
                  let screen = screens[request.displayID],
                  let wallpaper = wallpapers[request.displayID],
                  let effective = plan.displays.first(where: {
                      $0.displayId == request.displayID
                  }) else {
                preconditionFailure("resolved plan referenced an unavailable display")
            }
            return self.makeAssignment(
                displayID: request.displayID,
                binding: request.binding,
                screen: screen,
                wallpaper: wallpaper,
                effective: effective,
                policyRevision: schedulingPolicyRevision)
        }
        reconcileWebServices()
    }

    private func resolveAssignmentWallpaper(
        _ target: String, displayID: String
    ) -> Wallpaper? {
        cloneCompatibilityDisplayIDs.contains(displayID)
            ? resolveStateWallpaper(target)
            : resolveStateWallpaperExact(target)
    }

    private func makeAssignment(
        displayID: String, binding: FrescoBinding, screen: NSScreen, wallpaper: Wallpaper,
        effective: FrescoEffectiveDisplay, policyRevision: Int
    ) -> any RuntimeDisplayAssignment {
        switch wallpaper {
        case let .image(url):
            return ImageRuntimeAssignment(
                displayID: displayID, binding: binding, screen: screen, url: url)
        case let .video(url):
            return VideoRuntimeAssignment(
                displayID: displayID, binding: binding, screen: screen, url: url)
        case let .web(index, root, properties):
            let pending = mergedProperties(project: properties)
            return DesktopWebRuntimeAssignment(
                displayID: displayID,
                binding: binding,
                screen: screen,
                index: index,
                root: root,
                properties: properties,
                effectiveProperties: pending,
                mediaSnapshotJSON: mediaFeed.snapshotJSON(),
                accessScope: WebAccessScope(index: index, root: root, properties: pending))
        case let .scene(root, _, preview, properties, runtimePropertyNames):
            let executable = FileManager.default.isExecutableFile(atPath: sceneHelperFile.path)
                ? sceneHelperFile : nil
            return DesktopSceneRuntimeAssignment(
                displayID: displayID,
                binding: binding,
                screen: screen,
                root: root,
                preview: preview,
                properties: properties,
                runtimePropertyNames: runtimePropertyNames,
                executable: executable,
                assetRoot: configuredSceneAssetPath(),
                fpsCeiling: effective.fpsCeiling,
                policyRevision: policyRevision,
                policyReasonTokens: effective.reasons.fpsCeiling,
                onAudioSupportChanged: { [weak self] in self?.reconcileAudioTap() },
                onEvidenceChanged: { [weak self] in self?.publishStatus() })
        }
    }

    private func applyEffectivePolicy(
        _ plan: FrescoEffectivePlan, schedulingPolicyRevision: Int
    ) {
        let byDisplay = Dictionary(uniqueKeysWithValues: plan.displays.map { ($0.displayId, $0) })
        for assignment in desktopAssignments.values {
            guard let effective = byDisplay[assignment.displayID] else { continue }
            assignment.setPaused(effective.reasons.isPaused)
            assignment.setVisible(!effective.reasons.isHidden)
            assignment.setSchedulingPolicy(
                fpsCeiling: effective.fpsCeiling,
                policyRevision: schedulingPolicyRevision,
                reasonTokens: effective.reasons.fpsCeiling)
        }
        applySceneAudioOwnership(plan, byDisplay: byDisplay)
    }

    private func applySceneAudioOwnership(
        _ plan: FrescoEffectivePlan,
        byDisplay: [String: FrescoEffectiveDisplay]
    ) {
        let scenes = desktopAssignments.values.compactMap {
            $0 as? any SceneRuntimeDisplayAssignment
        }
        let policyMuted = Set(scenes.compactMap {
            byDisplay[$0.displayID]?.reasons.isMuted == true ? $0.displayID : nil
        })
        sceneAudioCoordinator.reconcile(
            endpoints: scenes,
            policyMutedDisplayIDs: policyMuted)
    }

    private func startSceneAssignments(
        root: URL, preview: URL?, properties: [String: Any],
        runtimePropertyNames: Set<String>, binding: FrescoBinding
    ) {
        let executable: URL?
        if FileManager.default.isExecutableFile(atPath: sceneHelperFile.path) {
            executable = sceneHelperFile
        } else {
            executable = nil
            print("scene: helper unavailable; run `fresco scene-build`")
        }
        let assetRoot = configuredSceneAssetPath()
        if assetRoot == nil {
            print("scene: official assets not configured; run `fresco scene-assets set <path>`")
        }
        desktopAssignments.reconcile(
            displays: NSScreen.screens,
            identify: FrescoMacObservation.displayID,
            create: { [weak self] displayID, screen in
                return DesktopSceneRuntimeAssignment(
                    displayID: displayID, binding: binding, screen: screen,
                    root: root, preview: preview, properties: properties,
                    runtimePropertyNames: runtimePropertyNames,
                    executable: executable, assetRoot: assetRoot,
                    onAudioSupportChanged: { [weak self] in self?.reconcileAudioTap() },
                    onEvidenceChanged: { [weak self] in self?.publishStatus() })
            })
        sceneAudioCoordinator.reconcile(
            endpoints: desktopAssignments.values.compactMap {
                $0 as? any SceneRuntimeDisplayAssignment
            },
            policyMutedDisplayIDs: [])
    }

    private var coverWebHosts: [WebHost] {
        coverDisplays.flatMap { [$0.backdropWeb, $0.composition].compactMap { $0 } }
    }
    private var desktopWebHosts: [WebHost] {
        desktopAssignments.values.compactMap {
            ($0 as? any WebRuntimeDisplayAssignment)?.webHost
        }
    }
    private var sceneSupervisors: [SceneHelperSupervisor] {
        desktopAssignments.values.compactMap {
            ($0 as? any SceneRuntimeDisplayAssignment)?.sceneSupervisor
        }
    }
    private var allWebHosts: [WebHost] { desktopWebHosts + coverWebHosts }

    // MARK: Repose cover (SIGUSR2; command written by `fresco repose*`)

    func handleReposeCommand() {
        guard let raw = try? String(contentsOf: reposeCommandFile, encoding: .utf8) else { return }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let action = (lines.first ?? "").split(separator: " ").first.map(String.init) ?? "toggle"
        let path = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespaces) : ""
        reposeState = ReposeState.load()

        if !coverDisplays.isEmpty {
            switch action {
            case "exit", "toggle":
                exitCover()
            default:
                // enter-while-covered and refresh both re-apply the record
                applyReposeState()
            }
            return
        }
        guard action == "enter" || action == "toggle" else { return }
        enterCover(path: path)
    }

    // Wallpaper-through: the configured scene (or the desktop wallpaper)
    // renders inside the cover beneath the composition — its own instance;
    // the occluded desktop copy pauses. nil = graded-opaque composition.
    private func resolveBackdrop(_ scene: String) -> Wallpaper? {
        var wallpaper: Wallpaper?
        if scene != "desktop" && !scene.isEmpty {
            wallpaper = resolveWallpaper(scene)
            if wallpaper == nil { print("repose: bad scene '\(scene)', mirroring desktop") }
        }
        if wallpaper == nil { wallpaper = loadConfiguredWallpaper() }
        if case .web(_, let root, _)? = wallpaper, root == compositionRoot {
            return nil   // never stack repose on itself
        }
        return wallpaper
    }

    private func attachBackdrop(_ display: inout CoverDisplay, wallpaper: Wallpaper?,
                                livery: [String: Any], mediaSnapshot: String) {
        switch wallpaper {
        case .image(let url)?:
            display.backdropImage = ImageHost(screen: display.screen, url: url,
                                              attachTo: display.panel)
        case .video(let url)?:
            display.backdropVideo = VideoHost(screen: display.screen, url: url,
                                              attachTo: display.panel)
        case .web(let index, let root, var properties)?:
            for (key, value) in livery { properties[key] = value }
            display.backdropWeb = WebHost(
                screen: display.screen, index: index, root: root,
                properties: properties, surface: .cover,
                attachTo: display.panel, mediaSnapshotJSON: mediaSnapshot)
        case .scene(_, _, let preview, _, _)?:
            if let preview {
                display.backdropImage = ImageHost(
                    screen: display.screen, url: preview, attachTo: display.panel)
            }
        case nil:
            break
        }
        // re-adding the composition web view moves it back above the backdrop
        if wallpaper != nil, let container = display.panel.contentView {
            container.addSubview(display.composition.webView)
        }
    }

    private func detachBackdrop(_ display: inout CoverDisplay) {
        if let old = display.backdropImage {
            old.view.removeFromSuperview()
            display.backdropImage = nil
        }
        if let old = display.backdropWeb {
            old.invalidate()
            old.webView.removeFromSuperview()
            display.backdropWeb = nil
        }
        if let old = display.backdropVideo {
            old.setPaused(true)
            old.view.removeFromSuperview()
            display.backdropVideo = nil
        }
    }

    private func enterCover(path: String) {
        guard !path.isEmpty, case .web(let index, let root, var properties)? = resolveWallpaper(path) else {
            print("repose: no web wallpaper at '\(path)'")
            return
        }
        compositionRoot = root
        coverScene = reposeState.scene
        let backdrop = resolveBackdrop(coverScene)
        let livery = liveryProperties()
        for (key, value) in livery { properties[key] = value }
        for (key, value) in sceneThemeProperties(coverScene) { properties[key] = value }
        for (key, value) in agentFeed.lastProperties { properties[key] = value }
        for (key, value) in reposeState.properties { properties[key] = value }
        properties["reposebackdrop"] = ["value": backdrop == nil ? "opaque" : "clear"]
        properties["reposecover"] = ["value": "on"]   // shows the key hint once
        let mediaSnapshot = mediaFeed.snapshotJSON()
        let compositionAccessScope = WebAccessScope(
            index: index, root: root, properties: properties)

        for screen in NSScreen.screens {
            let panel = makeCoverPanel(for: screen)
            var display = CoverDisplay(
                panel: panel, screen: screen, backdropImage: nil,
                backdropWeb: nil, backdropVideo: nil,
                composition: WebHost(screen: screen, index: index, root: root,
                                     properties: properties, surface: .cover,
                                     attachTo: panel, mediaSnapshotJSON: mediaSnapshot,
                                     transparent: true,
                                     accessScope: compositionAccessScope))
            attachBackdrop(&display, wallpaper: backdrop, livery: livery,
                           mediaSnapshot: mediaSnapshot)
            coverDisplays.append(display)
            panel.orderFrontRegardless()
        }
        (coverDisplays.first?.panel as? NSPanel)?.makeKeyAndOrderFront(nil)

        // Esc is the only way out (fat-finger protection — re-entry costs a
        // chord). Selection keys are carved out (see handleCoverKey); stray
        // keys, clicks, and scrolls are swallowed. Media keys are
        // systemDefined events — never matched, so they pass through.
        coverMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            guard let self, let window = event.window,
                  self.coverDisplays.contains(where: { $0.panel == window }) else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {   // esc
                    DispatchQueue.main.async { self.exitCover() }
                } else {
                    _ = self.handleCoverKey(event)
                }
            }
            return nil
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let hidden = shell(["sketchybar", "--bar", "hidden=on"]).status == 0
            DispatchQueue.main.async { self.coverBarHidden = hidden }
        }
        reconcileWebServices()
        let backdropNote = backdrop == nil ? "opaque" : "wallpaper-through"
        print("repose: cover entered (\(reposeState.look), \(reposeState.variant), "
            + "\(backdropNote)) on \(coverDisplays.count) display(s)")
    }

    // MARK: Live selection (in-cover keys — the picker is the config)

    private func handleCoverKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123: cycleScene(-1); return true   // ←
        case 124: cycleScene(1); return true    // →
        case 48:                                // tab
            reposeState.look = reposeState.look == "zephyr" ? "pixel" : "zephyr"
            persistAndApply()
            return true
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "b":
            reposeState.viz = reposeState.viz == "strings" ? "spectrum" : "strings"
            persistAndApply()
            return true
        case "x":
            reposeState.pixels = reposeState.pixels == "on" ? "off" : "on"
            persistAndApply()
            return true
        case "v":
            reposeState.variant = reposeState.variant == "quiet" ? "loud" : "quiet"
            persistAndApply()
            return true
        case "g":
            reposeState.grade = reposeState.grade == "on" ? "off" : "on"
            persistAndApply()
            return true
        case "n":
            reposeState.night = reposeState.night == "on" ? "off" : "on"
            persistAndApply()
            return true
        case "l":
            reposeState.label = reposeState.label == "on" ? "off" : "on"
            persistAndApply()
            return true
        default:
            return false
        }
    }

    private func cycleScene(_ step: Int) {
        let library = reposeRotation(reposeState.scenePool)
        let current = library.firstIndex(of: reposeState.scene) ?? 0
        reposeState.scene = library[(current + step + library.count) % library.count]
        persistAndApply()
    }

    private func persistAndApply() {
        reposeState.save()
        applyReposeState()
        let scene = reposeState.scene == "desktop"
            ? "desktop" : (reposeState.scene as NSString).lastPathComponent
        print("repose: \(reposeState.look) · \(scene) · \(reposeState.variant)"
            + " · pixels \(reposeState.pixels) · grade \(reposeState.grade)"
            + " · night \(reposeState.night)")
    }

    private func applyReposeState() {
        guard !coverDisplays.isEmpty else { return }
        var properties = reposeState.properties
        if reposeState.scene != coverScene {
            coverScene = reposeState.scene
            let backdrop = resolveBackdrop(coverScene)
            let livery = liveryProperties()
            let mediaSnapshot = mediaFeed.snapshotJSON()
            for index in coverDisplays.indices {
                detachBackdrop(&coverDisplays[index])
                attachBackdrop(&coverDisplays[index], wallpaper: backdrop,
                               livery: livery, mediaSnapshot: mediaSnapshot)
            }
            // re-push the Look, then the scene's theme over it — moving to an
            // unthemed scene restores Livery colors, a themed one overrides
            for (key, value) in livery { properties[key] = value }
            for (key, value) in sceneThemeProperties(coverScene) { properties[key] = value }
            properties["reposebackdrop"] = ["value": backdrop == nil ? "opaque" : "clear"]
        }
        for display in coverDisplays { display.composition.push(properties: properties) }
    }

    private func exitCover() {
        guard !coverDisplays.isEmpty else { return }
        if let coverMonitor { NSEvent.removeMonitor(coverMonitor) }
        coverMonitor = nil
        let panels = coverDisplays.map { $0.panel }
        let hosts = coverWebHosts
        let videos = coverDisplays.compactMap { $0.backdropVideo }
        coverDisplays.removeAll()
        reconcileWebServices()
        if coverBarHidden {
            coverBarHidden = false
            DispatchQueue.global(qos: .userInitiated).async {
                shell(["sketchybar", "--bar", "hidden=off"])
            }
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panels.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            for host in hosts {
                host.invalidate()
            }
            videos.forEach { $0.setPaused(true) }
            panels.forEach { $0.orderOut(nil) }
        })
        print("repose: cover exited")
    }

    private func reconcileWebServices() {
        if allWebHosts.isEmpty && sceneSupervisors.isEmpty {
            stopWebServices()
        } else if !webServicesStarted {
            startWebServices()
        }
        if webServicesStarted {
            sceneSupervisors.forEach { $0.setMediaEvents(mediaFeed.lastPayloads) }
        }
        reconcileAudioTap()
    }

    private func startWebServices() {
        guard !webServicesStarted else { return }
        webServicesStarted = true
        // Initial properties ride the document-start script (applied by the
        // listener trap); the watcher re-pushes when the Look changes.
        liveryModified = liveryManifestModificationDate()
        liveryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let modified = liveryManifestModificationDate()
            if modified != self.liveryModified {
                self.liveryModified = modified
                self.pushProperties()
                print("livery look changed — properties re-pushed")
            }
        }

        let mouseEvents: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
        ]
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            guard let self else { return }
            if event.type != .mouseMoved && !desktopReceives(event) { return }
            self.desktopWebHosts.forEach { $0.push(event: event) }
            if event.type == .leftMouseUp {
                let location = NSEvent.mouseLocation
                self.sceneSupervisors.forEach { $0.cursorClick(at: location) }
            }
        }

        if AgentFeed.available {
            agentFeed.onChange = { [weak self] properties in
                self?.allWebHosts.forEach { $0.push(properties: properties) }
            }
            agentFeed.start()
            print("agents: herald tasks channel feed live")
        }

        if MediaFeed.available {
            mediaFeed.onEvent = { [weak self] kind, payload in
                guard let self else { return }
                self.sceneSupervisors.forEach {
                    $0.pushMediaEvent(kind: kind, payload: payload)
                }
                guard let data = try? JSONSerialization.data(withJSONObject: payload),
                      let json = String(data: data, encoding: .utf8) else { return }
                for host in self.allWebHosts {
                    host.webView.evaluateJavaScript(
                        "window.__wePushMedia('\(kind)', \(json))", completionHandler: nil)
                }
            }
            mediaFeed.start()
            print("media: media-control feed live")
        } else {
            print("media: media-control not found (no media integration)")
        }
    }

    private func stopWebServices() {
        guard webServicesStarted else { return }
        webServicesStarted = false
        mediaFeed.stop()
        mediaFeed.onEvent = nil
        agentFeed.stop()
        agentFeed.onChange = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        liveryTimer?.invalidate()
        liveryTimer = nil
        print("web services stopped — no web wallpaper active")
    }

    private func reconcileAudioTap() {
        let needed = !allWebHosts.isEmpty
            || sceneSupervisors.contains(where: \.audioSpectrumSupported)
        if needed && !audioTapStarted {
            startAudioTap()
        } else if !needed && audioTapStarted {
            audioTap.stop()
            audioTap.onFrame = nil
            audioTapStarted = false
            print("audio: stopped — no compatible wallpaper active")
        }
    }

    private func startAudioTap() {
        guard !audioTapStarted else { return }
        audioTapStarted = true
        let initialAudioFrames = audioTap.framesReceived
        audioTap.onFrame = { [weak self] frame in
            guard let self else { return }
            self.allWebHosts.forEach { $0.push(audio: frame) }
            self.sceneSupervisors.forEach { $0.pushAudioSpectrum(frame) }
        }
        audioTap.start()
        if !audioTap.capturePermissionAvailable {
            print("audio: disabled — capture permission unavailable (no prompt requested)")
        } else {
            print(audioTap.live ? "audio: cava launched" : "audio: cava unavailable — sending silence")
        }
        if audioTap.live {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.audioTapStarted else { return }
                if self.audioTap.framesReceived == initialAudioFrames {
                    print("""
                    audio: cava is running but no frames arrived — likely the \
                    system-audio capture permission. Grant it to your terminal \
                    under System Settings → Privacy & Security → Screen & \
                    System Audio Recording, then relaunch.
                    """)
                } else {
                    let received = self.audioTap.framesReceived - initialAudioFrames
                    print("audio: tap live (\(received) frames)")
                }
            }
        }
    }

    private func mergedProperties(project: [String: Any]? = nil) -> [String: Any] {
        mergedWallpaperProperties(
            project: project ?? projectProperties,
            overlays: [liveryProperties(), agentFeed.lastProperties])
    }

    private func pushProperties() {
        for assignment in desktopAssignments.values.compactMap({
            $0 as? any WebRuntimeDisplayAssignment
        }) {
            assignment.webHost.push(properties: mergedProperties(project: assignment.properties))
        }
        // covers get only the Livery roles — the desktop wallpaper's own
        // project properties must not leak into the repose composition
        let livery = liveryProperties()
        coverWebHosts.forEach { $0.push(properties: livery) }
    }

    private func observeOcclusion() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow else { return }
            let visible = window.occlusionState.contains(.visible)
            for assignment in self.desktopAssignments.values {
                (assignment as? any OcclusionRuntimeDisplayAssignment)?
                    .updateOcclusion(window: window, visible: visible)
            }
            self.reloadFromState()
        }
    }

    // Lock-screen split: the lock screen shows the desktop surface frozen,
    // which reads as broken for live wallpapers and defeats a separately
    // pinned image behind a static desktop layer. Hide the desktop windows
    // while locked so the lock screen falls back to the static system
    // wallpaper — that picture (System Settings > Wallpaper) is thereby
    // the separate lock wallpaper. An open cover exits on lock (it's a
    // manually invoked scene; re-enter after unlocking).
    private var screenLocked = false

    private func observeLock() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                           object: nil, queue: .main) { [weak self] _ in self?.setLocked(true) }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                           object: nil, queue: .main) { [weak self] _ in self?.setLocked(false) }
    }

    private func setLocked(_ locked: Bool) {
        guard locked != screenLocked else { return }
        screenLocked = locked
        if locked && !coverDisplays.isEmpty { exitCover() }
        desktopAssignments.values.forEach {
            $0.setPaused(locked)
            $0.setVisible(!locked)
        }
        print("lock: desktop wallpaper \(locked ? "hidden" : "restored")")
        reloadFromState()
    }

    private func observeSystemState() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sleeping = true
            self?.reloadFromState()
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sleeping = false
            self?.reloadFromState()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.reloadFromState() }
    }

    private func publishStatus() {
        guard daemon else { return }
        do {
            let loaded = try stateStore.load()
            reportStateDiagnostics(loaded.diagnostics)
            let observed = observedContext()
            let plan = FrescoStatePlanner.plan(state: loaded.state, observed: observed)
            try publishStatus(observed: observed, plan: plan)
        } catch {
            print("status: unavailable (\(error))")
        }
    }

    private func observedContext() -> FrescoObservedContext {
        FrescoMacObservation.context(
            screens: NSScreen.screens,
            generation: runtimeGeneration,
            locked: screenLocked,
            sleeping: sleeping,
            occludedDisplayIDs: desktopAssignments.occludedDisplayIDs)
    }

    private func reportStateDiagnostics(_ diagnostics: [String]) {
        guard diagnostics != lastStateDiagnostics else { return }
        lastStateDiagnostics = diagnostics
        for diagnostic in diagnostics { print("state: \(diagnostic)") }
    }

    private func publishStatus(
        observed: FrescoObservedContext,
        plan: FrescoEffectivePlan
    ) throws {
        let snapshot = FrescoStatusAssembler.snapshot(
            plan: plan,
            observed: observed,
            assignmentEvidence: desktopAssignments.evidence)
        try statusPublisher.publish(snapshot)
    }

    func shutdown() {
        if let muteHotKey { UnregisterEventHotKey(muteHotKey) }
        muteHotKey = nil
        if let muteHotKeyEventHandler { RemoveEventHandler(muteHotKeyEventHandler) }
        muteHotKeyEventHandler = nil
        // never strand a hidden bar if we die while covered
        if coverBarHidden { shell(["sketchybar", "--bar", "hidden=off"]) }
        desktopAssignments.removeAll()
        stopWebServices()
        audioTap.stop()
        audioTap.onFrame = nil
        audioTapStarted = false
        if daemon { statusPublisher.remove() }
        if daemon { try? FileManager.default.removeItem(at: pidFile) }
        exit(0)
    }
}
