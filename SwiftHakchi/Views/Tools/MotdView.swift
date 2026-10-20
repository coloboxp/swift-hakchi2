import SwiftUI

/// "Important message" from Team Shinkansen (CE's MOTD), cached for 6 hours
struct MotdView: View {
    @State private var motd: UpdateService.Motd?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let motd {
                if let stamp = motd.stamp {
                    Text(stamp).font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(Self.render(motd.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("The message could not be loaded.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Reload") { load(force: true) }
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { load(force: false) }
    }

    private func load(force: Bool) {
        isLoading = true
        Task {
            motd = await UpdateService().motd(forceRefresh: force)
            isLoading = false
        }
    }

    /// Markdown (links, bold) with the date comment removed
    static func render(_ text: String) -> AttributedString {
        let body = text.replacingOccurrences(of: #"<!-+[^>]*-+>\s*"#, with: "", options: .regularExpression)
        return (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(body)
    }
}
