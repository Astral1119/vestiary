import AppKit
import Combine
import Darwin
import SwiftUI

// Posted by showPanel(); the view refreshes its catalog so imports made
// outside the panel (liveryctl, workshop theme) appear without a restart.
let liveryPanelShown = Notification.Name("livery.panel.shown")

private let monoFamily = "JetBrainsMono Nerd Font"
private let readinessURL = URL(
    fileURLWithPath: "/tmp/livery-\(getuid()).ready"
)
private let runtimeLogURL = URL(
    fileURLWithPath: "/tmp/lvry-runtime.log"
)
private let reposeControlQueue = DispatchQueue(label: "local.vestiary.livery.repose-control")

@MainActor
private func runtimeLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) pid=\(ProcessInfo.processInfo.processIdentifier) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: runtimeLogURL.path),
       let handle = try? FileHandle(forWritingTo: runtimeLogURL) {
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    } else {
        try? data.write(to: runtimeLogURL, options: .atomic)
    }
}

private struct ThemePalette: Identifiable, Decodable {
    let id: String
    let name: String
    let shortcut: String
    let note: String
    let generator: String
    let scheme: String
    let sourceColor: String
    let background: String
    let surface: String
    let surfaceElevated: String
    let primary: String
    let primaryContainer: String
    let secondary: String
    let tertiary: String
    let text: String
    let textMuted: String
    let outline: String
    let error: String
    let terminal: [String]
    let ansi: [String]?
    let terminalBackground: String?
    let terminalForeground: String?
    let minimumContrast: Double?
    let ghosttyBackgroundOpacity: Double?

    var key: Character { shortcut.first ?? "?" }

    var isLight: Bool {
        RGBColor(hex: background).luminance > 0.55
    }

    var panelBackgroundOpacity: Double {
        isLight ? 0.84 : 0.46
    }

    func panelText(_ opacity: Double) -> Color {
        Color(hex: text).opacity(isLight ? max(opacity, 0.82) : opacity)
    }

    func panelMuted(_ opacity: Double) -> Color {
        Color(hex: isLight ? text : textMuted)
            .opacity(isLight ? max(opacity, 0.72) : opacity)
    }

    func panelAccent(_ opacity: Double) -> Color {
        Color(hex: primary).opacity(isLight ? max(opacity, 0.95) : opacity)
    }

    var roles: [(String, String)] {
        return [
            ("bg", background),
            ("surface", surface),
            ("elevated", surfaceElevated),
            ("primary", primary),
            ("secondary", secondary),
            ("tertiary", tertiary),
            ("text", text),
            ("error", error),
        ]
    }

    var terminalANSI: [String] {
        if let ansi {
            return ansi
        }
        return [
            terminal[0],
            terminal[8],
            terminal[11],
            terminal[10],
            terminal[13],
            terminal[14],
            terminal[12],
            terminal[5],
            terminal[3],
            terminal[8],
            terminal[11],
            terminal[10],
            terminal[13],
            terminal[14],
            terminal[12],
            terminal[7],
        ]
    }

    var terminalMap: [(String, String)] {
        terminalANSI.enumerated().map {
            (String(format: "%02X", $0.offset), $0.element)
        }
    }

    // Old generated catalogs predate the explicit terminal specimen fields.
    // These fallbacks mirror resolve_palette_theme(), where wallpaper-derived
    // themes intentionally map terminal bg/fg to UI bg/text and retain the
    // default profile's 0.5 opacity.
    var resolvedTerminalBackground: String { terminalBackground ?? background }
    var resolvedTerminalForeground: String { terminalForeground ?? text }
    var resolvedGhosttyBackgroundOpacity: Double { ghosttyBackgroundOpacity ?? 0.5 }
}

// Manifest v3 writes colors as {hex, rgb} objects; v2 wrote bare strings.
// Decode either, so the panel reads both generations of theme payloads.
private struct HexString: Decodable {
    let hex: String
    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let raw = try? single.decode(String.self) {
            hex = raw
        } else {
            struct Boxed: Decodable { let hex: String }
            hex = try single.decode(Boxed.self).hex
        }
    }
}

private struct SemanticThemeUI: Decodable {
    let background: HexString
    let surface: HexString
    let surfaceElevated: HexString
    let text: HexString
    let textMuted: HexString
    let primary: HexString
    let secondary: HexString
    let tertiary: HexString
    let outline: HexString
    let selection: HexString
}

private struct SemanticThemeSignals: Decodable {
    let success: HexString
    let warning: HexString
    let error: HexString
    let info: HexString
    let attention: HexString
}

private struct SemanticThemeTerminal: Decodable {
    let background: HexString
    let foreground: HexString
    let cursor: HexString
    let cursorText: HexString
    let selectionBackground: HexString
    let selectionForeground: HexString
    let minimumContrast: Double
    let ansi: [HexString]
}

private struct SemanticThemeEffects: Decodable {
    let ghosttyBackgroundOpacity: Double
    let ghosttyBlur: Double
}

private struct SemanticTheme: Decodable {
    let id: String
    let label: String
    let variant: String
    let ui: SemanticThemeUI
    let signals: SemanticThemeSignals
    let terminal: SemanticThemeTerminal
    let effects: SemanticThemeEffects
}

private struct ThemeLibraryEntry: Identifiable, Decodable {
    let id: String
    let label: String
    let style: String
    let summary: String
    let tags: [String]
    let ref: String
    let theme: SemanticTheme

    var palette: ThemePalette {
        ThemePalette(
            id: id,
            name: label,
            shortcut: "",
            note: summary,
            generator: "livery",
            scheme: style,
            sourceColor: theme.ui.primary.hex,
            background: theme.ui.background.hex,
            surface: theme.ui.surface.hex,
            surfaceElevated: theme.ui.surfaceElevated.hex,
            primary: theme.ui.primary.hex,
            primaryContainer: theme.ui.selection.hex,
            secondary: theme.ui.secondary.hex,
            tertiary: theme.ui.tertiary.hex,
            text: theme.ui.text.hex,
            textMuted: theme.ui.textMuted.hex,
            outline: theme.ui.outline.hex,
            error: theme.signals.error.hex,
            terminal: theme.terminal.ansi.map(\.hex),
            ansi: theme.terminal.ansi.map(\.hex),
            terminalBackground: theme.terminal.background.hex,
            terminalForeground: theme.terminal.foreground.hex,
            minimumContrast: theme.terminal.minimumContrast,
            ghosttyBackgroundOpacity: theme.effects.ghosttyBackgroundOpacity
        )
    }
}

private struct ThemeLibraryCatalog: Decodable {
    let schemaVersion: Int
    let generatedBy: String
    let themes: [ThemeLibraryEntry]
}

private struct WallpaperFixture: Identifiable, Decodable {
    let id: String
    let number: Int
    let name: String
    let subtitle: String
    let fileName: String
    let credit: String
    let assetPath: String?
    let assetDigest: String?
    let live: String?
    let palettes: [ThemePalette]

    var shortcut: Character? {
        guard number >= 1, number <= 9 else { return nil }
        return Character(String(number))
    }

    var image: NSImage {
        if let url = imageURL, let image = NSImage(contentsOf: url) {
            return image
        }
        return .fixture(named: fileName)
    }

    var imageURL: URL? {
        if let assetPath, FileManager.default.fileExists(atPath: assetPath) {
            return URL(fileURLWithPath: assetPath)
        }
        if let assets = ProcessInfo.processInfo.environment["LIVERY_ASSETS"] {
            let url = URL(fileURLWithPath: assets).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let resources = Bundle.main.resourceURL {
            let url = resources.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}

private struct PaletteCatalog: Decodable {
    let schemaVersion: Int
    let generatedBy: String
    let extraction: String
    let terminal: String
    let fixtures: [WallpaperFixture]
}

private let bundledCatalog: PaletteCatalog = {
    guard
        let url = Bundle.main.url(forResource: "palettes", withExtension: "json"),
        let data = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(PaletteCatalog.self, from: data),
        decoded.schemaVersion == 1,
        !decoded.fixtures.isEmpty
    else {
        fatalError("Livery could not load its generated palette catalog")
    }
    return decoded
}()

private let themeLibrary: ThemeLibraryCatalog = {
    guard
        let url = Bundle.main.url(forResource: "themes", withExtension: "json"),
        let data = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(ThemeLibraryCatalog.self, from: data),
        decoded.schemaVersion == 1,
        !decoded.themes.isEmpty
    else {
        fatalError("Livery could not load its semantic theme library")
    }
    return decoded
}()

private let themes = themeLibrary.themes

private extension Font {
    static func lab(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(monoFamily, fixedSize: size).weight(weight)
    }
}

private extension Color {
    init(hex: String, opacity: Double = 1) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255,
            opacity: opacity
        )
    }
}

private extension NSImage {
    static func fixture(named fileName: String) -> NSImage {
        var roots: [URL] = []
        if let assets = ProcessInfo.processInfo.environment["LIVERY_ASSETS"] {
            roots.append(URL(fileURLWithPath: assets))
        }
        if let resources = Bundle.main.resourceURL {
            roots.append(resources)
        }
        for root in roots {
            if let image = NSImage(contentsOf: root.appendingPathComponent(fileName)) {
                return image
            }
        }
        return NSImage()
    }
}

private struct BackdropBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underPageBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .underPageBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
    }
}

private struct ScrollContentFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct ScrollChrome: View {
    let axis: Axis.Set
    let palette: ThemePalette
    let viewport: CGSize
    let contentFrame: CGRect

    private var isVertical: Bool {
        axis == .vertical
    }

    private var viewportLength: CGFloat {
        isVertical ? viewport.height : viewport.width
    }

    private var contentLength: CGFloat {
        isVertical ? contentFrame.height : contentFrame.width
    }

    private var contentOffset: CGFloat {
        max(0, -(isVertical ? contentFrame.minY : contentFrame.minX))
    }

    private var thumbLength: CGFloat {
        guard contentLength > viewportLength, contentLength > 0 else {
            return viewportLength
        }
        return max(26, viewportLength * viewportLength / contentLength)
    }

    private var thumbOffset: CGFloat {
        let scrollableContent = max(contentLength - viewportLength, 1)
        let thumbTravel = max(viewportLength - thumbLength - 4, 0)
        return min(max(contentOffset / scrollableContent, 0), 1) * thumbTravel + 2
    }

    var body: some View {
        if contentLength > viewportLength + 1 {
            ZStack(alignment: isVertical ? .top : .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: palette.outline).opacity(0.10))
                    .frame(
                        width: isVertical ? 4 : max(viewportLength - 4, 0),
                        height: isVertical ? max(viewportLength - 4, 0) : 4
                    )
                    .offset(
                        x: isVertical ? 0 : 2,
                        y: isVertical ? 2 : 0
                    )

                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.panelAccent(0.52))
                    .frame(
                        width: isVertical ? 4 : thumbLength,
                        height: isVertical ? thumbLength : 4
                    )
                    .offset(
                        x: isVertical ? 0 : thumbOffset,
                        y: isVertical ? thumbOffset : 0
                    )
            }
            .frame(
                width: isVertical ? 8 : viewportLength,
                height: isVertical ? viewportLength : 8
            )
            .allowsHitTesting(false)
        }
    }
}

private struct ThemedScrollView<Content: View>: View {
    let axis: Axis.Set
    let palette: ThemePalette
    @ViewBuilder let content: () -> Content

