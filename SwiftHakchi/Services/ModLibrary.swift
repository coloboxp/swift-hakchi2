import Foundation
import SWCompression
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "ModLibrary")

/// A module in the local library: a packed `.hmod` (tar.gz) file or an unpacked `.hmod` folder
struct LocalModule: Identifiable, Hashable, Sendable {
    /// Package name (file name without ".hmod"), as hakchi installs it
    let id: String
    let url: URL
    let isDirectory: Bool
    let readme: HmodReadme?

    var name: String { readme?.name ?? id }
    var category: String { readme?.category ?? "Unknown" }
    var creator: String { readme?.creator ?? "Unknown" }
    var version: String { readme?.version ?? "" }
    var emulatedSystem: String { readme?.emulatedSystem ?? "Unknown" }
}

/// How the library list is grouped (CE's "Group by")
enum ModGrouping: String, CaseIterable, Identifiable, Sendable {
    case category = "Category", creator = "Creator", emulatedSystem = "Emulated Console"

    var id: String { rawValue }

    func key(for module: LocalModule) -> String {
        switch self {
        case .category: return module.category
        case .creator: return module.creator
        case .emulatedSystem: return module.emulatedSystem
        }
    }
}

/// The local module library (port of Hakchi2-CE's `user_mods` handling in `Hmod`).
@MainActor
final class ModLibrary: ObservableObject {
    @Published private(set) var modules: [LocalModule] = []

    let directory: URL
    private let cacheFile: URL
    /// Readme cache for packed modules, keyed by "path|size|mtime"
    private var readmeCache: [String: String] = [:]

    init(directory: URL, cacheFile: URL) {
        self.directory = directory
        self.cacheFile = cacheFile
        if let data = try? Data(contentsOf: cacheFile),
           let cache = try? JSONDecoder().decode([String: String].self, from: data) {
            readmeCache = cache
        }
        reload()
    }

    /// Library in the app's config folder
    static func standard() -> ModLibrary {
        ModLibrary(directory: AppConfig.shared.userModsDirectory,
                   cacheFile: AppConfig.configDirectory.appendingPathComponent("cache/readme_cache.json"))
    }

    // MARK: - Loading

    func reload() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

