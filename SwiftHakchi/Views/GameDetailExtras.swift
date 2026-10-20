import SwiftUI
import UniformTypeIdentifiers

/// Box art panel for the game details (CE's "Artwork" group): front cover and
/// thumbnail, browse/paste/drop/default, plus Mega Drive Mini art when present.
struct GameArtworkView: View {
    @EnvironmentObject var appState: AppState
    let game: Game
    @State private var isTargeted = false

    private var dir: URL { appState.gameManager.gameDirectory(game) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            artTile(url: game.coverArtPath.map(URL.init(fileURLWithPath:)), size: 120, label: "Front")
                .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted) { providers in
                    dropImage(providers)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2))
            VStack(alignment: .leading, spacing: 8) {
                artTile(url: CoverArt.thumbnailURL(dir, game.code), size: 40, label: "Thumbnail")
                if FileManager.default.fileExists(atPath: CoverArt.mdMiniURL(dir, game.code).path) {
                    artTile(url: CoverArt.mdMiniURL(dir, game.code), size: 60, label: "Mega Drive Mini")
                }
            }
            if game.source == .local {
                VStack(alignment: .leading, spacing: 6) {
                    Button("Browse...") { appState.browseForCover(game) }
                    Button("Paste") { appState.pasteCover(game) }
                        .disabled(!NSPasteboard.general.canReadObject(forClasses: [NSImage.self]))
                    Button("Default") { appState.deleteCovers([game]) }
                    Button("Scan Art Folder") { appState.scanForCovers([game]) }
                    if game.system == "Sega - Mega Drive - Genesis" {
                        Button("Spine...") { appState.spineGameId = game.id }
                    }
                }
                .controlSize(.small)
            }
            Spacer()
        }
    }

    private func artTile(url: URL?, size: CGFloat, label: String) -> some View {
        VStack(spacing: 2) {
            Group {
                if let url, let image = ImageCache.shared.image(for: url.path) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                }
            }
            .frame(width: size, height: size)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func dropImage(_ providers: [NSItemProvider]) -> Bool {
        guard game.source == .local, let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { return }
                Task { @MainActor in appState.setCover(data, for: game) }
            }
            return true
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in appState.setCover(data, for: game) }
        }
        return true
    }
}

/// CE's "Max players" choices, mapped to Players + Simultaneous
enum PlayerOption: Int, CaseIterable, Identifiable {
    case one, twoAlternating, twoSimultaneous, three, four, five
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .one: return "1 player"
        case .twoAlternating: return "2 players, not simultaneous"
        case .twoSimultaneous: return "2 players, simultaneous"
        case .three: return "3 players"
        case .four: return "4 players"
        case .five: return "5 players"
        }
    }

    init(players: Int, simultaneous: Bool) {
        switch players {
        case ...1: self = .one
        case 2: self = simultaneous ? .twoSimultaneous : .twoAlternating
        case 3: self = .three
        case 4: self = .four
        default: self = .five
        }
    }

    var players: Int { [1, 2, 2, 3, 4, 5][rawValue] }
    /// CE marks 3+ players as simultaneous too
    var simultaneous: Bool { rawValue >= 2 }
}

/// Extra fields from CE's details panel that the base editor doesn't show
struct GameMoreDetailsView: View {
    @EnvironmentObject var appState: AppState
    @Binding var game: Game
    @State private var saveCount = 0

    private var dir: URL { appState.gameManager.gameDirectory(game) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Sort Name") {
                TextField("Generated from the name", text: $game.sortName)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Copyright") {
                TextField("Copyright", text: $game.copyright)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Max Players") {
                Picker("", selection: Binding(
                    get: { PlayerOption(players: game.players, simultaneous: game.simultaneous) },
                    set: { game.players = $0.players; game.simultaneous = $0.simultaneous }
                )) {
                    ForEach(PlayerOption.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 240, alignment: .leading)
            }
            LabeledContent("Genre") {
                Picker("", selection: Binding(
                    get: { GenreCatalog.normalized(game.genre) },
                    set: { game.genre = $0 }
                )) {
                    Text("None").tag("")
                    ForEach(GenreCatalog.all) { Text($0.englishName).tag($0.desktopName) }
                    // Keep unknown values selectable instead of silently dropping them
                    let current = GenreCatalog.normalized(game.genre)
                    if !current.isEmpty && GenreCatalog.genre(desktopName: current) == nil {
                        Text(current).tag(current)
                    }
                }
                .labelsHidden()
                .frame(width: 240, alignment: .leading)
            }
            LabeledContent("Region") {
                Picker("", selection: $game.country) {
                    Text("None").tag("")
                    ForEach(GenreCatalog.regions) { Text($0.englishName).tag($0.desktopName) }
                }
                .labelsHidden()
                .frame(width: 240, alignment: .leading)
            }
            LabeledContent("Save Slots") {
                Picker("", selection: $game.saveCount) {
                    ForEach(0...3, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .frame(width: 80, alignment: .leading)
            }
            if game.source == .local {
                HStack(spacing: 16) {
                    Toggle("Compressed", isOn: Binding(
                        get: { GameCompression.isCompressed(exec: game.commandLine) },
                        set: { appState.compressGames([game], compress: $0) }
                    ))
                    .disabled(!GameCompression.isAvailable)
                    Button("Game Genie...") { appState.gameGenieGameId = game.id }
                    Spacer()
                    Text("ID: \(game.code)").font(.caption).foregroundStyle(.secondary)
                    Text("Size: \(ByteCountFormatter.string(fromByteCount: GameManagerService.gameSize(gameDirectory: dir, code: game.code), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Saves the game shortly after any field changes, and when switching games
/// (CE edits apply immediately; the Save button still works).
struct GameAutoSave: ViewModifier {
    @EnvironmentObject var appState: AppState
    @Binding var game: Game
    @State private var pending: Task<Void, Never>?
    @State private var pendingGame: Game?
    @State private var lastId: String?

    private var snapshot: [String] {
        [game.id, game.name, game.sortName, game.publisher, game.copyright, game.genre, game.releaseDate,
         "\(game.players)", "\(game.simultaneous)", game.description, game.commandLine,
         "\(game.saveCount)", game.country, game.cePrefix]
    }

    func body(content: Content) -> some View {
        content
            .onAppear { lastId = game.id }
            .onChange(of: snapshot) { _, _ in
                pending?.cancel()
                if game.id != lastId {
                    // Switched games: save the previous one now, don't resave the new one
                    flush()
                    lastId = game.id
                    return
                }
                guard game.source == .local else { return }
                pendingGame = game
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    guard !Task.isCancelled else { return }
                    flush()
                }
            }
            .onDisappear {
                pending?.cancel()
                flush()
            }
    }

    private func flush() {
        if let g = pendingGame { appState.gameManager.saveGame(g) }
        pendingGame = nil
        pending = nil
    }
}
