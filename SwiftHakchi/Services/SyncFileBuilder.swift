import Foundation
import CoreGraphics
import ImageIO

/// A game as input for a sync
struct SyncGameSource {
    let code: String
    /// Local folder with the game files (custom games; stock games only with
    /// "always copy original games" and a local cache)
    let directory: URL?
    /// The game's .desktop (local file for custom games, the console's file for stock games)
    let desktop: DesktopFile
    let isOriginal: Bool
}

/// Where and how files go on the console
struct SyncContext {
    /// Absolute upload folder on the console, e.g. /var/lib/hakchi/games/snes-usa
    var uploadPath: String
    /// Stock games in squashfs, e.g. /var/squashfs/usr/share/games
    var squashfsGamesPath: String
    var linked = true
    var alwaysCopyOriginals = false
    var consoleType: ConsoleType = .unknown
    var imageSet = ""
}

/// Result of building the file set for a menu tree (CE's BuildFiles)
struct SyncBuildResult {
    var files: [SyncFile] = []
    /// Every menu, in index order (NNN = index); index 0 is the root menu
    var menus: [MenuCollection] = []
    /// Shell script creating autoplay/pixelart links (CE's linkgamessync.sh)
    var linkScript = "#!/bin/sh\ncd \"/tmp\"\n"
    /// Custom games whose ROM is not in their local folder
    var missingRoms: [String] = []
    var gameCount = 0

    /// Space the files take on the console (4 KiB blocks)
    var totalSize: Int64 { files.reduce(0) { $0 + $1.paddedSize } }
}

/// Builds the files to upload from a menu tree (port of CE's `SyncTask.AddMenu`,
/// `NesApplication.CopyToSync(Linked)`, `NesMenuFolder.CopyTo` and `AddSymLinks`)
struct SyncFileBuilder {
    let context: SyncContext
    let games: [String: SyncGameSource]

    /// Files CE never uploads; the .desktop is generated instead
    private static func skippedNames(code: String) -> Set<String> {
        ["\(code).desktop", "\(code)_original.png", "\(code)_spine.png", "\(code)_logo.png", GameMetadata.fileName]
    }

    func build(root: MenuCollection) -> SyncBuildResult {
        var result = SyncBuildResult()
        addMenu(root, into: &result)
        return result
    }

    private func menuIndex(_ menu: MenuCollection, in result: inout SyncBuildResult) -> Int {
        if let i = result.menus.firstIndex(where: { $0 === menu }) { return i }
        result.menus.append(menu)
        return result.menus.count - 1
    }

    private func addMenu(_ menu: MenuCollection, into result: inout SyncBuildResult) {
        let index = menuIndex(menu, in: &result)
        let target = String(format: "%03d", index)

        for element in menu.elements {
            switch element {
            case .game(let game):
                guard let source = games[game.code] else { continue }
                addGame(source, targetDirectory: target, into: &result)
                result.gameCount += 1
            case .folder(let folder):
                if folder.name == MenuFolderNames.trashBin { continue }  // never sync the recycle bin
                if folder.child.count == 1 && folder.child.elements[0].name == MenuFolderNames.back { continue }
                if !result.menus.contains(where: { $0 === folder.child }) {
                    result.menus.append(folder.child)
                    addMenu(folder.child, into: &result)
                }
                folder.childIndex = result.menus.firstIndex { $0 === folder.child }!
                addFolder(folder, targetDirectory: target, into: &result)
            }
        }
        addLinks(menu, targetDirectory: target, into: &result)
    }

    // MARK: - Games

    private func addGame(_ game: SyncGameSource, targetDirectory: String, into result: inout SyncBuildResult) {
        let code = game.code
        let menuDir = "./\(targetDirectory)/\(code)"
        let storageDir = context.linked ? "./.storage/\(code)" : menuDir
        let storageMediaPath = context.linked ? "\(context.uploadPath)/.storage" : "/var/games"

        var mediaPath = storageMediaPath
        var iconPath = storageMediaPath

        if game.isOriginal && !(context.alwaysCopyOriginals && game.directory != nil) {
            // Stock game: the files stay in squashfs, only the menu entry is uploaded
            mediaPath = context.squashfsGamesPath
            iconPath = context.squashfsGamesPath
        } else if let dir = game.directory {
            result.files += gameFiles(code: code, directory: dir, to: storageDir)
            if !game.isOriginal && !Self.hasRomFile(desktop: game.desktop, directory: dir) {
                result.missingRoms.append(code)
            }
        }

        let desktop = DesktopFile(string: game.desktop.serialize())
        if desktop.code.isEmpty { desktop.code = code }
        desktop.rebaseGamePaths(to: mediaPath)
        desktop.iconPath = iconPath
        if desktop.iconFilename == nil { desktop.iconFilename = "\(code).png" }
        desktop.profilePath = "/var/saves"
        desktop.omitProfilePathCode = false
        // CE writes the SNES-only Status/MyPlayDemoTime lines for stock SNES games
        desktop.snesExtraFields = game.isOriginal && context.consoleType.isSNES
        result.files.append(.generated(path: "\(menuDir)/\(code).desktop", data: desktop.toData()))
    }

