import SwiftUI

/// Top-left panel: scrollable grid of game cover art tiles
struct GameGridView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isDraggingFromExplorer: Bool
    @Binding var selectionSource: SelectionSource
    @State private var gamesToDelete: [Game] = []

    /// Redraw when the View options change
    @ObservedObject private var librarySettings = LibrarySettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Games Explorer")
                    .font(.headline)

                TextField("Search", text: $appState.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Spacer()

                Button {
                    Task { await appState.importFromConsole() }
                } label: {
                    Label("Import from Console", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(ActionButtonStyle(compact: true))
                .disabled(!appState.deviceManager.isConnected)
                .help("Import custom games from the connected console")

                Button {
                    appState.addROMs()
                } label: {
                    Label("Add ROMs", systemImage: "plus.rectangle.on.folder")
                }
                .buttonStyle(ActionButtonStyle(compact: true))
                .help("Import ROM files from your Mac")
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 6)

            Divider()

            // Grid — always 3 columns, cards scale to fill
            GeometryReader { geo in
                let columns = 3
                let hPadding: CGFloat = 16 * 2
                let spacing: CGFloat = 12
                let totalSpacing = spacing * CGFloat(columns - 1) + hPadding
                let cardSize = max(60, (geo.size.width - totalSpacing) / CGFloat(columns))

                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                        spacing: 16
                    ) {
                        ForEach(appState.explorerSections) { section in
                          Section {
                           ForEach(section.games) { game in
                            GameCardView(
                                game: game,
                                isActive: game == appState.selectedGame && selectionSource == .explorer,
                                isMultiSelected: appState.selectedGameIds.count > 1
                                    && appState.selectedGameIds.contains(game.id),
                                isOnBar: game.isSelected,
                                cardSize: cardSize
                            )
                            .onTapGesture {
                                // ⌘-click toggles, ⇧-click selects a range (like Finder)
                                appState.select(game, modifiers: NSEvent.modifierFlags)
                                selectionSource = .explorer
                            }
                            .onDrag {
                                isDraggingFromExplorer = true
                                return NSItemProvider(object: game.id as NSString)
                            }
                            .contextMenu {
                                gameContextMenu(for: game)
                            }
                           }
                          } header: {
                            if !section.title.isEmpty {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                          }
                        }
                    }
                    .padding(16)
                }
                .modifier(ExplorerKeyboard { gamesToDelete = $0 })
            }
            .overlay {
                if appState.explorerGames.isEmpty {
                    ContentUnavailableView {
                        Label("No Games", systemImage: "gamecontroller")
                    } description: {
                        Text("Import ROM files to get started.")
                    } actions: {
                        Button {
                            appState.addROMs()
                        } label: {
                            Label("Add ROMs", systemImage: "plus.rectangle.on.folder")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .alert(gamesToDelete.count > 1 ? "Delete \(gamesToDelete.count) Games" : "Delete Game",
               isPresented: Binding(
                   get: { !gamesToDelete.isEmpty },
                   set: { if !$0 { gamesToDelete = [] } }
               )) {
            Button("Delete", role: .destructive) {
                for game in gamesToDelete {
                    appState.selectedGameIds.remove(game.id)
                    if appState.selectedGame?.id == game.id { appState.selectedGame = nil }
                }
                appState.gameManager.deleteGames(gamesToDelete)
                gamesToDelete = []
            }
            Button("Cancel", role: .cancel) {
                gamesToDelete = []
            }
        } message: {
            let what = gamesToDelete.count > 1 ? "these \(gamesToDelete.count) games" : "\"\(gamesToDelete.first?.name ?? "")\""
            Text("Are you sure you want to delete \(what)? This removes the imported copy from the app library. Your original ROM files are not affected.")
        }
    }

    /// Right-click menu; commands apply to the whole selection when the clicked game is in it
    @ViewBuilder
    private func gameContextMenu(for game: Game) -> some View {
        LibraryContextMenu(game: game) { gamesToDelete = $0 }
    }
}
