import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib

/// Box-art handling (port of Hakchi2-CE's `NesMenuElementBase.SetImage` and `Shared.ResizeImage`).
///
/// Files written in a game folder, same names as CE:
/// - `CODE.png`: fits 228×204 (upscaled if smaller)
/// - `CODE_small.png`: fits 40×40, optionally centered in a 40×40 square
/// - `CODE_original.png`: the image as given
/// - `CODE_mdmini.png`: 182×216 Mega Drive Mini art (spine at x=1, front at x=31)
enum CoverArt {
    static let coverSize = (width: 228, height: 204)
    static let thumbnailSize = 40
    static let mdMiniSize = (width: 182, height: 216)
    static let mdFrontArea = CGRect(x: 31, y: 1, width: 150, height: 214)
    static let mdSpineArea = CGRect(x: 1, y: 1, width: 28, height: 214)

    struct Options {
        /// 8-bit palette PNGs (CE: "Compress box art")
        var quantize = true
        /// Center the thumbnail in a 40×40 square (CE: "Center thumbnail")
        var centerThumbnail = false
    }

    // MARK: - Paths

    static func coverURL(_ dir: URL, _ code: String) -> URL { dir.appendingPathComponent("\(code).png") }
    static func thumbnailURL(_ dir: URL, _ code: String) -> URL { dir.appendingPathComponent("\(code)_small.png") }
    static func originalURL(_ dir: URL, _ code: String) -> URL { dir.appendingPathComponent("\(code)_original.png") }
    static func mdMiniURL(_ dir: URL, _ code: String) -> URL { dir.appendingPathComponent("\(code)_mdmini.png") }
    static func spineURL(_ dir: URL, _ code: String) -> URL { dir.appendingPathComponent("\(code)_spine.png") }
    static func logoURL(_ dir: URL, _ code: String) -> URL { dir.appendingPathComponent("\(code)_logo.png") }

    // MARK: - Setting covers

    /// Set a game's box art from image data (CE's `SetImage`), writing all derived files
    static func setCover(_ data: Data, gameDirectory dir: URL, code: String, options: Options) throws {
        guard var image = loadImage(data) else { throw CoverArtError.unreadableImage }
        try? FileManager.default.removeItem(at: originalURL(dir, code))

        // A 182×216 image with empty borders and separator is already Mega Drive Mini art
        var mdMiniFormatted = false
        if image.width == mdMiniSize.width, image.height == mdMiniSize.height, isMdMiniLayout(image) {
            mdMiniFormatted = true
            try writePNG(image, to: mdMiniURL(dir, code), quantize: false)
            if let front = image.cropping(to: mdFrontArea) { image = front }
        }

        try writePNG(image, to: originalURL(dir, code), quantize: false)
        if !mdMiniFormatted {
            try setMdMini(front: image, gameDirectory: dir, code: code)
        }
        try writeCoverAndThumbnail(image, gameDirectory: dir, code: code, options: options)
    }

    /// Write only CODE.png and CODE_small.png from an image
    static func writeCoverAndThumbnail(_ image: CGImage, gameDirectory dir: URL, code: String, options: Options) throws {
        if let cover = resize(image, width: coverSize.width, height: coverSize.height, upscale: true, expandHeight: false) {
            try writePNG(cover, to: coverURL(dir, code), quantize: options.quantize)
        }
        if let small = resize(image, width: thumbnailSize, height: thumbnailSize, upscale: false,
                              expandHeight: options.centerThumbnail) {
            try writePNG(small, to: thumbnailURL(dir, code), quantize: options.quantize)
        }
    }

    /// Replace only the thumbnail (CE's `SetThumbnail`)
    static func setThumbnail(_ data: Data, gameDirectory dir: URL, code: String, options: Options) throws {
        guard let image = loadImage(data),
              let small = resize(image, width: thumbnailSize, height: thumbnailSize, upscale: false,
                                 expandHeight: options.centerThumbnail) else { throw CoverArtError.unreadableImage }
        try writePNG(small, to: thumbnailURL(dir, code), quantize: options.quantize)
    }

