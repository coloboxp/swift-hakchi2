import SwiftUI
import AppKit

/// Export games to a USB/SD drive (port of CE's ExportGamesDialog). Mounted
/// removable volumes replace Windows drive letters.
struct ExportGamesView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var volumes: [URL] = []
    @State private var volume: URL?
    @State private var linked = false
    @State private var createSaves = true

    /// Linked export only works when the games folder is on the target drive
    private var linkedPossible: Bool {
        guard let volume else { return false }
        let gamesVolume = (try? AppConfig.shared.gamesDirectory.resourceValues(forKeys: [.volumeURLKey]))?.volume
        return gamesVolume?.standardizedFileURL == volume.standardizedFileURL
    }

    private var consoleType: ConsoleType { appState.effectiveConsoleType }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a drive to export to:").font(.headline)
            Picker("Drive", selection: $volume) {
                ForEach(volumes, id: \.self) { url in
                    Text(Self.label(for: url)).tag(URL?.some(url))
                }
            }
            .labelsHidden()
            Toggle("Linked export", isOn: $linked).disabled(!linkedPossible)
            Toggle("Create saves folder", isOn: $createSaves)
            Text("Games go to hakchi/games/\(consoleType.syncCode) on the drive, in one menu page (folders follow the sync settings once available).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Refresh Drives") { loadVolumes() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export") { export() }.keyboardShortcut(.defaultAction).disabled(volume == nil)
            }
        }
        .padding()
        .frame(width: 440)
        .onAppear { loadVolumes() }
        .onChange(of: volume) { _, _ in if !linkedPossible { linked = false } }
    }

    private func loadVolumes() {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsReadOnlyKey]
        volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return (v?.volumeIsRemovable == true || v?.volumeIsEjectable == true) && v?.volumeIsReadOnly != true
            }
        if volume == nil || !volumes.contains(where: { $0 == volume }) { volume = volumes.first }
    }

    static func label(for url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeAvailableCapacityKey])
        let free = v?.volumeAvailableCapacity.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "?"
        return "\(v?.volumeName ?? url.lastPathComponent) (\(free) free)"
    }

    private func export() {
        guard let volume else { return }
        let games = appState.gameManager.games
        var exportGames: [ExportGame] = games.filter { $0.isSelected && $0.source == .local }.map {
            ExportGame(code: $0.code, kind: .local(directory: URL(fileURLWithPath: $0.romPath)))
        }
        let selectedStock = Set(games.filter { $0.isStock && $0.isSelected }.map(\.code))
        if let cache = StockGameCache.load(deviceId: AppConfig.shared.lastDeviceId) {
            exportGames += cache.games.filter { selectedStock.contains($0.code) }
                .map { ExportGame(code: $0.code, kind: .stock(desktop: $0.desktopContent)) }
        }
        var layout = FlatExportLayout(consoleType: consoleType)
        if linked, linkedPossible {
            // Path of the games folder relative to the drive, as the console sees it
            let relative = AppConfig.shared.gamesDirectory.standardizedFileURL.path
                .dropFirst(volume.standardizedFileURL.path.count)
            layout.linkedMediaPath = "/media" + (relative.hasPrefix("/") ? relative : "/" + relative)
        }
        let plan = layout.plan(games: exportGames)
        let gameCount = exportGames.count
        let root = GameExporter.exportRoot(volume: volume, consoleType: consoleType)
        let savesFolder = createSaves ? volume.appendingPathComponent("hakchi/saves", isDirectory: true) : nil
        dismiss()

        appState.showTaskProgress = true
        appState.taskRunner.run(name: "Exporting games") { runner in
            let written = try GameExporter.export(plan: plan, to: root) { status, fraction in
                runner.updateProgress(status: status, fraction: fraction)
            }
            if let savesFolder {
                try FileManager.default.createDirectory(at: savesFolder, withIntermediateDirectories: true)
            }
            runner.updateProgress(status: "Exported \(gameCount) games (\(written) files written).", fraction: 1)
            await MainActor.run { _ = NSWorkspace.shared.open(root) }
        }
    }
}
