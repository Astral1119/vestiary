import AppKit
import Foundation

struct RGBColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(hex: String) {
        let value = UInt64(
            hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
            radix: 16
        ) ?? 0
        red = Double((value >> 16) & 0xff) / 255
        green = Double((value >> 8) & 0xff) / 255
        blue = Double(value & 0xff) / 255
    }

    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.sRGB) ?? .black
        red = color.redComponent
        green = color.greenComponent
        blue = color.blueComponent
    }

    var hex: String {
        String(
            format: "#%02x%02x%02x",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red)
            + 0.7152 * channel(green)
            + 0.0722 * channel(blue)
    }

    func mixed(with other: RGBColor, amount: Double) -> RGBColor {
        RGBColor(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }

    func composited(over background: RGBColor, alpha: Double) -> RGBColor {
        background.mixed(with: self, amount: alpha)
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }
}

struct BarLegibilityPalette {
    let text: String
    let textMuted: String
    let background: String
    let roles: [String: String]
}

struct BarLegibilityResult: Codable {
    let strategy: String
    let polarity: String
    let text: String
    let textMuted: String
    let accent: String
    let scrim: String
    let scrimAlpha: Int
    let textContrastP10: Double
    let textContrastMedian: Double
    let roles: [String: String]
    let sampleCount: Int
}

private func contrast(_ foreground: RGBColor, _ background: RGBColor) -> Double {
    let light = max(foreground.luminance, background.luminance)
    let dark = min(foreground.luminance, background.luminance)
    return (light + 0.05) / (dark + 0.05)
}

private func quantile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 1 }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * fraction).rounded(.down))
    return sorted[index]
}

private func contrastP10(
    foreground: RGBColor,
    samples: [RGBColor],
    scrim: RGBColor,
    scrimAlpha: Double
) -> Double {
    quantile(
        samples.map {
            contrast(foreground, scrim.composited(over: $0, alpha: scrimAlpha))
        },
        0.10
    )
}

private func adjustedRole(
    original: RGBColor,
    toward foreground: RGBColor,
    samples: [RGBColor],
    scrim: RGBColor,
    scrimAlpha: Double,
    minimum: Double
) -> RGBColor {
    if contrastP10(
        foreground: original,
        samples: samples,
        scrim: scrim,
        scrimAlpha: scrimAlpha
    ) >= minimum {
        return original
    }

    var low = 0.0
    var high = 1.0
    for _ in 0..<12 {
        let amount = (low + high) / 2
        let candidate = original.mixed(with: foreground, amount: amount)
        if contrastP10(
            foreground: candidate,
            samples: samples,
            scrim: scrim,
            scrimAlpha: scrimAlpha
        ) >= minimum {
            high = amount
        } else {
            low = amount
        }
    }
    return original.mixed(with: foreground, amount: high)
}

private func wallpaperSamples(
    image: NSImage,
    displaySizes: [CGSize],
    barHeight: CGFloat
) -> [RGBColor] {
    guard
        let representation = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()),
        representation.pixelsWide > 0,
        representation.pixelsHigh > 0
    else {
        return []
    }

    let imageWidth = CGFloat(representation.pixelsWide)
    let imageHeight = CGFloat(representation.pixelsHigh)
    var samples: [RGBColor] = []

    for display in displaySizes where display.width > 0 && display.height > 0 {
        let scale = max(display.width / imageWidth, display.height / imageHeight)
        let visibleWidth = display.width / scale
        let visibleHeight = display.height / scale
        let cropX = (imageWidth - visibleWidth) / 2
        let cropY = (imageHeight - visibleHeight) / 2
        let sampledBarHeight = min(barHeight / scale, visibleHeight)

        for row in 0..<8 {
            let y = cropY + sampledBarHeight * (Double(row) + 0.5) / 8
            for column in 0..<96 {
                let x = cropX + visibleWidth * (Double(column) + 0.5) / 96
                let pixelX = min(max(Int(x), 0), representation.pixelsWide - 1)
                let pixelY = min(max(Int(y), 0), representation.pixelsHigh - 1)
                if let color = representation.colorAt(x: pixelX, y: pixelY) {
                    samples.append(RGBColor(nsColor: color))
                }
            }
        }
    }
    return samples
}

func analyzeBarLegibility(
    image: NSImage,
    displaySizes: [CGSize],
    palette: BarLegibilityPalette,
    barHeight: CGFloat = 40
) -> BarLegibilityResult {
    let samples = wallpaperSamples(
        image: image,
        displaySizes: displaySizes.isEmpty
            ? [CGSize(width: 1728, height: 1117)]
            : displaySizes,
        barHeight: barHeight
    )
    let safeSamples = samples.isEmpty ? [RGBColor(hex: palette.background)] : samples
    let firstCandidate = RGBColor(hex: palette.text)
    let secondCandidate = RGBColor(hex: palette.background)
    let light = firstCandidate.luminance >= secondCandidate.luminance
        ? firstCandidate
        : secondCandidate
    let dark = firstCandidate.luminance < secondCandidate.luminance
        ? firstCandidate
        : secondCandidate
    let transparentScrim = RGBColor(hex: "#000000")
    let lightScore = contrastP10(
        foreground: light,
        samples: safeSamples,
        scrim: transparentScrim,
        scrimAlpha: 0
    )
    let darkScore = contrastP10(
        foreground: dark,
        samples: safeSamples,
        scrim: transparentScrim,
        scrimAlpha: 0
    )
    let foreground = lightScore >= darkScore ? light : dark
    let polarity = lightScore >= darkScore ? "light" : "dark"
    let scrim = polarity == "light"
        ? RGBColor(hex: "#000000")
        : RGBColor(hex: "#ffffff")

    var scrimAlpha = 0.0
    if max(lightScore, darkScore) < 4.5 {
        var low = 0.0
        var high = 0.82
        for _ in 0..<12 {
            let alpha = (low + high) / 2
            if contrastP10(
                foreground: foreground,
                samples: safeSamples,
                scrim: scrim,
                scrimAlpha: alpha
            ) >= 4.5 {
                high = alpha
            } else {
                low = alpha
            }
        }
        scrimAlpha = high
    }

    let adjusted = palette.roles.mapValues {
        adjustedRole(
            original: RGBColor(hex: $0),
            toward: foreground,
            samples: safeSamples,
            scrim: scrim,
            scrimAlpha: scrimAlpha,
            minimum: 3.0
        ).hex
    }
    let muted = adjustedRole(
        original: RGBColor(hex: palette.textMuted),
        toward: foreground,
        samples: safeSamples,
        scrim: scrim,
        scrimAlpha: scrimAlpha,
        minimum: 3.0
    )
    let accent = RGBColor(hex: adjusted["blue"] ?? palette.roles["blue"] ?? palette.text)
    let textContrasts = safeSamples.map {
        contrast(foreground, scrim.composited(over: $0, alpha: scrimAlpha))
    }

    return BarLegibilityResult(
        strategy: scrimAlpha > 0.005 ? "scrim" : "open",
        polarity: polarity,
        text: foreground.hex,
        textMuted: muted.hex,
        accent: accent.hex,
        scrim: scrim.hex,
        scrimAlpha: Int((scrimAlpha * 255).rounded()),
        textContrastP10: (quantile(textContrasts, 0.10) * 100).rounded() / 100,
        textContrastMedian: (quantile(textContrasts, 0.50) * 100).rounded() / 100,
        roles: adjusted,
        sampleCount: safeSamples.count
    )
}
