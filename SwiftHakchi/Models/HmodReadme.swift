import Foundation

/// A module readme: optional front matter between "---" lines, then the body
/// (port of Hakchi2-CE's `HmodReadme`).
///
/// ```
/// -----------------------
/// Name: Curl
/// Creator: madmonkey
/// Category: System
/// -----------------------
/// Body text…
/// ```
struct HmodReadme: Hashable, Sendable {
    /// Readme file names looked up inside a module, in order (CE)
    static let fileNames = ["readme.md", "readme.txt", "readme"]

    /// Front matter in file order; the first occurrence of a key wins
    let frontMatter: [(key: String, value: String)]
    /// Text after the front matter
    let body: String
    let rawText: String
    let isMarkdown: Bool

    init(_ text: String, isMarkdown: Bool = false) {
        rawText = text
        self.isMarkdown = isMarkdown

        // Same pattern as CE: optional "---…---" block, then the rest
        let ns = text as NSString
        let block = try! NSRegularExpression(
            pattern: #"^(?:-{3,}[\r\n]+(.*?)[\r\n]*-{3,})?[\r\n\t\s]*(.*)[\r\n\t\s]*$"#,
            options: .dotMatchesLineSeparators)
        var frontText = ""
        var bodyText = text
        if let m = block.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound { frontText = ns.substring(with: m.range(at: 1)) }
            if m.range(at: 2).location != NSNotFound { bodyText = ns.substring(with: m.range(at: 2)) }
        }
        body = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)

        var pairs: [(String, String)] = []
        var seen = Set<String>()
        let line = try! NSRegularExpression(pattern: #"^[\s\t]*([^:\r\n]+?)[\s\t]*:[\s\t]*(.*?)[\s\t]*$"#,
                                            options: .anchorsMatchLines)
        let fns = frontText as NSString
        for m in line.matches(in: frontText, range: NSRange(location: 0, length: fns.length)) {
            let key = fns.substring(with: m.range(at: 1))
            let value = fns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if seen.insert(key).inserted { pairs.append((key, value)) }
        }
        frontMatter = pairs
    }

    subscript(key: String) -> String? {
        frontMatter.first { $0.key == key }?.value
    }

    var name: String? { nonEmpty(self["Name"]) }
    var category: String? { nonEmpty(self["Category"]) }
    var creator: String? { nonEmpty(self["Creator"]) }
    var version: String? { nonEmpty(self["Version"]) }
    var emulatedSystem: String? { nonEmpty(self["Emulated System"]) }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    static func == (lhs: HmodReadme, rhs: HmodReadme) -> Bool { lhs.rawText == rhs.rawText }
    func hash(into hasher: inout Hasher) { hasher.combine(rawText) }
}
