import Foundation
import CryptoKit
import SWCompression
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "ModRepository")

/// Fetches items from a hakchi2-CE style repository, e.g. KMFD's Mod Hub
/// (port of CE's `ModHub.Repository`).
///
/// Repository layout (`<repo>/.repo/`):
/// ```
/// list                  # one item per line: "<name>.hmod" or "<name>.clvg"
/// readme.md             # repository welcome text
/// pack.tgz              # tar.gz of "list", "readme.md" and every item folder below
/// <item>/link           # download URL of the item
/// <item>/md5, sha1      # checksums of the download (optional)
/// <item>/readme.md      # front matter (Name, Category, Creator, Version...)
/// <item>/extract        # present when the download is an archive to unpack
/// ```
/// `.hmod` items are modules, `.clvg` items are games (hakchi game archives).
actor ModRepositoryService {
    /// What a repository item is
    enum ItemKind: String, Sendable {
        case hmod, game

        var fileExtension: String { self == .hmod ? ".hmod" : ".clvg" }
    }

    /// An item available for download
    struct RemoteModule: Identifiable, Hashable, Sendable {
        /// Item name without extension; for modules, the package name hakchi uses
        let id: String
        let kind: ItemKind
        let name: String
        let category: String
        let creator: String
        let version: String
        let emulatedSystem: String
        /// Download URL from the item's `link` file, if known yet
        let downloadURL: URL?
        let md5: String?
        /// The download is an archive to unpack into a module folder (CE's `extract`)
        let extract: Bool
        let readme: HmodReadme?
        /// URL of the item folder inside `.repo/`
        let itemURL: URL

        var fileName: String { id + kind.fileExtension }

        static func == (lhs: RemoteModule, rhs: RemoteModule) -> Bool { lhs.id == rhs.id && lhs.kind == rhs.kind }
        func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(kind) }
    }

    /// Everything a repository offers
    struct Contents: Sendable {
        var readme: String?
        var items: [RemoteModule]

        var modules: [RemoteModule] { items.filter { $0.kind == .hmod } }
        var games: [RemoteModule] { items.filter { $0.kind == .game } }
    }

    /// How long a downloaded pack.tgz is reused before it is fetched again
    private static let packCacheLifetime: TimeInterval = 24 * 60 * 60

    /// Fetch a repository's items and welcome readme.
    /// Uses `pack.tgz` (full metadata in one request, cached on disk);
    /// falls back to the plain `list` file (names only) if the pack fails.
    func fetchRepository(from repositoryURL: String, forceRefresh: Bool = false) async throws -> Contents {
        let repoURL = try Self.normalizedRepoURL(repositoryURL)

        do {
            let pack = try await loadPack(repoURL: repoURL, forceRefresh: forceRefresh)
            let contents = try Self.parsePack(pack, repoURL: repoURL)
            if !contents.items.isEmpty { return contents }
        } catch {
            logger.warning("pack.tgz failed (\(error.localizedDescription)), falling back to list")
        }

        let list = String(decoding: try await fetch(repoURL.appendingPathComponent("list")), as: UTF8.self)
        let readme = (try? await fetch(repoURL.appendingPathComponent("readme.md")))
            .map { String(decoding: $0, as: UTF8.self) }
        let items = Self.parseList(list).map { Self.makeItem(fileName: $0, files: [:], repoURL: repoURL) }
        return Contents(readme: readme, items: Self.sorted(items))
    }

    /// Modules only (kept for callers that don't need games or the readme)
    func fetchModules(from repositoryURL: String, forceRefresh: Bool = false) async throws -> [RemoteModule] {
        try await fetchRepository(from: repositoryURL, forceRefresh: forceRefresh).modules
    }

    /// Download an item and verify its MD5 checksum when the repository provides one.
    /// Returns the raw download (a tar.gz `.hmod`/`.clvg`, or an archive when `extract` is set).
    func downloadModule(_ module: RemoteModule) async throws -> Data {
        var url = module.downloadURL
        if url == nil {
            // List-only fallback: resolve the link now
            let link = String(decoding: try await fetch(module.itemURL.appendingPathComponent("link")), as: UTF8.self)
            url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let url else { throw ModRepositoryError.missingLink(module.name) }

        logger.info("Downloading \(module.fileName) from \(url.absoluteString)")
        let data = try await fetch(url)

        if let expected = module.md5?.lowercased(), !expected.isEmpty {
            let actual = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                throw ModRepositoryError.checksumMismatch(module.name)
            }
        }

        // Without "extract", the download must be a packed module/game (tar.gz)
        if !module.extract, !Self.isGzip(data) {
            throw ModRepositoryError.unsupportedFormat(module.name)
        }
        return data
    }

    static func isGzip(_ data: Data) -> Bool {
        data.count > 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    // MARK: - Networking

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ModRepositoryError.httpError(code, url.lastPathComponent)
        }
        return data
    }

    /// Download pack.tgz, or reuse a recent copy from the data directory.
    private func loadPack(repoURL: URL, forceRefresh: Bool) async throws -> Data {
        let cacheDir = AppConfig.configDirectory.appendingPathComponent("data/modhub", isDirectory: true)
        let key = Insecure.MD5.hash(data: Data(repoURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let cacheFile = cacheDir.appendingPathComponent("\(key).tgz")

        if !forceRefresh,
           let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < Self.packCacheLifetime,
           let data = try? Data(contentsOf: cacheFile) {
            logger.info("Using cached pack.tgz for \(repoURL.absoluteString)")
            return data
        }

        logger.info("Downloading pack.tgz from \(repoURL.absoluteString)")
        let data = try await fetch(repoURL.appendingPathComponent("pack.tgz"))
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: cacheFile)
        return data
    }

    // MARK: - Parsing

    /// Same rule as hakchi2-CE: ensure a trailing "/" and a ".repo/" suffix.
    static func normalizedRepoURL(_ string: String) throws -> URL {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasSuffix("/") { s += "/" }
        if !s.hasSuffix("/.repo/") { s += ".repo/" }
        guard let url = URL(string: s), url.scheme != nil else { throw ModRepositoryError.invalidURL }
        return url
    }

    /// Item names from the `list` file (`.hmod` and `.clvg` only)
    static func parseList(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { kind(ofFileName: $0) != nil }
    }

    static func kind(ofFileName name: String) -> ItemKind? {
        let lower = name.lowercased()
        if lower.hasSuffix(".hmod") { return .hmod }
        if lower.hasSuffix(".clvg") { return .game }
        return nil
    }

    /// Parse pack.tgz: group "<item>/<file>" entries by item folder.
    static func parsePack(_ data: Data, repoURL: URL) throws -> Contents {
        let tar = try GzipArchive.unarchive(archive: data)
        let entries = try TarContainer.open(container: tar)

        var items: [String: [String: String]] = [:]
        var list: [String]?
        var readme: String?
        let wanted: Set<String> = ["link", "md5", "extract", "readme.md", "readme.txt", "readme"]

        for entry in entries {
            var path = entry.info.name
            if path.hasPrefix("./") { path.removeFirst(2) }
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)

            if parts.count == 1, let d = entry.data {
                switch parts[0].lowercased() {
                case "list": list = parseList(String(decoding: d, as: UTF8.self))
                case "readme.md": readme = String(decoding: d, as: UTF8.self)
                default: break
                }
            }
            guard parts.count == 2 else { continue }
            let item = String(parts[0]), file = parts[1].lowercased()
            guard kind(ofFileName: item) != nil, wanted.contains(file) else { continue }
            items[item, default: [:]][file] = entry.data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }

        // The list is authoritative when present (pack may contain stale folders)
        let names = list.map { l in l.filter { items[$0] != nil } } ?? Array(items.keys)
        let parsed = names.map { makeItem(fileName: $0, files: items[$0] ?? [:], repoURL: repoURL) }
        return Contents(readme: readme, items: sorted(parsed))
    }

    private static func makeItem(fileName: String, files: [String: String], repoURL: URL) -> RemoteModule {
        let kind = kind(ofFileName: fileName) ?? .hmod
        let id = String(fileName.dropLast(kind.fileExtension.count))
        let readmeFile = HmodReadme.fileNames.first { files[$0] != nil }
        let readme = readmeFile.map { HmodReadme(files[$0] ?? "", isMarkdown: $0.hasSuffix(".md")) }
        let trimmed = { (s: String?) -> String? in
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        return RemoteModule(
            id: id,
            kind: kind,
            name: readme?.name ?? cleanModuleName(id),
            category: readme?.category ?? (kind == .game ? "Games" : "Other"),
            creator: readme?.creator ?? "",
            version: readme?.version ?? "",
            emulatedSystem: readme?.emulatedSystem ?? "",
            downloadURL: trimmed(files["link"]).flatMap(URL.init(string:)),
            md5: trimmed(files["md5"]),
            extract: files["extract"] != nil,
            readme: readme,
            itemURL: repoURL.appendingPathComponent(fileName, isDirectory: true)
        )
    }

    /// Kept for callers that parse front matter directly
    static func parseFrontMatter(_ readme: String) -> [String: String] {
        Dictionary(HmodReadme(readme).frontMatter.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    private static func sorted(_ items: [RemoteModule]) -> [RemoteModule] {
        items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Fallback display name: "_km_snes9x_xtreme" → "Km snes9x xtreme"
    private static func cleanModuleName(_ id: String) -> String {
        var name = id.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        if let first = name.first { name = first.uppercased() + name.dropFirst() }
        return name
    }
}

enum ModRepositoryError: LocalizedError {
    case invalidURL
    case httpError(Int, String)
    case missingLink(String)
    case checksumMismatch(String)
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid repository URL"
        case .httpError(let code, let file): return "Download of \(file) failed (HTTP \(code))"
        case .missingLink(let name): return "No download link for \(name)"
        case .checksumMismatch(let name): return "Checksum mismatch for \(name) — download corrupted"
        case .unsupportedFormat(let name): return "\(name) is not a .hmod (tar.gz) archive"
        }
    }
}
