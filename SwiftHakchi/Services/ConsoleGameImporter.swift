import Foundation
import SWCompression
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "ConsoleImport")

/// Finds custom games on the console and copies them into the library
/// (port of Hakchi2-CE's `GameImporterForm.FindGamesTask` / `GameCopyTask`).
enum ConsoleGameImporter {
    /// A game found on the console
    struct FoundGame: Identifiable, Sendable {
        /// Folder holding the game's files on the console
        let remotePath: String
        let code: String
        let name: String
        /// .desktop with paths already rebased to /var/games
        let desktopText: String
        var size: Int64

        var id: String { remotePath }
    }

    /// Scan the console's game folders for CLV-*.desktop files.
    /// Stock games (`stockCodes`) and menu folders (`/bin/chmenu`) are skipped.
    static func findGames(shell: SSHService, stockCodes: Set<String>) async throws -> [FoundGame] {
        let mountpoint = (try? await shell.execute("hakchi get mountpoint", timeout: 10_000))?.output ?? ""
        var rootfs = (try? await shell.execute("hakchi get rootfs", timeout: 10_000))?.output ?? ""
        if rootfs.isEmpty { rootfs = "/var/lib/hakchi/rootfs" }
        let searchPaths = ["\(rootfs)/usr/share/games", "\(mountpoint)/var/lib/hakchi/games",
                           "\(mountpoint)/media/hakchi/games"]
        let paths = searchPaths.map(SyncPlan.shellQuote).joined(separator: " ")

        let tar = try await shell.execute("find \(paths) -name \"CLV-*.desktop\" 2>/dev/null | sort | tar -cf - -T -",
                                          timeout: 120_000)
        guard !tar.stdoutData.isEmpty else { return [] }
        let du = try await shell.execute("du \(paths) 2>/dev/null", timeout: 120_000)

        var found = parse(desktopTar: tar.stdoutData, mountpoint: mountpoint, stockCodes: stockCodes)
        let sizes = parseDu(du.stdout)
        for i in found.indices {
            found[i].size = sizes[found[i].remotePath] ?? 0
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Turn the tar of .desktop files into found games (pure, testable)
    static func parse(desktopTar: Data, mountpoint: String, stockCodes: Set<String>) -> [FoundGame] {
        guard let entries = try? TarContainer.open(container: desktopTar) else { return [] }
        var result: [String: FoundGame] = [:]
        for entry in entries where entry.info.type == .regular {
            guard let data = entry.data else { continue }
            var key = "/" + (entry.info.name as NSString).deletingLastPathComponent
            while key.hasPrefix("//") { key.removeFirst() }
            let desktop = DesktopFile(data: data)
            if desktop.code.isEmpty {
                desktop.code = ((entry.info.name as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            // Linked game: the menu entry points at the files in .storage
            if desktop.iconPath.hasSuffix("/.storage") {
                key = "\(mountpoint)\(desktop.iconPath)/\(desktop.code)"
            }
            guard !stockCodes.contains(desktop.code), desktop.bin != "/bin/chmenu" else { continue }

            if !desktop.iconPath.isEmpty {
                desktop.exec = desktop.exec.replacingOccurrences(of: desktop.iconPath, with: "/var/games")
            }
            desktop.rebaseGamePaths(to: "/var/games")
            desktop.iconPath = "/var/games"
            desktop.profilePath = "/var/saves"
            result[key] = FoundGame(remotePath: key, code: desktop.code,
                                    name: desktop.name.isEmpty ? desktop.code : desktop.name,
                                    desktopText: desktop.serialize(), size: 0)
        }
        return Array(result.values)
    }

    /// `du` output ("<KiB>\t<path>") → bytes per path
    static func parseDu(_ text: String) -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count == 2, let kib = Int64(parts[0]) else { continue }
            sizes[String(parts[1]).trimmingCharacters(in: .whitespaces)] = kib * 1024
        }
        return sizes
    }

    /// Copy one game into `gamesDirectory/CODE` (replacing an existing copy), write its
    /// rebased .desktop and metadata.json. Files come over as a tar stream (binary-safe).
    @MainActor
    static func copy(_ game: FoundGame, shell: SSHService, gamesDirectory: URL, cores: CoreCatalog) async throws -> URL {
        let destination = gamesDirectory.appendingPathComponent(game.code, isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try await shell.downloadDirectory(game.remotePath, to: destination, timeout: 120_000)

        let desktop = DesktopFile(string: game.desktopText)
        desktop.normalizeForSave()
        try desktop.toData().write(to: destination.appendingPathComponent("\(game.code).desktop"))

        var meta = GameMetadata.load(gameDirectory: destination, exec: desktop.exec)
        if meta.core.isEmpty { meta.core = cores.core(forExec: desktop.exec)?.bin ?? "" }
        try meta.save(gameDirectory: destination)
        logger.info("Imported \(game.code) from \(game.remotePath)")
        return destination
    }
}
