import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Folders Manager (port of Hakchi2-CE's `FoldersManagerForm`): build the console menu
/// tree by hand. Used for the "Custom" structure mode.
struct FoldersManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var model: FoldersManagerModel
    @State private var renameText = ""
    @State private var showIconPicker = false
    @State private var confirmClose = false
    @State private var errorText: String?

    let purpose: SyncUIState.FoldersManagerPurpose
    private let games: [MenuGame]

    init(purpose: SyncUIState.FoldersManagerPurpose, console: ConsoleType, games: [MenuGame], settings: CollectionSettings) {
        self.purpose = purpose
        self.games = games
        _model = StateObject(wrappedValue: FoldersManagerModel(console: console, games: games, settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                tree.frame(minWidth: 280)
                details.frame(minWidth: 300, maxWidth: 360)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 520)
        .sheet(isPresented: $showIconPicker) {
            if let folder = model.selectedFolder {
                FolderIconPicker(selected: folder.imageId,
                                 set: AppConfig.shared.sync.collection(for: model.console).folderImagesSet) { id in
                    model.setIcon(folder, id)
                }
            }
        }
        .alert("Save changes to the folders structure?", isPresented: $confirmClose) {
            Button("Save") { save(); dismiss() }
            Button("Don't Save", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: model.selection) { _, _ in renameText = model.selectedFolder?.name ?? "" }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Text("Folders Manager").font(.title3.bold())
            Spacer()
            Button { model.newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            Button { model.cutSelection() } label: { Label("Cut", systemImage: "scissors") }
                .disabled(model.selection.isEmpty)
            Button { model.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .disabled(model.cut.isEmpty)
            Button(role: .destructive) { model.delete(model.selection) } label: { Label("Delete", systemImage: "trash") }
                .disabled(model.selection.isEmpty)
            Menu("File") {
                Button("New (no folders)") { model.resetToFlat() }
                Button("Open...") { open() }
                Button("Save") { save() }
                Button("Save As...") { saveAs() }
            }
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .padding(8)
    }

    // MARK: - Tree

    private var tree: some View {
        List(selection: $model.selection) {
            Section(MenuFolderNames.mainMenu) {
                OutlineGroup(model.nodes, children: \.children) { node in
                    row(node)
                }
            }
        }
        .id(model.revision)
        .dropDestination(for: String.self) { items, _ in
            model.move(ids(from: items), into: model.root)
        }
        .onDeleteCommand { model.delete(model.selection) }
    }

    private func row(_ node: FoldersManagerModel.Node) -> some View {
        let isCut = model.cut.contains(node.id)
        return HStack {
            Image(systemName: icon(for: node.element))
                .foregroundStyle(node.isFolder ? Color.accentColor : .secondary)
            Text(label(for: node.element))
            if let folder = node.element.folder, folder.position != .right {
                Text(folder.position.label).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .opacity(isCut ? 0.4 : 1)
        .tag(node.id)
        .draggable(Self.dragID(node.id))
        .dropDestination(for: String.self) { items, _ in
            guard let folder = node.element.folder else { return false }
            return model.move(ids(from: items), into: folder.child)
        }
    }

    private func icon(for element: MenuElement) -> String {
        switch element {
        case .folder(let f): return f.name == MenuFolderNames.trashBin ? "trash" : "folder"
        case .game(let g): return g.isOriginal ? "star" : "gamecontroller"
        }
    }

    private func label(for element: MenuElement) -> String {
        switch element {
        case .folder(let f): return f.name
        case .game(let g): return g.name
        }
    }

    /// Drag payload: the node's ObjectIdentifier as text (only meaningful inside this window)
    private static func dragID(_ id: ObjectIdentifier) -> String { "\(id.hashValue)" }

    private func ids(from items: [String]) -> Set<ObjectIdentifier> {
        var all: [ObjectIdentifier] = []
        func walk(_ nodes: [FoldersManagerModel.Node]) {
            for n in nodes { all.append(n.id); walk(n.children ?? []) }
        }
        walk(model.nodes)
        let wanted = Set(items)
        var result = Set(all.filter { wanted.contains(Self.dragID($0)) })
        // Dragging one of several selected rows moves the whole selection
        if !result.isDisjoint(with: model.selection) { result.formUnion(model.selection) }
        return result
    }

    // MARK: - Details

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let stats = model.statistics
                Text("\(stats.name): \(stats.count) element(s)")
                    .foregroundStyle(stats.tooMany ? .red : .secondary)
                    .help(stats.tooMany ? "Too many elements in one folder can make the console menu slow or glitchy." : "")

                if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }

                if let folder = model.selectedFolder {
                    GroupBox("Folder") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                TextField("Name", text: $renameText)
                                    .onSubmit { model.rename(folder, to: renameText) }
                                Button("Rename") { model.rename(folder, to: renameText) }
                            }
                            Picker("Position", selection: Binding(
                                get: { folder.position },
                                set: { model.setPosition(folder, $0) })) {
                                ForEach([FolderPriority.leftmost, .left, .right, .rightmost, .back], id: \.self) {
                                    Text($0.label).tag($0)
                                }
                            }
                            HStack(alignment: .top) {
                                folderImage(folder)
                                Button("Change Icon...") { showIconPicker = true }
                            }
                        }
                        .padding(4)
                    }
                }

                GroupBox("Create folders structure automatically") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Applies to the selected folder, or the main menu.").font(.caption).foregroundStyle(.secondary)
                        splitButton("No folders", .noSplit)
                        splitButton("Original games -> Other games", .originalNoSplit)
                        splitButton("Split equally", .foldersEqual)
                        splitButton("Original games -> Split equally", .originalFoldersEqual)
                        splitButton("Split by first letter", .foldersAlphabeticFoldersEqual)
                        splitButton("Original games -> Split by first letter", .originalFoldersAlphabeticFoldersEqual)
                        splitButton("Split by console", .foldersGroupByApp)
                        splitButton("Split by genre", .foldersGroupByGenre)
                        splitButton("Split by region", .foldersGroupByRegion)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Back button") {
                    VStack(alignment: .leading) {
                        Picker("Position", selection: Binding(
                            get: { model.backPosition },
                            set: { model.backPosition = $0; model.needsSave = true })) {
                            Text("Leftmost").tag(FolderPriority.leftBack)
                            Text("Rightmost").tag(FolderPriority.back)
                        }
                        Toggle("Add \"Home\" folder", isOn: Binding(
                            get: { model.homeFolder },
                            set: { model.homeFolder = $0; model.needsSave = true }))
                    }
                    .padding(4)
                }

                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
            .padding()
        }
    }

    private func splitButton(_ title: String, _ style: SplitStyle) -> some View {
        Button(title) { model.autoStructure(style) }
            .buttonStyle(.link)
    }

    private func folderImage(_ folder: MenuFolder) -> some View {
        let set = AppConfig.shared.sync.collection(for: model.console).folderImagesSet
        return Group {
            if let url = FolderImages.url(for: folder.imageId, set: set), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "folder").resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: 114, height: 102)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") {
                if model.needsSave { confirmClose = true } else { dismiss() }
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button(purpose == .sync ? "Save and Sync" : "Save") {
                save()
                if errorText == nil {
                    dismiss()
                    if purpose == .sync { appState.runIncrementalSync(customTree: model.root) }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.root.count == 0)
        }
        .padding(10)
    }

    // MARK: - Files

    private func save() {
        do {
            try model.save()
            errorText = nil
            // Games permanently deleted in the manager are unchecked (CE)
            let deleted = Set(model.deletedGames.map(\.code))
            for i in appState.gameManager.games.indices where deleted.contains(appState.gameManager.games[i].id) {
                appState.gameManager.games[i].isSelected = false
            }
            AppConfig.shared.sync.updateCollection(for: model.console) { c in
                c.backFolderPosition = model.backPosition
                c.homeFolder = model.homeFolder
            }
            AppConfig.shared.save()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.open(url, games: games) } catch { errorText = error.localizedDescription }
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "folders.htm"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.save(to: url) } catch { errorText = error.localizedDescription }
    }
}

/// Folder icon chooser (CE's SelectIconForm)
struct FolderIconPicker: View {
    @Environment(\.dismiss) private var dismiss
    let selected: String
    let set: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack {
            Text("Select Folder Icon").font(.headline)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 10) {
                    ForEach(FolderImages.availableIds(set: set), id: \.self) { id in
                        Button {
                            onSelect(id)
                            dismiss()
                        } label: {
                            VStack(spacing: 2) {
                                if let url = FolderImages.url(for: id, set: set), let image = NSImage(contentsOf: url) {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(height: 70)
                                }
                                Text(id).font(.caption2).lineLimit(1)
                            }
                            .padding(4)
                            .background(id == selected ? Color.accentColor.opacity(0.2) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 520, height: 460)
    }
}
