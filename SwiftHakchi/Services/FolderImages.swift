import Foundation
import CoreGraphics
import ImageIO

/// Folder icons for console menus (port of CE's `NesMenuFolder` image lookup).
///
/// Images are looked up by id (e.g. "folder_a", "folder_back") in, first match wins:
/// 1. the user folder `~/Library/Application Support/SwiftHakchi/folder_images/<set>/`
/// 2. the bundled set `Resources/folder_images/<set>/`
/// 3. the user folder root, 4. the bundled root, 5. the bundled "folder" image.
/// An optional "<id>_small.png" next to the image is used for the 40×40 thumbnail.
enum FolderImages {
    static var userDirectory: URL {
        AppConfig.configDirectory.appendingPathComponent("folder_images", isDirectory: true)
    }

    static var bundledDirectory: URL? {
        Bundle.appBundle.url(forResource: "folder_images", withExtension: nil)
    }

    /// Image sets: subfolders of the user and bundled folders
    static func availableSets() -> [String] {
        var sets = Set<String>()
        for dir in [userDirectory, bundledDirectory].compactMap({ $0 }) {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                sets.insert(item.lastPathComponent)
            }
        }
        return sets.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Image ids available for the folder icon picker (CE's SelectIconForm)
    static func availableIds(set: String) -> [String] {
        var ids = Set<String>()
        var dirs = [userDirectory, bundledDirectory].compactMap { $0 }
        if !set.isEmpty { dirs += dirs.map { $0.appendingPathComponent(set) } }
        for dir in dirs {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            where name.lowercased().hasSuffix(".png") && !name.lowercased().hasSuffix("_small.png") {
                ids.insert(String(name.dropLast(4)))
            }
        }
        return ids.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// File for an image id, following the lookup order above
    static func url(for id: String, set: String) -> URL? {
        var candidates: [URL] = []
        let roots = [userDirectory, bundledDirectory].compactMap { $0 }
        if !set.isEmpty { candidates += roots.map { $0.appendingPathComponent(set).appendingPathComponent("\(id).png") } }
        candidates += roots.map { $0.appendingPathComponent("\(id).png") }
        if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return found
        }
        return id == "folder" ? nil : url(for: "folder", set: set)
    }

    /// Icon (fit in 228×204) and thumbnail (fit in 40×40) PNGs for a folder image id
    static func pngs(for id: String, set: String) -> (icon: Data, small: Data)? {
        guard let url = url(for: id, set: set), let data = try? Data(contentsOf: url) else { return nil }
        let smallURL = url.deletingLastPathComponent().appendingPathComponent("\(id)_small.png")
        let smallSource = (try? Data(contentsOf: smallURL)) ?? data
        guard let icon = fit(data, maxWidth: 228, maxHeight: 204),
              let small = fit(smallSource, maxWidth: 40, maxHeight: 40) else { return nil }
        return (icon, small)
    }

    /// Scale an image to fit inside the box, keeping its aspect ratio (CE's ProcessImage
    /// with upscaling), and encode it as PNG
    static func fit(_ data: Data, maxWidth: Int, maxHeight: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { return nil }
        let scale = min(Double(maxWidth) / Double(image.width), Double(maxHeight) / Double(image.height))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, scaled, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
