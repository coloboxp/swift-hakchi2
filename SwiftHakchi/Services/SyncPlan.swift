import Foundation
import zlib

/// A file that should exist on the console after a sync (CE's `ApplicationFileInfo`)
struct SyncFile: Sendable {
    enum Source: Sendable {
        case file(URL)
        case data(Data)
    }

    /// Path relative to the upload folder, CE style: "./001/CLV-H-ABCDE/game.nes"
    let path: String
    let size: Int64
    /// Modification time, seconds since 1970 (stored in the tar and compared on the next sync)
    let modified: Int64
    let source: Source

    /// Generated content (menu entries, resized covers). The mtime is derived from the
    /// content, so unchanged content keeps its timestamp and is not uploaded again.
    /// (CE stamped generated files with "now", re-uploading them on every sync.)
    static func generated(path: String, data: Data) -> SyncFile {
        SyncFile(path: path, size: Int64(data.count), modified: contentTimestamp(data), source: .data(data))
    }

    static func file(path: String, url: URL) -> SyncFile? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let modified = Int64((values.contentModificationDate ?? Date()).timeIntervalSince1970)
        return SyncFile(path: path, size: Int64(size), modified: modified, source: .file(url))
    }

    /// Deterministic timestamp in 2001–2004 from the CRC32 of the content
    static func contentTimestamp(_ data: Data) -> Int64 {
        let crc = data.withUnsafeBytes { ptr -> UInt in
            UInt(zlib.crc32(0, ptr.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt(data.count)))
        }
        return 1_000_000_000 + Int64(crc % 100_000_000)
    }

    func contents() throws -> Data {
        switch source {
        case .data(let d): return d
        case .file(let url): return try Data(contentsOf: url)
        }
    }

    /// Size rounded up to the console's 4 KiB block size (CE's PadFileSize)
    var paddedSize: Int64 { SyncPlan.padded(size) }
}

/// A file found on the console by the remote listing
struct RemoteFile: Equatable, Sendable {
    let path: String
    let size: Int64
    let modified: Int64
}

/// Pure sync logic: listing parsing, diff, safety rules, memory stats (no console access)
enum SyncPlan {
    static let blockSize: Int64 = 4096

    static func padded(_ size: Int64) -> Int64 {
        size == 0 ? 0 : ((size + blockSize - 1) / blockSize) * blockSize
    }

    /// Shell command listing every file under the upload folder as "size mtime ./path".
    /// (CE used `stat -c "%n %s %y"`, a local time without zone; epoch seconds avoid that.)
    static func listingCommand(uploadPath: String) -> String {
        let p = shellQuote(uploadPath)
        return "mkdir -p \(p) && cd \(p) && find . -type f | while read -r f; do stat -c '%s %Y %n' \"$f\"; done"
    }

