import Foundation
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "GameSync")

/// Incremental game sync (port of Hakchi2-CE's `SyncTask.UploadGames`):
///
/// BuildMenu → BuildFiles → CheckRemoteStorageRequirements → PrepareRemoteTransfer →
/// CalculateRemoteDiff → upload (tar stream) → RemoteCleanup → LinkGames → SyncConfig →
/// `hakchi overmount_games; uistart`.
///
/// Layout in the upload folder (`<sync storage>[/<system code>]`):
///   .storage/CODE/  game files (linked sync)
///   000/            root menu; 001… sub-menus and pages, each CODE/CODE.desktop
/// Only files that changed are uploaded; files no longer wanted are deleted, except the
/// files of selected games whose ROM is not on this Mac (the console copy is kept).
actor GameSyncService {
    private let shell: SSHService
    private let consoleType: ConsoleType

    /// What to sync
    struct Request {
        /// All library games; `isSelected` decides what is synced
        var games: [Game]
        var settings: SyncSettings
        /// Tree from the Folders Manager (custom structure); nil = split by the settings
        var customTree: MenuCollection?
    }

    /// What happened
    struct Report {
        var uploadedFiles = 0
        var uploadedBytes: Int64 = 0
        var deletedFiles = 0
        var syncedGames = 0
        /// Names of selected games whose ROM is missing locally (kept on the console)
        var gamesWithoutLocalRom: [String] = []
        var warnings: [String] = []
    }

    init(shell: SSHService, consoleType: ConsoleType) {
        self.shell = shell
        self.consoleType = consoleType
    }

    /// Stock games folder below squashfs for this console (CE's GamesSquashFsPath)
    var gamesSquashFsPath: String {
        switch consoleType {
        case .nes, .famicom: return "/usr/share/games/nes/kachikachi"
        case .megaDrive: return ""
        default: return "/usr/share/games"
        }
    }

    func sync(_ request: Request, progress: @Sendable (String, Double) -> Void) async throws -> Report {
        var report = Report()
        let settings = request.settings
        let collection = settings.collection(for: consoleType)

        // Console paths
        progress("Reading console layout...", 0.02)
        let syncRoot = await output("hakchi findGameSyncStorage", fallback: "/var/lib/hakchi/games")
        let squashfs = await output("hakchi get squashfs", fallback: "/var/squashfs")
        let uploadPath = settings.uploadToTmp ? "/tmp/upload-test"
            : (settings.separateGamesForMultiboot ? "\(syncRoot)/\(consoleType.syncCode)" : syncRoot)
        let squashfsGames = squashfs + gamesSquashFsPath

        // Inputs: selected custom games from disk, selected stock games from squashfs
        progress("Collecting games...", 0.05)
        let customGames = request.games.filter { $0.isSelected && $0.source == .local }
        let stockGames = request.games.filter { $0.isSelected && $0.isStock }
        var sources: [String: SyncGameSource] = [:]
        for game in customGames {
            let dir = URL(fileURLWithPath: game.romPath)
            let desktopURL = dir.appendingPathComponent("\(game.code).desktop")
            let desktop = (try? Data(contentsOf: desktopURL)).map(DesktopFile.init(data:))
                ?? DesktopFile(string: "Exec=\(game.commandLine)\nCode=\(game.code)\nName=\(game.name)")
            sources[game.code] = SyncGameSource(code: game.code, directory: dir, desktop: desktop, isOriginal: false)
        }
        let stockDesktops = try await readStockDesktops(path: squashfsGames, codes: stockGames.map(\.code))
        for game in stockGames {
            guard let desktop = stockDesktops[game.code] else {
                report.warnings.append("\(game.name): stock menu entry not found on the console")
                continue
            }
            var cacheDir: URL?
            if settings.alwaysCopyOriginalGames {
                progress("Caching original game \(game.name)...", 0.08)
                cacheDir = try? await cacheOriginalGame(code: game.code, squashfsGames: squashfsGames)
            }
            sources[game.code] = SyncGameSource(code: game.code, directory: cacheDir, desktop: desktop, isOriginal: true)
        }

        // BuildMenu
        progress("Building menu...", 0.10)
        let options = MenuOptions(backPosition: collection.backFolderPosition, homeFolder: collection.homeFolder)
        let root: MenuCollection
        if let tree = request.customTree {
            root = tree
            root.addBack(options: options)
        } else {
            root = Self.menuRoot(customGames: customGames, stockGames: stockGames.filter { sources[$0.code] != nil },
                                 sources: sources)
            root.split(collection.foldersMode, maxElements: collection.maxGamesPerFolder, options: options)
        }

        // BuildFiles
        progress("Preparing files...", 0.14)
        let context = SyncContext(uploadPath: uploadPath, squashfsGamesPath: squashfsGames,
                                  linked: settings.syncLinked, alwaysCopyOriginals: settings.alwaysCopyOriginalGames,
                                  consoleType: consoleType, imageSet: collection.folderImagesSet)
        let build = SyncFileBuilder(context: context, games: sources).build(root: root)
        report.syncedGames = build.gameCount
        let missing = Set(build.missingRoms)
        report.gamesWithoutLocalRom = customGames.filter { missing.contains($0.code) }.map(\.name).sorted()

        // CheckRemoteStorageRequirements
        progress("Checking free space...", 0.18)
        if let stats = try await memoryStats(syncRoot: syncRoot) {
            let available = stats.availableForGames(separateMultiboot: settings.separateGamesForMultiboot,
                                                    systemCode: consoleType.syncCode)
            if build.totalSize > available {
                throw GameSyncError.notEnoughSpace(needed: build.totalSize, available: available)
            }
        } else {
            report.warnings.append("Could not read the console's free space")
        }

        // PrepareRemoteTransfer (FinishRemoteTransfer always runs afterwards)
        progress("Preparing console...", 0.20)
        await showSplashScreen()
        _ = try? await shell.execute("hakchi eval 'umount \"$gamepath\"'", timeout: 15_000)
        do {
            try await transfer(build: build, uploadPath: uploadPath,
                               syncRoot: settings.uploadToTmp ? "/tmp/upload-test" : syncRoot,
                               settings: settings, missing: missing, report: &report, progress: progress)
        } catch {
            await finishRemoteTransfer()
            throw error
        }
        progress("Restarting console menu...", 0.97)
        await finishRemoteTransfer()

        if !report.gamesWithoutLocalRom.isEmpty {
            report.warnings.append("\(report.gamesWithoutLocalRom.count) game(s) have no ROM on this Mac; their console copy was kept: "
                                   + report.gamesWithoutLocalRom.prefix(10).joined(separator: ", "))
        }
        progress("Sync complete!", 1.0)
        logger.info("Sync done: \(report.uploadedFiles) uploaded, \(report.deletedFiles) deleted, \(report.syncedGames) games")
        return report
    }

    // MARK: - Steps

    /// CalculateRemoteDiff → upload → RemoteCleanup → LinkGames → SyncConfig
    private func transfer(build: SyncBuildResult, uploadPath: String, syncRoot: String, settings: SyncSettings,
                          missing: Set<String>, report: inout Report,
                          progress: @Sendable (String, Double) -> Void) async throws {
        progress("Comparing with the console...", 0.24)
        _ = try? await shell.execute(SyncPlan.layoutCleanupCommand(syncRoot: syncRoot,
                                                                   separateMultiboot: settings.separateGamesForMultiboot),
                                     timeout: 60_000)
        _ = try? await shell.execute("find \(SyncPlan.shellQuote(uploadPath)) -type l | while read f; do rm \"$f\"; done",
                                     timeout: 60_000)
        let listing = try await shell.execute(SyncPlan.listingCommand(uploadPath: uploadPath), timeout: 120_000)
        let remote = SyncPlan.parseListing(listing.stdout)
        let diff = SyncPlan.diff(local: build.files, remote: remote, protectedCodes: missing)

        if !diff.delete.isEmpty {
            progress("Removing \(diff.delete.count) old file(s)...", 0.28)
            try await shell.runScript(SyncPlan.deleteScript(paths: diff.delete, uploadPath: uploadPath),
                                      name: "cleanup.sh", timeout: 120_000)
            report.deletedFiles = diff.delete.count
        }

        // Upload in tar batches; busybox tar keeps the stored mtimes for the next diff
        let total = max(1, diff.upload.reduce(Int64(0)) { $0 + $1.size })
        var sent: Int64 = 0
        for batch in SyncPlan.batches(diff.upload) {
            try Task.checkCancellation()
            var tar = TarWriter()
            for file in batch {
                tar.addFile(name: file.path, contents: try file.contents(),
                            modified: Date(timeIntervalSince1970: TimeInterval(file.modified)))
            }
            let label = batch.count == 1 ? (batch[0].path as NSString).lastPathComponent : "\(batch.count) files"
            progress("Uploading \(label)...", 0.30 + 0.60 * Double(sent) / Double(total))
            try await shell.uploadTar(data: tar.finalize(), to: uploadPath, timeout: 300_000)
            sent += batch.reduce(0) { $0 + $1.size }
            report.uploadedFiles += batch.count
        }
        report.uploadedBytes = sent

        progress("Cleaning up...", 0.91)
        _ = try? await shell.execute(SyncPlan.emptyDirectoryCleanupCommand(uploadPath: uploadPath), timeout: 120_000)

        progress("Linking games...", 0.93)
        _ = try? await shell.runScript(build.linkScript, name: "linkgamessync.sh", timeout: 120_000)

        progress("Saving console settings...", 0.95)
        do {
            let config = settings.console.configDictionary(isFamicom: consoleType == .famicom)
            try await ConsoleConfigService.push(config, shell: shell)
        } catch {
            report.warnings.append("Console settings were not saved: \(error.localizedDescription)")
        }
    }

    /// Root menu: selected custom games plus selected stock games (CE builds it from the checked list)
    static func menuRoot(customGames: [Game], stockGames: [Game], sources: [String: SyncGameSource]) -> MenuCollection {
        let root = MenuCollection()
        for game in customGames + stockGames {
            let desktop = sources[game.code]?.desktop
            root.add(.game(MenuGame(code: game.code, name: game.name,
                                    sortName: desktop?.sortName ?? game.sortName,
                                    isOriginal: game.isStock, system: game.system,
                                    bin: desktop?.bin ?? "", genre: game.genre, country: game.country)))
        }
        return root
    }

    /// The stock games' .desktop files from squashfs, in one round trip
    private func readStockDesktops(path: String, codes: [String]) async throws -> [String: DesktopFile] {
        guard !codes.isEmpty else { return [:] }
        let script = """
        for d in \(SyncPlan.shellQuote(path))/CLV-*; do
          c=$(basename "$d"); [ -f "$d/$c.desktop" ] || continue
          echo "@@DESKTOP@@ $c"; cat "$d/$c.desktop"; echo
        done
        """
        let result = try await shell.execute(script, timeout: 60_000)
        var desktops: [String: DesktopFile] = [:]
        for chunk in result.stdout.components(separatedBy: "@@DESKTOP@@ ").dropFirst() {
            guard let newline = chunk.firstIndex(of: "\n") else { continue }
            let code = String(chunk[..<newline]).trimmingCharacters(in: .whitespaces)
            let desktop = DesktopFile(string: String(chunk[chunk.index(after: newline)...]))
            if desktop.code.isEmpty { desktop.code = code }
            desktops[code] = desktop
        }
        return desktops
    }

    /// Download a stock game's folder once, for "always copy original games" (CE's GameCacheTask)
    private func cacheOriginalGame(code: String, squashfsGames: String) async throws -> URL {
        let dir = Self.originalGamesCacheDirectory.appendingPathComponent(code, isDirectory: true)
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        if !existing.isEmpty { return dir }
        try await shell.downloadDirectory("\(squashfsGames)/\(code)", to: dir, timeout: 120_000)
        return dir
    }

    /// Regular files under a game folder as (relative path, URL), skipping hidden files
    /// (kept for callers of the Phase 1 API)
    static func gameFiles(in dir: URL) -> [(String, URL)] {
        SyncFileBuilder.regularFiles(in: dir)
    }

    static var originalGamesCacheDirectory: URL {
        AppConfig.configDirectory.appendingPathComponent("games_cache", isDirectory: true)
    }

    private func memoryStats(syncRoot: String) async throws -> MemoryStats? {
        let df = try await shell.execute(MemoryStats.dfCommand, timeout: 15_000)
        let saves = try await shell.execute(MemoryStats.savesCommand, timeout: 30_000)
        let cols = try await shell.execute(MemoryStats.collectionsCommand(syncRoot: syncRoot), timeout: 60_000)
        return MemoryStats.parse(df: df.stdout, saves: saves.stdout, collections: cols.stdout)
    }

    /// `uistop` and show CE's "please wait" picture on the framebuffer
    private func showSplashScreen() async {
        _ = try? await shell.execute("uistop", timeout: 10_000)
        guard let url = Bundle.appBundle.url(forResource: "splash", withExtension: "gz"),
              let data = try? Data(contentsOf: url) else { return }
        _ = try? await shell.execute("gunzip -c - > /dev/fb0", input: data, name: "splash.gz", timeout: 10_000)
    }

    private func finishRemoteTransfer() async {
        _ = try? await shell.execute("hakchi overmount_games; uistart", timeout: 30_000)
    }

    private func output(_ command: String, fallback: String) async -> String {
        let value = (try? await shell.execute(command, timeout: 10_000))?.output ?? ""
        return value.isEmpty || value.contains(" ") ? fallback : value
    }
}

enum GameSyncError: LocalizedError {
    case notEnoughSpace(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed, let available):
            let f = ByteCountFormatter()
            return "Not enough space on the console: the games need \(f.string(fromByteCount: needed)), "
                + "\(f.string(fromByteCount: max(0, available))) is available."
        }
    }
}
