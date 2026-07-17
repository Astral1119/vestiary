import AppKit
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct PaletteEntry: Decodable {
    let role: String?
    let color: String
    let weight: Double
}

private struct GradeRequest: Decodable {
    let source: String
    let output: String
    let palette: [PaletteEntry]
    let strength: Double
    let preserveLightness: Bool
    let cubeDimension: Int
}

private struct TransformRequest: Decodable {
    let source: String
    let output: String
    let palette: [PaletteEntry]
    let steps: [TransformStep]
}

private struct TransformStep: Decodable {
    let operation: String
    let parameters: TransformParameters
}

private struct MappingStop: Decodable {
    let position: Double
    let color: String
}

private struct TransformParameters: Decodable {
    let strength: Double?
    let preserveLightness: Bool?
    let cubeDimension: Int?
    let contrast: Double?
    let saturation: Double?
    let exposure: Double?
    let shadowAmount: Double?
    let highlightAmount: Double?
    let chromaRetention: Double?
    let lightnessStrength: Double?
    let stops: [MappingStop]?
    let colors: Int?
    let algorithm: String?
    let amount: Double?
    let scale: Double?
    let width: Double?
    let angle: Double?
    let sharpness: Double?
}

private struct RGB {
    var r: Double
    var g: Double
    var b: Double
}

private struct OKLab {
    var l: Double
    var a: Double
    var b: Double
}

private struct WeightedColor {
    let rgb: RGB
    let lab: OKLab
    let weight: Double
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("livery-image: \(message)\n".utf8))
    exit(1)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sha256(fileAt url: URL) throws -> String {
    sha256(try Data(contentsOf: url, options: .mappedIfSafe))
}

private func mediaType(for url: URL, source: CGImageSource) -> String {
    if let type = CGImageSourceGetType(source) as String?,
       let utType = UTType(type),
       let mime = utType.preferredMIMEType {
        return mime
    }
    return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        ?? "application/octet-stream"
}

private func assetDescriptor(at url: URL) throws -> [String: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw NSError(domain: "LiveryImage", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "could not decode \(url.path)",
        ])
    }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
        throw NSError(domain: "LiveryImage", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "could not inspect \(url.path)",
        ])
    }

    let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    let profileName = properties[kCGImagePropertyProfileName] as? String
    let byteCount = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
        .int64Value ?? 0

    var color: [String: Any] = [
        "model": "rgb",
        "outputSpace": "srgb",
    ]
    if let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
       let space = image.colorSpace {
        color["name"] = space.name as String? ?? "unknown"
        if let profile = space.copyICCData() as Data? {
            color["embeddedProfileDigest"] = "sha256:\(sha256(profile))"
            color["embeddedProfileBytes"] = profile.count
        }
    }
    if let profileName {
        color["profileName"] = profileName
    }

    return [
        "digest": "sha256:\(try sha256(fileAt: url))",
        "mediaType": mediaType(for: url, source: source),
        "size": byteCount,
        "dimensions": [width, height],
        "orientation": orientation,
        "color": color,
    ]
}

private func decodeHex(_ value: String) -> RGB {
    let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard trimmed.count == 6, let raw = UInt64(trimmed, radix: 16) else {
        fail("invalid palette color \(value)")
    }
    return RGB(
        r: Double((raw >> 16) & 0xff) / 255,
        g: Double((raw >> 8) & 0xff) / 255,
        b: Double(raw & 0xff) / 255
    )
}

private func linearize(_ value: Double) -> Double {
    value <= 0.04045
        ? value / 12.92
        : pow((value + 0.055) / 1.055, 2.4)
}

private func encodeSRGB(_ value: Double) -> Double {
    let clamped = min(1, max(0, value))
    return clamped <= 0.0031308
        ? clamped * 12.92
        : 1.055 * pow(clamped, 1 / 2.4) - 0.055
}