    static func parseListing(_ output: String) -> [RemoteFile] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let size = Int64(parts[0]), let mtime = Int64(parts[1]) else { return nil }
            return RemoteFile(path: String(parts[2]), size: size, modified: mtime)
        }
    }

    /// CE's equality: same path and size, mtime within 3 seconds
    static func matches(_ local: SyncFile, _ remote: RemoteFile) -> Bool {
        local.path == remote.path && local.size == remote.size && abs(local.modified - remote.modified) < 3
    }

    struct Diff {
        /// Local files to upload (missing or different on the console)
        var upload: [SyncFile] = []
        /// Remote paths to delete
        var delete: [String] = []
        /// Remote files kept although not in the local set (their game's ROM is not on the Mac)
        var protected: [String] = []
    }

    /// Compare the wanted files with the console's files (CE's CalculateRemoteDiff).
    /// Remote files belonging to `protectedCodes` (selected games whose ROM is missing
    /// locally) are never deleted: the console copy is the only one.
    static func diff(local: [SyncFile], remote: [RemoteFile], protectedCodes: Set<String>) -> Diff {
        var result = Diff()
        let remoteByPath = Dictionary(remote.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let localPaths = Set(local.map(\.path))

        for file in local {
            if let r = remoteByPath[file.path], matches(file, r) { continue }
            result.upload.append(file)
        }
        for file in remote where !localPaths.contains(file.path) {
            if let code = gameCode(inPath: file.path), protectedCodes.contains(code) {
                result.protected.append(file.path)
            } else {
                result.delete.append(file.path)
            }
        }
        return result
    }

    /// Game code from "./.storage/CLV-H-ABCDE/x" or "./001/CLV-H-ABCDE/x" (nil for other files)
    static func gameCode(inPath path: String) -> String? {
        for component in path.split(separator: "/") where component.count == 11 && component.hasPrefix("CLV-") {
            return String(component)
        }
        return nil
    }

    /// Script that deletes remote files (CE's cleanup.sh)
    static func deleteScript(paths: [String], uploadPath: String) -> String {
        var lines = ["#!/bin/sh", "cd \(shellQuote(uploadPath)) || exit 1"]
        lines += paths.map { "rm -f \(shellQuote($0))" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Delete the other layout's folders when switching "separate games for multiboot"
    /// (CE's first CalculateRemoteDiff command)
    static func layoutCleanupCommand(syncRoot: String, separateMultiboot: Bool) -> String {
        let codes = "(/hvcj-jpn?|/snes(-usa|-eur|-jpn)?|/nes(-usa|-jpn)?|/md(-jpn|-usa|-eur|-asia)?|/)$"
        return "find \(shellQuote(syncRoot + "/")) -maxdepth 1 | tail -n +2 | grep -\(separateMultiboot ? "v" : "")Ee '\(codes)' | while read f; do rm -rf \"$f\"; done"
    }

    /// Remove directories left without files (CE's RemoteCleanup)
    static func emptyDirectoryCleanupCommand(uploadPath: String) -> String {
        let p = shellQuote(uploadPath)
        return "for f in $(find \(p) -type d -mindepth 1 -maxdepth 2); do { find \"$f\" -type f -mindepth 1 | grep -v pixelart | grep -v autoplay | wc -l | { read wc; test $wc -eq 0 && rm -rf \"$f\"; } } ; done"
    }

    /// Split files into tar batches of about `limit` bytes (a big file gets its own batch)
    static func batches(_ files: [SyncFile], limit: Int64 = 24 * 1024 * 1024) -> [[SyncFile]] {
        var result: [[SyncFile]] = []
        var current: [SyncFile] = []
        var currentSize: Int64 = 0
        for file in files {
            if !current.isEmpty && currentSize + file.size > limit {
                result.append(current)
                current = []
                currentSize = 0
            }
            current.append(file)
            currentSize += file.size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Single-quote for the console's shell
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Storage usage on the console (port of CE's `MemoryStats`)
struct MemoryStats: Equatable, Sendable {
    var storageTotal: Int64 = 0
    var storageUsed: Int64 = 0
    var storageFree: Int64 = 0
    var saveStatesSize: Int64 = 0
    var allGamesSize: Int64 = 0
    var nonMultibootGamesSize: Int64 = 0
    var extraFilesSize: Int64 = 0
    /// Size per system-code folder ("snes-usa" → bytes)
    var collections: [String: Int64] = [:]

    static let knownSystemCodes: Set<String> = [
        "nes-usa", "nes-jpn", "snes-eur", "snes-usa", "snes-jpn", "hvcj-jpn", "md-jpn", "md-usa", "md-eur", "md-asia",
    ]

    /// Commands, in order: df (total | used | free), du of saves, du -d 1 of the sync folder
    static let dfCommand = "df \"$(hakchi findGameSyncStorage)\" | tail -n 1 | awk '{ print $2 \" | \" $3 \" | \" $4 }'"
    static let savesCommand = "du -s \"$(readlink /var/saves)\" | awk '{ print $1 }'"
    static func collectionsCommand(syncRoot: String) -> String {
        "du -d 1 \(SyncPlan.shellQuote(syncRoot)) | head -n -1 | awk '{ print $2 \" | \" $1 }'"
    }

    /// Parse the three command outputs (sizes are in KiB, like CE)
    static func parse(df: String, saves: String, collections: String) -> MemoryStats? {
        let parts = df.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 3, let total = Int64(parts[0]), let used = Int64(parts[1]), let free = Int64(parts[2]) else {
            return nil
        }
        var stats = MemoryStats(storageTotal: total * 1024, storageUsed: used * 1024, storageFree: free * 1024)
        stats.saveStatesSize = (Int64(saves.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) * 1024

        for line in collections.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let cols = line.components(separatedBy: " | ")
            guard cols.count >= 2, let kib = Int64(cols[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let dir = (cols[0] as NSString).lastPathComponent
            let size = kib * 1024
            if dir == ".storage" || dir.range(of: #"^[0-9]{3}$"#, options: .regularExpression) != nil {
                stats.nonMultibootGamesSize += size
            } else if knownSystemCodes.contains(dir) {
                stats.collections[dir] = size
            } else {
                stats.extraFilesSize += size
            }
            stats.allGamesSize += size
        }
        return stats
    }

    /// Space the games may use (CE's AvailableForGames)
    func availableForGames(separateMultiboot: Bool, systemCode: String) -> Int64 {
        if separateMultiboot {
            return storageFree + (collections[systemCode] ?? 0) + nonMultibootGamesSize + extraFilesSize
        }
        return storageFree + allGamesSize
    }

    /// Bytes used by things other than games and saves (mods, configs)
    var otherFilesSize: Int64 { storageUsed - allGamesSize - saveStatesSize }
}
