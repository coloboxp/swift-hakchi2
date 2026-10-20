import SwiftUI

/// Format SD Card (port of CE's SDFormat dialog, non-bootable layout).
/// CE's "Make card bootable" / "Copy everything from NAND" options rely on files
/// CE's own code no longer prepares, so they are not offered.
struct FormatSDView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var storeSaves = true
    @State private var copySaves = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Format the SD card inserted in the console").font(.headline)
            Toggle("Copy saves from NAND", isOn: $copySaves)
            // CE: copying saves forces "store saves on SD card"
            Toggle("Store saves on SD card", isOn: copySaves ? .constant(true) : $storeSaves)
                .disabled(copySaves)
            Text("The console reboots into recovery mode, formats the card with one Linux (ext4) partition and enables the SD-card U-Boot. Afterwards hakchi uses the card for games.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Format") { format() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func format() {
        guard KernelDialogs.confirm(title: "Are you sure?",
                                    message: "Are you sure you want to format the SD card inserted in the classic?\n\nThis will erase all data present on the card!")
        else { return }
        let store = storeSaves || copySaves
        let copy = copySaves
        dismiss()
        appState.runRecovery("Formatting SD Card") { svc, p in
            try await svc.formatSDCard(storeSaves: store, copySaves: copy, progress: p)
        }
    }
}