    /// Reset to the system's blank cover (CE: "Delete box art" / `SetDefaultImage`)
    static func setDefaultCover(gameDirectory dir: URL, code: String, system: String, fileName: String,
                                options: Options) throws {
        guard let url = defaultCoverURL(system: system, fileName: fileName),
              let data = try? Data(contentsOf: url) else { throw CoverArtError.missingDefaultCover }
        try setCover(data, gameDirectory: dir, code: code, options: options)
        // The blank cover is not useful as Mega Drive art or as an "original"
        try? FileManager.default.removeItem(at: originalURL(dir, code))
    }

    // MARK: - Mega Drive Mini art

    /// Draw `front` into the front area of CODE_mdmini.png, keeping the spine (CE's `SetMdMini`)
    static func setMdMini(front: CGImage, gameDirectory dir: URL, code: String, stretch: Bool = false) throws {
        try drawIntoMdMini(front, area: mdFrontArea, aspectRange: stretch ? 100 : 0.04, gameDirectory: dir, code: code)
    }

    /// Draw a spine image into the spine area and keep a copy as CODE_spine.png
    static func setMdMiniSpine(_ spine: CGImage, gameDirectory dir: URL, code: String) throws {
        try writePNG(spine, to: spineURL(dir, code), quantize: false)
        try drawIntoMdMini(spine, area: mdSpineArea, aspectRange: 0.01, gameDirectory: dir, code: code)
    }

