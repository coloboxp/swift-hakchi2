import AppKit
import SwiftUI

/// Library actions: importing, multi-selection, and the emulation core dialog.
extension AppState {
    // MARK: - Import

    /// Console type for new games: the connected console, else the last one seen
    var effectiveConsoleType: ConsoleType {
        deviceManager.consoleType == .unknown ? AppConfig.shared.lastConsoleType : deviceManager.consoleType
    }

    /// Ask for files and import them (CE: "Add more games > Autodetect..." / "As-Is...")
    func addROMs(asIs: Bool = false) {
        let panel = NSOpenPanel()
        panel.title = asIs ? "Add Games As-Is" : "Add Games"
        panel.message = asIs
            ? "Files are imported untouched: archives are not unpacked and ROMs are not converted."
            : "Choose ROMs, archives (.zip, .7z), game archives (.clvg) or game folders (.desktop)."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importGames(urls: panel.urls, asIs: asIs)
    }

    /// Import files (from the open panel or drag and drop)
    func importGames(urls: [URL], asIs: Bool = false) {
        let result = gameManager.importROMs(
            urls: urls, consoleType: effectiveConsoleType, asIs: asIs,
            chooseFile: { [weak self] archive, entries in self?.chooseArchiveEntry(archive: archive, entries: entries) },
            ask: { title, message in Self.askYesNoToAll(title: title, message: message) })

        if let last = result.imported.last, let game = gameManager.games.first(where: { $0.id == last }) {
            selectedGame = game
            selectedGameIds = Set(result.imported)
        }
        if !result.errors.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some files could not be imported"
            alert.informativeText = result.errors.joined(separator: "\n")
            alert.runModal()
        }
        // CE opens the core dialog for games whose system was not detected
        if !result.unknownSystem.isEmpty {
            coreDialogGameIds = result.unknownSystem
        }
        // CE's SelectCoverDialog for games with several possible covers in art/
        let candidates = gameManager.importCoverCandidates
        gameManager.importCoverCandidates = [:]
        coverChoices = candidates.compactMap { code, urls in
            gameManager.games.first { $0.id == code }.map { CoverChoice(code: code, name: $0.name, candidates: urls) }
        }
        .sorted { $0.name < $1.name }
    }

    /// Let the user pick the ROM inside an archive with several candidates
    func chooseArchiveEntry(archive: String, entries: [String]) -> String? {
        let alert = NSAlert()
        alert.messageText = "Select a file from \(archive)"
        alert.informativeText = "The archive contains several files. Which one is the game?"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        popup.addItems(withTitles: entries)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Skip")
        return alert.runModal() == .alertFirstButtonReturn ? popup.titleOfSelectedItem : nil
    }

    /// Yes / Yes to All / No alert used during import
    static func askYesNoToAll(title: String, message: String) -> GameImporter.Answer {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "Yes to All")
        alert.addButton(withTitle: "No")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .yes
        case .alertSecondButtonReturn: return .yesToAll
        default: return .no
        }
    }

    // MARK: - Selection

    /// Explorer sections, following the View options (original games, sorting, grouping)
    var explorerSections: [ExplorerSection] {
        ExplorerGrouping.sections(for: filteredGames, settings: LibrarySettings.shared.values) { game in
            CoreCatalog.shared.core(game.core)?.name ?? CoreCatalog.shared.core(forExec: game.commandLine)?.name
                ?? "Unknown Core"
        }
    }

    /// Explorer games in display order (used for ⇧-click ranges)
    var explorerGames: [Game] {
        explorerSections.flatMap(\.games)
    }

    /// Games currently selected in the explorer, in display order
    var selectedGames: [Game] {
        explorerGames.filter { selectedGameIds.contains($0.id) }
    }

    /// Click handling: plain click selects one game, ⌘ toggles, ⇧ extends a range
    func select(_ game: Game, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selectedGameIds.contains(game.id) {
                selectedGameIds.remove(game.id)
                if selectedGame?.id == game.id {
                    selectedGame = selectedGames.last
                }
            } else {
                selectedGameIds.insert(game.id)
                selectedGame = game
            }
            selectionAnchorId = game.id
        } else if modifiers.contains(.shift), let anchor = selectionAnchorId,
                  let a = explorerGames.firstIndex(where: { $0.id == anchor }),
                  let b = explorerGames.firstIndex(where: { $0.id == game.id }) {
            selectedGameIds = Set(explorerGames[min(a, b)...max(a, b)].map(\.id))
            selectedGame = game
        } else {
            selectedGameIds = [game.id]
            selectedGame = game
            selectionAnchorId = game.id
        }
    }

    func clearSelection() {
        selectedGameIds = []
        selectedGame = nil
    }

    /// Games a context-menu command applies to: the selection if the clicked game
    /// is part of it, otherwise just the clicked game (Finder behaviour)
    func contextTargets(for game: Game) -> [Game] {
        selectedGameIds.contains(game.id) && selectedGameIds.count > 1 ? selectedGames : [game]
    }

    // MARK: - Emulation core dialog

    func openCoreDialog(for games: [Game]) {
        let ids = games.filter { $0.source == .local }.map(\.id)
        guard !ids.isEmpty else { return }
        coreDialogGameIds = ids
    }
}
