import SwiftUI

/// "Add custom app" (port of Hakchi2-CE's `NewCustomGameForm`): an empty game entry
/// whose command line you fill in yourself.
struct NewCustomAppView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @State private var name = ""
    @State private var code = ""
    @State private var generateCode = true
    @State private var error: String?

    private var effectiveCode: String {
        generateCode ? GameManagerService.customAppCode(for: name) : code.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Custom App")
                .font(.title2.bold())
            Form {
                TextField("App name", text: $name)
                Toggle("Generate code based on name", isOn: $generateCode)
                TextField("App code (folder)", text: Binding(
                    get: { generateCode ? effectiveCode : code },
                    set: { code = $0.uppercased() }
                ))
                .font(.system(.body, design: .monospaced))
                .disabled(generateCode)
                Text("Format: CLV-X-XXXXX (letters and digits)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || !GameManagerService.isValidCustomCode(effectiveCode))
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func add() {
        do {
            let newCode = try appState.gameManager.addCustomApp(
                name: name.trimmingCharacters(in: .whitespaces), code: effectiveCode,
                consoleType: appState.effectiveConsoleType)
            if let game = appState.gameManager.games.first(where: { $0.id == newCode }) {
                appState.selectedGame = game
                appState.selectedGameIds = [newCode]
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
