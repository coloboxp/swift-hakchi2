import Foundation

/// Folder names shown on the console (CE's English resource strings)
enum MenuFolderNames {
    static let back = "Back"
    static let moreGames = "More games..."
    static let originalGames = "Original games"
    static let home = "Home"
    static let newFolder = "New folder"
    static let unsorted = "Unsorted"
    static let trashBin = "Recycle Bin"
    static let mainMenu = "Main menu"
}

/// A game in the console menu tree
final class MenuGame {
    let code: String
    var name: String
    var sortName: String
    /// Stock game from the console's squashfs
    let isOriginal: Bool
    /// libretro system name ("" when unknown)
    var system: String
    /// Exec program (CE groups by it when the system is unknown)
    var bin: String
    var genre: String
    var country: String

    init(code: String, name: String, sortName: String, isOriginal: Bool,
         system: String = "", bin: String = "", genre: String = "", country: String = "") {
        self.code = code
        self.name = name
        self.sortName = sortName.isEmpty ? name.lowercased() : sortName
        self.isOriginal = isOriginal
        self.system = system
        self.bin = bin
        self.genre = genre
        self.country = country
    }
}

/// A folder in the console menu tree (port of CE's `NesMenuFolder`)
final class MenuFolder {
    var name: String
    var imageId: String
    var position: FolderPriority
    var child: MenuCollection
    /// Index of `child` in the list of all menus (sets the CLV-S-NNNNN code); set while building files
    var childIndex = 0

    init(name: String = "Folder", imageId: String = "folder", position: FolderPriority = .right,
         child: MenuCollection = MenuCollection()) {
        self.name = name
        self.imageId = imageId
        self.position = position
        self.child = child
    }

    var code: String { String(format: "CLV-S-%05d", childIndex) }

    /// "First - Last" name parts, as CE splits the name on "-"
    var nameParts: [String] {
        get {
            guard !name.isEmpty else { return ["", ""] }
            let parts = name.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count < 2 ? ["", ""] : parts
        }
        set { name = newValue.joined(separator: " - ") }
    }

    /// The .desktop CE writes for a folder: chmenu into the child menu, sort fields by position
    func desktopFile() -> DesktopFile {
        let d = DesktopFile()
        d.code = code
        d.name = name
        d.exec = String(format: "/bin/chmenu %03d /var/games", childIndex)
        d.profilePath = "/var/saves/FOLDER"
        d.omitProfilePathCode = true
        d.iconPath = "/var/games"
        d.iconFilename = "\(code).png"
        d.testId = 777

        let prefix: Character
        switch position {
        case .leftBack:
            prefix = "\u{01}"; d.players = 2; d.simultaneous = true
            d.releaseDate = "0000-00-00"; d.publisher = String(repeating: "\u{01}", count: 10)
        case .leftmost:
            prefix = "\u{02}"; d.players = 2; d.simultaneous = true
            d.releaseDate = "0001-11-11"; d.publisher = String(repeating: "\u{02}", count: 10)
        case .left:
            prefix = "\u{03}"; d.players = 2; d.simultaneous = true
            d.releaseDate = "0002-22-22"; d.publisher = String(repeating: "\u{03}", count: 10)
        case .right:
            prefix = "Э"; d.players = 1; d.simultaneous = false
            d.releaseDate = "7777-77-77"; d.publisher = String(repeating: "Z", count: 9) + "X"
        case .rightmost:
            prefix = "Ю"; d.players = 1; d.simultaneous = false
            d.releaseDate = "8888-88-88"; d.publisher = String(repeating: "Z", count: 9) + "Y"
        case .back:
            prefix = "Я"; d.players = 1; d.simultaneous = false
            d.releaseDate = "9999-99-99"; d.publisher = String(repeating: "Z", count: 10)
        }
        d.sortName = String(prefix) + (name.isEmpty ? code : name).lowercased()
        return d
    }
}

/// An entry of a menu: a game or a folder
enum MenuElement {
    case game(MenuGame)
    case folder(MenuFolder)

    var name: String {
        switch self {
        case .game(let g): return g.name
        case .folder(let f): return f.name
        }
    }

    /// CE: games sort by their sort name, folders by their name
    var sortName: String {
        switch self {
        case .game(let g): return g.sortName
        case .folder(let f): return f.name
        }
    }

    var game: MenuGame? {
        if case .game(let g) = self { return g }
        return nil
    }

    var folder: MenuFolder? {
        if case .folder(let f) = self { return f }
        return nil
    }

