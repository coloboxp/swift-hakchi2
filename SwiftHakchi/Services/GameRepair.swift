import Foundation
import SWCompression
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "GameRepair")

/// Port of Hakchi2-CE's `NesApplication.Repair`: find the game's ROM, unpack
/// single-file archives, give the ROM a console-safe name, and rebuild Exec.
///
/// Also used to migrate games imported by older versions of this app, which kept
/// file names with spaces and wrote broken Exec lines for unknown systems.
@MainActor
enum GameRepair {
    struct Options {
        /// Keep the arguments after the ROM path (migration). CE resets them to
        /// the core's defaults (manual "Repair games").
        var preserveArgs = false
        /// Picks a file when several candidates exist; nil = give up on this game
        var chooseFile: ((_ gameName: String, _ files: [String]) -> String?)?
        /// Unpack single-file .7z/.zip archives (CE). The migration keeps them:
        /// compressed ROMs are valid on the console.
        var unpackArchives = true
        /// When the ROM is not in the folder (e.g. it only exists on the console),
        /// keep it in Exec instead of removing it (CE removes it)
        var keepMissingFile = false
    }

    enum Outcome: Equatable {
        case unchanged, repaired, skipped
    }

    private static let compressed: Set<String> = ["7z", "zip"]

    static func repair(gameDirectory dir: URL, code: String, cores: CoreCatalog, options: Options) throws -> Outcome {
        let fm = FileManager.default
        let desktopURL = dir.appendingPathComponent("\(code).desktop")
        guard let data = try? Data(contentsOf: desktopURL) else { return .skipped }
        let desktop = DesktopFile(data: data)
        let originalExec = desktop.exec
        let bin = desktop.bin

        // 1. Locate the ROM from Exec: ".../CLV-X-XXXXX/<file>" up to " -", " /" or end
        var execFile: String?
        var execPrefix: String?
        var tailArgs = ""
        let regex = try! NSRegularExpression(pattern: #"([^\s]*\/...\-.\-.....\/)(.+?)(?:\s\-+|\s\/|$)"#)
        let ns = desktop.exec as NSString
        if let m = regex.firstMatch(in: desktop.exec, range: NSRange(location: 0, length: ns.length)) {
            execPrefix = ns.substring(with: m.range(at: 1))
            execFile = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            let end = m.range(at: 2).location + m.range(at: 2).length
            tailArgs = ns.substring(from: end).trimmingCharacters(in: .whitespaces)
        }

        // 2. Candidate files: the one named in Exec, else everything that isn't metadata
        let excluded: Set<String> = ["\(code).desktop", "\(code).png", "\(code)_small.png", GameMetadata.fileName]
        var found: [String]
        if let execFile, fm.fileExists(atPath: dir.appendingPathComponent(execFile).path) {
            found = [execFile]
        } else {
            found = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix(".") && !excluded.contains($0) }
                .filter { name in
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir)
                    return !isDir.boolValue
                }
                .sorted()
        }

        // 3. Unpack single-file archives in place
        var accepted: [String] = []
        for name in found {
            let url = dir.appendingPathComponent(name)
            if options.unpackArchives, compressed.contains(url.pathExtension.lowercased()),
               let entry = singleArchiveEntry(url) {
                let target = dir.appendingPathComponent((entry.name as NSString).lastPathComponent)
                if !fm.fileExists(atPath: target.path) {
                    try entry.data.write(to: target)
                    try fm.removeItem(at: url)
                    accepted.append(target.lastPathComponent)
                    continue
                }
            }
            accepted.append(name)
        }

        // 4. Choose the file
        let selected: String
        switch accepted.count {
        case 0:
            if options.keepMissingFile, let execFile {
                // Only normalize the location; the file may still be on the console
                desktop.exec = [bin, "/var/games/\(code)/\(execFile)", tailArgs]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                return try save(desktop, originalExec: originalExec, to: desktopURL)
            }
            // No game file: drop the dead path from Exec (CE behaviour)
            if let execPrefix, let execFile {
                desktop.exec = desktop.exec.replacingOccurrences(of: execPrefix + execFile, with: "")
                    .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            }
            return try save(desktop, originalExec: originalExec, to: desktopURL)
        case 1:
            selected = accepted[0]
        default:
            guard let pick = options.chooseFile?(desktop.name, accepted) else { return .skipped }
            selected = pick
        }

