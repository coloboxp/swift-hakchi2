import SwiftUI

/// Shows a module readme: title, front-matter fields (CE's heading lines:
/// Creator and Version first, then the rest except Name), then the body.
struct ModuleReadmeView: View {
    let title: String
    let readme: HmodReadme?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                if let readme {
                    ForEach(Array(Self.headingFields(readme).enumerated()), id: \.offset) { _, field in
                        (Text("\(field.key): ").bold() + Text(field.value))
                            .font(.caption)
                    }
                    if !readme.body.isEmpty {
                        Divider()
                        Text(Self.render(readme))
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("No readme available.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    /// CE order: Creator, Version, then every other key except Name
    static func headingFields(_ readme: HmodReadme) -> [(key: String, value: String)] {
        let first = ["Creator", "Version"].compactMap { key in readme[key].map { (key, $0) } }
        let rest = readme.frontMatter.filter { !["Creator", "Version", "Name"].contains($0.key) }
        return first + rest
    }

    /// Body as Markdown, without inline HTML (KMFD readmes embed base64 <img> tags)
    static func render(_ readme: HmodReadme) -> AttributedString {
        let text = readme.body.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        if readme.isMarkdown,
           let attributed = try? AttributedString(
               markdown: text,
               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(text)
    }
}