        var cacheChanged = false
        modules = urls
            .filter { $0.pathExtension.lowercased() == "hmod" }
            .map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                let readme = isDir ? Self.readmeInFolder(url) : cachedReadme(forPackedModule: url, changed: &cacheChanged)
                return LocalModule(id: url.deletingPathExtension().lastPathComponent, url: url,
                                   isDirectory: isDir, readme: readme)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if cacheChanged, let data = try? JSONEncoder().encode(readmeCache) {
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: cacheFile)
        }
    }

    func module(named id: String) -> LocalModule? {
        modules.first { $0.id == id }
    }

    /// Modules grouped for display, groups and members sorted by name
    func grouped(by grouping: ModGrouping) -> [(group: String, modules: [LocalModule])] {
        Dictionary(grouping: modules, by: grouping.key(for:))
            .map { ($0.key, $0.value) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    // MARK: - Changing the library

    func delete(_ module: LocalModule) throws {
        try FileManager.default.removeItem(at: module.url)
        reload()
    }

    /// Add `.hmod` files/folders, or archives (.zip/.7z/.tar/.tgz/.tar.gz) holding them.
    /// Returns the ids added; existing modules with the same name are replaced.
    @discardableResult
    func add(urls: [URL]) throws -> [String] {
        var added: [String] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "hmod" {
                let id = Self.cleanName(url.deletingPathExtension().lastPathComponent)
                let target = directory.appendingPathComponent("\(id).hmod")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: url, to: target)
                added.append(id)
            } else if ["zip", "7z", "tar", "tgz", "gz"].contains(ext) {
                added += try addModules(fromArchive: try Data(contentsOf: url), named: url.lastPathComponent)
            } else {
                throw ModLibraryError.notAModule(url.lastPathComponent)
            }
        }
        reload()
        return added
    }

    /// Save a Mod Hub download. With `extract`, the archive is unpacked into a
    /// `<id>.hmod` folder (CE: ModHub "Download" with an `extract` file); otherwise
    /// it is stored as a packed `<id>.hmod`.
    func saveDownload(id: String, data: Data, extract: Bool) throws {
        let clean = Self.cleanName(id)
        let target = directory.appendingPathComponent("\(clean).hmod")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        if extract {
            let entries = try Self.archiveEntries(data)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Self.write(entries: entries, to: target)
        } else {
            try data.write(to: target)
        }
        reload()
    }

    /// Data to stage on the console: the packed file itself, or a tar of the folder
    /// containing a top-level "<id>.hmod/" directory
    func stagingPayload(for module: LocalModule) throws -> (data: Data, isFolderTar: Bool) {
        if module.isDirectory {
            return (try Self.tarFolder(module.url), true)
        }
        return (try Data(contentsOf: module.url), false)
    }

    // MARK: - Helpers

    /// CE's BadCharsRegex: anything but letters, digits, "_", "-" and "." becomes "_"
    static func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: #"[^a-zA-Z0-9_\-\.]"#, with: "_", options: .regularExpression)
    }

    private func addModules(fromArchive data: Data, named name: String) throws -> [String] {
        let entries = try Self.archiveEntries(data)
        var added: [String] = []

        // Packed modules inside the archive: "<x>.hmod" files
        for entry in entries where entry.name.lowercased().hasSuffix(".hmod") {
            let id = Self.cleanName(((entry.name as NSString).lastPathComponent as NSString).deletingPathExtension)
            let target = directory.appendingPathComponent("\(id).hmod")
            try? FileManager.default.removeItem(at: target)
            try entry.data.write(to: target)
            added.append(id)
        }

        // Unpacked modules: files under a "<x>.hmod/" folder
        var folders: [String: [(name: String, data: Data)]] = [:]
        for entry in entries {
            let parts = entry.name.split(separator: "/").map(String.init)
            guard let idx = parts.firstIndex(where: { $0.lowercased().hasSuffix(".hmod") }), idx < parts.count - 1 else {
                continue
            }
            let folder = parts[idx]
            folders[folder, default: []].append((parts[(idx + 1)...].joined(separator: "/"), entry.data))
        }
        for (folder, files) in folders {
            let id = Self.cleanName((folder as NSString).deletingPathExtension)
            let target = directory.appendingPathComponent("\(id).hmod")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Self.write(entries: files, to: target)
            added.append(id)
        }

        guard !added.isEmpty else { throw ModLibraryError.noModulesInArchive(name) }
        return added
    }

    /// Regular-file entries of a zip, 7z, tar or tar.gz archive
    static func archiveEntries(_ data: Data) throws -> [(name: String, data: Data)] {
        let raw: [any ContainerEntry]
        if data.starts(with: [0x50, 0x4B]) {
            raw = try ZipContainer.open(container: data)
        } else if data.starts(with: [0x37, 0x7A, 0xBC, 0xAF]) {
            raw = try SevenZipContainer.open(container: data)
        } else if ModRepositoryService.isGzip(data) {
            raw = try TarContainer.open(container: try GzipArchive.unarchive(archive: data))
        } else {
            raw = try TarContainer.open(container: data)
        }
        return raw.compactMap { entry in
            guard entry.info.type == .regular else { return nil }
            var name = entry.info.name
            if name.hasPrefix("./") { name.removeFirst(2) }
            return (name, entry.data ?? Data())
        }
    }

    private static func write(entries: [(name: String, data: Data)], to dir: URL) throws {
        let root = dir.standardizedFileURL.path
        for entry in entries where !entry.name.isEmpty {
            let dest = dir.appendingPathComponent(entry.name).standardizedFileURL
            guard dest.path.hasPrefix(root + "/") else { continue }  // refuse "../" escapes
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.data.write(to: dest)
        }
    }

    static func readmeInFolder(_ url: URL) -> HmodReadme? {
        for name in HmodReadme.fileNames {
            if let text = try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8) {
                return HmodReadme(text, isMarkdown: name.hasSuffix(".md"))
            }
        }
        return nil
    }

    private func cachedReadme(forPackedModule url: URL, changed: inout Bool) -> HmodReadme? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let cached = readmeCache[key] {
            return cached.isEmpty ? nil : HmodReadme(cached, isMarkdown: true)
        }
        let text = Self.readmeInPackedModule(url) ?? ""
        readmeCache[key] = text
        changed = true
        return text.isEmpty ? nil : HmodReadme(text, isMarkdown: true)
    }

    /// Readme of a packed module, streamed with /usr/bin/tar (no full unpack in memory)
    static func readmeInPackedModule(_ url: URL) -> String? {
        guard let listing = runTar(["-tzf", url.path]) else { return nil }
        let names = String(decoding: listing, as: UTF8.self).components(separatedBy: .newlines)
        for wanted in HmodReadme.fileNames {
            if let member = names.first(where: { $0 == wanted || $0 == "./" + wanted }),
               let data = runTar(["-xOzf", url.path, member]) {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return nil
    }

    private static func runTar(_ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// Tar a module folder so it unpacks as "<name>.hmod/…", keeping file modes
    static func tarFolder(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.environment = ["COPYFILE_DISABLE": "1"]  // no ._ AppleDouble files
        process.arguments = ["-cf", "-", "-C", url.deletingLastPathComponent().path, url.lastPathComponent]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()  // read before waiting
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ModLibraryError.tarFailed(url.lastPathComponent) }
        return data
    }
}

enum ModLibraryError: LocalizedError {
    case notAModule(String)
    case noModulesInArchive(String)
    case tarFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAModule(let name): return "\(name) is not a .hmod module or an archive"
        case .noModulesInArchive(let name): return "No .hmod module found in \(name)"
        case .tarFailed(let name): return "Could not pack folder \(name)"
        }
    }
}
