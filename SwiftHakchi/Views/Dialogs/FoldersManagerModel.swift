import Foundation
import Combine

/// Editing state of the Folders Manager (port of CE's `FoldersManagerForm` logic)
@MainActor
final class FoldersManagerModel: ObservableObject {
    /// One row of the tree
    struct Node: Identifiable, Hashable {
        let id: ObjectIdentifier
        let element: MenuElement
        static func == (a: Node, b: Node) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
        var children: [Node]?
        var isFolder: Bool { element.folder != nil }
    }

    let console: ConsoleType
    @Published private(set) var root: MenuCollection
    /// Bumped after every change so views re-read the tree
    @Published private(set) var revision = 0
    @Published var selection: Set<ObjectIdentifier> = []
    @Published private(set) var cut: Set<ObjectIdentifier> = []
    @Published var needsSave = false
    /// Games deleted from the Recycle Bin; deselected in the library on save
    private(set) var deletedGames: [MenuGame] = []
    var backPosition: FolderPriority
    var homeFolder: Bool
    var maxGamesPerFolder: Int
    /// Message after loading (e.g. new games put into "Unsorted")
    @Published var notice: String?

    /// `loadSaved`: start from the saved folders file of this console (false = flat list)
    init(console: ConsoleType, games: [MenuGame], settings: CollectionSettings, loadSaved: Bool = true) {
        self.console = console
        backPosition = settings.backFolderPosition == .leftBack ? .leftBack : .back
        homeFolder = settings.homeFolder
        maxGamesPerFolder = settings.maxGamesPerFolder
        if loadSaved, let loaded = try? FolderTreeStore.load(console: console, games: games) {
            root = loaded.root
            if loaded.unsorted > 0 { notice = "New games are moved to the \"Unsorted\" folder." }
        } else {
            root = MenuCollection(games.map { .game($0) })
        }
    }

    // MARK: - Tree

    /// Rows for the outline: folders by position, then by name (CE's sort), back links hidden
    var nodes: [Node] { nodes(of: root, ancestors: [root]) }

    private func nodes(of menu: MenuCollection, ancestors: [MenuCollection]) -> [Node] {
        sorted(menu.elements).compactMap { element in
            switch element {
            case .game(let g):
                return Node(id: ObjectIdentifier(g), element: element, children: nil)
            case .folder(let f):
                if ancestors.contains(where: { $0 === f.child }) { return nil }  // back link
                return Node(id: ObjectIdentifier(f), element: element,
                            children: nodes(of: f.child, ancestors: ancestors + [f.child]))
            }
        }
    }