    /// Same object (folders and games are reference types)
    func isSame(_ other: MenuElement) -> Bool {
        switch (self, other) {
        case (.game(let a), .game(let b)): return a === b
        case (.folder(let a), .folder(let b)): return a === b
        default: return false
        }
    }
}

/// Options that come from the collection settings
struct MenuOptions: Sendable {
    var backPosition: FolderPriority = .back
    var homeFolder = false
}

/// A menu (one console screen or page list); port of CE's `NesMenuCollection`
final class MenuCollection {
    var elements: [MenuElement]

    init(_ elements: [MenuElement] = []) {
        self.elements = elements
    }

    var count: Int { elements.count }
    var games: [MenuGame] { elements.compactMap(\.game) }
    var folders: [MenuFolder] { elements.compactMap(\.folder) }

    func add(_ element: MenuElement) { elements.append(element) }

    func remove(_ element: MenuElement) {
        elements.removeAll { $0.isSame(element) }
    }

    private static let alphaNum = try! NSRegularExpression(pattern: #"[^\p{L}\p{Nd}0-9]"#)

    private static func stripNonAlphaNum(_ s: String) -> String {
        alphaNum.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    /// Stable sort by sort name (CE's OrderBy)
    static func sortedBySortName(_ list: [MenuElement]) -> [MenuElement] {
        list.enumerated().sorted { a, b in
            let order = a.element.sortName.localizedCaseInsensitiveCompare(b.element.sortName)
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)
    }

    private func backFolder(to target: MenuCollection, options: MenuOptions,
                            name: String = MenuFolderNames.back) -> MenuElement {
        .folder(MenuFolder(name: name, imageId: "folder_back", position: options.backPosition, child: target))
    }

    // MARK: - Split

    /// Split this menu into pages or folders (CE's `NesMenuCollection.Split`)
    func split(_ inputStyle: SplitStyle, maxElements: Int = 35, options: MenuOptions = MenuOptions()) {
        var style = inputStyle
        var originalToRoot = false
        var originalCount = 0
        switch style {
        case .originalNoSplit, .originalAuto, .originalFoldersAlphabeticFoldersEqual,
             .originalFoldersAlphabeticPagesEqual, .originalFoldersEqual, .originalPagesEqual:
            style = SplitStyle(rawValue: style.rawValue - 1)!
            originalCount = games.filter(\.isOriginal).count
            if originalCount > 0 { originalToRoot = true }
        default:
            break
        }
        if style == .noSplit && !originalToRoot { return }
        if [.auto, .foldersEqual, .pagesEqual].contains(style) && !originalToRoot && count <= maxElements { return }

        let total = count - originalCount
        let maxElements = max(1, maxElements)
        let partsCount = max(1, Int(ceil(Double(total) / Double(maxElements))))
        let perPart = max(1, Int(ceil(Double(total) / Double(partsCount))))

        let root: MenuCollection
        if !originalToRoot {
            root = self
        } else {
            root = MenuCollection(elements.filter { $0.game.map { !$0.isOriginal } ?? false })
            if root.count == 0 { return }
            elements.removeAll { e in root.elements.contains { $0.isSame(e) } }
            add(.folder(MenuFolder(name: MenuFolderNames.moreGames, position: .rightmost, child: root)))
        }

        let sorted = Self.sortedBySortName(root.elements)
        var collections: [MenuCollection] = []
        if [.auto, .foldersEqual, .pagesEqual].contains(style) {
            var collection = MenuCollection()
            for (i, game) in sorted.enumerated() {
                collection.add(game)
                if (i + 1) % perPart == 0 || i + 1 == sorted.count {
                    collections.append(collection)
                    collection = MenuCollection()
                }
            }
        }

        if style == .auto {
            style = collections.count >= 12 ? .foldersEqual : .pagesEqual
        }

        func partNames(_ c: MenuCollection) -> [String] {
            let games = c.games
            return [Self.stripNonAlphaNum(games.first?.sortName.uppercased() ?? ""),
                    Self.stripNonAlphaNum(games.last?.sortName.uppercased() ?? "")]
        }

        switch style {
        case .foldersEqual:
            root.elements.removeAll()
            for coll in collections {
                let folder = MenuFolder(position: .right, child: coll)
                folder.nameParts = partNames(coll)
                coll.add(backFolder(to: root, options: options))
                root.add(.folder(folder))
            }
            Self.trimFolderNames(root)

        case .pagesEqual:
            root.elements.removeAll()
            root.elements.append(contentsOf: collections.first?.elements ?? [])
            if !collections.isEmpty { collections[0] = root }
            for i in collections.indices {
                for j in stride(from: i - 1, through: 0, by: -1) {
                    let folder = MenuFolder(position: .left, child: collections[j])
                    folder.nameParts = partNames(collections[j])
                    collections[i].elements.insert(.folder(folder), at: 0)
                }
                for j in (i + 1)..<collections.count {
                    let folder = MenuFolder(position: .right, child: collections[j])
                    folder.nameParts = partNames(collections[j])
                    collections[i].elements.append(.folder(folder))
                }
                Self.trimFolderNames(collections[i])
            }

        case .foldersAlphabeticPagesEqual, .foldersAlphabeticFoldersEqual:
            var letters: [(Character, MenuCollection)] = (65...90).map { (Character(UnicodeScalar($0)), MenuCollection()) }
            letters.append(("#", MenuCollection()))
            for element in root.elements {
                guard let game = element.game else { continue }
                var letter = game.sortName.uppercased().first ?? "#"
                if !(letter >= "A" && letter <= "Z") { letter = "#" }
                letters.first { $0.0 == letter }?.1.add(element)
            }
            root.elements.removeAll()
            for (letter, coll) in letters where coll.count > 0 {
                let imageId = letter == "#" ? "folder_number" : "folder_" + String(letter).lowercased()
                let folder = MenuFolder(name: String(letter), imageId: imageId, position: .right, child: coll)
                if style == .foldersAlphabeticPagesEqual {
                    coll.split(.pagesEqual, maxElements: maxElements, options: options)
                    coll.add(backFolder(to: root, options: options))
                    for f in coll.folders where f.child !== root {
                        f.child.add(backFolder(to: root, options: options))
                    }
                } else {
                    coll.split(.foldersEqual, maxElements: maxElements, options: options)
                    coll.add(backFolder(to: root, options: options))
                }
                root.add(.folder(folder))
            }

        case .foldersGroupByApp, .foldersGroupByGenre, .foldersGroupByRegion:
            var groups: [String: MenuCollection] = [:]
            for element in root.elements {
                guard let game = element.game else { continue }
                let key: String
                switch style {
                case .foldersGroupByApp:
                    key = !game.system.isEmpty ? game.system : (!game.bin.isEmpty ? game.bin : SystemCatalog.unknown.name)
                case .foldersGroupByGenre:
                    key = game.genre.isEmpty ? "Unknown Genre" : game.genre
                default:
                    key = game.country.isEmpty ? "Unknown Region" : game.country
                }
                // Store the collection explicitly: a class value from `default:` is not written back
                let group = groups[key] ?? MenuCollection()
                group.add(element)
                groups[key] = group
            }
            root.elements.removeAll()
            // SortedDictionary in CE: ordinal key order
            for key in groups.keys.sorted() {
                let coll = groups[key]!
                var name = key
                var imageId = "folder"
                if style == .foldersGroupByGenre, let genre = MenuGenre.byDesktopName[key] {
                    name = genre.englishName
                    imageId = genre.folderImageId
                } else if style == .foldersGroupByRegion, let region = MenuRegion.names[key] {
                    name = region
                }
                coll.add(backFolder(to: root, options: options))
                root.add(.folder(MenuFolder(name: name, imageId: imageId, position: .right, child: coll)))
            }

        default:
            break
        }

        if originalToRoot {
            if style != .pagesEqual {
                root.add(backFolder(to: self, options: options, name: MenuFolderNames.originalGames))
            } else {
                for collection in collections {
                    collection.add(backFolder(to: self, options: options, name: MenuFolderNames.originalGames))
                }
            }
        }
    }

    // MARK: - Unsplit / back folders

    /// Flatten folders back into this menu (CE's `Unsplit`); back links are dropped
    func unsplit(ignoring ignore: inout [MenuCollection]) {
        ignore.append(self)
        var newElements: [MenuElement] = []
        var oldElements: [MenuElement] = []
        for element in elements {
            guard let folder = element.folder else { continue }
            if ignore.contains(where: { $0 === folder.child }) { continue }
            folder.child.unsplit(ignoring: &ignore)
            newElements.append(contentsOf: folder.child.elements)
            folder.child.elements.removeAll()
            oldElements.append(element)
        }
        elements.append(contentsOf: newElements)
        elements.removeAll { e in oldElements.contains { $0.isSame(e) } }
        // Back folders point at menus already visited; remove them too
        elements.removeAll { e in
            guard let f = e.folder else { return false }
            return ignore.contains { $0 === f.child }
        }
    }

    func unsplit() {
        var ignore: [MenuCollection] = []
        unsplit(ignoring: &ignore)
    }

    /// Add "Back" (and optionally "Home") folders to every sub-menu (CE's `AddBack`),
    /// used for trees made in the Folders Manager
    func addBack(options: MenuOptions) {
        var ignore: [MenuCollection] = []
        addBack(options: options, ignore: &ignore, isRoot: true)
    }

    private func addBack(options: MenuOptions, ignore: inout [MenuCollection], isRoot: Bool) {
        ignore.append(self)
        for folder in folders {
            if ignore.contains(where: { $0 === folder.child }) { continue }
            folder.child.addBack(options: options, ignore: &ignore, isRoot: false)
            folder.child.add(backFolder(to: self, options: options))
            if !isRoot && options.homeFolder, let rootMenu = ignore.first {
                folder.child.add(.folder(MenuFolder(name: MenuFolderNames.home, imageId: "folder_home",
                                                    position: options.backPosition, child: rootMenu)))
            }
        }
    }

    // MARK: - Folder names

    /// Shorten "First - Last" folder names to 3–8 letters that still tell
    /// neighbours apart (CE's `TrimFolderNames`)
    static func trimFolderNames(_ collection: MenuCollection) {
        let minChars = 3
        let maxChars = 8
        let folders = collection.folders.enumerated().sorted { a, b in
            let order = a.element.name.localizedCaseInsensitiveCompare(b.element.name)
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)

        func prefix(_ s: String, _ n: Int) -> String { String(s.prefix(max(0, n))) }

        if folders.count > 1 {
            for i in 1..<folders.count {
                let prev = folders[i - 1], current = folders[i]
                var nameA = prev.nameParts[1]
                var nameB = current.nameParts[0]
                var l = min(maxChars - 1, max(nameA.count, nameB.count))
                while prefix(nameA, min(l, nameA.count)) != prefix(nameB, min(l, nameB.count)) && l >= minChars {
                    l -= 1
                }
                nameA = prefix(nameA, min(l + 1, nameA.count))
                nameB = prefix(nameB, min(l + 1, nameB.count))
                if nameA == nameB {  // no point in a long name
                    nameA = prefix(nameA, min(minChars, nameA.count))
                    nameB = nameA
                }
                prev.nameParts = [prev.nameParts[0], nameA]
                current.nameParts = [nameB, current.nameParts[1]]
            }
        }
        if let first = folders.first {
            first.nameParts = [prefix(first.nameParts[0], min(first.nameParts[0].count, minChars)), first.nameParts[1]]
        }
        if let last = folders.last {
            last.nameParts = [last.nameParts[0], prefix(last.nameParts[1], min(last.nameParts[1].count, minChars))]
        }
    }
}

/// Genres known to hakchi (CE's `data/Genre.cs`): desktop name → folder name and image
struct MenuGenre {
    let desktopName: String
    let englishName: String
    let folderImageId: String

    static let all: [MenuGenre] = [
        MenuGenre(desktopName: "Action", englishName: "Action", folderImageId: "genre_action"),
        MenuGenre(desktopName: "ActionShooting", englishName: "Action / Shooting", folderImageId: "genre_shooting"),
        MenuGenre(desktopName: "Adventure", englishName: "Adventure", folderImageId: "genre_adventure"),
        MenuGenre(desktopName: "Educational", englishName: "Educational", folderImageId: "genre_educational"),
        MenuGenre(desktopName: "Fighting", englishName: "Fighting", folderImageId: "genre_fighting"),
        MenuGenre(desktopName: "Puzzle", englishName: "Puzzle", folderImageId: "genre_puzzle"),
        MenuGenre(desktopName: "Racing", englishName: "Racing", folderImageId: "genre_racing"),
        MenuGenre(desktopName: "RacingSports", englishName: "Racing / Sports", folderImageId: "genre_racing_sports"),
        MenuGenre(desktopName: "RPG", englishName: "RPG", folderImageId: "genre_rpg"),
        MenuGenre(desktopName: "Shoot-'em-Up", englishName: "Shoot-'em-Up", folderImageId: "genre_shootemup"),
        MenuGenre(desktopName: "Simulation", englishName: "Simulation", folderImageId: "genre_simulation"),
        MenuGenre(desktopName: "Sports", englishName: "Sports", folderImageId: "genre_sports"),
        MenuGenre(desktopName: "Table", englishName: "Table", folderImageId: "genre_table"),
    ]

    static let byDesktopName: [String: MenuGenre] = Dictionary(uniqueKeysWithValues: all.map { ($0.desktopName, $0) })
}

/// Region names (CE's `data/Region.cs`)
enum MenuRegion {
    static let names: [String: String] = ["us": "United States", "eu": "Europe", "jp": "Japan"]
}
