import Foundation

/// A module repository (port of Hakchi2-CE's `RepositoryInfo`): a display name and
/// the base URL of a hakchi2-CE style `.repo/` folder.
struct ModRepository: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var url: String

    enum CodingKeys: String, CodingKey { case name, url }

    init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    /// CE's default repository
    static let kmfd = ModRepository(name: "KMFD's Mod Hub",
                                    url: "https://hakchi.net/KMFDManic/NESC-SNESC-Modifications/.repo/")

    /// Repository from an old config entry that only stored the URL
    init(legacyURL: String) {
        self.init(name: legacyURL == Self.kmfd.url ? Self.kmfd.name : Self.displayName(for: legacyURL),
                  url: legacyURL)
    }

    /// Short name from a URL: its host plus first path component
    static func displayName(for url: String) -> String {
        guard let u = URL(string: url), let host = u.host else { return url }
        let first = u.pathComponents.dropFirst().first { $0 != "/" && $0 != ".repo" }
        return first.map { "\(host)/\($0)" } ?? host
    }

    /// Parse a `.hrepo` file: front matter with `Name:` and `Link:` (CE drag-and-drop format)
    static func parseHrepo(_ text: String) -> ModRepository? {
        let readme = HmodReadme(text)
        guard let link = readme["Link"]?.trimmingCharacters(in: .whitespaces), !link.isEmpty,
              URL(string: link)?.scheme != nil else { return nil }
        let name = readme["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? displayName(for: link)
        return ModRepository(name: name, url: link)
    }
}
