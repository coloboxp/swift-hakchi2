import SwiftUI
import UniformTypeIdentifiers

/// Sheets, drag and drop, and scraper queue handling for the library commands.
/// Attached once to the main window (`ContentView`).
struct LibrarySheets: ViewModifier {
    @EnvironmentObject var appState: AppState

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { !appState.coverChoices.isEmpty },
                set: { if !$0 { appState.coverChoices = [] } }
            )) {
                SelectCoverView(choices: appState.coverChoices)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $appState.showNewCustomApp) {
                NewCustomAppView().environmentObject(appState)
            }
            .sheet(isPresented: $appState.showPrepareArtFolders) {
                PrepareArtFoldersView()
            }
            .sheet(isPresented: Binding(
                get: { appState.gameGenieGameId != nil },
                set: { if !$0 { appState.gameGenieGameId = nil } }
            )) {
                GameGenieView(gameId: appState.gameGenieGameId ?? "").environmentObject(appState)
            }
            .sheet(isPresented: Binding(
                get: { appState.spineGameId != nil },
                set: { if !$0 { appState.spineGameId = nil } }
            )) {
                SpineView(gameId: appState.spineGameId ?? "").environmentObject(appState)
            }
            // "Scrape selected games" walks through the queue one sheet at a time
            .onChange(of: appState.showScraper) { _, showing in
                if !showing { appState.advanceScraperQueue() }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                loadURLs(providers) { appState.handleDroppedFiles($0) }
                return true
            }
    }

    private func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.withLock { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let result = lock.withLock { urls }
            MainActor.assumeIsolated { completion(result) }
        }
    }
}

/// Explorer keyboard shortcuts (CE: Ctrl+A select all, Esc deselect, Space toggles,
/// Del deletes). Only active while the grid has focus, so text fields keep their keys.
struct ExplorerKeyboard: ViewModifier {
    @EnvironmentObject var appState: AppState
    let onDelete: ([Game]) -> Void

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.space) {
                appState.toggleSyncSelection()
                return .handled
            }
            .onKeyPress(.escape) {
                appState.clearSelection()
                return .handled
            }
            .onKeyPress(.delete) {
                let local = appState.selectedGames.filter { $0.source == .local }
                guard !local.isEmpty else { return .ignored }
                onDelete(local)
                return .handled
            }
            .onKeyPress(characters: ["a"]) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                appState.selectAllInExplorer()
                return .handled
            }
    }
}
