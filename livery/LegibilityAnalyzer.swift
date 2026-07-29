import AppKit
import Foundation

private struct DisplayRecord: Decodable {
    struct Frame: Decodable {
        let w: Double
        let h: Double
    }

    let frame: Frame
}

private enum AnalyzerError: LocalizedError {
    case usage
    case missingImage(String)
    case unreadableImage(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: livery-legibility <image> <palette.json> <displays.json>"
        case .missingImage(let path):
            return "image does not exist: \(path)"
        case .unreadableImage(let path):
            return "image could not be decoded: \(path)"
        }
    }
}

@main
private enum LiveryLegibilityAnalyzer {
    static func main() {
        do {
            let arguments = CommandLine.arguments
            guard arguments.count == 4 else { throw AnalyzerError.usage }
            let imagePath = arguments[1]
            guard FileManager.default.fileExists(atPath: imagePath) else {
                throw AnalyzerError.missingImage(imagePath)
            }
            guard let image = NSImage(contentsOfFile: imagePath) else {
                throw AnalyzerError.unreadableImage(imagePath)
            }
            let palette = try JSONDecoder().decode(
                BarLegibilityPaletteInput.self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[2]))
            )
            let displays = try JSONDecoder().decode(
                [DisplayRecord].self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments[3]))
            )
            let displaySizes = displays.map {
                CGSize(width: $0.frame.w, height: $0.frame.h)
            }
            let result = LegibilityOutput(
                barLegibility: analyzeBarLegibility(
                    image: image,
                    displaySizes: displaySizes,
                    palette: BarLegibilityPalette(
                        text: palette.text,
                        textMuted: palette.textMuted,
                        background: palette.background,
                        roles: palette.roles
                    )
                ),
                terminalLegibility: analyzeTerminalLegibility(
                    image: image,
                    displaySizes: displaySizes,
                    palette: TerminalLegibilityPalette(
                        background: palette.terminal.background,
                        foreground: palette.terminal.foreground,
                        ansi: palette.terminal.ansi,
                        roles: palette.terminal.roles
                    ),
                    backdropOpacity: palette.terminal.backdropOpacity,
                    paletteMinimumContrast: palette.terminal.minimumContrast
                )
            )
            try write(result)
        } catch {
            fputs("livery-legibility: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func write<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([10]))
    }
}

private struct BarLegibilityPaletteInput: Decodable {
    let text: String
    let textMuted: String
    let background: String
    let roles: [String: String]
    let terminal: TerminalPaletteInput
}

private struct TerminalPaletteInput: Decodable {
    let background: String
    let foreground: String
    let ansi: [String]
    let roles: [String: String]
    let backdropOpacity: Double
    let minimumContrast: Double
}

private struct LegibilityOutput: Encodable {
    let barLegibility: BarLegibilityResult
    let terminalLegibility: TerminalLegibilityResult
}
