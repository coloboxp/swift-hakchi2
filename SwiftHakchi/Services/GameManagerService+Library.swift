import Foundation
import SWCompression
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "GameLibrary")

/// Library commands from Hakchi2-CE's game context menu and File menu.
/// The disk work is in static functions so it can be tested on temporary folders.
extension GameManagerService {
    // MARK: - Paths

    func gameDirectory(_ game: Game) -> URL {
        AppConfig.shared.gamesDirectory.appendingPathComponent(game.code)
    }

    func desktopURL(_ game: Game) -> URL {
        gameDirectory(game).appendingPathComponent("\(game.code).desktop")
    }

    private var coverOptions: CoverArt.Options {
        let s = LibrarySettings.shared.values
        return CoverArt.Options(quantize: s.compressCoverArt, centerThumbnail: s.centerThumbnail)
    }

    /// Re-read a game from disk after a command changed its files
    func reloadGame(_ code: String) {
        guard let index = games.firstIndex(where: { $0.id == code && $0.source == .local }) else { return }
        let dir = AppConfig.shared.gamesDirectory.appendingPathComponent(code)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(code).desktop")) else { return }
        let desktop = DesktopFile(data: data)
        if desktop.code.isEmpty { desktop.code = code }
        var game = Game(desktopFile: desktop, consoleType: games[index].consoleType,
                        basePath: AppConfig.shared.gamesDirectory.path, source: .local)
        let meta = GameMetadata.load(gameDirectory: dir, exec: desktop.exec)
        game.system = meta.system
        game.core = meta.core
        game.isSelected = games[index].isSelected
        game.isOnConsole = games[index].isOnConsole
        game.invalidateCoverCache()
        games[index] = game
    }

    // MARK: - Prefix and region

    /// "Add prefix": `Name` becomes "P: name", `SortName` "p: sort name" (CE)
    func addPrefix(_ prefix: String, to codes: [String]) {
        editDesktops(codes) { Self.addPrefix(prefix, to: $0) }
    }

    func removePrefix(_ prefix: String, from codes: [String]) {
        editDesktops(codes) { Self.removePrefix(prefix, from: $0) }
    }

    func setRegion(_ region: String, for codes: [String]) {
        editDesktops(codes) { $0.country = region }
    }

    static func addPrefix(_ prefix: String, to desktop: DesktopFile) {
        let p = prefix.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        desktop.normalizeForSave() // make sure a sort name exists
        desktop.name = "\(p): \(desktop.name.trimmingCharacters(in: .whitespaces))"
        desktop.sortName = "\(p.lowercased()): \(desktop.sortName.trimmingCharacters(in: .whitespaces).lowercased())"
    }

    static func removePrefix(_ prefix: String, from desktop: DesktopFile) {
        let formatted = "\(prefix.trimmingCharacters(in: .whitespaces)): "
        if desktop.name.hasPrefix(formatted) { desktop.name.removeFirst(formatted.count) }
        if desktop.sortName.hasPrefix(formatted.lowercased()) { desktop.sortName.removeFirst(formatted.count) }
    }

    /// Load each game's .desktop, apply `edit`, save, and refresh the game
    private func editDesktops(_ codes: [String], _ edit: (DesktopFile) -> Void) {
        for code in codes {
            guard let game = games.first(where: { $0.id == code && $0.source == .local }),
                  let data = try? Data(contentsOf: desktopURL(game)) else { continue }
            let desktop = DesktopFile(data: data)
            edit(desktop)
            desktop.normalizeForSave()
            try? desktop.toData().write(to: desktopURL(game))
            reloadGame(code)
        }
    }

    // MARK: - Box art

    /// Set a game's cover from image data and mark it as custom art
    func setCover(_ data: Data, for code: String) throws {
        guard let game = games.first(where: { $0.id == code && $0.source == .local }) else { return }
        let dir = gameDirectory(game)
        try CoverArt.setCover(data, gameDirectory: dir, code: code, options: coverOptions)
        try markCustomCover(true, gameDirectory: dir, exec: game.commandLine)
        reloadGame(code)
    }

    func setThumbnail(_ data: Data, for code: String) throws {
        guard let game = games.first(where: { $0.id == code && $0.source == .local }) else { return }
        try CoverArt.setThumbnail(data, gameDirectory: gameDirectory(game), code: code, options: coverOptions)
        reloadGame(code)
    }

