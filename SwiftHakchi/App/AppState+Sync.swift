import AppKit
import Combine
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "AppSync")

/// UI state for the sync features (kept outside AppState so AppState only needs
/// one-line hooks): Folders Manager presentation and selection tracking
@MainActor
final class SyncUIState: ObservableObject {
    static let shared = SyncUIState()

    enum FoldersManagerPurpose {
        /// Opened from the Structure menu
        case edit
        /// Opened by Sync in Custom mode: "Sync" continues with the tree
        case sync
    }

    @Published var foldersManagerPurpose: FoldersManagerPurpose?
    /// Last error or warnings of a sync, shown after the task sheet closes
    @Published var syncWarnings: [String] = []
    /// Games found by "Import from Console" (non-nil shows the picker)
    @Published var foundConsoleGames: [ConsoleGameImporter.FoundGame]?

    /// Codes whose stored selection was already applied this session
    var appliedSelectionCodes: Set<String> = []
    var selectionConsole: ConsoleType?
    var cancellables = Set<AnyCancellable>()
}

extension AppState {
    /// Console type whose collection settings are in use
    var collectionConsole: ConsoleType {
        deviceManager.consoleType == .unknown ? AppConfig.shared.lastConsoleType : deviceManager.consoleType
    }

    var collectionSettings: CollectionSettings {
        AppConfig.shared.sync.collection(for: collectionConsole)
    }

    func updateCollectionSettings(_ change: (inout CollectionSettings) -> Void) {
        AppConfig.shared.sync.updateCollection(for: collectionConsole, change)
        AppConfig.shared.save()
        objectWillChange.send()
    }

    // MARK: - Sync

    /// Start a sync; in Custom mode the Folders Manager opens first (CE's BuildMenu)
    func startIncrementalSync() {
        if collectionSettings.foldersMode == .custom {
            SyncUIState.shared.foldersManagerPurpose = .sync
        } else {
            runIncrementalSync(customTree: nil)
        }
    }

    /// Run the sync task (CE's UploadGames)
    func runIncrementalSync(customTree: MenuCollection?) {
        guard deviceManager.isConnected, let shell = deviceManager.sshService else { return }
        let consoleType = deviceManager.consoleType
        let request = GameSyncService.Request(games: gameManager.games, settings: AppConfig.shared.sync,
                                              customTree: customTree)
        showTaskProgress = true

        taskRunner.run(name: "Syncing games") { [weak self] runner in
            guard let self else { return }
            let service = GameSyncService(shell: shell, consoleType: consoleType)
            let report = try await service.sync(request) { status, fraction in
                runner.updateProgress(status: status, fraction: fraction)
            }
            runner.updateProgress(status: "Verifying installed games...", fraction: 0.98)
            await self.gameManager.refreshInstalledStatus(shell: shell, consoleType: consoleType)
            let summary = "Synced \(report.syncedGames) games: \(report.uploadedFiles) file(s) uploaded, "
                + "\(report.deletedFiles) removed."
            runner.updateProgress(status: ([summary] + report.warnings).joined(separator: "\n"), fraction: 1.0)
            await MainActor.run { SyncUIState.shared.syncWarnings = report.warnings }
        }
    }

    // MARK: - Selection persistence (CE's SelectedGames / OriginalGames)

