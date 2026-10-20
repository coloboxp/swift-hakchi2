import SwiftUI

/// Pick box art when several images in `art/` match (port of Hakchi2-CE's `SelectCoverDialog`).
struct SelectCoverView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let choices: [CoverChoice]

    /// Per game: chosen image, or nil = keep the current cover
    @State private var picks: [String: URL?] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Box Art")
                .font(.title2.bold())
            Text("Several images in your art folder match these games. Pick one for each, or keep the current cover.")
                .foregroundStyle(.secondary)

            List(choices) { choice in
                VStack(alignment: .leading, spacing: 6) {
                    Text(choice.name).font(.headline)
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            option(for: choice, url: nil)
                            ForEach(choice.candidates, id: \.self) { url in
                                option(for: choice, url: url)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(minHeight: 300)

            HStack {
                Button("I'm Feeling Lucky") {
                    // CE: take the first candidate for every game
                    for c in choices { picks[c.code] = c.candidates.first }
                }
                Button("Keep All Current") {
                    for c in choices { picks[c.code] = .some(nil) }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 640, height: 520)
    }

    private func option(for choice: CoverChoice, url: URL?) -> some View {
        let selected = (picks[choice.code] ?? nil) == url
        return VStack(spacing: 4) {
            Group {
                if let url, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "nosign").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(width: 90, height: 90)
            Text(url?.deletingPathExtension().lastPathComponent ?? "Keep current")
                .font(.caption2)
                .lineLimit(2)
                .frame(width: 100)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onTapGesture { picks[choice.code] = .some(url) }
    }

    private func apply() {
        for choice in choices {
            guard let pick = picks[choice.code], let url = pick, let data = try? Data(contentsOf: url) else { continue }
            if let game = appState.gameManager.games.first(where: { $0.id == choice.code }) {
                appState.setCover(data, for: game)
            }
        }
        dismiss()
    }
}