    @State private var contentFrame = CGRect.zero
    private let coordinateSpace = UUID()

    var body: some View {
        GeometryReader { geometry in
            ScrollView(axis, showsIndicators: false) {
                content()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ScrollContentFrameKey.self,
                                value: proxy.frame(in: .named(coordinateSpace))
                            )
                        }
                    }
            }
            .coordinateSpace(name: coordinateSpace)
            .onPreferenceChange(ScrollContentFrameKey.self) {
                contentFrame = $0
            }
            .overlay(alignment: axis == .vertical ? .trailing : .bottom) {
                ScrollChrome(
                    axis: axis,
                    palette: palette,
                    viewport: geometry.size,
                    contentFrame: contentFrame
                )
                .padding(axis == .vertical ? .trailing : .bottom, 2)
            }
        }
    }
}

private struct Hairline: View {
    let palette: ThemePalette

    var body: some View {
        Rectangle()
            .fill(Color(hex: palette.outline).opacity(0.20))
            .frame(height: 1)
    }
}

private enum LabMode: String {
    case grid
    case detail
}

private enum LiveryWorkspace: String, CaseIterable, Identifiable {
    case looks
    case repose

    var id: String { rawValue }
}

private struct ReposeSelection: Decodable, Equatable {
    var look = "zephyr"
    var scene = "desktop"
    var variant = "quiet"
    var grade = "on"
    var night = "off"
    var pixels = "on"
    var label = "on"
    var scenePool: [String] = []

    var currentSceneID: String {
        scene == "desktop" ? "desktop" : URL(fileURLWithPath: scene).lastPathComponent
    }
}

private struct ReposeScene: Identifiable {
    let id: String
    let path: String
    let name: String
    let thumbnail: NSImage?

    var isDesktop: Bool { id == "desktop" }
}

private struct LockPolicy: Decodable, Equatable {
    let source: String
    let image: String?
    let selection: String?

    static let unmanaged = LockPolicy(source: "off", image: nil, selection: nil)

    var shortLabel: String {
        switch source {
        case "theme": "lock · follows look"
        case "file", "look", "scene": "lock · pinned"
        default: "lock · unmanaged"
        }
    }

    var detail: String {
        switch source {
        case "theme": "follows the current Look"
        case "file", "look", "scene": selection ?? image ?? "pinned image"
        default: "the next Look supplies the system wallpaper"
        }
    }
}

private enum ApplyState: Equatable {
    case idle
    case running(String)
    case succeeded(String)
    case failed(String)
}

private enum LookAuthority: String, CaseIterable, Identifiable {
    case wallpaper
    case theme

    var id: String { rawValue }
    var shortcut: Character { self == .wallpaper ? "w" : "t" }
    var direction: String { self == .wallpaper ? "wallpaper → theme" : "theme → wallpaper" }

    var explanation: String {
        self == .wallpaper
            ? "derive colors from the selected image"
            : "grade the selected image toward a held theme"
    }
}

private enum GradePreset: String, CaseIterable, Identifiable {
    case subtle
    case balanced
    case themeForward = "theme-forward"

    var id: String { rawValue }

    var shortcut: Character {
        switch self {
        case .subtle: "u"
        case .balanced: "b"
        case .themeForward: "f"
        }
    }

    var note: String {
        switch self {
        case .subtle: "source fidelity"
        case .balanced: "even compromise"
        case .themeForward: "theme affinity"
        }
    }
}

private enum MappingMode: String, CaseIterable, Identifiable {
    case natural
    case duotone
    case tritone
    case gradientMap = "gradient-map"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .natural: "natural"
        case .duotone: "duotone"
        case .tritone: "tritone"
        case .gradientMap: "gradient"
        }
    }

    var note: String {
        switch self {
        case .natural: "hue steering"
        case .duotone: "shadow / light"
        case .tritone: "adds midtone"
        case .gradientMap: "five-color ramp"
        }
    }
}

private enum QuantizationMode: String, CaseIterable, Identifiable {
    case continuous
    case q16
    case q8
    case q4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .continuous: "full"
        case .q16: "16"
        case .q8: "8"
        case .q4: "4"
        }
    }

    var note: String {
        switch self {
        case .continuous: "continuous color"
        case .q16: "tonal palette"
        case .q8: "graphic palette"
        case .q4: "severe reduction"
        }
    }
}

private enum DitherMode: String, CaseIterable, Identifiable {
    case none
    case bayer
    case blueNoise = "blue-noise"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "none"
        case .bayer: "bayer 8"
        case .blueNoise: "blue noise"
        }
    }

    var note: String {
        switch self {
        case .none: "hard bands"
        case .bayer: "ordered grid"
        case .blueNoise: "diffuse texture"
        }
    }
}

private enum FinishMode: String, CaseIterable, Identifiable {
    case clean
    case grain
    case halftone

    var id: String { rawValue }

    var note: String {
        switch self {
        case .clean: "no finish"
        case .grain: "seeded texture"
        case .halftone: "print dots"
        }
    }
}

private let terminalMinimumContrast = 3.0

private func contrastRatio(_ foreground: RGBColor, _ background: RGBColor) -> Double {
    let light = max(foreground.luminance, background.luminance)
    let dark = min(foreground.luminance, background.luminance)
    return (light + 0.05) / (dark + 0.05)
}

private func ghosttyTextColor(
    _ foreground: String,
    over background: RGBColor,
    minimumContrast: Double = terminalMinimumContrast
) -> String {
    let foregroundColor = RGBColor(hex: foreground)
    if contrastRatio(foregroundColor, background) >= minimumContrast {
        return foreground
    }

    let black = RGBColor(hex: "#000000")
    let white = RGBColor(hex: "#ffffff")
    return contrastRatio(white, background) >= contrastRatio(black, background)
        ? white.hex
        : black.hex
}

private func representativeColor(in image: NSImage, fallback: String) -> RGBColor {
    guard
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()),
        bitmap.pixelsWide > 0,
        bitmap.pixelsHigh > 0
    else { return RGBColor(hex: fallback) }

    var red = 0.0
    var green = 0.0
    var blue = 0.0
    var count = 0.0
    for row in 0..<5 {
        for column in 0..<7 {
            let x = min((2 * column + 1) * bitmap.pixelsWide / 14, bitmap.pixelsWide - 1)
            let y = min((2 * row + 1) * bitmap.pixelsHigh / 10, bitmap.pixelsHigh - 1)
            guard let color = bitmap.colorAt(x: x, y: y) else { continue }
            let sample = RGBColor(nsColor: color)
            red += sample.red
            green += sample.green
            blue += sample.blue
            count += 1
        }
    }
    guard count > 0 else { return RGBColor(hex: fallback) }
    let average = NSColor(
        srgbRed: red / count,
        green: green / count,
        blue: blue / count,
        alpha: 1
    )
    return RGBColor(nsColor: average)
}

private struct ApplyResult {
    let succeeded: Bool
    let message: String
}

private struct ControlResult {
    let status: Int32
    let output: String
}

private struct PendingWallpaperImport {
    let sourceURL: URL
    let preview: NSImage
}

private enum ImportState: Equatable {
    case idle
    case running
    case failed(String)
}

private enum WallpaperImportResult {
    case succeeded(WallpaperFixture)
    case failed(String)
}

private struct WallpaperOutput: Decodable {
    let artifact: String?
}

private struct LookOutputs: Decodable {
    let wallpaper: WallpaperOutput
}

private struct ResolvedLook: Decodable {
    let outputs: LookOutputs
}

private struct PreviewResult {
    let image: NSImage?
    let message: String
}

private func liveryControlURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["LIVERY_CTL"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    // The panel is always rebuilt from the live tree (lvry recompiles on
    // staleness), so the compile-time source path tracks the repo location.
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("liveryctl")
}

private func runLiveryControl(_ arguments: [String]) -> ControlResult {
    let control = liveryControlURL()
    guard FileManager.default.isExecutableFile(atPath: control.path) else {
        return ControlResult(status: 127, output: "liveryctl not found")
    }

    let process = Process()
    let output = Pipe()
    process.executableURL = control
    process.arguments = arguments
    process.currentDirectoryURL = control.deletingLastPathComponent()
    process.standardOutput = output
    process.standardError = output

    var environment = ProcessInfo.processInfo.environment
    let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(inheritedPath)"
    process.environment = environment

    do {
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return ControlResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    } catch {
        return ControlResult(status: 126, output: error.localizedDescription)
    }
}

private struct WorkshopItem: Decodable, Identifiable {
    let id: String
    let title: String
    let size: Double
    let subs: Int
    let preview: String?
    let playable: Bool
}

private struct WorkshopIngest: Decodable {
    let fixture: String
}

private func workshopControlURL() -> URL {
    // liveryctl file → livery/ → vestiary/, then the fresco sibling.
    liveryControlURL()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fresco/workshop")
}

private func runWorkshop(_ arguments: [String]) -> ControlResult {
    let control = workshopControlURL()
    guard FileManager.default.isExecutableFile(atPath: control.path) else {
        return ControlResult(status: 127, output: "workshop client not found")
    }
    let process = Process()
    let output = Pipe()
    process.executableURL = control
    process.arguments = arguments
    process.currentDirectoryURL = control.deletingLastPathComponent()
    process.standardOutput = output
    process.standardError = output
    var environment = ProcessInfo.processInfo.environment
    let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(inheritedPath)"
    process.environment = environment
    do {
        try process.run()
        process.waitUntilExit()
        return ControlResult(
            status: process.terminationStatus,
            output: String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    } catch {
        return ControlResult(status: 126, output: error.localizedDescription)
    }
}

private func wallpaperControlURL() -> URL {
    liveryControlURL()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("fresco/fresco")
}

private func runWallpaperControl(_ arguments: [String]) -> ControlResult {
    let control = wallpaperControlURL()
    guard FileManager.default.isExecutableFile(atPath: control.path) else {
        return ControlResult(status: 127, output: "fresco ctl not found")
    }
    let process = Process()
    let output = Pipe()
    process.executableURL = control
    process.arguments = arguments
    process.currentDirectoryURL = control.deletingLastPathComponent()
    process.standardOutput = output
    process.standardError = output
    var environment = ProcessInfo.processInfo.environment
    let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(inheritedPath)"
    process.environment = environment
    do {
        try process.run()
        process.waitUntilExit()
        return ControlResult(
            status: process.terminationStatus,
            output: String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    } catch {
        return ControlResult(status: 126, output: error.localizedDescription)
    }
}

private func loadReposeSelection() -> ReposeSelection {
    let result = runWallpaperControl(["repose-state"])
    guard
        result.status == 0,
        let data = result.output.data(using: .utf8),
        let state = try? JSONDecoder().decode(ReposeSelection.self, from: data)
    else { return ReposeSelection() }
    return state
}

private func reposeScenesURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/fresco/scenes")
}

private func sceneThumbnail(for scene: URL, generate: Bool) -> NSImage? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: scene.path, isDirectory: &isDirectory) else {
        return nil
    }
    if isDirectory.boolValue {
        let project = scene.appendingPathComponent("project.json")
        if let data = try? Data(contentsOf: project),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["preview", "file"] {
                if let relative = object[key] as? String,
                   let image = NSImage(contentsOf: scene.appendingPathComponent(relative)) {
                    return image
                }
            }
        }
        return nil
    }

    let attributes = try? FileManager.default.attributesOfItem(atPath: scene.path)
    let modified = Int((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    let safeName = scene.deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: "/", with: "-")
    let cache = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/livery/repose-thumbnails")
    let destination = cache.appendingPathComponent("\(safeName)-\(modified).jpg")
    if let image = NSImage(contentsOf: destination) { return image }
    guard generate else { return nil }

    try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "ffmpeg", "-loglevel", "error", "-y", "-ss", "0.8", "-i", scene.path,
        "-frames:v", "1", "-vf", "scale=640:-2", destination.path,
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    return process.terminationStatus == 0 ? NSImage(contentsOf: destination) : nil
}

