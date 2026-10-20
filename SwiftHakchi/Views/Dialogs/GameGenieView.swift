import SwiftUI

/// Game Genie codes for one game (CE's `GameGenieCodeForm` + `GameGenieCodeAddModForm`).
/// Checked codes are saved to the game's gamegenie.txt and patched into a copy of the
/// ROM at sync time. Suggested codes come from GameGenieDB.xml.
struct GameGenieView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let gameId: String

    @State private var database = GameGenieDatabase()
    @State private var known: [GameGenieCode] = []
    @State private var active: Set<String> = []
    @State private var newCode = ""
    @State private var newDescription = ""
    @State private var error: String?

    private var game: Game? { appState.gameManager.games.first { $0.id == gameId } }
    private var gameDir: URL? { game.map { appState.gameManager.gameDirectory($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Game Genie Codes").font(.title2.bold())
            Text(game?.name ?? gameId).foregroundStyle(.secondary)

            List(known) { entry in
                Toggle(isOn: Binding(
                    get: { active.contains(entry.code) },
                    set: { if $0 { active.insert(entry.code) } else { active.remove(entry.code) } }
                )) {
                    HStack {
                        Text(entry.code).font(.system(.body, design: .monospaced)).frame(width: 110, alignment: .leading)
                        Text(entry.description)
                    }
                }
                .contextMenu {
                    Button("Remove from Database") {
                        database.removeCode(entry.code, gameCode: gameId)
                        known.removeAll { $0.code == entry.code }
                        active.remove(entry.code)
                    }
                }
            }
            .frame(minHeight: 240)

            HStack {
                TextField("Code (NES: 6/8 letters, SNES: XXXX-XXXX)", text: $newCode)
                    .font(.system(.body, design: .monospaced))
                TextField("Description", text: $newDescription)
                Button("Add") { addCode() }
                    .disabled(newCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560, height: 480)
        .onAppear(perform: load)
    }

    private func load() {
        guard let gameDir else { return }
        let activeCodes = GameGenie.codes(gameDirectory: gameDir)
        known = database.codes(forGameCode: gameId)
        // Codes in gamegenie.txt that the database doesn't know are still listed
        for code in activeCodes where !known.contains(where: { $0.code == code }) {
            known.append(GameGenieCode(code: code, description: ""))
        }
        active = Set(activeCodes)
    }

    private func addCode() {
        let code = newCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard GameGenie.isValidCode(code) else {
            error = GameGenieError.badFormat(code).localizedDescription
            return
        }
        let entry = GameGenieCode(code: code, description: newDescription)
        known.removeAll { $0.code == code }
        known.append(entry)
        active.insert(code)
        let meta = gameDir.map { GameMetadata.load(gameDirectory: $0, exec: game?.commandLine ?? "") }
        database.setCode(entry, gameCode: gameId, gameName: game?.name ?? "", crc32: meta?.originalCrc32 ?? 0)
        newCode = ""
        newDescription = ""
        error = nil
    }

    private func save() {
        guard let gameDir else { return }
        do {
            try GameGenie.setCodes(known.map(\.code).filter { active.contains($0) }, gameDirectory: gameDir)
            try database.save()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
