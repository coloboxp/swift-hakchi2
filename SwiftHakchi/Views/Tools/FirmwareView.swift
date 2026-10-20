import SwiftUI

/// Switch running firmware (port of CE's SelectFirmwareDialog): pick the stock
/// NAND firmware or a .hsqs image on the console or USB drive.
struct FirmwareView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var list: ConsoleToolsService.FirmwareList?
    /// nil = stock NAND ("_nand_")
    @State private var selected: String??
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select the firmware to run:").font(.headline)
            if let list {
                List(selection: $selected) {
                    Text("Default (NAND)" + (list.current == "_nand_" ? " (current)" : ""))
                        .tag(String?.none)
                    ForEach(list.paths, id: \.self) { path in
                        Text(((path as NSString).lastPathComponent as NSString).deletingPathExtension
                             + (path == list.current ? " (current)" : ""))
                            .help(path)
                            .tag(String?.some(path))
                    }
                }
                .frame(minHeight: 160)
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Switch") { switchFirmware() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(list == nil || selected == nil)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear { load() }
    }

    private func load() {
        guard let shell = appState.deviceManager.sshService else { error = "Console not connected."; return }
        Task {
            do {
                let result = try await ConsoleToolsService(shell: shell).firmwares()
                list = result
                selected = .some(result.current == "_nand_" ? nil : result.current)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func switchFirmware() {
        guard let list, let shell = appState.deviceManager.sshService, let choice = selected else { return }
        let target = choice ?? "_nand_"
        guard target != list.current else { dismiss(); return }
        let name = choice.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "Default (NAND)"
        Task {
            await ConsoleToolsService(shell: shell).switchFirmware(to: choice)
            appState.deviceManager.manualDisconnect()
            KernelDialogs.info(title: "Firmware",
                               message: "Upon rebooting, your running mini should be running the selected firmware \"\(name)\"!")
            dismiss()
        }
    }
}