private func loadReposeScenes(generateThumbnails: Bool = false) -> [ReposeScene] {
    var scenes = [ReposeScene(
        id: "desktop", path: "desktop", name: "desktop mirror", thumbnail: nil
    )]
    let root = reposeScenesURL()
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    let videoExtensions = Set(["mp4", "mov", "m4v"])
    for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let supportedDirectory = values?.isDirectory == true
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path)
        guard supportedDirectory || videoExtensions.contains(url.pathExtension.lowercased()) else {
            continue
        }
        scenes.append(
            ReposeScene(
                id: url.lastPathComponent,
                path: url.path,
                name: url.deletingPathExtension().lastPathComponent,
                thumbnail: sceneThumbnail(for: url, generate: generateThumbnails)
            )
        )
    }
    return scenes
}

private func loadLockPolicy() -> LockPolicy {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/livery/lock.json")
    guard
        let data = try? Data(contentsOf: url),
        let policy = try? JSONDecoder().decode(LockPolicy.self, from: data)
    else { return .unmanaged }
    return policy
}

private func loadWorkshopItems(query: String, count: Int) -> [WorkshopItem]? {
    let result = runWorkshop(["search", query, "--n", "\(count)", "--json"])
    guard
        result.status == 0,
        let line = result.output.split(separator: "\n").last(where: { $0.hasPrefix("[") }),
        let data = String(line).data(using: .utf8),
        let items = try? JSONDecoder().decode([WorkshopItem].self, from: data)
    else {
        return nil
    }
    return items
}

private func loadWallpaperFixtures() -> [WallpaperFixture] {
    let result = runLiveryControl(["wallpapers", "--json"])
    guard
        result.status == 0,
        let data = result.output.data(using: .utf8),
        let catalog = try? JSONDecoder().decode(PaletteCatalog.self, from: data),
        catalog.schemaVersion == 1,
        !catalog.fixtures.isEmpty
    else {
        return bundledCatalog.fixtures
    }
    return catalog.fixtures
}

private func importWallpaper(
    sourceURL: URL,
    name: String,
    subtitle: String,
    credit: String
) -> WallpaperImportResult {
    let result = runLiveryControl([
        "import-wallpaper",
        sourceURL.path,
        "--name",
        name,
        "--subtitle",
        subtitle,
        "--credit",
        credit,
    ])
    guard result.status == 0 else {
        let finalLine = result.output.split(separator: "\n").last.map(String.init)
            ?? "import failed"
        return .failed(finalLine)
    }
    guard
        let data = result.output.data(using: .utf8),
        let fixture = try? JSONDecoder().decode(WallpaperFixture.self, from: data)
    else {
        return .failed("import returned an invalid wallpaper record")
    }
    return .succeeded(fixture)
}

private func applyLook(profile: String) -> ApplyResult {
    let result = runLiveryControl(["apply", profile])
    if result.status == 0 {
        return ApplyResult(succeeded: true, message: "applied \(profile)")
    }
    let finalLine = result.output.split(separator: "\n").last.map(String.init) ?? "apply failed"
    return ApplyResult(succeeded: false, message: finalLine)
}

private func renderLookPreview(profile: String) -> PreviewResult {
    let result = runLiveryControl(["render", profile])
    do {
        guard result.status == 0,
              let path = result.output
                .split(separator: "\n")
                .last
                .map(String.init)?
                .replacingOccurrences(of: "rendered and validated: ", with: ""),
              !path.isEmpty
        else {
            let finalLine = result.output.split(separator: "\n").last.map(String.init)
                ?? "preview failed"
            return PreviewResult(image: nil, message: finalLine)
        }

        let outputDirectory = URL(fileURLWithPath: path)
        let manifestURL = outputDirectory.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            ResolvedLook.self,
            from: Data(contentsOf: manifestURL)
        )
        guard let artifact = manifest.outputs.wallpaper.artifact,
              let image = NSImage(contentsOf: outputDirectory.appendingPathComponent(artifact))
        else {
            return PreviewResult(image: nil, message: "resolved Look has no image artifact")
        }
        return PreviewResult(image: image, message: "resolved derivative")
    } catch {
        return PreviewResult(image: nil, message: error.localizedDescription)
    }
}

@MainActor
private func dismissLiveryPanel() {
    (NSApp.delegate as? AppDelegate)?.hidePanel()
}

@MainActor
private func chooseWallpaperFile() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Import wallpaper"
    panel.message = "Choose an image to copy into Livery's managed library."
    panel.prompt = "Review"
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    return panel.runModal() == .OK ? panel.url : nil
}

private struct LockPolicyControl: View {
    let palette: ThemePalette
    let policy: LockPolicy
    let busy: Bool
    let setPolicy: (String) -> Void

    @State private var expanded = false

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            Text(busy ? "[lock] updating…" : "[lock] \(policy.shortLabel.replacingOccurrences(of: "lock · ", with: ""))")
                .font(.lab(9, weight: .medium))
                .foregroundStyle(palette.panelMuted(0.58))
                .padding(.horizontal, 7)
                .frame(height: 25)
                .contentShape(Rectangle())
                .overlay(
                    Rectangle().strokeBorder(
                        expanded
                            ? palette.panelAccent(0.48)
                            : Color(hex: palette.outline).opacity(0.14),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .overlay(alignment: .topTrailing) {
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LOCK POLICY")
                        .font(.lab(8, weight: .bold))
                        .foregroundStyle(palette.panelText(0.64))
                    Text(policy.detail)
                        .font(.lab(8))
                        .foregroundStyle(palette.panelMuted(0.44))
                        .lineLimit(2)

                    Hairline(palette: palette)

                    Button {
                        expanded = false
                        setPolicy("theme")
                    } label: {
                        Text("[f] follow applied Look")
                            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        expanded = false
                        setPolicy("off")
                    } label: {
                        Text("[u] unmanaged")
                            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .font(.lab(8, weight: .medium))
                .foregroundStyle(palette.panelAccent(0.72))
                .padding(11)
                .frame(width: 224, alignment: .leading)
                .background(Color(hex: palette.surfaceElevated, opacity: 0.98))
                .overlay(
                    Rectangle().strokeBorder(palette.panelAccent(0.42), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.36), radius: 14, y: 8)
                .offset(y: 29)
                .zIndex(30)
            }
        }
        .fixedSize()
        .zIndex(30)
    }
}

private struct Header: View {
    let palette: ThemePalette
    let workspace: LiveryWorkspace
    let setWorkspace: (LiveryWorkspace) -> Void
    let authority: LookAuthority
    let lookLabel: String
    let mode: LabMode
    let setMode: (LabMode) -> Void
    let beginImport: () -> Void
    let lockPolicy: LockPolicy
    let lockBusy: Bool
    let setLockPolicy: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("livery")
                .foregroundStyle(Color(hex: palette.primary))
                .font(.lab(12, weight: .bold))

            Text("//")
                .foregroundStyle(palette.panelMuted(0.34))

            Text(workspace == .looks ? authority.direction : "cover workspace")
                .foregroundStyle(palette.panelText(0.72))

            Text("//")
                .foregroundStyle(palette.panelMuted(0.34))

            Text(workspace == .looks ? lookLabel : "live + persistent")
                .foregroundStyle(palette.panelMuted(0.58))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            ForEach(LiveryWorkspace.allCases) { option in
                Button {
                    setWorkspace(option)
                } label: {
                    Text("[⌘\(option == .looks ? "1" : "2")] \(option.rawValue)")
                        .foregroundStyle(
                            option == workspace
                                ? palette.panelAccent(0.82)
                                : palette.panelMuted(0.42)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(option == .looks ? "1" : "2", modifiers: .command)
            }

            if workspace == .looks {
                ForEach([LabMode.grid, LabMode.detail], id: \.rawValue) { option in
                    Button {
                        setMode(option)
                    } label: {
                        Text("[\(option == .grid ? "g" : "d")] \(option.rawValue)")
                            .foregroundStyle(
                                option == mode
                                    ? palette.panelAccent(0.82)
                                    : palette.panelMuted(0.42)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(option == .grid ? "g" : "d", modifiers: [])
                }

                Button(action: beginImport) {
                    Text("[i] import")
                        .foregroundStyle(palette.panelAccent(0.72))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("i", modifiers: [])
            }

            LockPolicyControl(
                palette: palette,
                policy: lockPolicy,
                busy: lockBusy,
                setPolicy: setLockPolicy
            )

            Button {
                dismissLiveryPanel()
            } label: {
                Text("[esc]")
                    .foregroundStyle(palette.panelMuted(0.62))
            }
            .buttonStyle(.plain)
        }
        .font(.lab(10, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 39)
        .background(Color(hex: palette.surface, opacity: 0.72))
        .gesture(WindowDragGesture())
        .zIndex(20)
    }
}

private struct ImportOverlay: View {
    let palette: ThemePalette
    let pending: PendingWallpaperImport
    @Binding var name: String
    @Binding var subtitle: String
    @Binding var credit: String
    let state: ImportState
    let cancel: () -> Void
    let submit: () -> Void

    private var isRunning: Bool {
        state == .running
    }

    private var error: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    private func field(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.lab(8, weight: .semibold))
                .foregroundStyle(palette.panelMuted(0.48))
            TextField("", text: value)
                .textFieldStyle(.plain)
                .font(.lab(10))
                .foregroundStyle(palette.panelText(0.88))
                .padding(.horizontal, 9)
                .frame(height: 31)
                .background(Color(hex: palette.background, opacity: 0.54))
                .overlay(
                    Rectangle()
                        .stroke(Color(hex: palette.outline).opacity(0.28), lineWidth: 1)
                )
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isRunning { cancel() }
                }

            HStack(spacing: 0) {
                Image(nsImage: pending.preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 270, height: 270)
                    .clipped()

                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("IMPORT / WALLPAPER")
                                .font(.lab(10, weight: .bold))
                                .foregroundStyle(Color(hex: palette.primary))
                            Text("managed copy · three generated schemes")
                                .font(.lab(8))
                                .foregroundStyle(palette.panelMuted(0.42))
                        }
                        Spacer()
                        Text(pending.sourceURL.pathExtension.uppercased())
                            .font(.lab(8, weight: .semibold))
                            .foregroundStyle(palette.panelMuted(0.38))
                    }

                    field("NAME", value: $name)
                    field("DESCRIPTION", value: $subtitle)
                    field("CREDIT / SOURCE", value: $credit)

                    if let error {
                        Text(error)
                            .font(.lab(8))
                            .foregroundStyle(Color(hex: palette.error).opacity(0.76))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        Button(action: cancel) {
                            Text("[esc] cancel")
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isRunning)

                        Button(action: submit) {
                            Text(isRunning ? "[·] analyzing" : "[return] import")
                                .foregroundStyle(Color(hex: palette.primary))
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isRunning || name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.return, modifiers: [])
                    }
                    .font(.lab(9, weight: .semibold))
                    .overlay(Rectangle().stroke(Color(hex: palette.outline).opacity(0.22)))
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: 270)
                .background(Color(hex: palette.surface, opacity: 0.96))
            }
            .frame(width: 700, height: 270)
            .overlay(
                Rectangle()
                    .stroke(palette.panelAccent(0.54), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.42), radius: 24, y: 12)
        }
    }
}