    func sorted(_ list: [MenuElement]) -> [MenuElement] {
        list.sorted { a, b in
            let pa = a.folder.map { $0.position.rawValue } ?? 2
            let pb = b.folder.map { $0.position.rawValue } ?? 2
            if pa != pb { return pa < pb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Element and the menu that holds it
    func find(_ id: ObjectIdentifier) -> (element: MenuElement, parent: MenuCollection)? {
        func search(_ menu: MenuCollection, _ visited: [MenuCollection]) -> (MenuElement, MenuCollection)? {
            for element in menu.elements {
                switch element {
                case .game(let g) where ObjectIdentifier(g) == id: return (element, menu)
                case .folder(let f):
                    if ObjectIdentifier(f) == id { return (element, menu) }
                    if visited.contains(where: { $0 === f.child }) { continue }
                    if let hit = search(f.child, visited + [f.child]) { return hit }
                default: continue
                }
            }
            return nil
        }
        return search(root, [root])
    }

    /// The menu new items go into: the selected folder, the folder of the selected game, or root
    var targetMenu: MenuCollection {
        guard let id = selection.first, let hit = find(id) else { return root }
        return hit.element.folder?.child ?? hit.parent
    }

    var selectedFolder: MenuFolder? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return find(id)?.element.folder
    }

    private func changed() {
        needsSave = true
        revision += 1
    }

    // MARK: - Editing

    @discardableResult
    func newFolder(in menu: MenuCollection? = nil) -> MenuFolder {
        let folder = MenuFolder(name: MenuFolderNames.newFolder)
        (menu ?? targetMenu).add(.folder(folder))
        selection = [ObjectIdentifier(folder)]
        changed()
        return folder
    }

    func rename(_ folder: MenuFolder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        folder.name = trimmed
        changed()
    }

    func setPosition(_ folder: MenuFolder, _ position: FolderPriority) {
        folder.position = position
        changed()
    }

    func setIcon(_ folder: MenuFolder, _ id: String) {
        folder.imageId = id
        changed()
    }

    /// True when `menu` is `folder`'s own menu or inside it (moving would make a loop)
    private func isInside(_ menu: MenuCollection, _ folder: MenuFolder) -> Bool {
        if menu === folder.child { return true }
        var visited: [MenuCollection] = []
        func walk(_ m: MenuCollection) -> Bool {
            if m === menu { return true }
            visited.append(m)
            return m.folders.contains { f in !visited.contains(where: { $0 === f.child }) && walk(f.child) }
        }
        return walk(folder.child)
    }

    /// Move items into a folder (CE's MoveToFolder); returns false when not possible
    @discardableResult
    func move(_ ids: Set<ObjectIdentifier>, into target: MenuCollection) -> Bool {
        let items = ids.compactMap(find)
        for (element, _) in items {
            if let f = element.folder, isInside(target, f) { return false }
        }
        for (element, parent) in items where parent !== target {
            parent.remove(element)
            target.add(element)
        }
        changed()
        return true
    }

    func cutSelection() { cut = selection }

    func paste() {
        guard !cut.isEmpty, move(cut, into: targetMenu) else { return }
        cut = []
    }

    /// Recycle Bin folder in the root, created on demand
    private func trashBin() -> MenuFolder {
        if let bin = root.folders.first(where: { $0.name == MenuFolderNames.trashBin }) { return bin }
        let bin = MenuFolder(name: MenuFolderNames.trashBin, position: .leftmost)
        root.add(.folder(bin))
        return bin
    }

    private func isInTrash(_ menu: MenuCollection) -> Bool {
        guard let bin = root.folders.first(where: { $0.name == MenuFolderNames.trashBin }) else { return false }
        return bin.child === menu || isInside(menu, bin)
    }

    /// Delete items (CE): games and folder contents go to the Recycle Bin; items already in
    /// the bin are removed for good (their games are deselected on save)
    func delete(_ ids: Set<ObjectIdentifier>) {
        for id in ids {
            guard let (element, parent) = find(id) else { continue }
            if isInTrash(parent) || (element.folder.map { $0.name == MenuFolderNames.trashBin } ?? false) {
                collectGames(element, into: &deletedGames)
                parent.remove(element)
                continue
            }
            switch element {
            case .game:
                parent.remove(element)
                trashBin().child.add(element)
            case .folder(let f):
                let bin = trashBin()
                for child in f.child.elements where !(child.folder.map { $0.child === parent } ?? false) {
                    bin.child.add(child)
                }
                parent.remove(element)
            }
        }
        selection = []
        cut.subtract(ids)
        changed()
    }

    private func collectGames(_ element: MenuElement, into list: inout [MenuGame]) {
        switch element {
        case .game(let g): list.append(g)
        case .folder(let f): f.child.elements.forEach { collectGames($0, into: &list) }
        }
    }

    // MARK: - Automatic structure (CE's split buttons)

    /// Re-split the selected folder's menu (or the root) with a split mode
    func autoStructure(_ style: SplitStyle) {
        let menu = selectedFolder?.child ?? root
        menu.unsplit()
        menu.split(style, maxElements: maxGamesPerFolder, options: MenuOptions(backPosition: backPosition))
        stripBackLinks(menu, ancestors: [root, menu])
        changed()
    }

    /// Splitting adds Back folders; the manager adds them at sync time instead (AddBack)
    private func stripBackLinks(_ menu: MenuCollection, ancestors: [MenuCollection]) {
        menu.elements.removeAll { e in
            guard let f = e.folder else { return false }
            return ancestors.contains { $0 === f.child }
        }
        for f in menu.folders { stripBackLinks(f.child, ancestors: ancestors + [f.child]) }
    }

    // MARK: - Files

    func resetToFlat() {
        root.unsplit()
        selection = []
        changed()
    }

    func open(_ url: URL, games: [MenuGame]) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parsed = try FolderTreeStore.parse(text, games: games)
        root = parsed.root
        notice = parsed.unsorted > 0 ? "New games are moved to the \"Unsorted\" folder." : nil
        selection = []
        changed()
    }

    func save(to url: URL? = nil) throws {
        if let url {
            try Data(FolderTreeStore.htm(for: root, title: console.displayName).utf8).write(to: url)
        } else {
            try FolderTreeStore.save(root, console: console)
            needsSave = false
        }
    }

    /// Number of entries in the selected folder or root, and whether it exceeds the limit
    var statistics: (name: String, count: Int, tooMany: Bool) {
        let folder = selectedFolder
        let count = (folder?.child ?? root).elements.filter { e in
            !(e.folder.map { f in f.child === root || f.name == MenuFolderNames.back } ?? false)
        }.count
        return (folder?.name ?? MenuFolderNames.mainMenu, count, count >= maxGamesPerFolder)
    }
}
