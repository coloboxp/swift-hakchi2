import SwiftUI

/// Mega Drive spine generator (port of Hakchi2-CE's `SpineForm`). Load the game's
/// clear logo, pick a template, and save: writes CODE_logo.png, CODE_spine.png
/// and the spine part of CODE_mdmini.png.
struct SpineView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let gameId: String

    @State private var templates: [SpineTemplate] = []
    @State private var selected: SpineTemplate?
    @State private var logo: CGImage?
    @State private var error: String?

    private var game: Game? { appState.gameManager.games.first { $0.id == gameId } }
    private var dir: URL? { game.map { appState.gameManager.gameDirectory($0) } }
    private var rendered: CGImage? { logo.flatMap { selected?.render(logo: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spine").font(.title2.bold())
            HStack(alignment: .top, spacing: 16) {
                List(templates, selection: Binding(get: { selected?.id }, set: { id in
                    selected = templates.first { $0.id == id }
                })) { template in
                    Text(template.name).tag(template.id)
                }
                .frame(width: 220, height: 320)

                VStack {
                    if let rendered {
                        Image(decorative: rendered, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Text("Load a clear logo (transparent PNG) to preview the spine.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(width: 80, height: 320)
                .background(.quaternary.opacity(0.3))
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Open Clear Logo...") { openLogo() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(rendered == nil)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            templates = SpineTemplate.all()
            // CE generates spines with "Custom (Black Grid)" by default
            selected = templates.first { $0.name == "Custom (Black Grid)" } ?? templates.first
            if let dir, let game { logo = CoverArt.loadImage(url: CoverArt.logoURL(dir, game.code)) }
        }
    }

    private func openLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        logo = CoverArt.loadImage(url: url)
        if logo == nil { error = CoverArtError.unreadableImage.localizedDescription }
    }

    private func save() {
        guard let dir, let game, let logo, let spine = rendered else { return }
        do {
            try CoverArt.writePNG(logo, to: CoverArt.logoURL(dir, game.code), quantize: false)
            try CoverArt.setMdMiniSpine(spine, gameDirectory: dir, code: game.code)
            appState.gameManager.reloadGame(game.code)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