private struct AuthoritySelector: View {
    let palette: ThemePalette
    let authority: LookAuthority
    let setAuthority: (LookAuthority) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("ANCHOR")
                .font(.lab(8, weight: .semibold))
                .foregroundStyle(palette.panelMuted(0.46))
                .frame(width: 54, alignment: .leading)

            ForEach(LookAuthority.allCases) { option in
                Button {
                    setAuthority(option)
                } label: {
                    HStack(spacing: 9) {
                        Text("[\(String(option.shortcut))]")
                            .foregroundStyle(
                                option == authority
                                    ? Color(hex: palette.primary)
                                    : palette.panelMuted(0.38)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.rawValue)
                                .foregroundStyle(
                                    palette.panelText(option == authority ? 0.88 : 0.54)
                                )
                            Text(option.explanation)
                                .foregroundStyle(palette.panelMuted(0.42))
                        }
                    }
                    .font(.lab(9, weight: option == authority ? .semibold : .regular))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 43, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        option == authority
                            ? Color(hex: palette.surfaceElevated, opacity: 0.76)
                            : Color.clear
                    )
                    .overlay(
                        Rectangle()
                            .stroke(
                                option == authority
                                    ? palette.panelAccent(0.62)
                                    : Color(hex: palette.outline).opacity(0.16),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(option.shortcut), modifiers: [])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(hex: palette.surface, opacity: 0.48))
    }
}

private struct WallpaperOption: View {
    let fixture: WallpaperFixture
    let selected: Bool
    let accent: String
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(nsImage: fixture.image)
                .resizable()
                .scaledToFill()
                .frame(width: 68)
                .frame(height: 42)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    Text(fixture.shortcut.map { "[\(String($0))]" } ?? "··")
                        .font(.lab(8, weight: .bold))
                        .foregroundStyle(selected ? Color(hex: accent) : .white.opacity(0.68))
                        .padding(4)
                        .background(Color.black.opacity(0.58))
                }
                .overlay(
                    Rectangle()
                        .stroke(selected ? Color(hex: accent) : Color.white.opacity(0.10), lineWidth: selected ? 2 : 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if let shortcut = fixture.shortcut {
            button.keyboardShortcut(KeyEquivalent(shortcut), modifiers: [])
        } else {
            button
        }
    }
}

private struct SourcePane: View {
    let fixture: WallpaperFixture
    let palette: ThemePalette
    let authority: LookAuthority
    let wallpaperImage: NSImage
    let previewStatus: String
    let showingOriginal: Bool
    let selectedFixture: Int
    let fixtures: [WallpaperFixture]
    let reposeLibraryBusy: Bool
    let chooseFixture: (Int) -> Void
    let toggleComparison: () -> Void
    let addToRepose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(authority == .wallpaper ? "ANCHOR / WALLPAPER" : "TARGET / WALLPAPER")
                    .foregroundStyle(palette.panelMuted(0.58))
                Spacer()
                if authority == .theme {
                    Text(previewStatus)
                        .foregroundStyle(palette.panelMuted(0.34))
                    Button(action: toggleComparison) {
                        Text(showingOriginal ? "[x] show graded" : "[x] show original")
                            .foregroundStyle(palette.panelAccent(0.62))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("x", modifiers: [])
                } else {
                    Text(fixture.name)
                        .foregroundStyle(palette.panelMuted(0.34))
                }
                if fixture.live != nil {
                    Button(action: addToRepose) {
                        Text(reposeLibraryBusy ? "[·] adding" : "[+] add to repose")
                            .foregroundStyle(palette.panelAccent(0.62))
                    }
                    .buttonStyle(.plain)
                    .disabled(reposeLibraryBusy)
                }
            }
            .font(.lab(9, weight: .semibold))
            .padding(.bottom, 9)

            GeometryReader { geometry in
                Image(nsImage: wallpaperImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.72)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 82)
                        .overlay(alignment: .bottomLeading) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(fixture.name)
                                    .font(.lab(12, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.90))
                                Text(fixture.credit)
                                    .font(.lab(9))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            .padding(11)
                        }
                    }
                    .overlay(Rectangle().stroke(Color.white.opacity(0.15), lineWidth: 1))
            }

            ThemedScrollView(axis: .horizontal, palette: palette) {
                LazyHStack(spacing: 5) {
                    ForEach(Array(fixtures.enumerated()), id: \.element.id) { index, item in
                        WallpaperOption(
                            fixture: item,
                            selected: index == selectedFixture,
                            accent: palette.primary
                        ) {
                            chooseFixture(index)
                        }
                    }
                }
            }
            .frame(height: 43)
            .padding(.top, 10)
        }
        .padding(14)
    }
}

private struct WallpaperGridCard: View {
    let fixture: WallpaperFixture
    let selected: Bool
    let action: () -> Void

    private var palette: ThemePalette { fixture.palettes[0] }

    var body: some View {
        let button = Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: fixture.image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 132)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        Text(fixture.shortcut.map { "[\(String($0))]" } ?? "local")
                            .font(.lab(9, weight: .bold))
                            .foregroundStyle(selected ? Color(hex: palette.primary) : .white.opacity(0.72))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.62))
                    }

                HStack(spacing: 9) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fixture.name)
                            .font(.lab(10, weight: .semibold))
                            .foregroundStyle(palette.panelText(0.88))
                        Text(fixture.subtitle)
                            .font(.lab(8))
                            .foregroundStyle(palette.panelMuted(0.48))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 2) {
                        ForEach([palette.primary, palette.secondary, palette.tertiary], id: \.self) { hex in
                            Rectangle().fill(Color(hex: hex)).frame(width: 8, height: 19)
                        }
                    }
                }
                .padding(9)
                .background(
                    selected
                        ? Color(hex: palette.surfaceElevated, opacity: 0.92)
                        : Color(hex: palette.surface, opacity: 0.72)
                )
            }
            .contentShape(Rectangle())
            .overlay(
                Rectangle()
                    .stroke(
                        selected
                            ? Color(hex: palette.primary)
                            : Color(hex: palette.outline).opacity(0.22),
                        lineWidth: selected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        if let shortcut = fixture.shortcut {
            button.keyboardShortcut(KeyEquivalent(shortcut), modifiers: [])
        } else {
            button
        }
    }
}

private struct GridPane: View {
    let selectedFixture: Int
    let palette: ThemePalette
    let fixtures: [WallpaperFixture]
    let selectFixture: (Int) -> Void
    let workshopIngested: (String) -> Void

    @State private var workshopQuery = ""
    @State private var workshopItems: [WorkshopItem] = []
    @State private var workshopBusy: String?
    @State private var workshopNote: String?
    @State private var workshopCount = 12

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WALLPAPER LIBRARY")
                    .foregroundStyle(palette.panelText(0.62))
                Text("// \(fixtures.count) sources")
                    .foregroundStyle(palette.panelMuted(0.36))
                Spacer()
                Text("1–9 open detail · scroll for library")
                    .foregroundStyle(palette.panelMuted(0.40))
            }
            .font(.lab(9, weight: .semibold))

            HStack(spacing: 8) {
                Text("WORKSHOP")
                    .font(.lab(9, weight: .semibold))
                    .foregroundStyle(palette.panelText(0.62))
                TextField("search wallpaper engine…", text: $workshopQuery)
                    .textFieldStyle(.plain)
                    .font(.lab(10))
                    .foregroundStyle(palette.panelText(0.85))
                    .onSubmit { searchWorkshop() }
                if let note = workshopNote {
                    Text(note)
                        .font(.lab(9))
                        .foregroundStyle(palette.panelMuted(0.45))
                }
                if !workshopItems.isEmpty {
                    if workshopItems.count >= workshopCount {
                        Button("more") {
                            workshopCount += 12
                            searchWorkshop(resetCount: false)
                        }
                        .buttonStyle(.plain)
                        .font(.lab(9, weight: .semibold))
                        .foregroundStyle(palette.panelAccent(0.62))
                    }
                    Button("clear") {
                        workshopItems = []
                        workshopNote = nil
                        workshopCount = 12
                    }
                    .buttonStyle(.plain)
                    .font(.lab(9, weight: .semibold))
                    .foregroundStyle(palette.panelAccent(0.62))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color(hex: palette.surface))
            .overlay(Rectangle().stroke(Color(hex: palette.outline).opacity(0.16), lineWidth: 1))

            ThemedScrollView(axis: .vertical, palette: palette) {
                if !workshopItems.isEmpty {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(workshopItems) { item in
                            WorkshopCard(
                                item: item,
                                palette: palette,
                                busy: workshopBusy == item.id
                            ) {
                                ingest(item)
                            }
                        }
                    }
                    .padding(.bottom, 10)
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(fixtures.enumerated()), id: \.element.id) { index, fixture in
                        WallpaperGridCard(fixture: fixture, selected: index == selectedFixture) {
                            selectFixture(index)
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func searchWorkshop(resetCount: Bool = true) {
        if resetCount {
            workshopCount = 12
        }
        let query = workshopQuery.trimmingCharacters(in: .whitespaces)
        let count = workshopCount
        workshopNote = "searching…"
        workshopBusy = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let items = loadWorkshopItems(query: query, count: count)
            DispatchQueue.main.async {
                guard let items else {
                    workshopNote = "search failed — is the workshop client reachable?"
                    return
                }
                workshopItems = items
                workshopNote = items.isEmpty ? "no results" : "\(items.count) results"
            }
        }
    }

    private func ingest(_ item: WorkshopItem) {
        guard item.playable, workshopBusy == nil else { return }
        workshopBusy = item.id
        workshopNote = "ingesting \(item.title)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runWorkshop(["ingest", item.id, "--json"])
            DispatchQueue.main.async {
                workshopBusy = nil
                guard
                    result.status == 0,
                    let line = result.output.split(separator: "\n")
                        .last(where: { $0.hasPrefix("{") }),
                    let data = String(line).data(using: .utf8),
                    let ingested = try? JSONDecoder().decode(WorkshopIngest.self, from: data)
                else {
                    workshopNote = "ingest failed"
                    return
                }
                workshopNote = nil
                workshopIngested(ingested.fixture)
            }
        }
    }
}

private struct WorkshopCard: View {
    let item: WorkshopItem
    let palette: ThemePalette
    let busy: Bool
    let ingest: () -> Void