    /// "Delete box art": back to the system's blank cover
    func resetCover(for codes: [String]) {
        for code in codes {
            guard let game = games.first(where: { $0.id == code && $0.source == .local }) else { continue }
            let dir = gameDirectory(game)
            let meta = GameMetadata.load(gameDirectory: dir, exec: game.commandLine)
            do {
                try CoverArt.setDefaultCover(gameDirectory: dir, code: code, system: meta.system,
                                             fileName: meta.originalFilename, options: coverOptions)
                try? FileManager.default.removeItem(at: CoverArt.mdMiniURL(dir, code))
                try markCustomCover(false, gameDirectory: dir, exec: game.commandLine)
            } catch {
                logger.error("Reset cover \(code): \(error.localizedDescription)")
            }
            reloadGame(code)
        }
    }

    /// "Scan for new box art": look in art/ again. Returns games with several candidates.
    @discardableResult
    func scanForCovers(_ codes: [String], matcher: CoverArtMatcher = CoverArtMatcher()) -> [String: [URL]] {
        var ambiguous: [String: [URL]] = [:]
        for code in codes {
            guard let game = games.first(where: { $0.id == code && $0.source == .local }) else { continue }
            let dir = gameDirectory(game)
            let meta = GameMetadata.load(gameDirectory: dir, exec: game.commandLine)
            let romName = meta.originalFilename.isEmpty
                ? ((DesktopFile.splitExec(game.commandLine).args.first ?? "") as NSString).lastPathComponent
                : meta.originalFilename
            switch matcher.findCover(romFileName: romName, sourceDirectory: nil, crc32: meta.originalCrc32,
                                     system: meta.system, alternateTitle: game.name) {
            case .found(let url):
                if let data = try? Data(contentsOf: url) { try? setCover(data, for: code) }
            case .mdMini(let data):
                try? data.write(to: CoverArt.mdMiniURL(dir, code))
                if let image = CoverArt.loadImage(data), let front = image.cropping(to: CoverArt.mdFrontArea) {
                    try? CoverArt.writeCoverAndThumbnail(front, gameDirectory: dir, code: code, options: coverOptions)
                }
                reloadGame(code)
            case .ambiguous(let urls):
                ambiguous[code] = urls
            case .none:
                break
            }
        }
        return ambiguous
    }

    /// Covers for a newly imported game (CE: `FindCover`, else `SetDefaultImage`).
    /// Returns true when real box art was found; ambiguous matches are kept in
    /// `importCoverCandidates` and the game gets the blank cover meanwhile.
    func applyImportCover(_ imported: GameImporter.ImportedGame, desktop: DesktopFile, meta: GameMetadata) -> Bool {
        let dir = imported.directory, code = imported.code
        let source = imported.sourceFile.deletingLastPathComponent()
        let sourceDir = FileManager.default.fileExists(atPath: source.path) ? source : nil
        let result = CoverArtMatcher().findCover(
            romFileName: meta.originalFilename.isEmpty ? imported.sourceFile.lastPathComponent : meta.originalFilename,
            sourceDirectory: sourceDir, crc32: meta.originalCrc32, system: meta.system, alternateTitle: desktop.name)

        switch result {
        case .found(let url):
            if let data = try? Data(contentsOf: url),
               (try? CoverArt.setCover(data, gameDirectory: dir, code: code, options: coverOptions)) != nil {
                reloadGame(code)
                return true
            }
        case .mdMini(let data):
            try? data.write(to: CoverArt.mdMiniURL(dir, code))
            if let image = CoverArt.loadImage(data), let front = image.cropping(to: CoverArt.mdFrontArea) {
                try? CoverArt.writeCoverAndThumbnail(front, gameDirectory: dir, code: code, options: coverOptions)
                reloadGame(code)
                return true
            }
        case .ambiguous(let urls):
            importCoverCandidates[code] = urls
        case .none:
            break
        }
        try? CoverArt.setDefaultCover(gameDirectory: dir, code: code, system: meta.system,
                                      fileName: meta.originalFilename, options: coverOptions)
        reloadGame(code)
        return false
    }

    /// CE: "Compress games when adding"
    func compressAfterImport(code: String, gameDirectory dir: URL) {
        guard LibrarySettings.shared.values.compressGames,
              GameCompression.canCompress(gameDirectory: dir, code: code) else { return }
        do {
            try GameCompression.compress(gameDirectory: dir, code: code)
            reloadGame(code)
        } catch {
            logger.error("Compress \(code) after import: \(error.localizedDescription)")
        }
    }

