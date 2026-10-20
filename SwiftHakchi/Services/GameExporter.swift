import Foundation
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "Export")

/// Where an exported file comes from
enum ExportSource: Equatable {
    case file(URL)
    case data(Data)
}

/// Decides which files an export writes. The flat layout below puts every game
/// in folder 000; the sync engine's menu builder (folders, pages) can provide a
/// richer layout through the same protocol.
protocol GameExportLayout {
    /// Relative path (under the export root) → source
    func plan(games: [ExportGame]) -> [String: ExportSource]
}

/// A game to export: a local game folder, or a stock game's .desktop text
struct ExportGame {
    enum Kind {
        case local(directory: URL)
        case stock(desktop: String)
    }
    let code: String
    let kind: Kind
}

/// CE's export without folders: games in `000/CODE/`, stock games pointing at squashfs.
struct FlatExportLayout: GameExportLayout {
    let consoleType: ConsoleType
    /// Linked export: ROMs stay where they are, the .desktop points at this
    /// console-side path (CE: `/media/<path of the games folder on the drive>`)
    var linkedMediaPath: String?

    /// Files CE never exports
    private func isExcluded(_ name: String, code: String) -> Bool {
        let lower = name.lowercased()
        return lower == GameMetadata.fileName.lowercased()
            || ["_original.png", "_spine.png", "_logo.png"].contains { lower == (code + $0).lowercased() }
    }

    func plan(games: [ExportGame]) -> [String: ExportSource] {
        var plan: [String: ExportSource] = [:]
        for game in games {
            let code = game.code
            switch game.kind {
            case .stock(let text):
                // Same rewrite as the sync: the original path is reached through /var/squashfs
                let gp = consoleType.originalGamesPath
                plan["000/\(code)/\(code).desktop"] = .data(Data(text.replacingOccurrences(of: gp, with: "/var/squashfs\(gp)").utf8))
            case .local(let dir):
                let desktopURL = dir.appendingPathComponent("\(code).desktop")
                let desktop = (try? Data(contentsOf: desktopURL)).map(DesktopFile.init(data:)) ?? DesktopFile()
                if desktop.code.isEmpty { desktop.code = code }
                desktop.rebaseGamePaths(to: linkedMediaPath ?? "/var/games")
                desktop.profilePath = "/var/saves"
                desktop.iconPath = linkedMediaPath ?? "/var/games"
                desktop.normalizeForSave()
                plan["000/\(code)/\(code).desktop"] = .data(desktop.toData())
                guard linkedMediaPath == nil else { continue }
                for (relative, url) in GameSyncService.gameFiles(in: dir)
                where !relative.lowercased().hasSuffix(".desktop") && !isExcluded(relative, code: code) {
                    plan["000/\(code)/\(relative)"] = .file(url)
                }
            }
        }
        return plan
    }
}

/// Writes an export plan to a folder: copies new or changed files, deletes stale
/// ones and empty folders (CE's local diff).
struct GameExporter {
    /// `<volume>/hakchi/games/<system-code>` (CE with "separate games for multiboot")
    static func exportRoot(volume: URL, consoleType: ConsoleType) -> URL {
        volume.appendingPathComponent("hakchi/games/\(consoleType.syncCode)", isDirectory: true)
    }