    var body: some View {
        Button(action: ingest) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let path = item.preview, let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.black
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
                .clipped()
                .overlay(alignment: .topLeading) {
                    if busy {
                        Text("INGESTING…")
                            .font(.lab(8, weight: .bold))
                            .foregroundStyle(Color(hex: palette.primary))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.62))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.lab(10, weight: .semibold))
                        .foregroundStyle(palette.panelText(0.85))
                        .lineLimit(1)
                    Text(item.playable
                        ? String(format: "%.1f MB · %d subs · click to add", item.size, item.subs)
                        : "scene — needs the phase-2 renderer")
                        .font(.lab(8))
                        .foregroundStyle(palette.panelMuted(0.50))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: palette.surface))
            }
        }
        .buttonStyle(.plain)
        .disabled(!item.playable || busy)
        .overlay(Rectangle().stroke(Color(hex: palette.outline).opacity(0.20), lineWidth: 1))
    }
}

private struct CandidateSelector: View {
    let palettes: [ThemePalette]
    let selectedPalette: Int
    let choosePalette: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(palettes.enumerated()), id: \.element.id) { index, palette in
                Button {
                    choosePalette(index)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Text("[\(String(palette.key))]")
                                .foregroundStyle(
                                    index == selectedPalette
                                        ? Color(hex: palette.primary)
                                        : palette.panelMuted(0.44)
                                )
                            Text(palette.name)
                                .foregroundStyle(
                                    palette.panelText(index == selectedPalette ? 0.90 : 0.56)
                                )
                        }
                        Text(palette.note)
                            .foregroundStyle(palette.panelMuted(0.44))
                    }
                    .font(.lab(9, weight: index == selectedPalette ? .semibold : .regular))
                    .padding(.vertical, 9)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        index == selectedPalette
                            ? Color(hex: palette.surfaceElevated, opacity: 0.82)
                            : Color.clear
                    )
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(
                                index == selectedPalette
                                    ? Color(hex: palette.primary)
                                    : Color(hex: palette.outline).opacity(0.18)
                            )
                            .frame(height: index == selectedPalette ? 2 : 1)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(palette.key), modifiers: [])
            }
        }
    }
}

private struct ThemeLibrarySelector: View {
    let palette: ThemePalette
    let selectedTheme: Int
    let chooseTheme: (Int) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 128, maximum: 190), spacing: 5),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(Array(themes.enumerated()), id: \.element.id) { index, entry in
                let themePalette = entry.palette
                Button {
                    chooseTheme(index)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.label)
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)
                            .foregroundStyle(
                                palette.panelText(index == selectedTheme ? 0.90 : 0.52)
                            )

                        HStack(spacing: 2) {
                            ForEach(
                                [themePalette.primary, themePalette.secondary, themePalette.tertiary],
                                id: \.self
                            ) { hex in
                                Rectangle()
                                    .fill(Color(hex: hex))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 5)
                            }
                        }

                        HStack(spacing: 4) {
                            Text(entry.style)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(Int(entry.theme.effects.ghosttyBackgroundOpacity * 100))%")
                        }
                        .foregroundStyle(palette.panelMuted(0.38))
                    }
                    .font(.lab(8, weight: index == selectedTheme ? .semibold : .regular))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        index == selectedTheme
                            ? Color(hex: palette.surfaceElevated, opacity: 0.82)
                            : Color.clear
                    )
                    .overlay(
                        Rectangle()
                            .stroke(
                                index == selectedTheme
                                    ? palette.panelAccent(0.70)
                                    : Color(hex: palette.outline).opacity(0.16),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SectionCaption: View {
    let palette: ThemePalette
    let title: String
    let detail: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let detail {
                Text(detail)
                    .foregroundStyle(palette.panelMuted(0.32))
            }
        }
        .font(.lab(8, weight: .semibold))
        .foregroundStyle(palette.panelMuted(0.48))
    }
}

private struct GradePresetSelector: View {
    let palette: ThemePalette
    let selectedPreset: GradePreset
    let choosePreset: (GradePreset) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(GradePreset.allCases) { preset in
                Button {
                    choosePreset(preset)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Text("[\(String(preset.shortcut))]")
                                .foregroundStyle(
                                    preset == selectedPreset
                                        ? Color(hex: palette.primary)
                                        : palette.panelMuted(0.44)
                                )
                            Text(preset.rawValue)
                                .foregroundStyle(
                                    palette.panelText(
                                        preset == selectedPreset ? 0.90 : 0.56
                                    )
                                )
                        }
                        Text(preset.note)
                            .foregroundStyle(palette.panelMuted(0.44))
                    }
                    .font(.lab(9, weight: preset == selectedPreset ? .semibold : .regular))
                    .padding(.vertical, 9)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        preset == selectedPreset
                            ? Color(hex: palette.surfaceElevated, opacity: 0.82)
                            : Color.clear
                    )
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(
                                preset == selectedPreset
                                    ? Color(hex: palette.primary)
                                    : Color(hex: palette.outline).opacity(0.18)
                            )
                            .frame(height: preset == selectedPreset ? 2 : 1)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(preset.shortcut), modifiers: [])
            }
        }
    }
}

private struct TransformOption: Identifiable {
    let id: String
    let label: String
    let note: String
}

private struct TransformSelector: View {
    let palette: ThemePalette
    let options: [TransformOption]
    let selected: String
    var enabled = true
    let choose: (String) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 82, maximum: 150), spacing: 5),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
            ForEach(options) { option in
                Button {
                    choose(option.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.label)
                            .foregroundStyle(
                                palette.panelText(
                                    option.id == selected ? 0.90 : 0.56
                                )
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        Text(option.note)
                            .foregroundStyle(palette.panelMuted(0.42))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .font(.lab(8, weight: option.id == selected ? .semibold : .regular))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, minHeight: 43, alignment: .leading)
                    .contentShape(Rectangle())
                    .background(
                        option.id == selected
                            ? Color(hex: palette.surfaceElevated, opacity: 0.82)
                            : Color.clear
                    )
                    .overlay(
                        Rectangle()
                            .stroke(
                                option.id == selected
                                    ? palette.panelAccent(0.68)
                                    : Color(hex: palette.outline).opacity(0.16),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
    }
}

private struct RoleCell: View {
    let palette: ThemePalette
    let role: String
    let hex: String

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Rectangle()
                    .fill(Color(hex: palette.surfaceElevated))
                Rectangle()
                    .fill(Color(hex: hex))
                    .padding(3)
                    .overlay(
                        Rectangle()
                            .stroke(palette.panelText(0.46), lineWidth: 1)
                            .padding(3)
                    )
            }
            .frame(width: 31, height: 31)
            .overlay(Rectangle().stroke(Color(hex: palette.outline).opacity(0.32)))

            VStack(alignment: .leading, spacing: 3) {
                Text(role)
                    .foregroundStyle(palette.panelText(0.72))
                Text(hex.uppercased())
                    .foregroundStyle(palette.panelMuted(0.46))
            }
            .font(.lab(9, weight: .medium))

            Spacer(minLength: 0)
        }
    }
}

private struct TerminalSpecimen: View {
    let wallpaperImage: NSImage
    let palette: ThemePalette

    private var bgLiteral: String { "0xff\(palette.background.dropFirst())" }
    private var surfaceLiteral: String { "0xff\(palette.surface.dropFirst())" }
    private var accentLiteral: String { "0xff\(palette.primary.dropFirst())" }
    private var ansi: [String] { palette.terminalANSI }
    private var terminalBackground: String { palette.resolvedTerminalBackground }
    private var terminalForeground: String { palette.resolvedTerminalForeground }
    private var terminalOpacity: Double { palette.resolvedGhosttyBackgroundOpacity }
    private var cellBackground: RGBColor {
        RGBColor(hex: terminalBackground).composited(
            over: representativeColor(in: wallpaperImage, fallback: terminalBackground),
            alpha: terminalOpacity
        )
    }
    private var minimumContrast: Double {
        palette.minimumContrast ?? terminalMinimumContrast
    }
    private var minimumContrastLabel: String {
        minimumContrast.rounded() == minimumContrast
            ? String(format: "%.0f", minimumContrast)
            : String(format: "%.1f", minimumContrast)
    }

    private func terminalColor(_ hex: String) -> Color {
        Color(
            hex: ghosttyTextColor(
                hex,
                over: cellBackground,
                minimumContrast: minimumContrast
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CODE / LUA")
                    .foregroundStyle(palette.panelText(0.46))
                Spacer()
                Text("GHOSTTY SIM / \(Int((terminalOpacity * 100).rounded()))% / MIN \(minimumContrastLabel):1")
                    .foregroundStyle(palette.panelAccent(0.62))
            }
            .font(.lab(8, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color(hex: palette.surface))

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 0) {
                        Text("local ").foregroundStyle(terminalColor(ansi[5]))
                        Text("theme ").foregroundStyle(terminalColor(terminalForeground))
                        Text("= ").foregroundStyle(terminalColor(ansi[8]))
                        Text("{").foregroundStyle(terminalColor(ansi[6]))
                    }
                    HStack(spacing: 0) {
                        Text("  bg      ").foregroundStyle(terminalColor(ansi[8]))
                        Text("= ").foregroundStyle(terminalColor(ansi[8]))
                        Text(bgLiteral).foregroundStyle(terminalColor(ansi[4]))
                        Text(",").foregroundStyle(terminalColor(ansi[8]))
                    }
                    HStack(spacing: 0) {
                        Text("  surface ").foregroundStyle(terminalColor(ansi[8]))
                        Text("= ").foregroundStyle(terminalColor(ansi[8]))
                        Text(surfaceLiteral).foregroundStyle(terminalColor(ansi[4]))
                        Text(",").foregroundStyle(terminalColor(ansi[8]))
                    }
                    HStack(spacing: 0) {
                        Text("  accent  ").foregroundStyle(terminalColor(ansi[8]))
                        Text("= ").foregroundStyle(terminalColor(ansi[8]))
                        Text(accentLiteral).foregroundStyle(terminalColor(ansi[6]))
                        Text(",").foregroundStyle(terminalColor(ansi[8]))
                    }
                    HStack(spacing: 0) {
                        Text("}").foregroundStyle(terminalColor(ansi[6]))
                        Text("  -- \(palette.name)").foregroundStyle(terminalColor(ansi[8]))
                    }
                    HStack(spacing: 0) {
                        Text("return ").foregroundStyle(terminalColor(ansi[5]))
                        Text("theme").foregroundStyle(terminalColor(terminalForeground))
                    }
                }
                .font(.lab(9))
                .padding(11)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background {
                    // Color.clear pins the bounds to the snippet block, so the
                    // fill image clips there instead of its own proposed size
                    // (visible spill with small frames, e.g. workshop previews).
                    Color.clear
                        .overlay {
                            Image(nsImage: wallpaperImage)
                                .resizable()
                                .scaledToFill()
                        }
                        .overlay(Color(hex: terminalBackground, opacity: terminalOpacity))
                        .clipped()
                }
                .overlay(Rectangle().stroke(Color(hex: palette.outline).opacity(0.26), lineWidth: 1))

                LazyVGrid(columns: Array(repeating: GridItem(.fixed(27), spacing: 4), count: 4), spacing: 5) {
                    ForEach(palette.terminalMap, id: \.0) { number, hex in
                        VStack(spacing: 3) {
                            Rectangle()
                                .fill(Color(hex: hex))
                                .frame(width: 27, height: 18)
                                .overlay(
                                    Rectangle()
                                        .stroke(palette.panelText(0.56), lineWidth: 1)
                                )
                            Text(number)
                                .font(.lab(7))
                                .foregroundStyle(palette.panelText(0.32))
                        }
                    }
                }
                .padding(10)
                .background(Color(hex: terminalBackground))
                .overlay(Rectangle().stroke(Color(hex: palette.outline).opacity(0.26), lineWidth: 1))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: palette.surface))
        }
        .overlay(Rectangle().stroke(Color(hex: palette.outline).opacity(0.32), lineWidth: 1))
    }
}

