import Foundation

/// Groups for the games explorer (Hakchi2-CE's View menu: original games position,
/// sort by name/core/console/region, group games without box art).
struct ExplorerSection: Identifiable, Equatable {
    let title: String
    let games: [Game]
    var id: String { title }
}

enum ExplorerGrouping {
    /// `games` should already be filtered by the search text
    @MainActor
    static func sections(for games: [Game], settings: LibrarySettings.Values,
                         coreName: (Game) -> String) -> [ExplorerSection] {
        let byName = { (a: Game, b: Game) in a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
        var originals = games.filter(\.isStock).sorted(by: byName)
        var others = games.filter { !$0.isStock }.sorted(by: byName)

        switch settings.originalGamesPosition {
        case .hidden: originals = []
        case .sorted: others = (others + originals).sorted(by: byName); originals = []
        case .atTop, .atBottom: break
        }

        var noArt: [Game] = []
        if settings.groupGamesWithoutCoverArt {
            noArt = others.filter { !hasCover($0) }
            others.removeAll { !hasCover($0) }
        }

        var middle: [ExplorerSection]
        switch settings.gamesSorting {
        case .name:
            middle = others.isEmpty ? [] : [ExplorerSection(title: originals.isEmpty ? "" : "Custom Games", games: others)]
        case .core:
            middle = grouped(others) { coreName($0) }
        case .system:
            middle = grouped(others) { $0.system.isEmpty ? "Unknown System" : $0.system }
        case .region:
            middle = grouped(others) { GenreCatalog.region(desktopName: $0.country)?.englishName ?? "Unknown Region" }
        }

        var result: [ExplorerSection] = []
        let originalSection = originals.isEmpty ? nil : ExplorerSection(title: "Original Games", games: originals)
        if settings.originalGamesPosition == .atTop, let originalSection { result.append(originalSection) }
        result.append(contentsOf: middle)
        if !noArt.isEmpty { result.append(ExplorerSection(title: "No Box Art", games: noArt)) }
        if settings.originalGamesPosition == .atBottom, let originalSection { result.append(originalSection) }
        return result
    }

    private static func grouped(_ games: [Game], key: (Game) -> String) -> [ExplorerSection] {
        Dictionary(grouping: games, by: key)
            .map { ExplorerSection(title: $0.key, games: $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private static func hasCover(_ game: Game) -> Bool {
        guard let path = game.coverArtPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
}