private func rgbToOKLab(_ rgb: RGB) -> OKLab {
    let r = linearize(rgb.r)
    let g = linearize(rgb.g)
    let b = linearize(rgb.b)
    let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    let lRoot = cbrt(l)
    let mRoot = cbrt(m)
    let sRoot = cbrt(s)
    return OKLab(
        l: 0.2104542553 * lRoot + 0.7936177850 * mRoot - 0.0040720468 * sRoot,
        a: 1.9779984951 * lRoot - 2.4285922050 * mRoot + 0.4505937099 * sRoot,
        b: 0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.8086757660 * sRoot
    )
}

private func oklabToRGB(_ lab: OKLab) -> RGB {
    let lRoot = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b
    let mRoot = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b
    let sRoot = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b
    let l = lRoot * lRoot * lRoot
    let m = mRoot * mRoot * mRoot
    let s = sRoot * sRoot * sRoot
    return RGB(
        r: encodeSRGB(+4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        g: encodeSRGB(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        b: encodeSRGB(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    )
}

private func mix(_ first: Double, _ second: Double, amount: Double) -> Double {
    first + (second - first) * amount
}

private func mapColor(
    _ input: RGB,
    palette: [WeightedColor],
    strength: Double,
    preserveLightness: Bool,
    chromaRetention: Double
) -> RGB {
    let source = rgbToOKLab(input)
    var weightedA = 0.0
    var weightedB = 0.0
    var weightedL = 0.0
    var total = 0.0

    for color in palette {
        let dl = (source.l - color.lab.l) * 0.70
        let da = source.a - color.lab.a
        let db = source.b - color.lab.b
        let distance = dl * dl + da * da + db * db
        let influence = color.weight * exp(-distance * 42)
        weightedL += color.lab.l * influence
        weightedA += color.lab.a * influence
        weightedB += color.lab.b * influence
        total += influence
    }

    guard total > 0 else { return input }
    let paletteA = weightedA / total
    let paletteB = weightedB / total
    let sourceChroma = hypot(source.a, source.b)
    let paletteChroma = hypot(paletteA, paletteB)
    let retainedChroma = sourceChroma * min(1.25, max(0, chromaRetention))
    let targetChroma = max(paletteChroma, retainedChroma)
    let chromaScale = paletteChroma > 0.000_001 ? targetChroma / paletteChroma : 1
    let target = OKLab(
        l: preserveLightness ? source.l : weightedL / total,
        a: paletteA * chromaScale,
        b: paletteB * chromaScale
    )
    let mapped = OKLab(
        l: mix(source.l, target.l, amount: strength),
        a: mix(source.a, target.a, amount: strength),
        b: mix(source.b, target.b, amount: strength)
    )
    return oklabToRGB(mapped)
}

private func cubeData(
    dimension: Int,
    palette: [WeightedColor],
    strength: Double,
    preserveLightness: Bool,
    chromaRetention: Double = 0
) -> Data {
    var values = [Float]()
    values.reserveCapacity(dimension * dimension * dimension * 4)
    let scale = Double(dimension - 1)

    for blue in 0..<dimension {
        for green in 0..<dimension {
            for red in 0..<dimension {
                let mapped = mapColor(
                    RGB(
                        r: Double(red) / scale,
                        g: Double(green) / scale,
                        b: Double(blue) / scale
                    ),
                    palette: palette,
                    strength: strength,
                    preserveLightness: preserveLightness,
                    chromaRetention: chromaRetention
                )
                values.append(Float(mapped.r))
                values.append(Float(mapped.g))
                values.append(Float(mapped.b))
                values.append(1)
            }
        }
    }
    return values.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func weightedColors(_ entries: [PaletteEntry]) -> [WeightedColor] {
    entries.map {
        let rgb = decodeHex($0.color)
        return WeightedColor(rgb: rgb, lab: rgbToOKLab(rgb), weight: max(0.001, $0.weight))
    }
}

private func colorCube(
    image: CIImage,
    dimension: Int,
    data: Data
) -> CIImage {
    guard (8...64).contains(dimension) else {
        fail("cubeDimension must be between 8 and 64")
    }
    guard let filter = CIFilter(name: "CIColorCube") else {
        fail("CIColorCube is unavailable")
    }
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(dimension, forKey: "inputCubeDimension")
    filter.setValue(data, forKey: "inputCubeData")
    guard let output = filter.outputImage else {
        fail("CIColorCube produced no output")
    }
    return output
}

private func filtered(
    _ name: String,
    image: CIImage,
    values: [String: Any]
) -> CIImage {
    guard let filter = CIFilter(name: name) else {
        fail("\(name) is unavailable")
    }
    filter.setValue(image, forKey: kCIInputImageKey)
    for (key, value) in values {
        filter.setValue(value, forKey: key)
    }
    guard let output = filter.outputImage else {
        fail("\(name) produced no output")
    }
    return output
}

private func grade(
    _ image: CIImage,
    palette: [WeightedColor],
    parameters: TransformParameters
) -> CIImage {
    let dimension = parameters.cubeDimension ?? 32
    var output = filtered(
        "CIHighlightShadowAdjust",
        image: image,
        values: [
            "inputShadowAmount": parameters.shadowAmount ?? 0,
            "inputHighlightAmount": parameters.highlightAmount ?? 1,
            "inputRadius": 0,
        ]
    )
    output = filtered(
        "CIExposureAdjust",
        image: output,
        values: ["inputEV": parameters.exposure ?? 0]
    )
    output = filtered(
        "CIColorControls",
        image: output,
        values: [
            "inputSaturation": parameters.saturation ?? 1,
            "inputContrast": parameters.contrast ?? 1,
            "inputBrightness": 0,
        ]
    )
    return colorCube(
        image: output,
        dimension: dimension,
        data: cubeData(
            dimension: dimension,
            palette: palette,
            strength: min(1, max(0, parameters.strength ?? 0)),
            preserveLightness: parameters.preserveLightness ?? true,
            chromaRetention: parameters.chromaRetention ?? 0.85
        )
    )
}

private func mappingColor(
    lightness: Double,
    stops: [(position: Double, lab: OKLab)]
) -> OKLab {
    guard let first = stops.first, let last = stops.last else {
        fail("mapping requires at least two color stops")
    }
    if lightness <= first.position { return first.lab }
    if lightness >= last.position { return last.lab }

    for index in 0..<(stops.count - 1) {
        let lower = stops[index]
        let upper = stops[index + 1]
        guard lightness >= lower.position, lightness <= upper.position else {
            continue
        }
        let span = max(0.000_001, upper.position - lower.position)
        let amount = (lightness - lower.position) / span
        return OKLab(
            l: mix(lower.lab.l, upper.lab.l, amount: amount),
            a: mix(lower.lab.a, upper.lab.a, amount: amount),
            b: mix(lower.lab.b, upper.lab.b, amount: amount)
        )
    }
    return last.lab
}

private func mappingCubeData(
    dimension: Int,
    stops: [MappingStop],
    strength: Double,
    lightnessStrength: Double
) -> Data {
    let resolvedStops = stops
        .map {
            (
                position: min(1, max(0, $0.position)),
                lab: rgbToOKLab(decodeHex($0.color))
            )
        }
        .sorted { $0.position < $1.position }
    guard resolvedStops.count >= 2 else {
        fail("mapping requires at least two color stops")
    }

    var values = [Float]()
    values.reserveCapacity(dimension * dimension * dimension * 4)
    let scale = Double(dimension - 1)
    let amount = min(1, max(0, strength))
    let lightnessAmount = min(1, max(0, lightnessStrength))
    for blue in 0..<dimension {
        for green in 0..<dimension {
            for red in 0..<dimension {
                let source = rgbToOKLab(
                    RGB(
                        r: Double(red) / scale,
                        g: Double(green) / scale,
                        b: Double(blue) / scale
                    )
                )
                let target = mappingColor(lightness: source.l, stops: resolvedStops)
                let mapped = oklabToRGB(
                    OKLab(
                        l: mix(source.l, target.l, amount: lightnessAmount),
                        a: mix(source.a, target.a, amount: amount),
                        b: mix(source.b, target.b, amount: amount)
                    )
                )
                values.append(Float(mapped.r))
                values.append(Float(mapped.g))
                values.append(Float(mapped.b))
                values.append(1)
            }
        }
    }
    return values.withUnsafeBufferPointer { Data(buffer: $0) }
}

private func uniqueColors(_ colors: [RGB]) -> [RGB] {
    var seen = Set<String>()
    return colors.filter {
        let key = String(format: "%.6f:%.6f:%.6f", $0.r, $0.g, $0.b)
        return seen.insert(key).inserted
    }
}

private func imagePaletteColor(
    _ color: RGB,
    lightnessOffset: Double = 0,
    chromaScale: Double = 1,
    minimumChroma: Double = 0
) -> RGB {
    var lab = rgbToOKLab(color)
    lab.l = min(0.96, max(0.04, lab.l + lightnessOffset))
    let chroma = hypot(lab.a, lab.b)
    if chroma > 0.000_001 {
        let targetChroma = max(chroma * chromaScale, minimumChroma)
        let scale = targetChroma / chroma
        lab.a *= scale
        lab.b *= scale
    }
    return oklabToRGB(lab)
}

private func quantizationPalette(
    entries: [PaletteEntry],
    maximum: Int
) -> [RGB] {
    let byRole = Dictionary(
        entries.compactMap { entry in entry.role.map { ($0, decodeHex(entry.color)) } },
        uniquingKeysWith: { first, _ in first }
    )
    let fallback = entries.map { decodeHex($0.color) }
    let primary = byRole["primary"] ?? fallback.first
    let secondary = byRole["secondary"] ?? fallback.dropFirst().first ?? primary
    let tertiary = byRole["tertiary"] ?? fallback.dropFirst(2).first ?? secondary
    let accents = [primary, secondary, tertiary].compactMap { $0 }
    let shadow = byRole["shadow"] ?? fallback.first
    let highlight = byRole["highlight"] ?? fallback.last
    var candidates = [RGB]()

    if let shadow {
        candidates.append(imagePaletteColor(shadow, lightnessOffset: -0.04))
    }
    if maximum <= 4 {
        candidates += accents.prefix(2).map {
            imagePaletteColor($0, chromaScale: 1.30, minimumChroma: 0.10)
        }
    } else {
        candidates += accents.prefix(2).map {
            imagePaletteColor(
                $0,
                lightnessOffset: -0.16,
                chromaScale: 1.15,
                minimumChroma: 0.075
            )
        }
        candidates += accents.map {
            imagePaletteColor($0, chromaScale: 1.35, minimumChroma: 0.10)
        }
        candidates += accents.prefix(1).map {
            imagePaletteColor(
                $0,
                lightnessOffset: 0.16,
                chromaScale: 1.18,
                minimumChroma: 0.075
            )
        }
        if maximum >= 16 {
            candidates += accents.dropFirst().map {
                imagePaletteColor(
                    $0,
                    lightnessOffset: 0.16,
                    chromaScale: 1.18,
                    minimumChroma: 0.075
                )
            }
            candidates += [
                byRole["surface"],
                byRole["elevated"],
                byRole["muted"],
            ].compactMap { $0 }
        }
    }
    if let highlight {
        candidates.append(imagePaletteColor(highlight, lightnessOffset: 0.03))
    }
    var result = uniqueColors(candidates + fallback)
    guard !result.isEmpty else { return [] }

    let labs = result.map(rgbToOKLab)
    let darkestIndex = labs.indices.min(by: { labs[$0].l < labs[$1].l }) ?? 0
    let lightestIndex = labs.indices.max(by: { labs[$0].l < labs[$1].l }) ?? 0
    let darkest = result[darkestIndex]
    let lightest = result[lightestIndex]
    let base = result
    var expansion = 0
    while result.count < maximum {
        let color = base[expansion % base.count]
        let cycle = expansion / base.count
        let target = cycle.isMultiple(of: 2) ? darkest : lightest
        let amount = cycle < 2 ? 0.28 : 0.52
        result.append(RGB(
            r: mix(color.r, target.r, amount: amount),
            g: mix(color.g, target.g, amount: amount),
            b: mix(color.b, target.b, amount: amount)
        ))
        result = uniqueColors(result)
        expansion += 1
        if expansion > maximum * 8 { break }
    }
    return Array(result.prefix(maximum))
}

private func nearestPaletteColor(_ input: RGB, palette: [RGB]) -> RGB {
    let source = rgbToOKLab(input)
    return palette.min {
        let first = rgbToOKLab($0)
        let second = rgbToOKLab($1)
        let firstDistance = pow(source.l - first.l, 2)
            + pow(source.a - first.a, 2)
            + pow(source.b - first.b, 2)
        let secondDistance = pow(source.l - second.l, 2)
            + pow(source.a - second.a, 2)
            + pow(source.b - second.b, 2)
        return firstDistance < secondDistance
    } ?? input
}

private func quantizationCubeData(dimension: Int, palette: [RGB]) -> Data {
    var values = [Float]()
    values.reserveCapacity(dimension * dimension * dimension * 4)
    let scale = Double(dimension - 1)
    for blue in 0..<dimension {
        for green in 0..<dimension {
            for red in 0..<dimension {
                let mapped = nearestPaletteColor(
                    RGB(
                        r: Double(red) / scale,
                        g: Double(green) / scale,
                        b: Double(blue) / scale
                    ),
                    palette: palette
                )
                values.append(Float(mapped.r))
                values.append(Float(mapped.g))
                values.append(Float(mapped.b))
                values.append(1)
            }
        }
    }
    return values.withUnsafeBufferPointer { Data(buffer: $0) }
}

private let bayer8: [UInt8] = [
     0, 48, 12, 60,  3, 51, 15, 63,
    32, 16, 44, 28, 35, 19, 47, 31,
     8, 56,  4, 52, 11, 59,  7, 55,
    40, 24, 36, 20, 43, 27, 39, 23,
     2, 50, 14, 62,  1, 49, 13, 61,
    34, 18, 46, 30, 33, 17, 45, 29,
    10, 58,  6, 54,  9, 57,  5, 53,
    42, 26, 38, 22, 41, 25, 37, 21,
]

private func hashedNoise(x: Int, y: Int, seed: UInt64) -> UInt8 {
    var value = UInt64(bitPattern: Int64(x &* 0x1f123bb5 ^ y &* 0x5f356495))
    value ^= seed &+ 0x9e3779b97f4a7c15
    value ^= value >> 30
    value &*= 0xbf58476d1ce4e5b9
    value ^= value >> 27
    value &*= 0x94d049bb133111eb
    value ^= value >> 31
    return UInt8(truncatingIfNeeded: value >> 24)
}

private func blueNoiseRanks(dimension: Int) -> [UInt8] {
    let seed: UInt64 = 0x6c6976657279
    let count = dimension * dimension
    let samples = (0..<count).map { index -> (index: Int, score: Double) in
        let x = index % dimension
        let y = index / dimension
        let center = Double(hashedNoise(x: x, y: y, seed: seed)) / 255
        var neighborhood = 0.0
        for offset in [
            (-1, -1), (0, -1), (1, -1),
            (-1,  0),          (1,  0),
            (-1,  1), (0,  1), (1,  1),
        ] {
            let neighborX = (x + offset.0 + dimension) % dimension
            let neighborY = (y + offset.1 + dimension) % dimension
            neighborhood += Double(
                hashedNoise(x: neighborX, y: neighborY, seed: seed)
            ) / 255
        }
        return (index, center - neighborhood / 8)
    }
    var ranks = [UInt8](repeating: 0, count: count)
    for (rank, sample) in samples.sorted(by: { $0.score < $1.score }).enumerated() {
        ranks[sample.index] = UInt8(Double(rank) / Double(count - 1) * 255)
    }
    return ranks
}

private func noiseTile(kind: String) -> CIImage {
    let dimension = kind == "bayer" ? 8 : 64
    let blueNoise = kind == "bayer" ? [] : blueNoiseRanks(dimension: dimension)
    var bytes = [UInt8](repeating: 0, count: dimension * dimension * 4)
    for y in 0..<dimension {
        for x in 0..<dimension {
            let value: UInt8
            if kind == "bayer" {
                value = UInt8((Double(bayer8[y * dimension + x]) + 0.5) / 64 * 255)
            } else {
                value = blueNoise[y * dimension + x]
            }
            let offset = (y * dimension + x) * 4
            bytes[offset] = value
            bytes[offset + 1] = value
            bytes[offset + 2] = value
            bytes[offset + 3] = 255
        }
    }
    let data = Data(bytes)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    return data.withUnsafeBytes { raw in
        CIImage(
            bitmapData: Data(raw),
            bytesPerRow: dimension * 4,
            size: CGSize(width: dimension, height: dimension),
            format: .RGBA8,
            colorSpace: colorSpace
        )
    }
}

private func addNoise(
    to image: CIImage,
    kind: String,
    amount: Double,
    scale: Double
) -> CIImage {
    let scaled = noiseTile(kind: kind).transformed(
        by: CGAffineTransform(
            scaleX: max(0.25, scale),
            y: max(0.25, scale)
        )
    )
    let tiled = filtered("CIAffineTile", image: scaled, values: [:])
        .cropped(to: image.extent)
    let amplitude = min(0.5, max(0, amount))
    let adjusted = filtered(
        "CIColorMatrix",
        image: tiled,
        values: [
            "inputRVector": CIVector(x: amplitude, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: amplitude, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: amplitude, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(
                x: -amplitude / 2,
                y: -amplitude / 2,
                z: -amplitude / 2,
                w: 0
            ),
        ]
    )
    guard let compositor = CIFilter(name: "CIAdditionCompositing") else {
        fail("CIAdditionCompositing is unavailable")
    }
    compositor.setValue(adjusted, forKey: kCIInputImageKey)
    compositor.setValue(image, forKey: kCIInputBackgroundImageKey)
    guard let output = compositor.outputImage else {
        fail("CIAdditionCompositing produced no output")
    }
    return output.cropped(to: image.extent)
}

private func execute(
    request: TransformRequest,
    source: CIImage
) -> CIImage {
    let colors = weightedColors(request.palette)
    var output = source
    for step in request.steps {
        switch step.operation {
        case "wallpaper.grade":
            output = grade(output, palette: colors, parameters: step.parameters)
        case "wallpaper.map":
            let dimension = step.parameters.cubeDimension ?? 32
            guard let stops = step.parameters.stops else {
                fail("wallpaper.map requires color stops")
            }
            output = colorCube(
                image: output,
                dimension: dimension,
                data: mappingCubeData(
                    dimension: dimension,
                    stops: stops,
                    strength: step.parameters.strength ?? 0.85,
                    lightnessStrength: step.parameters.lightnessStrength ?? 0.4
                )
            )
        case "wallpaper.dither":
            let algorithm = step.parameters.algorithm ?? "bayer"
            output = addNoise(
                to: output,
                kind: algorithm == "blue-noise" ? "blue-noise" : "bayer",
                amount: step.parameters.amount ?? 0.06,
                scale: step.parameters.scale ?? 1
            )
        case "wallpaper.quantize":
            let maximum = min(32, max(2, step.parameters.colors ?? 8))
            let palette = quantizationPalette(entries: request.palette, maximum: maximum)
            guard palette.count >= 2 else {
                fail("quantization requires at least two palette colors")
            }
            let dimension = step.parameters.cubeDimension ?? 32
            output = colorCube(
                image: output,
                dimension: dimension,
                data: quantizationCubeData(dimension: dimension, palette: palette)
            )
        case "wallpaper.grain":
            output = addNoise(
                to: output,
                kind: "blue-noise",
                amount: step.parameters.amount ?? 0.035,
                scale: step.parameters.scale ?? 1
            )
        case "wallpaper.halftone":
            output = filtered(
                "CICMYKHalftone",
                image: output,
                values: [
                    "inputWidth": step.parameters.width ?? 6,
                    "inputAngle": step.parameters.angle ?? 0,
                    "inputSharpness": step.parameters.sharpness ?? 0.7,
                    "inputGCR": 1,
                    "inputUCR": 0.5,
                    "inputCenter": CIVector(
                        x: output.extent.midX,
                        y: output.extent.midY
                    ),
                ]
            ).cropped(to: source.extent)
        default:
            fail("unknown transform operation \(step.operation)")
        }
    }
    return output.cropped(to: source.extent)
}

private func writeImage(_ image: CIImage, to outputURL: URL) throws {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let destination = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CIContext(options: [
        .workingColorSpace: working,
        .outputColorSpace: destination,
        .workingFormat: CIFormat.RGBAh,
        .highQualityDownsample: true,
    ])
    try context.writePNGRepresentation(
        of: image,
        to: outputURL,
        format: .RGBA8,
        colorSpace: destination,
        options: [:]
    )
}

private func sourceImage(at url: URL) -> CIImage {
    let sourceOptions: [CIImageOption: Any] = [
        .applyOrientationProperty: true,
    ]
    guard let source = CIImage(contentsOf: url, options: sourceOptions) else {
        fail("could not decode \(url.path)")
    }
    return source
}

private func renderGrade(_ request: GradeRequest) throws {
    let sourceURL = URL(fileURLWithPath: request.source)
    let outputURL = URL(fileURLWithPath: request.output)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
        fail("missing source image \(sourceURL.path)")
    }
    let parameters = TransformParameters(
        strength: request.strength,
        preserveLightness: request.preserveLightness,
        cubeDimension: request.cubeDimension,
        contrast: 1,
        saturation: 1,
        exposure: 0,
        shadowAmount: 0,
        highlightAmount: 1,
        chromaRetention: 0,
        lightnessStrength: nil,
        stops: nil,
        colors: nil,
        algorithm: nil,
        amount: nil,
        scale: nil,
        width: nil,
        angle: nil,
        sharpness: nil
    )
    let output = grade(
        sourceImage(at: sourceURL),
        palette: weightedColors(request.palette),
        parameters: parameters
    )
    try writeImage(output, to: outputURL)
}

private func renderTransform(_ request: TransformRequest) throws {
    let sourceURL = URL(fileURLWithPath: request.source)
    let outputURL = URL(fileURLWithPath: request.output)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
        fail("missing source image \(sourceURL.path)")
    }
    guard request.palette.count >= 3 else {
        fail("transform palette must contain at least three colors")
    }
    guard !request.steps.isEmpty else {
        fail("transform request must contain at least one step")
    }
    let output = execute(request: request, source: sourceImage(at: sourceURL))
    try writeImage(output, to: outputURL)
}

private func writeJSON(_ object: Any) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

@main
private enum LiveryImagePipeline {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            fail("usage: livery-image <inspect IMAGE | grade REQUEST.json | transform REQUEST.json>")
        }

        switch command {
        case "inspect":
            guard arguments.count == 2 else {
                fail("usage: livery-image inspect IMAGE")
            }
            try writeJSON(assetDescriptor(at: URL(fileURLWithPath: arguments[1])))
        case "grade":
            guard arguments.count == 2 else {
                fail("usage: livery-image grade REQUEST.json")
            }
            let requestURL = URL(fileURLWithPath: arguments[1])
            let request = try JSONDecoder().decode(
                GradeRequest.self,
                from: Data(contentsOf: requestURL)
            )
            try renderGrade(request)
            try writeJSON(assetDescriptor(at: URL(fileURLWithPath: request.output)))
        case "transform":
            guard arguments.count == 2 else {
                fail("usage: livery-image transform REQUEST.json")
            }
            let requestURL = URL(fileURLWithPath: arguments[1])
            let request = try JSONDecoder().decode(
                TransformRequest.self,
                from: Data(contentsOf: requestURL)
            )
            try renderTransform(request)
            try writeJSON(assetDescriptor(at: URL(fileURLWithPath: request.output)))
        default:
            fail("unknown command \(command)")
        }
    }
}