private struct PalettePane: View {
    let fixture: WallpaperFixture
    let palette: ThemePalette
    let authority: LookAuthority
    let wallpaperImage: NSImage
    let selectedTheme: Int
    let selectedPalette: Int
    let selectedPreset: GradePreset
    let selectedMapping: MappingMode
    let selectedQuantization: QuantizationMode
    let selectedDither: DitherMode
    let selectedFinish: FinishMode
    let chooseTheme: (Int) -> Void
    let choosePalette: (Int) -> Void
    let choosePreset: (GradePreset) -> Void
    let chooseMapping: (MappingMode) -> Void
    let chooseQuantization: (QuantizationMode) -> Void
    let chooseDither: (DitherMode) -> Void
    let chooseFinish: (FinishMode) -> Void

    private let roleColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 11),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(authority == .wallpaper ? "OUTPUT / THEME" : "ANCHOR / THEME")
                    .foregroundStyle(palette.panelMuted(0.58))
                Spacer()
                Text(
                    authority == .wallpaper
                        ? "\(palette.generator) / \(palette.scheme)"
                        : themes[selectedTheme].style
                )
                    .foregroundStyle(palette.panelAccent(0.48))
            }
            .font(.lab(9, weight: .semibold))
            .padding(.horizontal, 14)
            .frame(height: 35)

            ThemedScrollView(axis: .vertical, palette: palette) {
                VStack(alignment: .leading, spacing: 0) {
                    if authority == .theme {
                        SectionCaption(
                            palette: palette,
                            title: "THEME SOURCE",
                            detail: "held while wallpaper changes"
                        )
                        .padding(.horizontal, 10)
                        .padding(.top, 5)
                        .padding(.bottom, 6)

                        ThemeLibrarySelector(
                            palette: palette,
                            selectedTheme: selectedTheme,
                            chooseTheme: chooseTheme
                        )
                        .padding(.horizontal, 5)
                    }

                    if authority == .wallpaper {
                        SectionCaption(
                            palette: palette,
                            title: "SCHEME",
                            detail: nil
                        )
                        .padding(.horizontal, 10)
                        .padding(.top, 3)
                        .padding(.bottom, 3)

                        CandidateSelector(
                            palettes: fixture.palettes,
                            selectedPalette: selectedPalette,
                            choosePalette: choosePalette
                        )
                        .padding(.horizontal, 5)
                    } else {
                        Text(themes[selectedTheme].summary)
                            .font(.lab(8))
                            .foregroundStyle(palette.panelMuted(0.46))
                            .padding(.horizontal, 10)
                            .padding(.top, 7)
                    }

                    if authority == .theme {
                        SectionCaption(
                            palette: palette,
                            title: "WALLPAPER GRADE",
                            detail: "source fidelity → theme affinity"
                        )
                        .padding(.horizontal, 10)
                        .padding(.top, 9)
                        .padding(.bottom, 3)

                        GradePresetSelector(
                            palette: palette,
                            selectedPreset: selectedPreset,
                            choosePreset: choosePreset
                        )
                        .padding(.horizontal, 5)

                        SectionCaption(
                            palette: palette,
                            title: "LUMINANCE MAP",
                            detail: "natural → graphic"
                        )
                        .padding(.horizontal, 10)
                        .padding(.top, 9)
                        .padding(.bottom, 3)

                        TransformSelector(
                            palette: palette,
                            options: MappingMode.allCases.map {
                                TransformOption(id: $0.rawValue, label: $0.label, note: $0.note)
                            },
                            selected: selectedMapping.rawValue
                        ) { rawValue in
                            if let mode = MappingMode(rawValue: rawValue) {
                                chooseMapping(mode)
                            }
                        }
                        .padding(.horizontal, 5)

                        SectionCaption(
                            palette: palette,
                            title: "PALETTE REDUCTION",
                            detail: "theme-derived / OKLab"
                        )
                        .padding(.horizontal, 10)
                        .padding(.top, 9)
                        .padding(.bottom, 3)

                        TransformSelector(
                            palette: palette,
                            options: QuantizationMode.allCases.map {
                                TransformOption(id: $0.rawValue, label: $0.label, note: $0.note)
                            },
                            selected: selectedQuantization.rawValue
                        ) { rawValue in
                            if let mode = QuantizationMode(rawValue: rawValue) {
                                chooseQuantization(mode)
                            }
                        }
                        .padding(.horizontal, 5)

                        SectionCaption(
                            palette: palette,
                            title: "DITHER",
                            detail: selectedQuantization == .continuous
                                ? "select a reduced palette first"
                                : "before quantization"
                        )
                        .padding(.horizontal, 10)
                        .padding(.top, 9)
                        .padding(.bottom, 3)

                        TransformSelector(
                            palette: palette,
                            options: DitherMode.allCases.map {
                                TransformOption(id: $0.rawValue, label: $0.label, note: $0.note)
                            },
                            selected: selectedDither.rawValue,
                            enabled: selectedQuantization != .continuous
                        ) { rawValue in
                            if let mode = DitherMode(rawValue: rawValue) {
                                chooseDither(mode)
                            }
                        }
                        .padding(.horizontal, 5)

                        SectionCaption(
                            palette: palette,
                            title: "FINISH",
                            detail: "deterministic / replayable"
                        )
                        .padding(.horizontal, 10)
                        .padding(.top, 9)
                        .padding(.bottom, 3)

                        TransformSelector(
                            palette: palette,
                            options: FinishMode.allCases.map {
                                TransformOption(id: $0.rawValue, label: $0.rawValue, note: $0.note)
                            },
                            selected: selectedFinish.rawValue
                        ) { rawValue in
                            if let mode = FinishMode(rawValue: rawValue) {
                                chooseFinish(mode)
                            }
                        }
                        .padding(.horizontal, 5)
                    }

                    LazyVGrid(columns: roleColumns, alignment: .leading, spacing: 11) {
                        ForEach(palette.roles, id: \.0) { role, hex in
                            RoleCell(palette: palette, role: role, hex: hex)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)

                    TerminalSpecimen(wallpaperImage: wallpaperImage, palette: palette)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                }
            }
        }
    }
}

private struct ReposeSceneCard: View {
    let scene: ReposeScene
    let included: Bool
    let current: Bool
    let palette: ThemePalette
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let thumbnail = scene.thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else if scene.isDesktop {
                        ZStack {
                            LinearGradient(
                                colors: [
                                    Color(hex: palette.background),
                                    Color(hex: palette.primary).opacity(0.52),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Text("DESKTOP")
                                .font(.lab(10, weight: .bold))
                                .foregroundStyle(palette.panelText(0.72))
                        }
                    } else {
                        Color(hex: palette.surfaceElevated)
                            .overlay {
                                Text("generating preview…")
                                    .font(.lab(8))
                                    .foregroundStyle(palette.panelMuted(0.40))
                            }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if current {
                        Text("NOW")
                            .font(.lab(7, weight: .bold))
                            .foregroundStyle(Color(hex: palette.background))
                            .padding(.horizontal, 5)
                            .frame(height: 18)
                            .background(Color(hex: palette.primary))
                            .padding(5)
                    }
                }

                HStack(spacing: 7) {
                    Text(included ? "[in]" : "[  ]")
                        .font(.lab(7, weight: .bold))
                        .foregroundStyle(
                            included ? palette.panelAccent(0.88) : palette.panelMuted(0.34)
                        )
                    Text(scene.name)
                        .font(.lab(9, weight: included ? .semibold : .regular))
                        .foregroundStyle(palette.panelText(included ? 0.86 : 0.52))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if scene.isDesktop {
                        Text("mirror")
                            .font(.lab(7, weight: .semibold))
                            .foregroundStyle(palette.panelMuted(0.38))
                    }
                }
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
                .background(Color(hex: palette.surface, opacity: included ? 0.94 : 0.64))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay(
                Rectangle().strokeBorder(
                    included
                        ? palette.panelAccent(0.72)
                        : Color(hex: palette.outline).opacity(0.20),
                    lineWidth: 1
                )
            )
            .clipped()
        }
        .buttonStyle(.plain)
    }
}

private struct ReposeRotationCard: View {
    let scene: ReposeScene
    let position: Int
    let current: Bool
    let palette: ThemePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let thumbnail = scene.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else if scene.isDesktop {
                    LinearGradient(
                        colors: [Color(hex: palette.background), Color(hex: palette.primary)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                } else {
                    Color(hex: palette.surfaceElevated)
                }
            }
            .frame(width: 146, height: 76)
            .clipped()
            .overlay(alignment: .topLeading) {
                Text(String(format: "%02d", position + 1))
                    .font(.lab(7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.76))
                    .padding(5)
                    .background(Color.black.opacity(0.54))
            }
            .overlay(alignment: .topTrailing) {
                if current {
                    Text("NOW")
                        .font(.lab(7, weight: .bold))
                        .foregroundStyle(Color(hex: palette.background))
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .background(Color(hex: palette.primary))
                        .padding(5)
                }
            }

            Text(scene.name)
                .font(.lab(8, weight: current ? .semibold : .regular))
                .foregroundStyle(palette.panelText(current ? 0.88 : 0.58))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    Text("⠿")
                        .font(.lab(8, weight: .semibold))
                        .foregroundStyle(palette.panelMuted(0.44))
                }
                .padding(.horizontal, 7)
                .frame(width: 146, height: 28, alignment: .leading)
                .background(Color(hex: palette.surface, opacity: 0.82))
        }
        .overlay(
            Rectangle().strokeBorder(
                current ? palette.panelAccent(0.76) : Color(hex: palette.outline).opacity(0.20),
                lineWidth: 1
            )
        )
        .contentShape(Rectangle())
    }
}

private struct ReposePane: View {
    let palette: ThemePalette
    let scenes: [ReposeScene]
    let selection: ReposeSelection
    let status: String
    let toggleMembership: (ReposeScene) -> Void
    let commitOrder: ([String]) -> Void
    let toggleCover: () -> Void

    @State private var draggedID: String?
    @State private var draftOrder: [String]?

    private let rotationCoordinateSpace = "repose.rotation.order"
    private let rotationCardSpan: CGFloat = 154

    private let columns = [
        GridItem(.adaptive(minimum: 190, maximum: 270), spacing: 10),
    ]

    private var displayedOrder: [String] {
        let persisted = selection.scenePool.isEmpty ? scenes.map(\.id) : selection.scenePool
        return draftOrder ?? persisted
    }

    private var rotationScenes: [ReposeScene] {
        let byID = Dictionary(uniqueKeysWithValues: scenes.map { ($0.id, $0) })
        return displayedOrder.compactMap { byID[$0] }
    }

    private func updateDrag(sceneID: String, x: CGFloat) {
        if draggedID == nil {
            draggedID = sceneID
            draftOrder = displayedOrder
        }
        guard var order = draftOrder,
              let from = order.firstIndex(of: sceneID), !order.isEmpty
        else { return }
        let proposed = Int(floor(max(x, 0) / rotationCardSpan))
        let target = min(proposed, order.count - 1)
        guard target != from else { return }
        order.move(
            fromOffsets: IndexSet(integer: from),
            toOffset: target > from ? target + 1 : target
        )
        draftOrder = order
    }