    private static func drawIntoMdMini(_ image: CGImage, area: CGRect, aspectRange: Double,
                                       gameDirectory dir: URL, code: String) throws {
        let w = mdMiniSize.width, h = mdMiniSize.height
        guard let ctx = makeContext(width: w, height: h) else { throw CoverArtError.unreadableImage }
        if let existing = (try? Data(contentsOf: mdMiniURL(dir, code))).flatMap(loadImage) {
            ctx.draw(existing, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // CGContext has a bottom-left origin; template areas use top-left
        let flipped = CGRect(x: area.minX, y: CGFloat(h) - area.maxY, width: area.width, height: area.height)
        ctx.clear(flipped)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: fitRect(image: image, into: flipped, aspectRange: aspectRange, enlarge: true))
        guard let out = ctx.makeImage() else { throw CoverArtError.unreadableImage }
        try writePNG(out, to: mdMiniURL(dir, code), quantize: false)
    }

    /// Rectangle for drawing `image` centered in `area`. Stretches when the aspect
    /// ratios differ by no more than `aspectRange` (SpineGen's AspectRange).
    static func fitRect(image: CGImage, into area: CGRect, aspectRange: Double, enlarge: Bool) -> CGRect {
        let imageAspect = Double(image.width) / Double(max(image.height, 1))
        let areaAspect = Double(area.width) / Double(max(area.height, 1))
        if abs(imageAspect - areaAspect) / areaAspect <= aspectRange { return area }
        var scale = min(Double(area.width) / Double(image.width), Double(area.height) / Double(image.height))
        if !enlarge { scale = min(scale, 1) }
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        return CGRect(x: Double(area.midX) - w / 2, y: Double(area.midY) - h / 2, width: w, height: h)
    }

    /// CE's check: rows 0/215 and columns 0/29/30/181 fully transparent
    static func isMdMiniLayout(_ image: CGImage) -> Bool {
        guard let pixels = rgbaPixels(image) else { return false }
        let w = image.width
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * w + x) * 4 + 3] }
        let rowEmpty = { (y: Int) in (0..<w).allSatisfy { alpha($0, y) == 0 } }
        let colEmpty = { (x: Int) in (0..<image.height).allSatisfy { alpha(x, $0) == 0 } }
        return rowEmpty(0) && rowEmpty(215) && colEmpty(0) && colEmpty(181) && colEmpty(29) && colEmpty(30)
    }

    // MARK: - Default covers

    /// CE's per-system blank cover. "(J)"/"(E)" in the file name pick the Japanese/EU variants.
    static func defaultCoverName(system: String, fileName: String) -> String {
        let japanese = fileName.contains("(J)")
        switch system {
        case "Nintendo - Nintendo Entertainment System": return japanese ? "blank_jp" : "blank_nes"
        case "Nintendo - Family Computer Disk System": return "blank_fds"
        case "Nintendo - Super Nintendo Entertainment System",
             "Nintendo - Super Nintendo Entertainment System (MSU-1)":
            return fileName.contains("(E)") || japanese ? "blank_snes-eu-jp" : "blank_snes-us"
        case "Nintendo - Nintendo 64": return "blank_n64"
        case "Nintendo - Game Boy": return "blank_gb"
        case "Nintendo - Game Boy Color": return "blank_gbc"
        case "Nintendo - Game Boy Advance": return "blank_gba"
        case "Sega - Master System - Mark III": return "blank_sms"
        case "Sega - Mega Drive - Genesis": return "blank_genesis"
        case "Sega - 32X": return "blank_32x"
        case "Sega - Game Gear": return "blank_gg"
        case "NEC - PC Engine - TurboGrafx 16", "NEC - PC Engine SuperGrafx": return "blank_pce"
        case "Atari - 2600": return "blank_2600"
        case "DOS", "SquashFS", "Shell Script": return "blank_dos"
        case "Neo Geo": return "blank_neogeo"
        default: return system.lowercased().contains("arcade") || system.contains("MAME") ? "blank_arcade" : "blank_app"
        }
    }

    static func defaultCoverURL(system: String, fileName: String) -> URL? {
        Bundle.appBundle.url(forResource: defaultCoverName(system: system, fileName: fileName),
                             withExtension: "png", subdirectory: "BlankCovers")
    }

    // MARK: - Image helpers

    static func loadImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func loadImage(url: URL) -> CGImage? {
        (try? Data(contentsOf: url)).flatMap(loadImage)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// CE's `ResizeImage` (keepProportions = true, no expandWidth): sizes are rounded
    /// up to even numbers; `expandHeight` centers the image in a full-height canvas.
    static func resize(_ image: CGImage, width targetWidth: Int, height targetHeight: Int,
                       upscale: Bool, expandHeight: Bool) -> CGImage? {
        var x: Int, y: Int
        if !upscale && image.width <= targetWidth && image.height <= targetHeight {
            x = image.width
            y = image.height
        } else if Double(image.width) / Double(image.height) > Double(targetWidth) / Double(targetHeight) {
            x = targetWidth
            y = Int((Double(targetWidth) * Double(image.height) / Double(image.width)).rounded())
            if y % 2 == 1 { y += 1 }
        } else {
            x = Int((Double(targetHeight) * Double(image.width) / Double(image.height)).rounded())
            if x % 2 == 1 { x += 1 }
            y = targetHeight
        }
        let canvasW = x, canvasH = expandHeight ? targetHeight : y
        guard let ctx = makeContext(width: canvasW, height: canvasH) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (canvasW - x) / 2, y: (canvasH - y) / 2, width: x, height: y))
        return ctx.makeImage()
    }

    /// Straight (non-premultiplied) RGBA bytes, top row first
    static func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // Un-premultiply so palette colors match the original
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            guard a > 0, a < 255 else { continue }
            for c in 0..<3 { pixels[i + c] = UInt8(min(255, Int(pixels[i + c]) * 255 / a)) }
        }
        return pixels
    }

    static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func writePNG(_ image: CGImage, to url: URL, quantize: Bool) throws {
        let data = quantize ? (PalettePNG.encode(image) ?? pngData(image)) : pngData(image)
        guard let data else { throw CoverArtError.encodeFailed }
        try data.write(to: url, options: .atomic)
    }
}

/// 8-bit palette PNG writer with median-cut quantization (stand-in for CE's nQuant Wu quantizer).
enum PalettePNG {
    static func encode(_ image: CGImage, maxColors: Int = 256) -> Data? {
        guard let pixels = CoverArt.rgbaPixels(image) else { return nil }
        let (palette, indices) = quantize(pixels, maxColors: maxColors)

        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(be32(UInt32(image.width)))
        ihdr.append(be32(UInt32(image.height)))
        ihdr.append(contentsOf: [8, 3, 0, 0, 0])  // 8-bit depth, indexed color
        out.append(chunk("IHDR", ihdr))
        out.append(chunk("PLTE", Data(palette.flatMap { [$0[0], $0[1], $0[2]] })))
        if palette.contains(where: { $0[3] < 255 }) {
            out.append(chunk("tRNS", Data(palette.map { $0[3] })))
        }
        // Each row: filter byte 0 + one index per pixel
        var raw = Data(capacity: (image.width + 1) * image.height)
        for y in 0..<image.height {
            raw.append(0)
            raw.append(contentsOf: indices[(y * image.width)..<((y + 1) * image.width)])
        }
        guard let compressed = deflate(raw) else { return nil }
        out.append(chunk("IDAT", compressed))
        out.append(chunk("IEND", Data()))
        return out
    }