    /// Run the export; returns the number of files written
    @discardableResult
    static func export(plan: [String: ExportSource], to root: URL,
                       progress: (String, Double) -> Void) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // Delete files that are not in the plan
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            let base = root.standardizedFileURL.path + "/"
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
                if plan[relative] == nil { try? fm.removeItem(at: url) }
            }
        }
        removeEmptyFolders(in: root)

        var written = 0
        let entries = plan.sorted { $0.key < $1.key }
        for (index, (relative, source)) in entries.enumerated() {
            let dest = root.appendingPathComponent(relative)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch source {
            case .data(let data):
                if (try? Data(contentsOf: dest)) != data {
                    try data.write(to: dest)
                    written += 1
                }
            case .file(let url):
                if !sameFile(url, dest) {
                    try? fm.removeItem(at: dest)
                    try fm.copyItem(at: url, to: dest)
                    written += 1
                }
            }
            progress("Exporting \(relative)", Double(index + 1) / Double(max(entries.count, 1)))
        }
        logger.info("Export to \(root.path): \(written) files written, \(entries.count) planned")
        return written
    }

    /// Same size and modification time within 3 seconds (CE's diff rule)
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let aa = try? fm.attributesOfItem(atPath: a.path), let ba = try? fm.attributesOfItem(atPath: b.path),
              (aa[.size] as? Int64) == (ba[.size] as? Int64),
              let am = aa[.modificationDate] as? Date, let bm = ba[.modificationDate] as? Date else { return false }
        return abs(am.timeIntervalSince(bm)) < 3
    }

    private static func removeEmptyFolders(in root: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for item in items where item.hasDirectoryPath {
            removeEmptyFolders(in: item)
            if (try? fm.contentsOfDirectory(atPath: item.path))?.isEmpty == true { try? fm.removeItem(at: item) }
        }
    }
}

/// CE's export with the same menu structure as the sync: the collection's split
/// mode (pages, folders, Folders Manager tree), folder entries and images.
/// Files go to `NNN/CODE/` with ROM paths under /var/games (CE's normal, not linked, layout).
struct MenuExportLayout {
    let consoleType: ConsoleType
    let collection: CollectionSettings
    /// Folders Manager tree, used in Custom mode
    var customTree: MenuCollection?

    /// Stock games below squashfs on the console (CE's GamesSquashFsPath)
    private var squashfsGamesPath: String {
        switch consoleType {
        case .nes, .famicom: return "/var/squashfs/usr/share/games/nes/kachikachi"
        case .megaDrive: return "/var/squashfs"
        default: return "/var/squashfs/usr/share/games"
        }
    }

    /// `stockGames` pairs each selected stock game with its .desktop from the console cache
    func plan(customGames: [Game], stockGames: [(game: Game, desktop: DesktopFile)]) -> [String: ExportSource] {
        var sources: [String: SyncGameSource] = [:]
        for game in customGames {
            let dir = URL(fileURLWithPath: game.romPath)
            let desktop = (try? Data(contentsOf: dir.appendingPathComponent("\(game.code).desktop")))
                .map(DesktopFile.init(data:))
                ?? DesktopFile(string: "Exec=\(game.commandLine)\nCode=\(game.code)\nName=\(game.name)")
            sources[game.code] = SyncGameSource(code: game.code, directory: dir, desktop: desktop, isOriginal: false)
        }
        for (game, desktop) in stockGames {
            sources[game.code] = SyncGameSource(code: game.code, directory: nil, desktop: desktop, isOriginal: true)
        }

        let options = MenuOptions(backPosition: collection.backFolderPosition, homeFolder: collection.homeFolder)
        let root: MenuCollection
        if let customTree {
            root = customTree
            root.addBack(options: options)
        } else {
            root = GameSyncService.menuRoot(customGames: customGames, stockGames: stockGames.map(\.game),
                                            sources: sources)
            root.split(collection.foldersMode, maxElements: collection.maxGamesPerFolder, options: options)
        }

        let context = SyncContext(uploadPath: "/var/games", squashfsGamesPath: squashfsGamesPath, linked: false,
                                  alwaysCopyOriginals: false, consoleType: consoleType,
                                  imageSet: collection.folderImagesSet)
        let build = SyncFileBuilder(context: context, games: sources).build(root: root)

        var plan: [String: ExportSource] = [:]
        for file in build.files {
            let relative = file.path.hasPrefix("./") ? String(file.path.dropFirst(2)) : file.path
            switch file.source {
            case .file(let url): plan[relative] = .file(url)
            case .data(let data): plan[relative] = .data(data)
            }
        }
        return plan
    }
}
