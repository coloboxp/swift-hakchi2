import AppKit
import SwiftUI

/// Modules menu (port of Hakchi2-CE's Modules menu): manager tabs, one item per
/// repository, repository management, the modules report, and Bluetooth.
struct ModulesCommands: Commands {
    @ObservedObject var appState: AppState
    @ObservedObject var config = AppConfig.shared
    @ObservedObject var bluetooth = BluetoothState.shared

    var body: some Commands {
        CommandMenu("Modules") {
            Button("Module Manager...") { open(.installed) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Install Extra Modules...") { open(.library) }
            Button("Uninstall Extra Modules...") { open(.installed) }

            Divider()

            if config.modRepositories.isEmpty {
                Button("No Repositories Configured") {}.disabled(true)
            } else {
                ForEach(config.modRepositories) { repo in
                    Button(repo.name) {
                        ModuleRouter.shared.repository = repo
                        open(.modHub)
                    }
                }
            }
            Button("Manage Repositories...") {
                ModuleRouter.shared.showRepositoryManager = true
            }

            Divider()

            Button("Generate Modules Report...") {
                Task { await ModuleReportAction.run(appState: appState) }
            }

            // CE shows Bluetooth only when the console has bluetoothctl
            if bluetooth.isAvailable && appState.deviceManager.isConnected {
                Divider()
                Button("Bluetooth...") { ModuleRouter.shared.showBluetooth = true }
            }
        }
    }

    private func open(_ tab: ModuleTab) {
        ModuleRouter.shared.tab = tab
        appState.showModuleManager = true
    }
}

/// "Generate modules report": installed (when connected) and library modules as HTML
@MainActor
enum ModuleReportAction {
    static func run(appState: AppState) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "hmod_audit.html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let library = ModLibrary.standard()
        var installed: [ModReportGenerator.Entry]?
        if appState.deviceManager.isConnected, let shell = appState.deviceManager.sshService,
           let names = try? await HmodService(ssh: shell).installedHmods() {
            installed = names.map { name in
                ModReportGenerator.Entry(rawName: name, frontMatter: library.module(named: name)?.readme?.frontMatter ?? [])
            }
        }
        let available = library.modules.map {
            ModReportGenerator.Entry(rawName: $0.id, frontMatter: $0.readme?.frontMatter ?? [])
        }
        do {
            try ModReportGenerator.html(installed: installed, available: available)
                .write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
