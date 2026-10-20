import SwiftUI

/// Library menu items from Hakchi2-CE's File and View menus.
struct LibraryCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var settings: LibrarySettings

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Add Custom App...") { appState.showNewCustomApp = true }
            Button("Restore Original Games...") { appState.restoreOriginalGames() }
            Button("Prepare Art Folders...") { appState.showPrepareArtFolders = true }
            Button("Reload Games") {
                appState.gameManager.loadGames()
                appState.gameManager.matchExistingGames()
            }
        }

        // View menu
        CommandGroup(after: .toolbar) {
            Picker("Original Games", selection: $settings.values.originalGamesPosition) {
                ForEach(LibrarySettings.OriginalGamesPosition.allCases) { Text($0.label).tag($0) }
            }
            Picker("Sort By", selection: $settings.values.gamesSorting) {
                ForEach(LibrarySettings.GamesSorting.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Group Games Without Box Art", isOn: $settings.values.groupGamesWithoutCoverArt)
        }
    }
}
