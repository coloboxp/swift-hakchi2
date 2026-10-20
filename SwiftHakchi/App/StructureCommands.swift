import SwiftUI

/// "Structure" menu (CE's foldersContextMenuStrip) plus selection presets and console settings
struct StructureCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject private var config = AppConfig.shared

    private var settings: CollectionSettings { appState.collectionSettings }

    /// Max games choices: CE offers different steps for Mega Drive (multiples of 6)
    private var maxChoices: [Int] {
        appState.collectionConsole == .megaDrive
            ? [24, 30, 36, 42, 48, 60, 72, 84, 96, 102]
            : [20, 25, 30, 35, 40, 45, 50, 60, 70, 80, 90, 100]
    }

    var body: some Commands {
        CommandMenu("Structure") {
            ForEach(SplitStyle.menuModes, id: \.0) { mode, title in
                Button((settings.foldersMode == mode ? "✓ " : "") + title) {
                    if mode == .custom && settings.foldersMode == .custom {
                        SyncUIState.shared.foldersManagerPurpose = .edit  // click again to open (CE)
                    }
                    appState.updateCollectionSettings { $0.foldersMode = mode }
                }
            }
            Button("Folders Manager...") { SyncUIState.shared.foldersManagerPurpose = .edit }
                .keyboardShortcut("f", modifiers: [.command, .shift])

            Divider()

            Menu("Maximum Games per Page/Folder") {
                ForEach(maxChoices, id: \.self) { n in
                    let warn = n >= (appState.collectionConsole == .megaDrive ? 103 : 50)
                    Button((settings.maxGamesPerFolder == n ? "✓ " : "") + "\(n)" + (warn ? " (not recommended)" : "")) {
                        appState.updateCollectionSettings { $0.maxGamesPerFolder = n }
                    }
                }
            }
            Menu("Back Folder Button Position") {
                Button((settings.backFolderPosition == .leftBack ? "✓ " : "") + "Leftmost") {
                    appState.updateCollectionSettings { $0.backFolderPosition = .leftBack }
                }
                Button((settings.backFolderPosition != .leftBack ? "✓ " : "") + "Rightmost") {
                    appState.updateCollectionSettings { $0.backFolderPosition = .back }
                }
            }
            Menu("Folder Images Set") {
                Button((settings.folderImagesSet.isEmpty ? "✓ " : "") + "Default") {
                    appState.updateCollectionSettings { $0.folderImagesSet = "" }
                }
                ForEach(FolderImages.availableSets(), id: \.self) { set in
                    Button((settings.folderImagesSet == set ? "✓ " : "") + set) {
                        appState.updateCollectionSettings { $0.folderImagesSet = set }
                    }
                }
                Divider()
                Button("Open Folder Images Folder") {
                    try? FileManager.default.createDirectory(at: FolderImages.userDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(FolderImages.userDirectory)
                }
            }
            Button("Sync Structure Settings for All Games Collections") {
                config.sync.copyStructureToAllCollections(from: appState.collectionConsole)
                config.save()
            }

            Divider()

            Menu("Selection Presets") {
                ForEach(appState.presetNames, id: \.self) { name in
                    Button(name) { appState.applyPreset(name) }
                }
                if !appState.presetNames.isEmpty { Divider() }
                Button("Add Preset...") { appState.addPreset() }
                Menu("Delete Preset") {
                    ForEach(appState.presetNames, id: \.self) { name in
                        Button(name) { appState.deletePreset(name) }
                    }
                }
                .disabled(appState.presetNames.isEmpty)
            }

            Divider()

            Button("Save Settings to Console Now") { appState.saveSettingsToConsole() }
                .disabled(!appState.deviceManager.isConnected)
            if appState.deviceManager.consoleType == .megaDrive {
                Menu("SEGA UI Theme") {
                    Button("Auto") { appState.setSegaTheme("auto") }
                    Button("United States") { appState.setSegaTheme("us") }
                    Button("Europe") { appState.setSegaTheme("eu") }
                    Button("Japan") { appState.setSegaTheme("jp") }
                }
            }
        }
    }
}
