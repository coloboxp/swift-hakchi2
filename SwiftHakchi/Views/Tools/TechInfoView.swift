import SwiftUI
import AppKit

/// Technical information (port of CE's TechInfo): app, local hakchi.hmod,
/// shell, running hakchi, remote paths, memory stats, console and app settings,
/// plus the debug log. "Copy" puts everything on the clipboard for bug reports.
struct TechInfoView: View {
    @EnvironmentObject var appState: AppState

    struct Section: Identifiable {
        let title: String
        var rows: [(String, String)]
        var id: String { title }
    }

    @State private var sections: [Section] = []
    @State private var log = ""
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(sections) { section in
                    SwiftUI.Section(section.title) {
                        ForEach(section.rows.indices, id: \.self) { i in
                            LabeledContent(section.rows[i].0) {
                                Text(section.rows[i].1).textSelection(.enabled)
                            }
                        }
                    }
                }
                SwiftUI.Section("Log (/tmp/swifthakchi-debug.log)") {
                    Text(log.isEmpty ? "—" : log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .overlay { if isLoading { ProgressView() } }
            HStack {
                Button("Refresh") { load() }
                Spacer()
                Button("Copy") { copy() }
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { load() }
    }

    private func load() {
        isLoading = true
        let dm = appState.deviceManager
        var result: [Section] = []

        // General
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let config = AppConfig.shared
        let gameDirs = (try? FileManager.default.contentsOfDirectory(atPath: config.gamesDirectory.path)) ?? []
        result.append(Section(title: "General information", rows: [
            ("Swift Hakchi2 version", bundleVersion),
            ("Data folder", AppConfig.configDirectory.path),
            ("Games", "\(gameDirs.filter { $0.hasPrefix("CLV-") }.count) folders"),
            ("Developer tools", UserDefaults.standard.bool(forKey: "showDeveloperTools") ? "Shown" : "Hidden"),
        ]))

        // Local hakchi.hmod
        let local = (try? PayloadService.shared.hmodFile("var/version"))
            .map { ConsoleTools.parseHakchiVersion(String(decoding: $0, as: UTF8.self)) } ?? .init()
        let latestPath = config.dataDirectory.appendingPathComponent("hakchi-latest.hmod").path
        result.append(Section(title: "Local hakchi.hmod", rows: [
            ("Boot version", local.boot), ("Kernel version", local.kernel), ("Script version", local.script),
            ("Source", FileManager.default.fileExists(atPath: latestPath) ? "data/hakchi-latest.hmod" : "bundled"),
        ]))

        // Shell
        var shellRows: [(String, String)] = [("Connected", dm.isConnected ? "Yes" : "No")]
        if dm.isConnected {
            shellRows += [("Shell", "SSH over RNDIS"), ("Can interact", dm.canInteract ? "Yes" : "No"),
                          ("Minimal memboot (recovery)", dm.isRecoveryMode ? "Yes" : "No"),
                          ("Console unique ID", dm.uniqueId),
                          ("Detected console type", dm.consoleType.displayName),
                          ("Custom firmware", dm.customFirmwareLoaded ? "Yes" : "No")]
        }
        result.append(Section(title: "Shell information", rows: shellRows))
        if dm.isConnected {
            result.append(Section(title: "Running hakchi.hmod", rows: [
                ("Boot version", dm.bootVersion), ("Kernel version", dm.kernelVersion), ("Script version", dm.scriptVersion),
            ]))
        }
        result.append(Section(title: "Settings", rows: [
            ("Separate games for multiboot", config.separateGameStorage ? "Yes" : "No"),
            ("Upload games compressed", config.uploadCompressed ? "Yes" : "No"),
        ]))
        sections = result
        log = (try? String(contentsOfFile: "/tmp/swifthakchi-debug.log", encoding: .utf8))
            .map { String($0.suffix(20_000)) } ?? ""

        guard dm.isConnected, dm.canInteract, !dm.isRecoveryMode, let shell = dm.sshService else {
            isLoading = false
            return
        }
        Task {
            let tools = ConsoleToolsService(shell: shell)
            let paths = await tools.remotePaths()
            let stats = await tools.memoryStats()
            let settings = await tools.consoleSettings()
            var memory: [(String, String)] = [
                ("Storage total", ConsoleTools.sizeString(stats.storageTotal)),
                ("Storage used", ConsoleTools.sizeString(stats.storageUsed)),
                ("Storage free", ConsoleTools.sizeString(stats.storageFree)),
                ("External saves", stats.externalSaves ? "Yes" : "No"),
                ("Saves", ConsoleTools.sizeString(stats.saveStatesSize)),
                ("All games", ConsoleTools.sizeString(stats.allGamesSize)),
                ("Non multiboot games", ConsoleTools.sizeString(stats.nonMultibootGamesSize)),
                ("Extra files", ConsoleTools.sizeString(stats.extraFilesSize)),
            ]
            memory += stats.collections.sorted { $0.key < $1.key }.map { ("\($0.key) games", ConsoleTools.sizeString($0.value)) }
            sections.append(Section(title: "Paths", rows: paths))
            sections.append(Section(title: "Memory stats", rows: memory))
            sections.append(Section(title: "Console settings", rows: settings))
            isLoading = false
        }
    }

    private func copy() {
        var text = sections.map { s in
            "## \(s.title)\n" + s.rows.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        text += "\n\n## Log\n" + log
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
