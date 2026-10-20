import Foundation
import os

/// Local game folders (port of Hakchi2-CE's `GamesDirectory` and related paths).
///
/// With "Separate games storage" on, SNES-family consoles use `games_snes/` and the
/// Mega Drive uses `games_md/`; everything else (and the default) uses `games/`.
enum LibraryStorage {
    /// Mirrors `LibrarySettings.values.separateGameLocalStorage`, readable from any thread
    /// (AppConfig.gamesDirectory is used off the main actor)
    private static let separateFlag = OSAllocatedUnfairLock(initialState: false)

    static var separateLocalStorage: Bool {
        get { separateFlag.withLock { $0 } }
        set { separateFlag.withLock { $0 = newValue } }
    }

    /// Folder name for a console's local games
    static func gamesFolderName(for consoleType: ConsoleType, separate: Bool = separateLocalStorage) -> String {
        guard separate else { return "games" }
        if consoleType == .megaDrive { return "games_md" }
        if consoleType.isSNES { return "games_snes" }
        return "games"
    }

    /// `art/`: local box-art library used for automatic cover matching
    static var artDirectory: URL {
        AppConfig.configDirectory.appendingPathComponent("art", isDirectory: true)
    }

    /// `games_originals/`: editable copies of the stock games' .desktop files
    static var originalGamesDirectory: URL {
        AppConfig.configDirectory.appendingPathComponent("games_originals", isDirectory: true)
    }

    /// `info/`: user-supplied libretro core info files
    static var coreInfoDirectory: URL {
        AppConfig.configDirectory.appendingPathComponent("info", isDirectory: true)
    }
}
