import Foundation
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "GameCores")

/// Emulation core assignment (port of Hakchi2-CE's `SelectCoreDialog` apply logic).
extension GameManagerService {
    /// How the new command line is built
    enum CoreCommand: Equatable {
        /// Keep the current Exec (core "Unassigned")
        case keep
        /// `<core launcher> <rom> <current args>` or, with `resetArgs`, the core's default args
        case core(CoreInfo, resetArgs: Bool)
        /// Exact text typed by the user (single game only)
        case custom(String)
    }

    /// Build the command line a game would get, without saving anything
    func previewCommand(for game: Game, command: CoreCommand) -> String {
        let desktop = loadDesktop(for: game) ?? DesktopFile(string: "Exec=\(game.commandLine)")
        return Self.buildExec(desktop: desktop, command: command, romFallback: romFallbackPath(for: game))
    }

    /// Assign a system and core to games and rewrite their Exec lines.
    func applyCore(to codes: [String], system: String, coreBin: String, command: CoreCommand) {
        let gamesDir = AppConfig.shared.gamesDirectory
        for code in codes {
            guard let index = games.firstIndex(where: { $0.id == code && $0.source == .local }) else { continue }
            let gameDir = gamesDir.appendingPathComponent(code)
            let desktopURL = gameDir.appendingPathComponent("\(code).desktop")
            guard let desktop = loadDesktop(for: games[index]) else { continue }

            desktop.exec = Self.buildExec(desktop: desktop, command: command,
                                          romFallback: romFallbackPath(for: games[index]))
            desktop.normalizeForSave()
            do {
                try desktop.toData().write(to: desktopURL)
                var meta = GameMetadata.load(gameDirectory: gameDir, exec: desktop.exec)
                meta.system = system
                meta.core = coreBin
                try meta.save(gameDirectory: gameDir)
            } catch {
                logger.error("Could not save core for \(code): \(error.localizedDescription)")
                continue
            }

            games[index].commandLine = desktop.exec
            games[index].system = system
            games[index].core = coreBin
            logger.info("Core for \(code): \(coreBin.isEmpty ? "-" : coreBin) → \(desktop.exec)")
        }
    }

    // MARK: - Helpers

    /// Exec for a game under `command`. `romFallback` is used when the current
    /// Exec has no arguments (CE crashed in that case).
    static func buildExec(desktop: DesktopFile, command: CoreCommand, romFallback: String?) -> String {
        let args = desktop.args
        let rom = args.first ?? romFallback ?? ""
        let rest = args.dropFirst().joined(separator: " ")

        switch command {
        case .keep:
            return desktop.exec
        case .custom(let text):
            return text.trimmingCharacters(in: .whitespaces)
        case .core(let core, let resetArgs):
            let tail = resetArgs ? core.defaultArgs : rest
            return [core.qualifiedBin, rom, tail]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    private func loadDesktop(for game: Game) -> DesktopFile? {
        let url = AppConfig.shared.gamesDirectory
            .appendingPathComponent(game.code)
            .appendingPathComponent("\(game.code).desktop")
        return (try? Data(contentsOf: url)).map(DesktopFile.init(data:))
    }

    /// "/var/games/CODE/<rom file>" from the files in the game folder, for games
    /// whose Exec lost its ROM argument
    private func romFallbackPath(for game: Game) -> String? {
        let dir = AppConfig.shared.gamesDirectory.appendingPathComponent(game.code)
        let skip: Set<String> = ["desktop", "png", "jpg", "json", "txt"]
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        guard let rom = files.sorted().first(where: { name in
            !name.hasPrefix(".") && !skip.contains((name as NSString).pathExtension.lowercased())
        }) else { return nil }
        return "/var/games/\(game.code)/\(rom)"
    }
}
