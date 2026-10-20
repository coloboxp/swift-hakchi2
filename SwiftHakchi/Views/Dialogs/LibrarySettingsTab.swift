import SwiftUI

/// PC-side library settings from Hakchi2-CE's Settings and View menus
struct LibrarySettingsTab: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var settings = LibrarySettings.shared
    @ObservedObject private var config = AppConfig.shared

    var body: some View {
        Form {
            Section("When Adding Games") {
                Toggle("Compress games (7z)", isOn: $settings.values.compressGames)
                    .help(GameCompression.isAvailable ? "Store ROMs as .7z to save space on the console"
                                                      : "Not available yet in this version")
                Toggle("Compress box art (8-bit colors)", isOn: $settings.values.compressCoverArt)
                Toggle("Center box art thumbnail", isOn: $settings.values.centerThumbnail)
                Toggle("Convert SNES ROMs to SFROM", isOn: $config.convertToSfrom)
                    .onChange(of: config.convertToSfrom) { _, _ in config.save() }
                Toggle("Look up game information online (TheGamesDB)", isOn: $settings.values.enableImportScraper)
                    .disabled(config.theGamesDbApiKey.isEmpty)
            }
            Section("Library") {
                Toggle("Separate games storage (SNES and Mega Drive in their own folders)",
                       isOn: $settings.values.separateGameLocalStorage)
                    .onChange(of: settings.values.separateGameLocalStorage) { _, _ in
                        appState.gameManager.loadGames()
                    }
                Toggle("Disable \"Done\" pop-ups", isOn: $settings.values.disablePopups)
            }
            Section("View") {
                Picker("Original games", selection: $settings.values.originalGamesPosition) {
                    ForEach(LibrarySettings.OriginalGamesPosition.allCases) { Text($0.label).tag($0) }
                }
                Picker("Sort by", selection: $settings.values.gamesSorting) {
                    ForEach(LibrarySettings.GamesSorting.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Group games without box art", isOn: $settings.values.groupGamesWithoutCoverArt)
            }
        }
        .formStyle(.grouped)
    }
}
