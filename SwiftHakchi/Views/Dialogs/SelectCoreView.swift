import SwiftUI

/// "Select emulation core" dialog (port of Hakchi2-CE's `SelectCoreDialog`).
///
/// Pick rows in the table, choose a console (system) and a core, then Apply.
/// Applying rewrites each game's Exec line: `<core launcher> <rom> <args>`.
struct SelectCoreView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @ObservedObject private var catalog = CoreCatalog.shared

    let gameIds: [String]

    @State private var selectedRows: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\Row.name)]
    @State private var system = Self.unassigned
    @State private var coreBin = Self.unassigned
    @State private var showAllSystems = false
    @State private var resetArgs = false
    @State private var commandText = ""
    @State private var commandEdited = false
    @State private var isRefreshing = false
    @State private var refreshError: String?
    @State private var hasApplied = false

    private static let unassigned = "Unassigned"

    /// One table row
    struct Row: Identifiable {
        let id: String
        let name: String
        let ext: String
        let system: String
        let core: String
    }

    // MARK: - Data

    private var games: [Game] {
        gameIds.compactMap { id in appState.gameManager.games.first { $0.id == id } }
    }

    private var rows: [Row] {
        games.map { game in
            Row(id: game.id, name: game.name, ext: Self.romExtension(of: game),
                system: game.system.isEmpty ? Self.unassigned : game.system,
                core: catalog.core(game.core)?.name ?? (game.core.isEmpty ? Self.unassigned : game.core))
        }
        .sorted(using: sortOrder)
    }

    private var selectedGames: [Game] {
        games.filter { selectedRows.contains($0.id) }
    }

    /// Systems offered: those that can run the first selected game's extension,
    /// or everything with "Show all" (CE behaviour)
    private var systemOptions: [String] {
        var list: [String]
        if showAllSystems || selectedGames.isEmpty {
            list = catalog.allSystems
        } else {
            let ext = Self.romExtension(of: selectedGames[0])
            list = catalog.systems(forExtension: ext)
            if list.isEmpty {
                let known = SystemCatalog.system(forExtension: ext)
                if !known.isUnknown { list = [known.name] }
            }
        }
        // Keep the current choice visible even if the filter would hide it
        if system != Self.unassigned && !list.contains(system) { list.append(system) }
        return [Self.unassigned] + list.sorted()
    }

    private var coreOptions: [CoreInfo] {
        system == Self.unassigned ? catalog.allCores : catalog.cores(forSystem: system)
    }

    private var chosenCore: CoreInfo? {
        coreBin == Self.unassigned ? nil : catalog.core(coreBin)
    }

    private var command: GameManagerService.CoreCommand {
        if commandEdited && selectedGames.count == 1 { return .custom(commandText) }
        guard let core = chosenCore else { return .keep }
        return .core(core, resetArgs: resetArgs)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Emulation Core")
                .font(.title2.bold())
            Text("Select the games, then choose the console and core to use for them:")
                .foregroundStyle(.secondary)

            Table(rows, selection: $selectedRows, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name)
                TableColumn("Ext", value: \.ext).width(60)
                TableColumn("Console", value: \.system)
                TableColumn("Core", value: \.core).width(min: 90, ideal: 140)
            }
            .frame(minHeight: 180)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Console:")
                    HStack {
                        Picker("", selection: $system) {
                            ForEach(systemOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        Toggle("Show all", isOn: $showAllSystems)
                    }
                }
                GridRow {
                    Text("Core:")
                    Picker("", selection: $coreBin) {
                        Text(Self.unassigned).tag(Self.unassigned)
                        ForEach(coreOptions) { core in
                            Text(core.label).tag(core.bin)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("Command line:")
                    TextField(selectedGames.count == 1 ? "" : "Shown for a single game only", text: Binding(
                        get: { commandText },
                        set: { commandText = $0; commandEdited = true }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .disabled(selectedGames.count != 1)
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Toggle("Also reset to default parameters", isOn: $resetArgs)
                }
            }
            .disabled(selectedGames.isEmpty)

            Text("For advanced users only: the command line is used exactly as typed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            coreSourceInfo

            HStack {
                Button(isRefreshing ? "Refreshing..." : "Refresh Cores from Console") {
                    refreshCores()
                }
                .disabled(!appState.deviceManager.isConnected || isRefreshing)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedGames.isEmpty)
            }
        }
        .padding()
        .frame(width: 680, height: 600)
        .onAppear {
            selectedRows = Set(gameIds)
            loadChoicesFromSelection()
        }
        .onChange(of: selectedRows) { _, _ in loadChoicesFromSelection() }
        .onChange(of: system) { _, newSystem in
            // Keep the core if it supports the new system, else use the system's default
            if let core = chosenCore, newSystem == Self.unassigned || core.systems.contains(newSystem) { return }
            coreBin = defaultCore(for: newSystem)?.bin ?? Self.unassigned
        }
        .onChange(of: coreBin) { _, _ in updatePreview() }
        .onChange(of: resetArgs) { _, _ in updatePreview() }
    }

    private var coreSourceInfo: some View {
        let libretro = catalog.allCores.filter { $0.kind == .libretro }.count
        let text: String
        if let date = catalog.consoleRefreshDate {
            text = "\(libretro) installed cores read from the console on \(date.formatted(date: .abbreviated, time: .shortened))."
        } else {
            text = "Only built-in emulators are known. Connect the console to read its installed cores."
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(text)
            if let refreshError {
                Text(refreshError).foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    /// Show the first selected game's system and core (CE preselects them)
    private func loadChoicesFromSelection() {
        commandEdited = false
        guard let first = selectedGames.first else {
            commandText = ""
            return
        }
        system = first.system.isEmpty ? Self.unassigned : first.system
        if !first.core.isEmpty, catalog.core(first.core) != nil {
            coreBin = first.core
        } else {
            coreBin = defaultCore(for: system)?.bin ?? Self.unassigned
        }
        updatePreview()
    }

    /// System's default core if installed, else the first core that runs it
    private func defaultCore(for system: String) -> CoreInfo? {
        guard system != Self.unassigned else { return nil }
        let known = SystemCatalog.system(named: system)
        if !known.isUnknown, let core = catalog.core(known.defaultCore) { return core }
        return catalog.cores(forSystem: system).first
    }

    private func updatePreview() {
        commandEdited = false
        if selectedGames.count == 1, let game = selectedGames.first {
            let cmd: GameManagerService.CoreCommand = chosenCore.map { .core($0, resetArgs: resetArgs) } ?? .keep
            commandText = appState.gameManager.previewCommand(for: game, command: cmd)
        } else {
            commandText = ""
        }
    }

    private func apply() {
        let codes = selectedGames.map(\.id)
        appState.gameManager.applyCore(
            to: codes,
            system: system == Self.unassigned ? "" : system,
            coreBin: chosenCore?.bin ?? "",
            command: command)
        hasApplied = true
        // Refresh the detail panel if it shows one of these games
        if let current = appState.selectedGame,
           let updated = appState.gameManager.games.first(where: { $0.id == current.id }) {
            appState.selectedGame = updated
        }
        updatePreview()
    }

    private func refreshCores() {
        guard let shell = appState.deviceManager.sshService else { return }
        isRefreshing = true
        refreshError = nil
        Task {
            do {
                try await catalog.refreshFromConsole(shell: shell)
            } catch {
                refreshError = "Could not read cores: \(error.localizedDescription)"
            }
            isRefreshing = false
        }
    }

    // MARK: - Helpers

    /// Extension of the game's ROM, ignoring .7z/.zip wrappers (CE behaviour)
    static func romExtension(of game: Game) -> String {
        var rom = DesktopFile.splitExec(game.commandLine).args.first ?? ""
        for wrapper in [".7z", ".zip"] where rom.lowercased().hasSuffix(wrapper) {
            rom = String(rom.dropLast(wrapper.count))
        }
        let ext = (rom as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "" : "." + ext
    }
}
