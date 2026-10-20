import Foundation

/// A game genre as the console menus know it (port of Hakchi2-CE's `data/Genre.cs`).
/// `desktopName` is the value written to `sortRawGenre=` in `.desktop` files.
struct Genre: Hashable, Sendable, Identifiable {
    let desktopName: String
    let englishName: String
    /// Folder icon used when grouping games by genre
    let folderImageId: String
    /// TheGamesDB genre IDs that map to this genre
    let gamesDbIds: [Int]

    var id: String { desktopName }

    init(_ desktopName: String, english: String? = nil, folderImage: String, gamesDb: [Int] = []) {
        self.desktopName = desktopName
        self.englishName = english ?? desktopName
        self.folderImageId = folderImage
        self.gamesDbIds = gamesDb
    }
}

/// Region of a game (`country=` key; CE's `data/Region.cs`)
struct GameRegion: Hashable, Sendable, Identifiable {
    let desktopName: String
    let englishName: String
    /// Region names seen in databases that map to this region
    let defaultNames: [String]

    var id: String { desktopName }
}

enum GenreCatalog {
    static let all: [Genre] = [
        Genre("Action", folderImage: "genre_action", gamesDb: [1]),
        Genre("ActionShooting", english: "Action / Shooting", folderImage: "genre_shooting", gamesDb: [8]),
        Genre("Adventure", folderImage: "genre_adventure", gamesDb: [2]),
        Genre("Educational", folderImage: "genre_educational"),
        Genre("Fighting", folderImage: "genre_fighting", gamesDb: [10]),
        Genre("Puzzle", folderImage: "genre_puzzle", gamesDb: [5]),
        Genre("Racing", folderImage: "genre_racing", gamesDb: [7]),
        Genre("RacingSports", english: "Racing / Sports", folderImage: "genre_racing_sports"),
        Genre("RPG", folderImage: "genre_rpg", gamesDb: [4, 14]),
        Genre("Shoot-'em-Up", folderImage: "genre_shootemup", gamesDb: [8]),
        Genre("Simulation", folderImage: "genre_simulation", gamesDb: [3, 9, 13, 19]),
        Genre("Sports", folderImage: "genre_sports", gamesDb: [11]),
        Genre("Table", folderImage: "genre_table"),
    ]

    static let regions: [GameRegion] = [
        GameRegion(desktopName: "us", englishName: "United States", defaultNames: ["United States", "US", "USA"]),
        GameRegion(desktopName: "eu", englishName: "Europe",
                   defaultNames: ["Europe", "France", "Germany", "Spain", "Italy", "Sweden", "Netherlands",
                                  "Scandinavia", "United Kingdom", "UK"]),
        GameRegion(desktopName: "jp", englishName: "Japan", defaultNames: ["Japan"]),
    ]

    static func genre(desktopName: String) -> Genre? {
        all.first { $0.desktopName.caseInsensitiveCompare(desktopName) == .orderedSame }
    }

    /// First genre that lists any of the TheGamesDB IDs (CE picks the first match too)
    static func genre(forGamesDbIds ids: [Int]) -> Genre? {
        for id in ids {
            if let genre = all.first(where: { $0.gamesDbIds.contains(id) }) { return genre }
        }
        return nil
    }

    /// Normalize a stored genre value: known names stay, TheGamesDB ID lists
    /// written by older versions ("1, 8") become a genre name, anything else is kept
    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if genre(desktopName: trimmed) != nil { return genre(desktopName: trimmed)!.desktopName }
        let ids = trimmed.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if !ids.isEmpty, ids.count == trimmed.split(separator: ",").count {
            return genre(forGamesDbIds: ids)?.desktopName ?? ""
        }
        return trimmed
    }

    static func region(desktopName: String) -> GameRegion? {
        regions.first { $0.desktopName == desktopName.lowercased() }
    }

    /// Region from a database name such as "USA" or "Germany"
    static func region(forName name: String) -> GameRegion? {
        regions.first { r in r.defaultNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }
}
