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

// OKLab, after Björn Ottosson. Contrast depends only on luminance, so a role
// that has to get lighter does not have to get greyer: holding hue and keeping
// as much chroma as the gamut allows at the new lightness costs nothing in
// contrast. Mixing toward a near-white foreground drives chroma to zero as a
// side effect, which is what flattened the palette.
struct OKLCh {
    var lightness: Double
    var chroma: Double
    var hue: Double
}

private func linearize(_ value: Double) -> Double {
    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
}

private func encodeChannel(_ value: Double) -> Double {
    value <= 0.0031308
        ? value * 12.92
        : 1.055 * pow(value, 1 / 2.4) - 0.055
}

extension RGBColor {
    var oklch: OKLCh {
        let r = linearize(red)
        let g = linearize(green)
        let b = linearize(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return OKLCh(
            lightness: lightness,
            chroma: (a * a + bb * bb).squareRoot(),
            hue: atan2(bb, a)
        )
    }
}

// Unclamped on purpose: the caller needs to know whether the requested
// lightness/chroma pair actually exists in sRGB.
private func linearRGB(from color: OKLCh) -> (Double, Double, Double) {
    let a = color.chroma * cos(color.hue)
    let b = color.chroma * sin(color.hue)
    let l = pow(color.lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
    let m = pow(color.lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
    let s = pow(color.lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
    return (
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    )
}

private func inGamut(_ color: OKLCh) -> Bool {
    let (r, g, b) = linearRGB(from: color)
    let limit = -0.0001 ... 1.0001
    return limit.contains(r) && limit.contains(g) && limit.contains(b)
}

// The most chroma this hue can hold at this lightness. Beyond it sRGB has
// nothing to offer and the conversion would clip, which shifts hue.
private func maximumChroma(lightness: Double, hue: Double) -> Double {
    var low = 0.0
    var high = 0.4
    guard inGamut(OKLCh(lightness: lightness, chroma: low, hue: hue)) else {
        return 0
    }
    for _ in 0..<20 {
        let middle = (low + high) / 2
        if inGamut(OKLCh(lightness: lightness, chroma: middle, hue: hue)) {
            low = middle
        } else {
            high = middle
        }
    }
    return low
}

extension RGBColor {
    init(_ color: OKLCh) {
        let fitted = OKLCh(
            lightness: min(max(color.lightness, 0), 1),
            chroma: min(
                color.chroma,
                maximumChroma(lightness: min(max(color.lightness, 0), 1), hue: color.hue)
            ),
            hue: color.hue
        )
        let (r, g, b) = linearRGB(from: fitted)
        self.init(red: encodeChannel(r), green: encodeChannel(g), blue: encodeChannel(b))
    }
}

struct BarLegibilityPalette {
    let text: String
    let textMuted: String
    let background: String
    let roles: [String: String]
}

struct TerminalLegibilityPalette {
    let background: String
    let foreground: String
    let ansi: [String]
    let roles: [String: String]
}

struct TerminalLegibilityResult: Codable {
    let backdropOpacity: Double
    let polarity: String
    let foreground: String
    let ansi: [String]
    let roles: [String: String]
    let foregroundContrastP10: Double
    let foregroundContrastMedian: Double
    let paletteContrastP10: Double
    let adjustedCount: Int
    let maximumHueDriftDegrees: Double
    let sampleCount: Int
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

// Both solvers work against `backdrops`: the colors text is actually drawn on,
// after whatever the surface puts between the glyph and the wallpaper. The bar
// composites its scrim; the terminal composites its cell background at the
// configured opacity. Neither role adjustment cares which produced them.
private func contrastP10(foreground: RGBColor, backdrops: [RGBColor]) -> Double {
    quantile(backdrops.map { contrast(foreground, $0) }, 0.10)
}

// Candidates are measured after the round-trip through 8-bit hex, because that
// is the value the adapters emit. Solving in full precision leaves the emitted
// color a fraction under the floor it was solved for.
private func adjustedRole(
    original: RGBColor,
    toward foreground: RGBColor,
    backdrops: [RGBColor],
    minimum: Double
) -> RGBColor {
    func quantized(_ color: RGBColor) -> RGBColor { RGBColor(hex: color.hex) }

    if contrastP10(foreground: quantized(original), backdrops: backdrops) >= minimum {
        return quantized(original)
    }

    var low = 0.0
    var high = 1.0
    for _ in 0..<12 {
        let amount = (low + high) / 2
        let candidate = quantized(original.mixed(with: foreground, amount: amount))
        if contrastP10(foreground: candidate, backdrops: backdrops) >= minimum {
            high = amount
        } else {
            low = amount
        }
    }
    // Quantized, not the full-precision mix: this is the value that gets
    // emitted, so it must also be the value every reported contrast measures.
    return quantized(original.mixed(with: foreground, amount: high))
}

// Hue held exactly, lightness ramped toward the polarity extreme, chroma kept
// at whatever the gamut allows once it gets there. Slots that must clear the
// same floor against the same backdrop end up at similar lightness — that part
// is unavoidable — but they stay told apart by hue and chroma instead of
// collapsing into one pale band.
private func atLightness(_ original: RGBColor, _ lightness: Double) -> RGBColor {
    var moved = original.oklch
    moved.lightness = min(max(lightness, 0), 1)
    return RGBColor(hex: RGBColor(moved).hex)
}

// The lightness this role needs to clear the floor, or nil if it already does.
private func requiredLightness(
    original: RGBColor,
    towardLightness targetLightness: Double,
    backdrops: [RGBColor],
    minimum: Double
) -> Double? {
    let authored = original.oklch.lightness
    if contrastP10(
        foreground: RGBColor(hex: original.hex), backdrops: backdrops
    ) >= minimum {
        return nil
    }

    var low = 0.0
    var high = 1.0
    for _ in 0..<16 {
        let amount = (low + high) / 2
        let candidate = atLightness(original, authored + (targetLightness - authored) * amount)
        if contrastP10(foreground: candidate, backdrops: backdrops) >= minimum {
            high = amount
        } else {
            low = amount
        }
    }
    return authored + (targetLightness - authored) * high
}

private func liftedRole(
    original: RGBColor,
    towardLightness targetLightness: Double,
    backdrops: [RGBColor],
    minimum: Double
) -> RGBColor {
    guard let required = requiredLightness(
        original: original,
        towardLightness: targetLightness,
        backdrops: backdrops,
        minimum: minimum
    ) else {
        return RGBColor(hex: original.hex)
    }
    return atLightness(original, required)
}

private func scrimmed(
    _ samples: [RGBColor],
    scrim: RGBColor,
    scrimAlpha: Double
) -> [RGBColor] {
    samples.map { scrim.composited(over: $0, alpha: scrimAlpha) }
}

// `regionHeight` is the strip below the top of the display that the surface can
// occupy, in display points. The bar owns a fixed 40; a terminal window can sit
// anywhere, so it passes nil for the whole visible crop and samples it denser.
private func wallpaperSamples(
    image: NSImage,
    displaySizes: [CGSize],
    regionHeight: CGFloat?,
    rows: Int = 8,
    columns: Int = 96
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
        let sampledHeight = regionHeight.map { min($0 / scale, visibleHeight) }
            ?? visibleHeight

        for row in 0..<rows {
            let y = cropY + sampledHeight * (Double(row) + 0.5) / Double(rows)
            for column in 0..<columns {
                let x = cropX + visibleWidth * (Double(column) + 0.5) / Double(columns)
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
        regionHeight: barHeight
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
    let lightScore = contrastP10(foreground: light, backdrops: safeSamples)
    let darkScore = contrastP10(foreground: dark, backdrops: safeSamples)
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
                backdrops: scrimmed(safeSamples, scrim: scrim, scrimAlpha: alpha)
            ) >= 4.5 {
                high = alpha
            } else {
                low = alpha
            }
        }
        scrimAlpha = high
    }

    let backdrops = scrimmed(safeSamples, scrim: scrim, scrimAlpha: scrimAlpha)
    let adjusted = palette.roles.mapValues {
        adjustedRole(
            original: RGBColor(hex: $0),
            toward: foreground,
            backdrops: backdrops,
            minimum: 3.0
        ).hex
    }
    let muted = adjustedRole(
        original: RGBColor(hex: palette.textMuted),
        toward: foreground,
        backdrops: backdrops,
        minimum: 3.0
    )
    let accent = RGBColor(hex: adjusted["blue"] ?? palette.roles["blue"] ?? palette.text)
    let textContrasts = backdrops.map { contrast(foreground, $0) }

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

// The terminal draws its cell background over the wallpaper at
// `backdropOpacity`, so the color behind a glyph is neither the authored
// background nor the wallpaper. Ghostty's own `minimum-contrast` cannot reach
// this: the compositor performs the blend, so the wallpaper pixel behind the
// window is not readable from inside the process. Livery holds both, so the
// solve belongs here.
//
// A terminal window can sit anywhere, so every visible wallpaper pixel is a
// candidate backdrop — unlike the bar, which owns a fixed strip.
func analyzeTerminalLegibility(
    image: NSImage,
    displaySizes: [CGSize],
    palette: TerminalLegibilityPalette,
    backdropOpacity: Double,
    paletteMinimumContrast: Double = 3.0,
    foregroundMinimumContrast: Double = 4.5
) -> TerminalLegibilityResult {
    let samples = wallpaperSamples(
        image: image,
        displaySizes: displaySizes.isEmpty
            ? [CGSize(width: 1728, height: 1117)]
            : displaySizes,
        regionHeight: nil,
        rows: 48,
        columns: 64
    )
    let cell = RGBColor(hex: palette.background)
    let safeSamples = samples.isEmpty ? [cell] : samples
    let backdrops = safeSamples.map {
        cell.composited(over: $0, alpha: backdropOpacity)
    }

    // Same polarity rule as the bar: whichever of the authored pair reads
    // better on the backdrop wins. For a dark theme over most wallpapers the
    // authored foreground wins outright; the rule only bites when the cell
    // background is pulled past the foreground by a contrary wallpaper.
    let authoredForeground = RGBColor(hex: palette.foreground)
    let foregroundScore = contrastP10(foreground: authoredForeground, backdrops: backdrops)
    let backgroundScore = contrastP10(foreground: cell, backdrops: backdrops)
    let polarity = foregroundScore >= backgroundScore
        ? (authoredForeground.luminance >= cell.luminance ? "light" : "dark")
        : (cell.luminance >= authoredForeground.luminance ? "light" : "dark")
    let targetLightness = polarity == "light" ? 1.0 : 0.0

    // A floor of 1 is Ghostty's native setting and means the theme wants no
    // contrast policy at all — the checked-in baseline keeps its palette
    // exactly. Honour that as a total opt-out rather than adjusting the
    // foreground anyway, and still report what the colors measure.
    let enforcing = paletteMinimumContrast > 1

    // There is no scrim to fall back on inside a terminal cell, so the
    // foreground itself is lifted toward the polarity extreme.
    let preferred = foregroundScore >= backgroundScore ? authoredForeground : cell
    let foreground = enforcing
        ? liftedRole(
            original: preferred,
            towardLightness: targetLightness,
            backdrops: backdrops,
            minimum: foregroundMinimumContrast
        )
        : authoredForeground

    // Slot 0 is base00 and is the background color: terminal applications fill
    // with it as often as they draw with it, and lifting it to foreground
    // lightness would wreck every one of those fills. It stays as authored.
    // Each slot goes to its own minimum, which stacks the palette near one
    // lightness and costs the authored lightness separation. That is not a
    // choice the mapping can undo: lifting every slot by a common amount to
    // keep the spacing was measured here and is worse, because the band
    // between the floor and white is narrower than the spread the palette
    // wants, so the bright slots saturate to white and lose all chroma. The
    // band is what has to widen — see `backdropOpacity`.
    var adjustedCount = 0
    var maximumHueDrift = 0.0
    func solved(_ hex: String) -> String {
        let original = RGBColor(hex: hex)
        guard enforcing else { return original.hex }
        let result = liftedRole(
            original: original,
            towardLightness: targetLightness,
            backdrops: backdrops,
            minimum: paletteMinimumContrast
        )
        if result.hex != original.hex {
            adjustedCount += 1
            // Achromatic colors have no meaningful hue to preserve, and the
            // reading would be noise.
            let before = original.oklch
            let after = result.oklch
            if before.chroma > 0.01 && after.chroma > 0.01 {
                var drift = abs(after.hue - before.hue) * 180 / .pi
                if drift > 180 { drift = 360 - drift }
                maximumHueDrift = max(maximumHueDrift, drift)
            }
        }
        return result.hex
    }
    let ansi = palette.ansi.enumerated().map { index, hex in
        index > 0 ? solved(hex) : RGBColor(hex: hex).hex
    }
    let roles = palette.roles.mapValues { solved($0) }

    let foregroundContrasts = backdrops.map { contrast(foreground, $0) }
    let paletteFloor = ansi.dropFirst().map {
        contrastP10(foreground: RGBColor(hex: $0), backdrops: backdrops)
    }.min() ?? foregroundMinimumContrast

    return TerminalLegibilityResult(
        backdropOpacity: backdropOpacity,
        polarity: polarity,
        foreground: foreground.hex,
        ansi: ansi,
        roles: roles,
        foregroundContrastP10: (quantile(foregroundContrasts, 0.10) * 100).rounded() / 100,
        foregroundContrastMedian: (quantile(foregroundContrasts, 0.50) * 100).rounded() / 100,
        paletteContrastP10: (paletteFloor * 100).rounded() / 100,
        adjustedCount: adjustedCount,
        maximumHueDriftDegrees: (maximumHueDrift * 100).rounded() / 100,
        sampleCount: backdrops.count
    )
}