    private func markCustomCover(_ custom: Bool, gameDirectory dir: URL, exec: String) throws {
        var meta = GameMetadata.load(gameDirectory: dir, exec: exec)
        meta.customCoverArt = custom
        try meta.save(gameDirectory: dir)
    }

    // MARK: - Archive (.clvg)

    /// Write `.clvg` archives (tar.gz of the game folder). One game: `destination` is the
    /// file; several: `destination` is a folder and files are named "CODE - Name.clvg".
    func archiveGames(_ codes: [String], to destination: URL) throws {
        let selected = games.filter { codes.contains($0.id) && $0.source == .local }
        for game in selected {
            let target = selected.count == 1 && !destination.hasDirectoryPath
                ? destination
                : destination.appendingPathComponent(Self.archiveFileName(code: game.code, name: game.name))
            try Self.archive(gameDirectory: gameDirectory(game), to: target)
        }
    }

    static func archiveFileName(code: String, name: String) -> String {
        let safeName = name.replacingOccurrences(of: #"[/:\\]"#, with: "_", options: .regularExpression)
        return "\(code) - \(safeName).clvg"
    }

    /// tar.gz of every file in the folder, paths relative to it (CE's `Archive`)
    static func archive(gameDirectory dir: URL, to target: URL) throws {
        var entries: [TarEntry] = []
        for (relative, url) in GameSyncService.gameFiles(in: dir) {
            let data = try Data(contentsOf: url)
            var info = TarEntryInfo(name: relative, type: .regular)
            info.modificationTime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            info.permissions = Permissions(rawValue: 0o644)
            entries.append(TarEntry(info: info, data: data))
        }
        let tar = TarContainer.create(from: entries)
        try GzipArchive.archive(data: tar).write(to: target, options: .atomic)
    }

    // MARK: - Repair and compression

    /// "Repair games" with CE's behaviour (unpack archives, reset arguments)
    func repairGames(_ codes: [String], chooseFile: @escaping (String, [String]) -> String?) -> [String] {
        var errors: [String] = []
        for code in codes {
            guard let game = games.first(where: { $0.id == code && $0.source == .local }) else { continue }
            do {
                let outcome = try GameRepair.repair(
                    gameDirectory: gameDirectory(game), code: code, cores: CoreCatalog.shared,
                    options: GameRepair.Options(preserveArgs: false, chooseFile: chooseFile))
                if outcome != .skipped, LibrarySettings.shared.values.compressGames,
                   GameCompression.canCompress(gameDirectory: gameDirectory(game), code: code) {
                    try GameCompression.compress(gameDirectory: gameDirectory(game), code: code)
                }
            } catch {
                errors.append("\(game.name): \(error.localizedDescription)")
            }
            reloadGame(code)
        }
        return errors
    }

    func compressGames(_ codes: [String], compress: Bool) -> [String] {
        var errors: [String] = []
        for code in codes {
            guard let game = games.first(where: { $0.id == code && $0.source == .local }) else { continue }
            do {
                if compress {
                    try GameCompression.compress(gameDirectory: gameDirectory(game), code: code)
                } else {
                    try GameCompression.decompress(gameDirectory: gameDirectory(game), code: code)
                }
            } catch {
                errors.append("\(game.name): \(error.localizedDescription)")
            }
            reloadGame(code)
        }
        return errors
    }

    // MARK: - Size

    /// Size on the console: files rounded up to 4 KiB blocks, without the art CE never uploads
    static func gameSize(gameDirectory dir: URL, code: String) -> Int64 {
        let skip: Set<String> = ["\(code)_original.png", "\(code)_spine.png", "\(code)_logo.png", GameMetadata.fileName]
        return GameSyncService.gameFiles(in: dir).reduce(Int64(0)) { total, entry in
            guard !skip.contains(entry.0) else { return total }
            let size = Int64((try? entry.1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return total + (size + 4095) / 4096 * 4096
        }
    }

    // MARK: - Custom app

    /// "Add custom app" (CE's `NewCustomGameForm` + `CreateEmptyApp`)
    func addCustomApp(name: String, code: String, consoleType: ConsoleType) throws -> String {
        let dir = AppConfig.shared.gamesDirectory.appendingPathComponent(code)
        try Self.createCustomApp(name: name, code: code, in: AppConfig.shared.gamesDirectory, options: coverOptions)
        let desktop = DesktopFile(data: try Data(contentsOf: dir.appendingPathComponent("\(code).desktop")))
        var game = Game(desktopFile: desktop, consoleType: consoleType,
                        basePath: AppConfig.shared.gamesDirectory.path, source: .local)
        game.isSelected = true
        games.append(game)
        games.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        return code
    }

    /// Generated code for a custom app name: CRC32 of the UTF-8 name, CE's prefix rule
    static func customAppCode(for name: String) -> String {
        GameImporter.generateCode(crc32: CRC32.checksum(Data(name.utf8)), prefix: SystemCatalog.availablePrefix(for: name))
    }

    static func isValidCustomCode(_ code: String) -> Bool {
        code.range(of: #"^CLV-[A-Z0-9]-[A-Z0-9]{5}$"#, options: .regularExpression) != nil
    }

    static func createCustomApp(name: String, code: String, in gamesDirectory: URL, options: CoverArt.Options) throws {
        guard isValidCustomCode(code) else { throw LibraryError.invalidCode(code) }
        let dir = gamesDirectory.appendingPathComponent(code)
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw LibraryError.codeExists(code) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let desktop = DesktopFile()
        desktop.code = code
        desktop.name = name
        desktop.exec = "/bin/enter-custom-command-here"
        desktop.profilePath = "/var/saves"
        desktop.iconPath = "/var/games"
        desktop.iconFilename = "\(code).png"
        desktop.normalizeForSave()
        try desktop.toData().write(to: dir.appendingPathComponent("\(code).desktop"))
        try GameMetadata().save(gameDirectory: dir)
        try? CoverArt.setDefaultCover(gameDirectory: dir, code: code, system: "", fileName: "", options: options)
    }

    // MARK: - Original games

    /// Stock `.desktop` files for a console from the bundled desktop_entries.tar
    /// (folders are named by system code: nes-usa, snes-eur, md-jpn, ...)
    static func originalDesktopEntries(systemCode: String, tar: URL?) -> [(code: String, content: String)] {
        guard let tar, let data = try? Data(contentsOf: tar), let entries = try? TarContainer.open(container: data) else {
            return []
        }
        let prefix = "\(systemCode)/"
        return entries.compactMap { entry in
            var name = entry.info.name
            if name.hasPrefix("./") { name.removeFirst(2) }
            guard name.hasPrefix(prefix), name.hasSuffix(".desktop"), let d = entry.data else { return nil }
            let code = (name as NSString).lastPathComponent.replacingOccurrences(of: ".desktop", with: "")
            return (code, String(decoding: d, as: UTF8.self))
        }
        .sorted { $0.code < $1.code }
    }

    /// "Restore original games": put every stock game back on the console bar.
    /// Without a console cache, the stock list comes from the bundled entries.
    func restoreOriginalGames(consoleType: ConsoleType) -> Int {
        var restored = 0
        for i in games.indices where games[i].source == .stock && !games[i].isSelected {
            games[i].isSelected = true
            restored += 1
        }
        if !games.contains(where: { $0.source == .stock }) {
            let tar = Bundle.appBundle.url(forResource: "desktop_entries", withExtension: "tar")
            var entries = Self.originalDesktopEntries(systemCode: consoleType.syncCode, tar: tar)
            if consoleType == .megaDrive {
                // CE keeps the English/US entries (the tar has every language)
                entries = entries.filter { $0.code.contains("_en_") || $0.code.contains("_us_") || $0.code.contains("eu_eu_") }
            }
            let coversDir = AppConfig.configDirectory.appendingPathComponent("covers", isDirectory: true)
            for entry in entries {
                var game = Game(code: entry.code, desktopContent: entry.content, consoleType: consoleType, source: .stock)
                let cover = coversDir.appendingPathComponent("\(entry.code).png")
                if FileManager.default.fileExists(atPath: cover.path) { game.coverArtPath = cover.path }
                games.append(game)
                restored += 1
            }
            games.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        return restored
    }
}

enum LibraryError: LocalizedError {
    case invalidCode(String), codeExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidCode(let c): return "\"\(c)\" is not a valid code. Use the form CLV-X-XXXXX."
        case .codeExists(let c): return "A game with the code \(c) already exists."
        }
    }
}