    private func finishDrag() {
        if let draftOrder { commitOrder(draftOrder) }
        draggedID = nil
        draftOrder = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("ROTATION")
                    .foregroundStyle(palette.panelText(0.68))
                Text("// \(rotationScenes.count) included · drag to order")
                    .foregroundStyle(palette.panelMuted(0.38))
                Spacer()
                Text(status)
                    .foregroundStyle(palette.panelMuted(0.44))
                    .lineLimit(1)

                Button(action: toggleCover) {
                    Text("[r] open / close cover")
                        .foregroundStyle(palette.panelAccent(0.82))
                        .padding(.horizontal, 9)
                        .frame(height: 27)
                        .contentShape(Rectangle())
                        .overlay(Rectangle().strokeBorder(palette.panelAccent(0.42), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: [])
            }
            .font(.lab(9, weight: .semibold))

            ThemedScrollView(axis: .horizontal, palette: palette) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(rotationScenes.enumerated()), id: \.element.id) { index, scene in
                        ReposeRotationCard(
                            scene: scene,
                            position: index,
                            current: scene.id == selection.currentSceneID,
                            palette: palette
                        )
                        .highPriorityGesture(
                            DragGesture(
                                minimumDistance: 4,
                                coordinateSpace: .named(rotationCoordinateSpace)
                            )
                            .onChanged { value in
                                updateDrag(sceneID: scene.id, x: value.location.x)
                            }
                            .onEnded { _ in finishDrag() }
                        )
                        .opacity(draggedID == scene.id ? 0.48 : 1)
                    }
                }
                .coordinateSpace(name: rotationCoordinateSpace)
                .animation(.easeOut(duration: 0.12), value: displayedOrder)
            }
            .frame(height: 108)

            Hairline(palette: palette)

            HStack {
                Text("SCENE LIBRARY")
                    .foregroundStyle(palette.panelText(0.64))
                Text("// click to include or exclude · catalog remains untouched")
                    .foregroundStyle(palette.panelMuted(0.36))
                Spacer()
                Text("composition: tab look · v variant · g grade · n night · x strings · l label")
                    .foregroundStyle(palette.panelMuted(0.38))
            }
            .font(.lab(8, weight: .semibold))

            ThemedScrollView(axis: .vertical, palette: palette) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(scenes) { scene in
                        ReposeSceneCard(
                            scene: scene,
                            included: displayedOrder.contains(scene.id),
                            current: scene.id == selection.currentSceneID,
                            palette: palette
                        ) {
                            toggleMembership(scene)
                        }
                    }
                }
            }
        }
        .padding(14)
    }
}

private struct Footer: View {
    let palette: ThemePalette
    let applyState: ApplyState
    let lockPolicy: LockPolicy
    let lockBusy: Bool
    let lockMessage: String?
    let apply: () -> Void
    let applyToLock: () -> Void

    private var label: String {
        switch applyState {
        case .idle:
            "[p] apply"
        case .running:
            "[·] applying"
        case .succeeded:
            "[p] applied"
        case .failed:
            "[p] retry"
        }
    }

    private var failure: String? {
        if case .failed(let message) = applyState {
            return message
        }
        return nil
    }

    private var labelColor: Color {
        switch applyState {
        case .failed:
            Color(hex: palette.error).opacity(0.82)
        case .running:
            palette.panelMuted(0.42)
        case .idle:
            palette.panelAccent(0.72)
        case .succeeded:
            Color(hex: "#9ed072").opacity(0.76)
        }
    }

    private var isApplying: Bool {
        if case .running = applyState { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            if let message = failure ?? lockMessage {
                Text(message)
                    .foregroundStyle(Color(hex: palette.error).opacity(0.70))
                    .lineLimit(1)
            }
            Spacer()

            Text(lockPolicy.shortLabel)
                .foregroundStyle(palette.panelMuted(0.40))

            Button(action: applyToLock) {
                Text(lockBusy ? "[·] rendering lock" : "[⇧p] lock only")
                    .foregroundStyle(
                        lockBusy ? palette.panelMuted(0.42) : palette.panelAccent(0.64)
                    )
            }
            .buttonStyle(.plain)
            .disabled(lockBusy || isApplying)
            .keyboardShortcut("p", modifiers: .shift)

            Button(action: apply) {
                Text(label)
                    .foregroundStyle(labelColor)
            }
            .buttonStyle(.plain)
            .disabled(isApplying)
            .keyboardShortcut("p", modifiers: [])
        }
        .font(.lab(9))
        .padding(.horizontal, 16)
        .frame(height: 39)
        .background(Color(hex: palette.surface, opacity: 0.72))
    }
}

private struct LiveryView: View {
    @State private var wallpapers = loadWallpaperFixtures()
    @State private var workspace = LiveryWorkspace.looks
    @State private var selectedFixture = 0
    @State private var wallpaperPalette = 0
    @State private var selectedTheme = 0
    @State private var authority = LookAuthority.wallpaper
    @State private var gradePreset = GradePreset.balanced
    @State private var mapping = MappingMode.natural
    @State private var quantization = QuantizationMode.continuous
    @State private var dithering = DitherMode.none
    @State private var finish = FinishMode.clean
    @State private var mode: LabMode = .detail
    @State private var applyState: ApplyState = .idle
    @State private var derivedWallpaper: NSImage?
    @State private var derivedProfile = ""
    @State private var previewStatus = "source pixels"
    @State private var showingOriginal = false
    @State private var pendingImport: PendingWallpaperImport?
    @State private var importName = ""
    @State private var importSubtitle = ""
    @State private var importCredit = ""
    @State private var importState = ImportState.idle
    @State private var reposeSelection = loadReposeSelection()
    @State private var reposeScenes = loadReposeScenes()
    @State private var reposeStatus = "saved · ready for the next cover"
    @State private var lockPolicy = loadLockPolicy()
    @State private var lockBusy = false
    @State private var lockMessage: String?
    @State private var reposeLibraryBusy = false
    @State private var reposeMutation = 0

    private var fixture: WallpaperFixture { wallpapers[selectedFixture] }
    private var selectedPalette: Int {
        authority == .wallpaper ? wallpaperPalette : 0
    }
    private var palette: ThemePalette {
        authority == .wallpaper
            ? fixture.palettes[wallpaperPalette]
            : themes[selectedTheme].palette
    }
    private var wallpaperImage: NSImage {
        if authority == .theme, showingOriginal {
            return fixture.image
        }
        if authority == .theme, derivedProfile == profile, let derivedWallpaper {
            return derivedWallpaper
        }
        return fixture.image
    }
    private var transformRecipe: String {
        [
            gradePreset.rawValue,
            mapping.rawValue,
            quantization.rawValue,
            dithering.rawValue,
            finish.rawValue,
        ].joined(separator: "~")
    }
    private var profile: String {
        switch authority {
        case .wallpaper:
            "wallpaper:\(fixture.id):\(palette.name)"
        case .theme:
            "theme:\(themes[selectedTheme].ref)@\(fixture.id):\(transformRecipe)"
        }
    }
    private var lookLabel: String {
        switch authority {
        case .wallpaper:
            "\(fixture.name):\(palette.name)"
        case .theme:
            "\(themes[selectedTheme].label) @ \(fixture.name):\(transformRecipe)"
        }
    }

    private func invalidatePreview() {
        derivedWallpaper = nil
        derivedProfile = ""
        previewStatus = "rendering derivative…"
        showingOriginal = false
    }

    private func setAuthority(_ next: LookAuthority) {
        guard next != authority else { return }
        if next == .theme {
            invalidatePreview()
        } else {
            derivedWallpaper = nil
            derivedProfile = ""
            previewStatus = "source pixels"
        }
        authority = next
    }

    private func chooseTheme(_ index: Int) {
        selectedTheme = index
        invalidatePreview()
    }

    private func chooseFixture(_ index: Int, openDetail: Bool = false) {
        guard wallpapers.indices.contains(index) else { return }
        selectedFixture = index
        if authority == .wallpaper {
            wallpaperPalette = 0
        } else {
            invalidatePreview()
        }
        if openDetail {
            mode = .detail
        }
    }

    private func choosePalette(_ index: Int) {
        if authority == .wallpaper {
            wallpaperPalette = index
        }
    }

    private func chooseQuantization(_ next: QuantizationMode) {
        quantization = next
        if next == .continuous {
            dithering = .none
        }
        invalidatePreview()
    }