    /// Restore saved selections when games appear and save changes per console
    func startSelectionTracking() {
        let ui = SyncUIState.shared
        gameManager.$games
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] games in self?.reconcileSelection(games) }
            .store(in: &ui.cancellables)
    }

    private func reconcileSelection(_ games: [Game]) {
        let ui = SyncUIState.shared
        let console = collectionConsole
        if ui.selectionConsole != console {
            ui.selectionConsole = console
            ui.appliedSelectionCodes = []
        }
        var settings = AppConfig.shared.sync.collection(for: console)
        let known = Set(settings.knownGames)
        let selectedCustom = Set(settings.selectedGames)
        let selectedStock = Set(settings.originalGames)

        // First appearance this session: apply the stored choice for known games
        var changed = false
        for (i, game) in games.enumerated() where !ui.appliedSelectionCodes.contains(game.id) {
            ui.appliedSelectionCodes.insert(game.id)
            guard known.contains(game.id), game.source != .console else { continue }
            let wanted = game.isStock ? selectedStock.contains(game.id) : selectedCustom.contains(game.id)
            if gameManager.games.indices.contains(i), gameManager.games[i].id == game.id,
               gameManager.games[i].isSelected != wanted {
                gameManager.games[i].isSelected = wanted
                changed = true
            }
        }
        if changed { return }  // the change publishes again; save on that pass

        let current = gameManager.games.filter { $0.source != .console }
        let newSelected = current.filter { !$0.isStock && $0.isSelected }.map(\.id).sorted()
        let newOriginal = current.filter { $0.isStock && $0.isSelected }.map(\.id).sorted()
        let newKnown = Array(known.union(current.map(\.id))).sorted()
        guard newSelected != settings.selectedGames.sorted() || newOriginal != settings.originalGames.sorted()
                || newKnown != settings.knownGames.sorted() else { return }
        settings.selectedGames = newSelected
        settings.originalGames = newOriginal
        settings.knownGames = newKnown
        AppConfig.shared.sync.collections[console.rawValue] = settings
        AppConfig.shared.save()
    }

    // MARK: - Presets (CE's File > Selection presets)

    var presetNames: [String] {
        collectionSettings.presets.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func addPreset() {
        let alert = NSAlert()
        alert.messageText = "New Selection Preset"
        alert.informativeText = "Name for the current selection of games:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // CE replaces "=" (it was used in the old ini format)
        let name = field.stringValue.replacingOccurrences(of: "=", with: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let codes = gameManager.games.filter { $0.isSelected && $0.source != .console }.map(\.id)
        updateCollectionSettings { $0.presets[name] = codes }
    }

    func deletePreset(_ name: String) {
        updateCollectionSettings { $0.presets[name] = nil }
    }

    /// Select exactly the games of a preset
    func applyPreset(_ name: String) {
        guard let codes = collectionSettings.presets[name] else { return }
        let set = Set(codes)
        for i in gameManager.games.indices where gameManager.games[i].source != .console {
            gameManager.games[i].isSelected = set.contains(gameManager.games[i].id)
        }
    }

    // MARK: - Console settings (p0000_config)

    /// Read the console's cfg_* values; they override the local settings (CE behaviour)
    func refreshConsoleConfig() async {
        guard let shell = deviceManager.sshService else { return }
        do {
            let config = try await ConsoleConfigService.read(shell: shell)
            guard !config.isEmpty else { return }
            AppConfig.shared.sync.console.apply(config)
            AppConfig.shared.save()
            objectWillChange.send()
        } catch {
            logger.warning("Reading console settings failed: \(error.localizedDescription)")
        }
    }

    /// CE's "Save settings to mini now": push cfg_* values and reboot
    func saveSettingsToConsole(reboot: Bool = true) {
        guard let shell = deviceManager.sshService else { return }
        let config = AppConfig.shared.sync.console.configDictionary(isFamicom: deviceManager.consoleType == .famicom)
        Task {
            do {
                try await ConsoleConfigService.push(config, shell: shell, reboot: reboot)
                statusMessage = reboot ? "Settings saved, console rebooting" : "Settings saved"
            } catch {
                statusMessage = "Saving settings failed: \(error.localizedDescription)"
            }
        }
    }

    func setSegaTheme(_ region: String) {
        guard let shell = deviceManager.sshService else { return }
        Task { try? await ConsoleConfigService.setSegaTheme(region, shell: shell) }
    }

    // MARK: - Folders Manager input

    /// Menu games for the Folders Manager: selected custom and stock games
    func selectedMenuGames() -> [MenuGame] {
        gameManager.games.filter { $0.isSelected && $0.source != .console }.map { game in
            MenuGame(code: game.code, name: game.name, sortName: game.sortName, isOriginal: game.isStock,
                     system: game.system, bin: DesktopFile.splitExec(game.commandLine).bin,
                     genre: game.genre, country: game.country)
        }
    }

    // MARK: - Import from console (CE's GameImporterForm)

    /// Scan the console, then show the list of games to import
    func startConsoleImport() {
        guard deviceManager.isConnected, let shell = deviceManager.sshService else { return }
        let stockCodes = Set(gameManager.games.filter(\.isStock).map(\.id))
        showTaskProgress = true
        taskRunner.run(name: "Scanning console for games") { runner in
            runner.updateProgress(status: "Looking for games...", fraction: 0.2)
            let found = try await ConsoleGameImporter.findGames(shell: shell, stockCodes: stockCodes)
            runner.updateProgress(status: found.isEmpty ? "No games found" : "Found \(found.count) game(s)", fraction: 1.0)
            await MainActor.run {
                if !found.isEmpty {
                    self.showTaskProgress = false
                    SyncUIState.shared.foundConsoleGames = found
                }
            }
        }
    }

    /// Copy the chosen games into the library and select them for sync
    func importConsoleGames(_ games: [ConsoleGameImporter.FoundGame]) {
        guard let shell = deviceManager.sshService, !games.isEmpty else { return }
        let gamesDir = AppConfig.shared.gamesDirectory
        let codes = Set(games.map(\.code))
        showTaskProgress = true
        taskRunner.run(name: "Copying games from console") { [weak self] runner in
            guard let self else { return }
            var failed: [String] = []
            for (i, game) in games.enumerated() {
                try Task.checkCancellation()
                runner.updateProgress(status: "\(game.name) (\(i + 1)/\(games.count))",
                                      fraction: Double(i) / Double(games.count))
                do {
                    _ = try await ConsoleGameImporter.copy(game, shell: shell, gamesDirectory: gamesDir,
                                                          cores: CoreCatalog.shared)
                } catch {
                    failed.append(game.name)
                }
            }
            await MainActor.run {
                self.gameManager.loadGames()
                for i in self.gameManager.games.indices where codes.contains(self.gameManager.games[i].id) {
                    self.gameManager.games[i].isSelected = true
                    self.gameManager.games[i].isOnConsole = true
                }
            }
            let summary = "Imported \(games.count - failed.count) game(s)"
            runner.updateProgress(status: failed.isEmpty ? summary : summary + ". Failed: " + failed.joined(separator: ", "),
                                  fraction: 1.0)
        }
    }
}
