import Foundation
import CryptoKit
import SWCompression
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "ModRepository")

/// Fetches modules from a hakchi2-CE style repository (e.g., KMFD Mod Hub).
///
/// Repository layout (`<repo>/.repo/`):
/// ```
/// list                  # one item per line: "<name>.hmod" or "<name>.clvg"
/// pack.tgz              # tar.gz of every item folder below, plus "list"
/// <item>/link           # download URL of the item
/// <item>/md5, sha1      # checksums of the download (optional)
/// <item>/readme.md      # front matter (Name, Category, Creator, Version...)
/// <item>/extract        # present when the download is an archive
/// ```
/// Only `.hmod` items are returned; `.clvg` items are games, not modules.
actor ModRepositoryService {
    /// A remote module available for download
    struct RemoteModule: Identifiable, Hashable, Sendable {
        /// Package name as hakchi knows it (file name without ".hmod")
        let id: String
        let name: String
        let category: String
        let creator: String
        let version: String
        /// Download URL from the item's `link` file, if known yet
        let downloadURL: URL?
        let md5: String?
        /// URL of the item folder inside `.repo/`
        let itemURL: URL

        var fileName: String { id + ".hmod" }

        static func == (lhs: RemoteModule, rhs: RemoteModule) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// How long a downloaded pack.tgz is reused before it is fetched again
    private static let packCacheLifetime: TimeInterval = 24 * 60 * 60

    /// Fetch available modules from a repository URL.
    /// Uses `pack.tgz` (full metadata in one request, cached on disk);
    /// falls back to the plain `list` file (names only) if the pack fails.
    func fetchModules(from repositoryURL: String, forceRefresh: Bool = false) async throws -> [RemoteModule] {
        let repoURL = try Self.normalizedRepoURL(repositoryURL)

        do {
            let pack = try await loadPack(repoURL: repoURL, forceRefresh: forceRefresh)
            let modules = try Self.parsePack(pack, repoURL: repoURL)
            if !modules.isEmpty { return modules }
        } catch {
            logger.warning("pack.tgz failed (\(error.localizedDescription)), falling back to list")
        }

        let listData = try await fetch(repoURL.appendingPathComponent("list"))
        let list = String(decoding: listData, as: UTF8.self)
        return Self.parseList(list).map { Self.makeModule(fileName: $0, files: [:], repoURL: repoURL) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Download a module and verify its MD5 checksum when the repository provides one.
    /// Returns the raw `.hmod` (tar.gz) data.
    func downloadModule(_ module: RemoteModule) async throws -> Data {
        var url = module.downloadURL
        if url == nil {
            // List-only fallback: resolve the link now
            let link = String(decoding: try await fetch(module.itemURL.appendingPathComponent("link")), as: UTF8.self)
            url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let url else { throw ModRepositoryError.missingLink(module.name) }

        logger.info("Downloading module \(module.id) from \(url.absoluteString)")
        let data = try await fetch(url)

        if let expected = module.md5?.lowercased(), !expected.isEmpty {
            let actual = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                throw ModRepositoryError.checksumMismatch(module.name)
            }
        }

        // hakchi's pack_install only understands tar.gz files
        guard data.count > 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            throw ModRepositoryError.unsupportedFormat(module.name)
        }
        return data
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
        let cacheDir = AppConfig.shared.dataDirectory.appendingPathComponent("modhub", isDirectory: true)
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

    static func parseList(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.lowercased().hasSuffix(".hmod") }
    }

    /// Parse pack.tgz: group "<item>/<file>" entries by item folder.
    static func parsePack(_ data: Data, repoURL: URL) throws -> [RemoteModule] {
        let tar = try GzipArchive.unarchive(archive: data)
        let entries = try TarContainer.open(container: tar)

        var items: [String: [String: String]] = [:]
        var list: [String]?
        let wanted: Set<String> = ["link", "md5", "extract", "readme.md", "readme.txt", "readme"]

        for entry in entries {
            var path = entry.info.name
            if path.hasPrefix("./") { path.removeFirst(2) }
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)

            if parts.count == 1, parts[0].lowercased() == "list", let d = entry.data {
                list = parseList(String(decoding: d, as: UTF8.self))
            }
            guard parts.count == 2 else { continue }
            let item = String(parts[0]), file = parts[1].lowercased()
            guard item.lowercased().hasSuffix(".hmod"), wanted.contains(file) else { continue }
            items[item, default: [:]][file] = entry.data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }

        // The list is authoritative when present (pack may contain stale folders)
        let names = list.map { l in l.filter { items[$0] != nil } } ?? Array(items.keys)
        return names.map { makeModule(fileName: $0, files: items[$0] ?? [:], repoURL: repoURL) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func makeModule(fileName: String, files: [String: String], repoURL: URL) -> RemoteModule {
        let id = String(fileName.dropLast(".hmod".count))
        let readme = files["readme.md"] ?? files["readme.txt"] ?? files["readme"] ?? ""
        let meta = parseFrontMatter(readme)
        let trimmed = { (s: String?) -> String? in
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        return RemoteModule(
            id: id,
            name: meta["Name"] ?? cleanModuleName(id),
            category: meta["Category"] ?? "Other",
            creator: meta["Creator"] ?? "",
            version: meta["Version"] ?? "",
            downloadURL: trimmed(files["link"]).flatMap(URL.init(string:)),
            md5: trimmed(files["md5"]),
            itemURL: repoURL.appendingPathComponent(fileName, isDirectory: true)
        )
    }

    /// Parse the "Key: Value" block between the leading "-----" lines of a readme.
    static func parseFrontMatter(_ readme: String) -> [String: String] {
        let lines = readme.components(separatedBy: .newlines)
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[first].hasPrefix("---") else { return [:] }

        var result: [String: String] = [:]
        for line in lines[(first + 1)...] {
            if line.hasPrefix("---") { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
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
