import Foundation
import CoreGraphics

/// Mega Drive spine templates (port of the SpineGen library used by Hakchi2-CE's `SpineForm`).
///
/// A template is a background image plus a logo area: the game's clear logo is
/// trimmed, rotated, fitted into the area and aligned, then drawn on the background.
struct SpineTemplate: Identifiable, Hashable {
    struct Area: Codable, Hashable { var X: Int; var Y: Int; var Width: Int; var Height: Int }

    struct Definition: Codable, Hashable {
        var Name: String
        var Category: String?
        var LogoArea: Area
        var LogoRotation: Int
        /// 0 = left, 1 = middle, 2 = right (after rotation)
        var LogoHorizontalAlignment: Int
        /// 0 = top, 1 = middle, 2 = bottom
        var LogoVerticalAlignment: Int
        var AspectRange: Double
        var Enlarge: Bool
    }

    let definition: Definition
    let imageURL: URL
    var id: String { imageURL.path }
    var name: String { definition.Name }

    /// Templates bundled with the app plus any in `~/…/SwiftHakchi/spine_templates/<name>/`
    static func all() -> [SpineTemplate] {
        var dirs: [URL] = []
        if let bundled = Bundle.appBundle.url(forResource: "SpineTemplates", withExtension: nil) { dirs.append(bundled) }
        dirs.append(AppConfig.configDirectory.appendingPathComponent("spine_templates", isDirectory: true))
        return dirs.flatMap(load(from:)).sorted { $0.name < $1.name }
    }

    static func load(from root: URL) -> [SpineTemplate] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("template.json")),
                  let def = try? JSONDecoder().decode(Definition.self, from: data) else { return nil }
            let image = folder.appendingPathComponent("template.png")
            return fm.fileExists(atPath: image.path) ? SpineTemplate(definition: def, imageURL: image) : nil
        }
    }

    /// Draw `logo` on the template background
    func render(logo: CGImage) -> CGImage? {
        guard let background = CoverArt.loadImage(url: imageURL) else { return nil }
        let w = background.width, h = background.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h))

        let trimmed = Self.trimTransparent(logo) ?? logo
        guard let rotated = Self.rotate(trimmed, degrees: definition.LogoRotation) else { return nil }
        let a = definition.LogoArea
        // Template coordinates are top-left based; CoreGraphics is bottom-left
        let area = CGRect(x: a.X, y: h - a.Y - a.Height, width: a.Width, height: a.Height)
        var rect = CoverArt.fitRect(image: rotated, into: area, aspectRange: definition.AspectRange,
                                    enlarge: definition.Enlarge)
        switch definition.LogoHorizontalAlignment {
        case 0: rect.origin.x = area.minX
        case 2: rect.origin.x = area.maxX - rect.width
        default: break
        }
        switch definition.LogoVerticalAlignment {
        case 0: rect.origin.y = area.maxY - rect.height   // top
        case 2: rect.origin.y = area.minY                 // bottom
        default: break
        }
        ctx.interpolationQuality = .high
        ctx.draw(rotated, in: rect)
        return ctx.makeImage()
    }

    /// Crop fully transparent borders
    static func trimTransparent(_ image: CGImage) -> CGImage? {
        guard let px = CoverArt.rgbaPixels(image) else { return nil }
        let w = image.width, h = image.height
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    /// Rotate clockwise by 0/90/180/270 degrees
    static func rotate(_ image: CGImage, degrees: Int) -> CGImage? {
        let d = ((degrees % 360) + 360) % 360
        guard d != 0 else { return image }
        let swap = d == 90 || d == 270
        let w = swap ? image.height : image.width, h = swap ? image.width : image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -CGFloat(d) * .pi / 180)  // clockwise on screen
        ctx.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
