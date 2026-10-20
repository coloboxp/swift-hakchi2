import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Save-State Manager (port of CE's SaveStateManager): list, export (.clvs),
/// import and delete save states. Selecting one game shows its screenshots.
struct SaveStateManagerView: View {
    @EnvironmentObject var appState: AppState

    @State private var saves: [ConsoleTools.SaveState] = []
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\Row.name)]
    @State private var isBusy = false
    @State private var error: String?
    @State private var previews: [CGImage] = []
    @State private var previewCode: String?

    /// Table row with a display name for unknown games
    struct Row: Identifiable {
        let id: String
        let name: String
        let sizeKB: Int
        let flags: String
    }

    private var tools: ConsoleToolsService? {
        appState.deviceManager.sshService.map { ConsoleToolsService(shell: $0) }
    }

    private var rows: [Row] {
        saves.map { save in
            let local = appState.gameManager.games.first { $0.id == save.code }?.name
            return Row(id: save.code, name: save.name ?? local ?? "Unknown game", sizeKB: save.sizeKB, flags: save.flags)
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name)
                TableColumn("Code", value: \.id).width(110)
                TableColumn("Size", value: \.sizeKB) { Text("\($0.sizeKB) KB") }.width(80)
                TableColumn("Save slots", value: \.flags).width(90)
            }
            .overlay {
                if isBusy { ProgressView() }
                else if saves.isEmpty { Text("No save states").foregroundStyle(.secondary) }
            }

            if !previews.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(previews.indices, id: \.self) { i in
                            Image(decorative: previews[i], scale: 1)
                                .resizable().aspectRatio(contentMode: .fit).frame(height: 120)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 136)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal).textSelection(.enabled)
            }

            HStack {
                Button("Refresh") { refresh() }
                Spacer()
                Button("Import...") { importSaves() }
                Button("Export...") { exportSaves() }.disabled(selection.isEmpty)
                Button("Delete...", role: .destructive) { deleteSaves() }.disabled(selection.isEmpty)
            }
            .padding()
            .disabled(isBusy || tools == nil)
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { refresh() }
        .onDisappear { if let tools { Task { await tools.restartUI() } } }
        .onChange(of: selection) { _, new in loadPreviews(new.count == 1 ? new.first : nil) }
    }

    // MARK: - Actions

    private func run(_ work: @escaping (ConsoleToolsService) async throws -> Void) {
        guard let tools else { error = "Console not connected."; return }
        isBusy = true
        error = nil
        Task {
            do { try await work(tools) } catch { self.error = error.localizedDescription }
            isBusy = false
        }
    }

    private func refresh() {
        run { tools in saves = try await tools.listSaveStates() }
    }

    private func exportSaves() {
        let chosen = rows.filter { selection.contains($0.id) }
        if chosen.count == 1, let row = chosen.first {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "clvs") ?? .data]
            panel.nameFieldStringValue = Self.safeName(row.name) + ".clvs"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            run { tools in try await tools.exportSave(code: row.id, to: url) }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Export Here"
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            run { tools in
                for row in chosen {
                    try await tools.exportSave(code: row.id,
                                               to: dir.appendingPathComponent(Self.safeName(row.name) + ".clvs"))
                }
            }
        }
    }

    private func importSaves() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "clvs") ?? .data, .data]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        run { tools in
            try await tools.importSaves(urls)
            saves = try await tools.listSaveStates()
        }
    }

    private func deleteSaves() {
        guard KernelDialogs.confirm(title: "Are you sure?", message: "Do you really want to delete those save-states?") else { return }
        let codes = Array(selection)
        run { tools in
            try await tools.deleteSaves(codes: codes)
            selection = []
            saves = try await tools.listSaveStates()
        }
    }

    private func loadPreviews(_ code: String?) {
        previews = []
        previewCode = code
        guard let code, let tools else { return }
        Task {
            let images = (try? await tools.saveScreenshots(code: code)) ?? []
            if previewCode == code { previews = images }
        }
    }

    /// File name without characters macOS or CE reject
    static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: #"[/:\\?%*|"<>]"#, with: "", options: .regularExpression)
    }
}
