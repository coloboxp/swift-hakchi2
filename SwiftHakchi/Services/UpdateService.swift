import Foundation
import SWCompression
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "Updates")

/// Startup downloads Hakchi2-CE performs: a newer hakchi.hmod, the ROM hash
/// database, and the "Important message" (MOTD).
actor UpdateService {
    static let hakchiUpdateURL = URL(string: "https://hakchi.net/hakchi/hakchi.hmod")!
    static let romFilesURL = URL(string: "https://github.com/TeamShinkansen/hash-db/releases/download/data/romfiles.xml.gz")!
    static let motdURL = URL(string: "https://teamshinkansen.github.io/motd.md")!

    private let dataDirectory: URL
    private let cacheDirectory: URL
    private let session: URLSession

    init(dataDirectory: URL = AppConfig.shared.dataDirectory,
         cacheDirectory: URL = AppConfig.configDirectory.appendingPathComponent("cache", isDirectory: true),
         session: URLSession = .shared) {
        self.dataDirectory = dataDirectory
        self.cacheDirectory = cacheDirectory
        self.session = session
    }

    var latestHmodURL: URL { dataDirectory.appendingPathComponent("hakchi-latest.hmod") }
    var romFilesFile: URL { dataDirectory.appendingPathComponent("romfiles.xml") }
    var motdFile: URL { cacheDirectory.appendingPathComponent("motd.md") }

    // MARK: - hakchi.hmod

    /// Download hakchi.hmod and keep it as data/hakchi-latest.hmod when its
    /// var/version is newer than the bundled one. Returns the new version, if any.
    @discardableResult
    func checkHakchiUpdate(bundled: ConsoleTools.HakchiVersion) async throws -> ConsoleTools.HakchiVersion? {
        let (data, response) = try await session.data(from: Self.hakchiUpdateURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let candidate = try Self.hmodVersion(data)
        let current = (try? Data(contentsOf: latestHmodURL)).flatMap { try? Self.hmodVersion($0) } ?? bundled
        guard ConsoleTools.isNewer(candidate, than: current) else {
            logger.info("hakchi.hmod is up to date (\(current.script))")
            return nil
        }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try data.write(to: latestHmodURL)
        PayloadService.shared.clearHakchiHmodCache()
        logger.info("Downloaded newer hakchi.hmod \(candidate.script)")
        return candidate
    }

    /// var/version inside a hakchi.hmod (tar.gz)
    static func hmodVersion(_ hmod: Data) throws -> ConsoleTools.HakchiVersion {
        let tar = try GzipArchive.unarchive(archive: hmod)
        guard let entry = try TarContainer.open(container: tar)
                .first(where: { ["var/version", "./var/version"].contains($0.info.name) }),
              let data = entry.data else { throw PayloadError.entryNotFound("var/version") }
        return ConsoleTools.parseHakchiVersion(String(decoding: data, as: UTF8.self))
    }

    // MARK: - romfiles.xml

    /// Refresh data/romfiles.xml when the server copy changed (If-Modified-Since)
    @discardableResult
    func updateRomFiles() async throws -> Bool {
        var request = URLRequest(url: Self.romFilesURL)
        if let modified = Self.modificationDate(romFilesFile) {
            request.setValue(Self.httpDate(modified), forHTTPHeaderField: "If-Modified-Since")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        let xml = try GzipArchive.unarchive(archive: data)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try xml.write(to: romFilesFile)
        logger.info("Updated romfiles.xml (\(xml.count) bytes)")
        return true
    }

    // MARK: - MOTD

    struct Motd: Equatable {
        let text: String
        /// Date stamp from the "<!--- DATE --->" comment
        let stamp: String?
    }

    /// The message of the day, cached for 6 hours like CE
    func motd(forceRefresh: Bool = false) async -> Motd? {
        if !forceRefresh, ConsoleTools.isCacheFresh(modified: Self.modificationDate(motdFile)),
           let text = try? String(contentsOf: motdFile, encoding: .utf8) {
            return Motd(text: text, stamp: ConsoleTools.motdStamp(text))
        }
        do {
            let (data, response) = try await session.data(from: Self.motdURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: motdFile)
            let text = String(decoding: data, as: UTF8.self)
            return Motd(text: text, stamp: ConsoleTools.motdStamp(text))
        } catch {
            logger.warning("MOTD download failed: \(error.localizedDescription)")
            // Fall back to a stale cache rather than nothing
            return (try? String(contentsOf: motdFile, encoding: .utf8)).map { Motd(text: $0, stamp: ConsoleTools.motdStamp($0)) }
        }
    }

    // MARK: - Helpers

    static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func httpDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: date)
    }
}