    /// Median cut on RGBA. Returns the palette and one palette index per pixel.
    static func quantize(_ pixels: [UInt8], maxColors: Int) -> (palette: [[UInt8]], indices: [UInt8]) {
        let count = pixels.count / 4
        var colors = [[UInt8]]()
        colors.reserveCapacity(count)
        for i in 0..<count { colors.append(Array(pixels[(i * 4)..<(i * 4 + 4)])) }

        // Few distinct colors: use them as they are
        let unique = Array(Set(colors.map { UInt32($0[0]) << 24 | UInt32($0[1]) << 16 | UInt32($0[2]) << 8 | UInt32($0[3]) }))
        var palette: [[UInt8]]
        if unique.count <= maxColors {
            palette = unique.map { [UInt8($0 >> 24), UInt8(($0 >> 16) & 0xFF), UInt8(($0 >> 8) & 0xFF), UInt8($0 & 0xFF)] }
        } else {
            var boxes = [colors]
            while boxes.count < maxColors {
                // Split the box with the widest channel range
                guard let (index, channel) = widestBox(boxes), boxes[index].count > 1 else { break }
                let box = boxes[index].sorted { $0[channel] < $1[channel] }
                boxes[index] = Array(box[..<(box.count / 2)])
                boxes.append(Array(box[(box.count / 2)...]))
            }
            palette = boxes.map { box in
                (0..<4).map { c in UInt8(box.reduce(0) { $0 + Int($1[c]) } / box.count) }
            }
        }

        var cache = [UInt32: UInt8]()
        let indices = colors.map { color -> UInt8 in
            let key = UInt32(color[0]) << 24 | UInt32(color[1]) << 16 | UInt32(color[2]) << 8 | UInt32(color[3])
            if let hit = cache[key] { return hit }
            var best = 0, bestDistance = Int.max
            for (i, p) in palette.enumerated() {
                var d = 0
                for c in 0..<4 { let diff = Int(p[c]) - Int(color[c]); d += diff * diff }
                if d < bestDistance { bestDistance = d; best = i }
            }
            cache[key] = UInt8(best)
            return UInt8(best)
        }
        return (palette, indices)
    }

    private static func widestBox(_ boxes: [[[UInt8]]]) -> (Int, Int)? {
        var best: (Int, Int)?
        var bestRange = -1
        for (i, box) in boxes.enumerated() where box.count > 1 {
            for c in 0..<4 {
                var lo = 255, hi = 0
                for color in box { lo = min(lo, Int(color[c])); hi = max(hi, Int(color[c])) }
                if hi - lo > bestRange { bestRange = hi - lo; best = (i, c) }
            }
        }
        return best
    }

    private static func be32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static func chunk(_ type: String, _ data: Data) -> Data {
        var body = Data(type.utf8)
        body.append(data)
        var out = be32(UInt32(data.count))
        out.append(body)
        let crc = body.withUnsafeBytes { ptr in
            zlib.crc32(0, ptr.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt(body.count))
        }
        out.append(be32(UInt32(crc)))
        return out
    }

    /// zlib stream (what PNG's IDAT expects)
    private static func deflate(_ data: Data) -> Data? {
        var destLen = compressBound(uLong(data.count))
        var dest = [UInt8](repeating: 0, count: Int(destLen))
        let status = data.withUnsafeBytes { src in
            compress2(&dest, &destLen, src.baseAddress?.assumingMemoryBound(to: UInt8.self), uLong(data.count), 9)
        }
        return status == Z_OK ? Data(dest[0..<Int(destLen)]) : nil
    }
}

enum CoverArtError: LocalizedError {
    case unreadableImage, encodeFailed, missingDefaultCover

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "The image could not be read."
        case .encodeFailed: return "The image could not be saved."
        case .missingDefaultCover: return "The default cover for this system is missing."
        }
    }
}
