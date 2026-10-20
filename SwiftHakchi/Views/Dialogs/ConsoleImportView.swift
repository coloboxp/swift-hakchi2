import SwiftUI

/// Pick which games found on the console to copy into the library (CE's GameImporterForm)
struct ConsoleImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let games: [ConsoleGameImporter.FoundGame]
    @State private var selection: Set<String> = []

    private var localCodes: Set<String> {
        Set(appState.gameManager.games.filter { $0.source == .local }.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import Games from Console").font(.title2.bold())
            Text("Select the games to copy to this Mac. Games already in the library are replaced.")
                .foregroundStyle(.secondary)
            Table(games, selection: $selection) {
                TableColumn("Name") { game in
                    HStack {
                        Text(game.name)
                        if localCodes.contains(game.code) {
                            Text("in library").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                TableColumn("Path", value: \.remotePath)
                TableColumn("Size") { game in
                    Text(ByteCountFormatter.string(fromByteCount: game.size, countStyle: .file))
                }
                .width(80)
            }
            HStack {
                Button("Select New") {
                    selection = Set(games.filter { !localCodes.contains($0.code) }.map(\.id))
                }
                Spacer()
                let size = games.filter { selection.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
                Text(selection.isEmpty ? "No items selected"
                     : "\(selection.count) selected, \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    let chosen = games.filter { selection.contains($0.id) }
                    dismiss()
                    appState.importConsoleGames(chosen)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
        .padding()
        .frame(width: 720, height: 480)
        .onAppear { selection = Set(games.filter { !localCodes.contains($0.code) }.map(\.id)) }
    }
}

/// Sheets for the sync features, attached to the main window with one modifier
struct SyncSheets: ViewModifier {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var ui = SyncUIState.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { ui.foldersManagerPurpose != nil },
                                        set: { if !$0 { ui.foldersManagerPurpose = nil } })) {
                FoldersManagerView(purpose: ui.foldersManagerPurpose ?? .edit, console: appState.collectionConsole,
                                   games: appState.selectedMenuGames(), settings: appState.collectionSettings)
                    .environmentObject(appState)
            }
            .sheet(isPresented: Binding(get: { ui.foundConsoleGames != nil },
                                        set: { if !$0 { ui.foundConsoleGames = nil } })) {
                ConsoleImportView(games: ui.foundConsoleGames ?? [])
                    .environmentObject(appState)
            }
    }
}
