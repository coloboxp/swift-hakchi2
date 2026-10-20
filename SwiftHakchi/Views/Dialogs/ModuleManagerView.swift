import SwiftUI

/// Module (hmod) manager: installed modules, the local library, and the Mod Hub.
///
/// Installs and removals are staged on the console and applied by hakchi on the
/// next boot (see `HmodService`), so the bottom bar offers "Apply & Reboot".
struct ModuleManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @ObservedObject private var router = ModuleRouter.shared
    @StateObject private var holder = ModelHolder()

    var body: some View {
        Group {
            if let model = holder.model {
                content(model)
            } else {
                ProgressView().frame(width: 820, height: 600)
            }
        }
        .onAppear {
            if holder.model == nil { holder.model = ModuleManagerModel(appState: appState) }
            holder.model?.loadInstalled()
        }
    }

    private func content(_ model: ModuleManagerModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Module Manager")
                    .font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if !appState.deviceManager.isConnected {
                Label("Connect a console with hakchi installed to install or remove modules.",
                      systemImage: "cable.connector.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.1))
            }

            Picker("", selection: $router.tab) {
                Text("Installed").tag(ModuleTab.installed)
                Text("Library").tag(ModuleTab.library)
                Text("Mod Hub").tag(ModuleTab.modHub)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch router.tab {
            case .installed: ModuleInstalledTab(model: model)
            case .library: ModuleLibraryTab(model: model)
            case .modHub: ModHubTab(model: model)
            }

            ModuleMessagesBar(model: model)
        }
        .frame(width: 820, height: 600)
        .onChange(of: appState.deviceManager.isConnected) { _, _ in model.loadInstalled() }
    }
}

/// Keeps the model alive across view updates (it needs the AppState from the environment)
@MainActor
private final class ModelHolder: ObservableObject {
    @Published var model: ModuleManagerModel?
}

/// Error/status line and the pending-changes bar
private struct ModuleMessagesBar: View {
    @ObservedObject var model: ModuleManagerModel

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            } else if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            }
            Divider()
            HStack {
                if model.hasPendingChanges {
                    Text("\(model.pendingInstalls.count + model.pendingUninstalls.count) change(s) pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Apply & Reboot") { model.applyAndReboot() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasPendingChanges || !model.isConnected || model.isWorking || !model.busyItems.isEmpty)
                    .help("Reboot the console; hakchi installs/removes the pending modules during boot")
            }
            .padding()
        }
    }
}