    private func refreshPreview() {
        guard authority == .theme else {
            derivedWallpaper = nil
            derivedProfile = ""
            previewStatus = "source pixels"
            return
        }
        let requestedProfile = profile
        previewStatus = "rendering derivative…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = renderLookPreview(profile: requestedProfile)
            DispatchQueue.main.async {
                guard authority == .theme, profile == requestedProfile else { return }
                derivedWallpaper = result.image
                derivedProfile = result.image == nil ? "" : requestedProfile
                previewStatus = result.message
            }
        }
    }

    private func applySelection() {
        let selectedProfile = profile
        applyState = .running(selectedProfile)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = applyLook(profile: selectedProfile)
            DispatchQueue.main.async {
                guard profile == selectedProfile else {
                    applyState = .idle
                    return
                }
                applyState = result.succeeded
                    ? .succeeded(result.message)
                    : .failed(result.message)
            }
        }
    }

    private func refreshReposeWorkspace(generateThumbnails: Bool) {
        reposeSelection = loadReposeSelection()
        if generateThumbnails {
            DispatchQueue.global(qos: .userInitiated).async {
                let loaded = loadReposeScenes(generateThumbnails: true)
                DispatchQueue.main.async {
                    reposeScenes = loaded
                }
            }
        } else {
            reposeScenes = loadReposeScenes()
        }
    }

    private func persistReposePool(_ pool: [String]) {
        guard !pool.isEmpty else {
            reposeStatus = "rotation needs at least one scene"
            return
        }
        var next = reposeSelection
        next.scenePool = pool
        if !pool.contains(next.currentSceneID), let firstID = pool.first,
           let first = reposeScenes.first(where: { $0.id == firstID }) {
            next.scene = first.path
        }
        reposeSelection = next
        reposeMutation += 1
        let mutation = reposeMutation
        reposeStatus = "saving rotation…"
        reposeControlQueue.async {
            let result = runWallpaperControl(["repose-pool"] + pool)
            DispatchQueue.main.async {
                guard mutation == reposeMutation else { return }
                if result.status == 0 {
                    reposeSelection = loadReposeSelection()
                    reposeStatus = "rotation saved · arrows follow this order"
                } else {
                    reposeSelection = loadReposeSelection()
                    reposeStatus = result.output.isEmpty ? "could not save rotation" : result.output
                }
            }
        }
    }

    private func toggleReposeMembership(_ scene: ReposeScene) {
        var pool = reposeSelection.scenePool.isEmpty
            ? reposeScenes.map(\.id)
            : reposeSelection.scenePool
        if let index = pool.firstIndex(of: scene.id) {
            guard pool.count > 1 else {
                reposeStatus = "rotation needs at least one scene"
                return
            }
            pool.remove(at: index)
        } else {
            pool.append(scene.id)
        }
        persistReposePool(pool)
    }

    private func toggleReposeCover() {
        reposeStatus = "toggling cover…"
        reposeControlQueue.async {
            let result = runWallpaperControl(["repose"])
            DispatchQueue.main.async {
                reposeStatus = result.status == 0
                    ? "cover toggled · state remains persistent"
                    : (result.output.isEmpty ? "could not toggle cover" : result.output)
            }
        }
    }

    private func changeLockPolicy(_ action: String) {
        guard !lockBusy else { return }
        lockBusy = true
        lockMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runLiveryControl(["lock", action])
            DispatchQueue.main.async {
                lockBusy = false
                if result.status == 0 {
                    lockPolicy = loadLockPolicy()
                } else {
                    lockMessage = result.output.split(separator: "\n").last.map(String.init)
                        ?? "lock update failed"
                }
            }
        }
    }

    private func applySelectionToLock() {
        changeLockPolicy("look:\(profile)")
    }

    private func addSelectedWallpaperToRepose() {
        guard !reposeLibraryBusy, let live = fixture.live else { return }
        reposeLibraryBusy = true
        reposeControlQueue.async {
            let result = runWallpaperControl(["repose-add", live])
            let refreshed = result.status == 0 ? loadReposeScenes(generateThumbnails: true) : nil
            DispatchQueue.main.async {
                reposeLibraryBusy = false
                if let refreshed {
                    reposeScenes = refreshed
                    reposeStatus = result.output
                }
            }
        }
    }

    @MainActor
    private func beginImport() {
        guard let sourceURL = chooseWallpaperFile(),
              let preview = NSImage(contentsOf: sourceURL)
        else {
            return
        }
        pendingImport = PendingWallpaperImport(sourceURL: sourceURL, preview: preview)
        importName = sourceURL.deletingPathExtension().lastPathComponent
        importSubtitle = "local / imported / awaiting tags"
        importCredit = "personal library"
        importState = .idle
    }

    private func cancelImport() {
        guard importState != .running else { return }
        pendingImport = nil
        importState = .idle
    }

    private func submitImport() {
        guard let pendingImport, importState != .running else { return }
        let requestedName = importName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedName.isEmpty else { return }
        let requestedSubtitle = importSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedCredit = importCredit.trimmingCharacters(in: .whitespacesAndNewlines)
        importState = .running

        DispatchQueue.global(qos: .userInitiated).async {
            let result = importWallpaper(
                sourceURL: pendingImport.sourceURL,
                name: requestedName,
                subtitle: requestedSubtitle.isEmpty
                    ? "local / imported / unclassified"
                    : requestedSubtitle,
                credit: requestedCredit.isEmpty ? "personal library" : requestedCredit
            )
            DispatchQueue.main.async {
                switch result {
                case .succeeded(let imported):
                    let refreshed = loadWallpaperFixtures()
                    wallpapers = refreshed
                    if let index = refreshed.firstIndex(where: { $0.id == imported.id }) {
                        chooseFixture(index, openDetail: true)
                    }
                    self.pendingImport = nil
                    importState = .idle
                case .failed(let message):
                    importState = .failed(message)
                }
            }
        }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Header(
                    palette: palette,
                    workspace: workspace,
                    setWorkspace: { next in
                        workspace = next
                        if next == .repose {
                            refreshReposeWorkspace(generateThumbnails: true)
                        }
                    },
                    authority: authority,
                    lookLabel: lookLabel,
                    mode: mode,
                    setMode: { mode = $0 },
                    beginImport: beginImport,
                    lockPolicy: lockPolicy,
                    lockBusy: lockBusy,
                    setLockPolicy: changeLockPolicy
                )
                Hairline(palette: palette)

                if workspace == .repose {
                    ReposePane(
                        palette: palette,
                        scenes: reposeScenes,
                        selection: reposeSelection,
                        status: reposeStatus,
                        toggleMembership: toggleReposeMembership,
                        commitOrder: persistReposePool,
                        toggleCover: toggleReposeCover
                    )
                    .frame(maxHeight: .infinity)
                } else if mode == .grid {
                    AuthoritySelector(
                        palette: palette,
                        authority: authority,
                        setAuthority: setAuthority
                    )
                    Hairline(palette: palette)
                    GridPane(
                        selectedFixture: selectedFixture,
                        palette: palette,
                        fixtures: wallpapers,
                        selectFixture: { index in
                            chooseFixture(index, openDetail: true)
                        },
                        workshopIngested: { fixtureID in
                            let refreshed = loadWallpaperFixtures()
                            wallpapers = refreshed
                            if let index = refreshed.firstIndex(where: { $0.id == fixtureID }) {
                                chooseFixture(index, openDetail: true)
                            }
                        }
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    AuthoritySelector(
                        palette: palette,
                        authority: authority,
                        setAuthority: setAuthority
                    )
                    Hairline(palette: palette)
                    HStack(spacing: 0) {
                        SourcePane(
                            fixture: fixture,
                            palette: palette,
                            authority: authority,
                            wallpaperImage: wallpaperImage,
                            previewStatus: previewStatus,
                            showingOriginal: showingOriginal,
                            selectedFixture: selectedFixture,
                            fixtures: wallpapers,
                            reposeLibraryBusy: reposeLibraryBusy
                        ) { index in
                            chooseFixture(index)
                        } toggleComparison: {
                            showingOriginal.toggle()
                        } addToRepose: {
                            addSelectedWallpaperToRepose()
                        }
                        .frame(minWidth: 340, idealWidth: 424, maxWidth: 520)
                        .layoutPriority(0.85)

                        Rectangle()
                            .fill(Color(hex: palette.outline).opacity(0.20))
                            .frame(width: 1)

                        PalettePane(
                            fixture: fixture,
                            palette: palette,
                            authority: authority,
                            wallpaperImage: wallpaperImage,
                            selectedTheme: selectedTheme,
                            selectedPalette: selectedPalette,
                            selectedPreset: gradePreset,
                            selectedMapping: mapping,
                            selectedQuantization: quantization,
                            selectedDither: dithering,
                            selectedFinish: finish,
                            chooseTheme: chooseTheme,
                            choosePalette: choosePalette,
                            choosePreset: { preset in
                                gradePreset = preset
                                invalidatePreview()
                            },
                            chooseMapping: { mode in
                                mapping = mode
                                invalidatePreview()
                            },
                            chooseQuantization: chooseQuantization,
                            chooseDither: { mode in
                                dithering = mode
                                invalidatePreview()
                            },
                            chooseFinish: { mode in
                                finish = mode
                                invalidatePreview()
                            }
                        )
                        .frame(minWidth: 390, maxWidth: .infinity)
                        .layoutPriority(1)
                    }
                    .frame(maxHeight: .infinity)
                }

                if workspace == .looks, mode == .detail {
                    Hairline(palette: palette)
                    Footer(
                        palette: palette,
                        applyState: applyState,
                        lockPolicy: lockPolicy,
                        lockBusy: lockBusy,
                        lockMessage: lockMessage,
                        apply: applySelection,
                        applyToLock: applySelectionToLock
                    )
                }
            }
            .disabled(pendingImport != nil)

            if let pendingImport {
                ImportOverlay(
                    palette: palette,
                    pending: pendingImport,
                    name: $importName,
                    subtitle: $importSubtitle,
                    credit: $importCredit,
                    state: importState,
                    cancel: cancelImport,
                    submit: submitImport
                )
            }
        }
        .background {
            ZStack {
                BackdropBlur()
                Color(
                    hex: palette.background,
                    opacity: palette.panelBackgroundOpacity
                )
            }
        }
        .overlay(
            Rectangle()
                .stroke(Color(hex: palette.outline).opacity(0.16), lineWidth: 1)
        )
        .preferredColorScheme(palette.isLight ? .light : .dark)
        .onAppear {
            refreshPreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: liveryPanelShown)) { _ in
            wallpapers = loadWallpaperFixtures()
            lockPolicy = loadLockPolicy()
            if workspace == .repose {
                refreshReposeWorkspace(generateThumbnails: true)
            }
        }
        .onChange(of: profile) {
            applyState = .idle
            lockMessage = nil
            showingOriginal = false
            refreshPreview()
        }
        .onExitCommand {
            if pendingImport != nil {
                cancelImport()
            } else {
                dismissLiveryPanel()
            }
        }
    }
}

private final class LiveryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        dismissLiveryPanel()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: LiveryPanel?
    private var signalSource: DispatchSourceSignal?
    private weak var previousApplication: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtimeLog("applicationDidFinishLaunching")
        buildPanel()
        installToggleSignal()
        markReady()
        showPanel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard
            let contents = try? String(contentsOf: readinessURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            contents == String(ProcessInfo.processInfo.processIdentifier)
        else {
            return
        }
        try? FileManager.default.removeItem(at: readinessURL)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        runtimeLog(
            "applicationShouldHandleReopen visible=\(panel?.isVisible ?? false) "
                + "active=\(NSApp.isActive)"
        )
        if panel?.isVisible == true {
            hidePanel()
            return false
        }

        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            self?.showPanel()
        }
        return true
    }

    private func buildPanel() {
        let panel = LiveryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 560),
            styleMask: [.titled, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Livery"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // Only the header is a drag region. Treating the whole borderless
        // surface as draggable steals Repose's filmstrip reorder gesture.
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 860, height: 520)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        let host = NSHostingView(rootView: LiveryView())
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.center()
        self.panel = panel
        runtimeLog("buildPanel visible=\(panel.isVisible) key=\(panel.isKeyWindow)")
    }

    private func installToggleSignal() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            runtimeLog("received SIGUSR1")
            self?.togglePanel()
        }
        source.resume()
        signalSource = source
    }

    private func markReady() {
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try? pid.write(to: readinessURL, atomically: true, encoding: .utf8)
    }

    private func togglePanel() {
        guard let panel else { return }
        runtimeLog("togglePanel visible=\(panel.isVisible) key=\(panel.isKeyWindow)")
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let panel else { return }
        NotificationCenter.default.post(name: liveryPanelShown, object: nil)
        runtimeLog("showPanel begin visible=\(panel.isVisible) active=\(NSApp.isActive)")
        if panel.isVisible {
            panel.orderOut(nil)
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2
            ))
        }
        let promoted = NSApp.setActivationPolicy(.regular)
        runtimeLog("showPanel promoted=\(promoted)")
        let activated = NSRunningApplication.current.activate(options: [.activateAllWindows])
        runtimeLog("showPanel activated=\(activated)")
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            runtimeLog(
                "showPanel end visible=\(panel.isVisible) key=\(panel.isKeyWindow) "
                    + "main=\(panel.isMainWindow) active=\(NSApp.isActive) "
                    + "activeSpace=\(panel.isOnActiveSpace) "
                    + "occluded=\(panel.occlusionState.contains(.visible) == false)"
            )
        }
    }

    func hidePanel() {
        runtimeLog("hidePanel begin visible=\(panel?.isVisible ?? false)")
        panel?.orderOut(nil)
        if let previousApplication, !previousApplication.isTerminated {
            previousApplication.activate(options: [.activateAllWindows])
        } else {
            NSApp.deactivate()
        }
        NSApp.setActivationPolicy(.accessory)
        previousApplication = nil
        DispatchQueue.main.async {
            runtimeLog(
                "hidePanel end visible=\(self.panel?.isVisible ?? false) "
                    + "active=\(NSApp.isActive)"
            )
        }
    }
}

@main
private struct LiveryApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