        // Names containing " -" end CE's regex early; take the args after the real file name
        if let execPrefix, let range = desktop.exec.range(of: execPrefix + selected) {
            tailArgs = String(desktop.exec[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }

        // 5. Console-safe file name
        let safe = GameImporter.safeFileName(selected)
        if safe != selected {
            let target = dir.appendingPathComponent(safe)
            guard !fm.fileExists(atPath: target.path) else { throw RepairError.nameTaken(safe) }
            try fm.moveItem(at: dir.appendingPathComponent(selected), to: target)
        }

        // 6. Rebuild Exec
        let romPath = "/var/games/\(code)/\(safe)"
        if !originalExec.contains("/var/games/") && execFile == nil && !isRunnable(bin, cores: cores) {
            // Older app versions wrote "Exec=/bin/<rom name>" for unknown systems
            let system = SystemCatalog.system(forExtension: (safe as NSString).pathExtension)
            let core = cores.core(system.defaultCore)
            let app = core?.qualifiedBin ?? "/bin/" + (safe as NSString).pathExtension.lowercased()
            desktop.exec = [app, romPath, core?.defaultArgs ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        } else if let core = cores.core(forExec: desktop.exec) {
            let tail = options.preserveArgs ? tailArgs : core.defaultArgs
            desktop.exec = [core.qualifiedBin, romPath, tail].filter { !$0.isEmpty }.joined(separator: " ")
        } else {
            let tail = options.preserveArgs ? tailArgs : ""
            desktop.exec = [bin, romPath, tail].filter { !$0.isEmpty }.joined(separator: " ")
        }

        return try save(desktop, originalExec: originalExec, to: desktopURL)
    }

    /// Repair games made by older versions of this app (no metadata.json yet),
    /// keeping their arguments, and write metadata.json for them.
    static func migrateLegacyGames(in gamesDirectory: URL, cores: CoreCatalog) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: gamesDirectory, includingPropertiesForKeys: nil) else { return }
        for dir in dirs where dir.hasDirectoryPath {
            let code = dir.lastPathComponent
            guard !fm.fileExists(atPath: dir.appendingPathComponent(GameMetadata.fileName).path),
                  fm.fileExists(atPath: dir.appendingPathComponent("\(code).desktop").path) else { continue }
            do {
                let outcome = try repair(gameDirectory: dir, code: code, cores: cores,
                                         options: Options(preserveArgs: true, chooseFile: nil,
                                                          unpackArchives: false, keepMissingFile: true))
                let desktop = DesktopFile(data: (try? Data(contentsOf: dir.appendingPathComponent("\(code).desktop"))) ?? Data())
                var meta = GameMetadata.load(gameDirectory: dir, exec: desktop.exec)
                if meta.system.isEmpty, let rom = desktop.romPath {
                    let system = SystemCatalog.system(forExtension: (rom as NSString).pathExtension)
                    if !system.isUnknown { meta.system = system.name }
                }
                meta.core = cores.core(forExec: desktop.exec)?.bin ?? ""
                try meta.save(gameDirectory: dir)
                logger.info("Migrated \(code): \(String(describing: outcome))")
            } catch {
                logger.error("Migration of \(code) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private static func save(_ desktop: DesktopFile, originalExec: String, to url: URL) throws -> Outcome {
        desktop.normalizeForSave()
        try desktop.toData().write(to: url)
        return desktop.exec == originalExec ? .unchanged : .repaired
    }

    /// True when `bin` is a known emulator launcher
    private static func isRunnable(_ bin: String, cores: CoreCatalog) -> Bool {
        cores.core(forExec: bin) != nil || SystemCatalog.all.contains { $0.legacyApps.contains(bin) }
    }

    private static func singleArchiveEntry(_ url: URL) -> (name: String, data: Data)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let entries: [any ContainerEntry]? = url.pathExtension.lowercased() == "zip"
            ? try? ZipContainer.open(container: data)
            : try? SevenZipContainer.open(container: data)
        let files = (entries ?? []).filter { $0.info.type == .regular }
        guard files.count == 1, let d = files[0].data else { return nil }
        return (files[0].info.name, d)
    }
}

enum RepairError: LocalizedError {
    case nameTaken(String)

    var errorDescription: String? {
        switch self {
        case .nameTaken(let name): return "A file named \"\(name)\" already exists in the game folder."
        }
    }
}
