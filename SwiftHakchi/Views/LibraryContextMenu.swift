import SwiftUI

/// Right-click menu for games in the explorer (Hakchi2-CE's game list context menu).
/// Commands apply to the whole selection when the clicked game is part of it.
struct LibraryContextMenu: View {
    @EnvironmentObject var appState: AppState
    let game: Game
    /// Asks the grid to confirm deleting these games
    let onDelete: ([Game]) -> Void

    var body: some View {
        let targets = appState.contextTargets(for: game)
        let local = targets.filter { $0.source == .local }
        let count = targets.count > 1 ? " (\(targets.count) games)" : ""

        Button("Show in Finder") { appState.showInFinder(local) }
            .disabled(local.isEmpty)

        Divider()

        Button("Add Prefix...") { appState.addPrefix(to: local) }
            .disabled(local.isEmpty)
        Button("Remove Prefix...") { appState.removePrefix(from: local) }
            .disabled(local.isEmpty)
        Menu("Set Region") {
            ForEach(GenreCatalog.regions) { region in
                Button(region.englishName) { appState.setRegion(region.desktopName, for: local) }
            }
        }
        .disabled(local.isEmpty)

        Divider()

        Button("Scrape Selected Games...\(count)") { appState.scrapeGames(local) }
            .disabled(local.isEmpty || AppConfig.shared.theGamesDbApiKey.isEmpty)
        Button("Scan for New Box Art") { appState.scanForCovers(local) }
            .disabled(local.isEmpty)
        Button("Delete Box Art") { appState.deleteCovers(local) }
            .disabled(local.isEmpty)

        Divider()

        Button("Archive Selected Games...\(count)") { appState.archiveGames(local) }
            .disabled(local.isEmpty)
        Button("Compress Selected Games") { appState.compressGames(local, compress: true) }
            .disabled(local.isEmpty || !GameCompression.isAvailable)
        Button("Decompress Selected Games") { appState.compressGames(local, compress: false) }
            .disabled(local.isEmpty || !GameCompression.isAvailable)
        Button("Repair Games") { appState.repairGames(local) }
            .disabled(local.isEmpty)
        Button("Game Genie Codes...") { appState.gameGenieGameId = game.id }
            .disabled(game.source != .local || targets.count > 1)

        Divider()

        Button("Select Emulation Core...\(count)") { appState.openCoreDialog(for: local) }
            .disabled(local.isEmpty)

        Divider()

        Button(local.count > 1 ? "Delete \(local.count) Games..." : "Delete Game...") { onDelete(local) }
            .disabled(local.isEmpty)
    }
}
