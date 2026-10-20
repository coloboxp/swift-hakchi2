import Foundation
import SWCompression

/// Compress / decompress game files as `.7z` (port of Hakchi2-CE's
/// `NesApplication.CompressPossible`, `Compress` and `Decompress`).
///
/// Only files named in the game's Exec line are touched. Compressing writes
/// `<file>.7z`, points Exec at it and deletes the original; the console unpacks
/// it at launch. Decompressing reverses this for single-file `.7z`/`.zip` archives.
enum GameCompression {
    enum CompressionError: LocalizedError {
        case noDesktopFile(String)
        case unreadableArchive(String)

        var errorDescription: String? {
            switch self {
            case .noDesktopFile(let code): return "\(code).desktop not found"
            case .unreadableArchive(let name): return "Could not read the archive \(name)"
            }
        }
    }

    /// Files bigger than this stay uncompressed (CE's MaxCompress, 16 MiB)
    static let maxCompressSize = 16 * 1024 * 1024
    /// Extensions CE never compresses
    static let nonCompressibleExtensions: Set<String> = [
        "7z", "zip", "rar", "hsqs", "sh", "pbp", "chd", "cue", "gdi", "m3u",
    ]
    /// Archive types that can be decompressed
    static let compressedExtensions: Set<String> = ["7z", "zip"]

    /// True when at least one game file can be compressed
    static func canCompress(gameDirectory: URL, code: String) -> Bool {
        !compressibleFiles(gameDirectory: gameDirectory, code: code).isEmpty
    }

    /// True when at least one single-file archive named in Exec can be unpacked
    static func canDecompress(gameDirectory: URL, code: String) -> Bool {
        !decompressibleFiles(gameDirectory: gameDirectory, code: code).isEmpty
    }

    static func compress(gameDirectory: URL, code: String) throws {
        let desktop = try loadDesktop(gameDirectory: gameDirectory, code: code)
        for file in compressibleFiles(gameDirectory: gameDirectory, code: code) {
            let data = try Data(contentsOf: file)
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let archiveName = file.lastPathComponent + ".7z"
            let archive = try SevenZipWriter.archive(data: data, fileName: file.lastPathComponent, modificationDate: date)
            try archive.write(to: gameDirectory.appendingPathComponent(archiveName), options: .atomic)
            desktop.exec = replaceFileName(in: desktop.exec, old: file.lastPathComponent, new: archiveName)
            try FileManager.default.removeItem(at: file)
        }
        try save(desktop, gameDirectory: gameDirectory, code: code)
    }

    static func decompress(gameDirectory: URL, code: String) throws {
        let desktop = try loadDesktop(gameDirectory: gameDirectory, code: code)
        for archive in decompressibleFiles(gameDirectory: gameDirectory, code: code) {
            guard let entry = singleEntry(of: archive) else {
                throw CompressionError.unreadableArchive(archive.lastPathComponent)
            }
            let name = (entry.name as NSString).lastPathComponent
            try entry.data.write(to: gameDirectory.appendingPathComponent(name), options: .atomic)
            desktop.exec = replaceFileName(in: desktop.exec, old: archive.lastPathComponent, new: name)
            try FileManager.default.removeItem(at: archive)
        }
        try save(desktop, gameDirectory: gameDirectory, code: code)
    }

    // MARK: - Candidates (CE rules)

    static func compressibleFiles(gameDirectory: URL, code: String) -> [URL] {
        guard let exec = try? loadDesktop(gameDirectory: gameDirectory, code: code).exec else { return [] }
        let tokens = execTokens(exec)
        return topLevelFiles(in: gameDirectory).filter { file in
            !nonCompressibleExtensions.contains(file.pathExtension.lowercased())
                && tokens.contains(file.lastPathComponent)
                && ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) <= maxCompressSize
        }
    }

    static func decompressibleFiles(gameDirectory: URL, code: String) -> [URL] {
        guard let exec = try? loadDesktop(gameDirectory: gameDirectory, code: code).exec else { return [] }
        let tokens = execTokens(exec)
        return topLevelFiles(in: gameDirectory).filter { file in
            compressedExtensions.contains(file.pathExtension.lowercased())
                && tokens.contains(file.lastPathComponent)
                && singleEntry(of: file) != nil
        }
    }

    // MARK: - Helpers

    /// Exec split like CE: "/" and quotes become spaces, so file names stand alone
    static func execTokens(_ exec: String) -> Set<String> {
        Set(exec.replacingOccurrences(of: #"[/\\"]"#, with: " ", options: .regularExpression)
                .split(separator: " ").map(String.init))
    }

    /// Replace `old` where it is a whole path component (after "/" or a space,
    /// before a space, quote or the end)
    static func replaceFileName(in exec: String, old: String, new: String) -> String {
        let pattern = #"(?<=[/\s"]|^)"# + NSRegularExpression.escapedPattern(for: old) + #"(?=[\s"]|$)"#
        return exec.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: new),
                                         options: .regularExpression)
    }

    private static func topLevelFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func singleEntry(of archive: URL) -> (name: String, data: Data)? {
        guard let data = try? Data(contentsOf: archive) else { return nil }
        let entries: [any ContainerEntry]? = archive.pathExtension.lowercased() == "zip"
            ? try? ZipContainer.open(container: data)
            : try? SevenZipContainer.open(container: data)
        let files = (entries ?? []).filter { $0.info.type == .regular }
        guard files.count == 1 else { return nil }
        return (files[0].info.name, files[0].data ?? Data())
    }

    private static func loadDesktop(gameDirectory: URL, code: String) throws -> DesktopFile {
        let url = gameDirectory.appendingPathComponent("\(code).desktop")
        guard let data = try? Data(contentsOf: url) else { throw CompressionError.noDesktopFile(code) }
        return DesktopFile(data: data)
    }

    private static func save(_ desktop: DesktopFile, gameDirectory: URL, code: String) throws {
        desktop.normalizeForSave()
        try desktop.toData().write(to: gameDirectory.appendingPathComponent("\(code).desktop"))
    }
}
