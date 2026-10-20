import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Box-art candidates for one game, shown in the "Select cover" sheet
struct CoverChoice: Identifiable, Equatable {
    let code: String
    let name: String
    let candidates: [URL]
    var id: String { code }
}

/// UI side of the library commands (Hakchi2-CE's game context menu and File menu).
extension AppState {
    // MARK: - Small dialogs

    /// Text prompt (CE's StringInputForm). Returns nil when cancelled.
    func promptString(title: String, message: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// "Done" message, unless pop-ups are disabled (CE: DisablePopups)
    func notifyDone(_ message: String) {
        guard !LibrarySettings.shared.values.disablePopups else {
            statusMessage = message
            return
        }
        let alert = NSAlert()
        alert.messageText = "Done"
        alert.informativeText = message
        alert.runModal()
    }

    func showErrors(_ errors: [String], title: String) {
        guard !errors.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = errors.prefix(15).joined(separator: "\n") + (errors.count > 15 ? "\n…" : "")
        alert.runModal()
    }

    private func localCodes(_ games: [Game]) -> [String] {
        games.filter { $0.source == .local }.map(\.id)
    }

    private func refreshSelectedGame() {
        if let current = selectedGame, let updated = gameManager.games.first(where: { $0.id == current.id }) {
            selectedGame = updated
        }
    }

    // MARK: - Context menu commands

    func showInFinder(_ games: [Game]) {
        let urls = games.filter { $0.source == .local }.map { gameManager.gameDirectory($0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func addPrefix(to games: [Game]) {
        guard let prefix = promptString(title: "Enter a Prefix",
                                        message: "The prefix is added before the name, e.g. \"SMB: Super Mario Bros\"."),
              !prefix.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        gameManager.addPrefix(prefix, to: localCodes(games))
        refreshSelectedGame()
    }

    func removePrefix(from games: [Game]) {
        guard let prefix = promptString(title: "Enter a Prefix", message: "Remove this prefix from the selected names."),
              !prefix.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        gameManager.removePrefix(prefix, from: localCodes(games))
        refreshSelectedGame()
    }

    func setRegion(_ region: String, for games: [Game]) {
        gameManager.setRegion(region, for: localCodes(games))
        refreshSelectedGame()
    }

    /// CE's scraper walks through the selected games one by one
    func scrapeGames(_ games: [Game]) {
        let local = games.filter { $0.source == .local }
        guard let first = local.first else { return }
        scraperQueue = local.dropFirst().map(\.id)
        selectedGame = first
        showScraper = true
    }

    /// Called when the scraper sheet closes: open it for the next queued game
    func advanceScraperQueue() {
        guard !scraperQueue.isEmpty else { return }
        let next = scraperQueue.removeFirst()
        guard let game = gameManager.games.first(where: { $0.id == next }) else { return advanceScraperQueue() }
        selectedGame = game
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            self.showScraper = true
        }
    }

    func scanForCovers(_ games: [Game]) {
        let ambiguous = gameManager.scanForCovers(localCodes(games))
        coverChoices = ambiguous.compactMap { code, urls in
            gameManager.games.first { $0.id == code }.map { CoverChoice(code: code, name: $0.name, candidates: urls) }
        }
        .sorted { $0.name < $1.name }
        refreshSelectedGame()
    }

    func deleteCovers(_ games: [Game]) {
        gameManager.resetCover(for: localCodes(games))
        refreshSelectedGame()
    }

    /// Ask for an image and set it as the cover of one game
    func browseForCover(_ game: Game) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.title = "Choose Box Art for \(game.name)"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        setCover(data, for: game)
    }

    func pasteCover(_ game: Game) {
        guard let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation else { return }
        setCover(tiff, for: game)
    }

    func setCover(_ data: Data, for game: Game) {
        do {
            try gameManager.setCover(data, for: game.id)
            refreshSelectedGame()
        } catch {
            showErrors([error.localizedDescription], title: "Could not set the box art")
        }
    }

    func archiveGames(_ games: [Game]) {
        let local = games.filter { $0.source == .local }
        guard !local.isEmpty else { return }
        let destination: URL
        if local.count == 1 {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = GameManagerService.archiveFileName(code: local[0].code, name: local[0].name)
            panel.allowedContentTypes = [UTType(filenameExtension: "clvg") ?? .data]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.prompt = "Archive Here"
            panel.message = "Choose a folder for the \(local.count) game archives"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        do {
            try gameManager.archiveGames(local.map(\.id), to: destination)
            notifyDone("Archived \(local.count) game(s).")
        } catch {
            showErrors([error.localizedDescription], title: "Archiving failed")
        }
    }

    func canCompress(_ game: Game) -> Bool {
        game.source == .local && GameCompression.canCompress(gameDirectory: gameManager.gameDirectory(game), code: game.code)
    }

    func canDecompress(_ game: Game) -> Bool {
        game.source == .local && GameCompression.canDecompress(gameDirectory: gameManager.gameDirectory(game), code: game.code)
    }

    func compressGames(_ games: [Game], compress: Bool) {
        let errors = gameManager.compressGames(localCodes(games), compress: compress)
        showErrors(errors, title: compress ? "Some games could not be compressed" : "Some games could not be decompressed")
        refreshSelectedGame()
    }

    func repairGames(_ games: [Game]) {
        let errors = gameManager.repairGames(localCodes(games)) { [weak self] name, files in
            self?.chooseArchiveEntry(archive: name, entries: files)
        }
        showErrors(errors, title: "Some games could not be repaired")
        refreshSelectedGame()
        if errors.isEmpty { notifyDone("Repaired \(localCodes(games).count) game(s).") }
    }

    // MARK: - File menu commands

    func restoreOriginalGames() {
        let alert = NSAlert()
        alert.messageText = "Restore Original Games?"
        alert.informativeText = "All built-in games will be selected again for the console."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let count = gameManager.restoreOriginalGames(consoleType: effectiveConsoleType)
        notifyDone("Restored \(count) original game(s).")
    }

    // MARK: - TheGamesDB

    /// Validate a newly entered TheGamesDB key before enriching the whole library
    func enrichLibraryIfKeyValid(_ key: String) {
        Task {
            do {
                _ = try await ScraperService().validateApiKey(key)
                enrichLibrary()
            } catch {
                statusMessage = "TheGamesDB API key is not valid"
            }
        }
    }

    // MARK: - Drag and drop

    /// Files dropped on the main window, handled like CE's `dragDrop`
    func handleDroppedFiles(_ urls: [URL]) {
        let fm = FileManager.default
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "bmp", "gif", "tif", "tiff"]
        var games: [URL] = []
        var modules: [URL] = []

        // A single image sets the box art of the selected game
        if urls.count == 1, imageExts.contains(urls[0].pathExtension.lowercased()) {
            if let game = selectedGame, game.source == .local, let data = try? Data(contentsOf: urls[0]) {
                setCover(data, for: game)
            }
            return
        }

        for url in urls {
            switch url.pathExtension.lowercased() {
            case "hrepo":
                addRepository(from: url)
            case "hmod":
                modules.append(url)
            case let ext where ["zip", "7z"].contains(ext) && archiveContainsHmod(url):
                modules.append(url)
            default:
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { games.append(url) }
            }
        }
        if !games.isEmpty { importGames(urls: games) }
        // CE copies dropped modules to user_mods and opens the module dialog
        if !modules.isEmpty {
            do {
                let added = try ModLibrary.standard().add(urls: modules)
                statusMessage = "Added \(added.count) module(s) to the library"
                showModuleManager = true
            } catch {
                showErrors([error.localizedDescription], title: "Could not add the modules")
            }
        }
    }

    /// `.hrepo`: front matter with `Name:` and `Link:` (CE)
    func addRepository(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8), let repo = ModRepository.parseHrepo(text) else {
            showErrors(["\(url.lastPathComponent) is not a valid .hrepo file."], title: "Invalid repository file")
            return
        }
        let config = AppConfig.shared
        if !config.modRepositories.contains(where: { $0.url == repo.url }) {
            config.modRepositories.append(repo)
            config.save()
        }
        notifyDone("Added repository \(repo.name).")
    }

    private func archiveContainsHmod(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return data.range(of: Data(".hmod".utf8)) != nil
    }

    // MARK: - Keyboard

    /// Space: put the selected games on the console bar or take them off
    func toggleSyncSelection() {
        let targets = selectedGames
        guard !targets.isEmpty else { return }
        let newValue = !targets.allSatisfy(\.isSelected)
        for game in targets {
            if let i = gameManager.games.firstIndex(where: { $0.id == game.id }) {
                gameManager.games[i].isSelected = newValue
            }
        }
    }

    func selectAllInExplorer() {
        selectedGameIds = Set(explorerGames.map(\.id))
        if selectedGame == nil { selectedGame = explorerGames.first }
    }
}
