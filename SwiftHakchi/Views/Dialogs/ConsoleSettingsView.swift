import SwiftUI

/// Console and sync settings (CE's Settings menu: controller hacks, epilepsy protection,
/// global command-line arguments, sync options). Shown as a tab in Settings.
struct ConsoleSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var config = AppConfig.shared
    @State private var showDeveloper = false

    private var console: Binding<ConsoleSettings> {
        Binding(get: { config.sync.console }, set: { config.sync.console = $0; config.save() })
    }

    private func syncFlag(_ keyPath: WritableKeyPath<SyncSettings, Bool>) -> Binding<Bool> {
        Binding(get: { config.sync[keyPath: keyPath] }, set: { config.sync[keyPath: keyPath] = $0; config.save() })
    }

    private var isSnes: Bool { appState.collectionConsole.isSNES }

    var body: some View {
        Form {
            Section("Controller hacks") {
                Toggle("Use button combination to reset", isOn: console.resetHack)
                if config.sync.console.resetHack {
                    ButtonComboPicker(mask: console.resetCombination, snes: isSnes)
                }
                Toggle("Use \"Select+A/B\" to enable autofire on A/B", isOn: console.autofireHack)
                Toggle("Use X/Y on Classic Controller as autofire A/B", isOn: console.autofireXYHack)
                Toggle("\"Up+A+B = Start\" on 2nd controller (Famicom)", isOn: console.fcStart)
            }
            Section {
                Toggle("Disable epilepsy protection", isOn: Binding(
                    get: { config.sync.console.antiArmetLevel > 0 },
                    set: { console.wrappedValue.antiArmetLevel = $0 ? 2 : 0 }))
            }
            Section("Global command-line arguments (experts only)") {
                TextField("Kachikachi (NES)", text: console.extraArgsKachikachi)
                TextField("Canoe (SNES)", text: console.extraArgsCanoe)
                TextField("RetroArch", text: console.extraArgsRetroarch)
            }
            Section("Sync") {
                Toggle("Separate games for multiboot", isOn: syncFlag(\.separateGamesForMultiboot))
                Toggle("Use linked sync", isOn: syncFlag(\.syncLinked))
                Toggle("Always copy original games", isOn: syncFlag(\.alwaysCopyOriginalGames))
                if showDeveloper {
                    Toggle("Upload to /tmp (developer test)", isOn: syncFlag(\.uploadToTmp))
                }
            }
            HStack {
                Spacer()
                Button("Save Settings to Console Now") { appState.saveSettingsToConsole() }
                    .disabled(!appState.deviceManager.isConnected)
                    .help("Writes these settings to the console and reboots it")
            }
        }
        .formStyle(.grouped)
        .onTapGesture(count: 3) { showDeveloper.toggle() }
    }
}

/// Reset button combination picker (CE's SelectNesButtonsForm / SelectSnesButtonsForm)
struct ButtonComboPicker: View {
    @Binding var mask: UInt32
    let snes: Bool

    var body: some View {
        let buttons = snes ? ControllerButtons.snesButtons : ControllerButtons.nesButtons
        VStack(alignment: .leading, spacing: 4) {
            Text("Reset combination:").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), alignment: .leading) {
                ForEach(buttons, id: \.1) { button, name in
                    Toggle(name, isOn: Binding(
                        get: { mask & button.rawValue != 0 },
                        set: { mask = $0 ? mask | button.rawValue : mask & ~button.rawValue }))
                }
            }
        }
    }
}