    /// The game folder's files under `targetDir`; the cover is resized for the console
    /// and a 40×40 thumbnail is made when the folder has none
    private func gameFiles(code: String, directory: URL, to targetDir: String) -> [SyncFile] {
        let skipped = Self.skippedNames(code: code)
        var files: [SyncFile] = []
        var cover: Data?
        var hasSmall = false

        for (relative, url) in Self.regularFiles(in: directory) {
            let name = (relative as NSString).lastPathComponent
            if !relative.contains("/") && skipped.contains(name) { continue }
            if relative == "\(code).png" {
                cover = try? Data(contentsOf: url)
                continue
            }
            if relative == "\(code)_small.png" { hasSmall = true }
            if let f = SyncFile.file(path: "\(targetDir)/\(relative)", url: url) { files.append(f) }
        }

        let coverData = cover.map { resizeCoverArt(data: $0, width: context.consoleType.coverWidth,
                                                   height: context.consoleType.coverHeight) }
            ?? Self.placeholderPNG()
        files.append(.generated(path: "\(targetDir)/\(code).png", data: coverData))
        if !hasSmall {
            let small = cover.map { resizeCoverArt(data: $0, width: 40, height: 40) } ?? Self.placeholderPNG()
            files.append(.generated(path: "\(targetDir)/\(code)_small.png", data: small))
        }
        return files
    }

    /// True when the folder holds the ROM named in Exec
    static func hasRomFile(desktop: DesktopFile, directory: URL) -> Bool {
        guard let rom = desktop.romPath else { return false }
        let name = (rom as NSString).lastPathComponent
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    /// Regular files under a folder as (relative path, URL), skipping hidden files
    static func regularFiles(in dir: URL) -> [(String, URL)] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let base = dir.standardizedFileURL.path + "/"
        var result: [(String, URL)] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            result.append((String(path.dropFirst(base.count)), url))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    // MARK: - Folders

    private func addFolder(_ folder: MenuFolder, targetDirectory: String, into result: inout SyncBuildResult) {
        let code = folder.code
        let dir = "./\(targetDirectory)/\(code)"
        result.files.append(.generated(path: "\(dir)/\(code).desktop", data: folder.desktopFile().toData()))
        let images = FolderImages.pngs(for: folder.imageId, set: context.imageSet)
        result.files.append(.generated(path: "\(dir)/\(code).png", data: images?.icon ?? Self.placeholderPNG()))
        result.files.append(.generated(path: "\(dir)/\(code)_small.png", data: images?.small ?? Self.placeholderPNG()))
    }

    // MARK: - autoplay / pixelart links

    private func addLinks(_ menu: MenuCollection, targetDirectory: String, into result: inout SyncBuildResult) {
        let pixelArt = context.consoleType.isNES
        for game in menu.games {
            guard let source = games[game.code] else { continue }
            let dir = source.directory
            let hasExtras = dir.map { d in
                ["autoplay", "pixelart"].contains { FileManager.default.fileExists(atPath: d.appendingPathComponent($0).path) }
            } ?? false
            var src = "\(context.uploadPath)/.storage/\(game.code)"
            let dst = "\(context.uploadPath)/\(targetDirectory)/\(game.code)"
            var needLink = false

            let copiedOriginal = source.isOriginal && context.alwaysCopyOriginals && dir != nil
            if context.linked {
                if source.isOriginal {
                    needLink = true
                    if !copiedOriginal && !hasExtras { src = context.squashfsGamesPath + "/" + game.code }
                } else {
                    needLink = hasExtras
                }
            } else if source.isOriginal && !copiedOriginal && !hasExtras {
                needLink = true
                src = context.squashfsGamesPath + "/" + game.code
            }

            guard needLink else { continue }
            var line = "src=\"\(src)\" && dst=\"\(dst)\" && mkdir -p \"$dst\" && rm -rf \"$dst/autoplay\" && ln -s \"$src/autoplay\" \"$dst/\" "
            if pixelArt {
                line += "&& rm -rf \"$dst/pixelart\" && ln -s \"$src/pixelart\" \"$dst/\" "
            }
            result.linkScript += line + "\n"
        }
    }

    // MARK: - Helpers

    /// 40×40 grey placeholder for games and folders without an image
    static func placeholderPNG() -> Data {
        guard let ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        ctx.setFillColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        guard let image = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : Data()
    }
}
