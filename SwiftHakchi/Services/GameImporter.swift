import Foundation
import SWCompression
import zlib
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "GameImporter")

/// Imports ROMs and game folders into the local library
/// (port of Hakchi2-CE's `AddGamesTask.AddGames` + `NesApplication.Import`).
///
/// Per input file:
/// - `.desktop`: copy its whole folder (an already prepared game)
/// - `.clvg`: unpack (tar.gz of a game folder) and copy it
/// - `.zip` / `.7z` (unless "as is"): pick the ROM inside, asking when there are several
/// - anything else: detect the system by extension, build the Exec line from the
///   system's default core, run the system's ROM fixes, and write
///   `CODE.desktop` + `metadata.json` in `games/CODE/`
@MainActor
final class GameImporter {
    struct Options {
        /// Import files untouched: no archive unpacking, no ROM fixes (CE's "As-Is...")
        var asIs = false
        /// Console the games are for (affects FDS and cover defaults)
        var consoleType: ConsoleType = .unknown
        var convertToSfrom = true
    }

    struct ImportedGame {
        let code: String
        let directory: URL
        /// The ROM file that was imported (for database lookups)
        let sourceFile: URL
        let originalCrc32: UInt32
        /// True when no system was detected; CE opens the core dialog for these
        let unknownSystem: Bool
    }

    struct Report {
        var imported: [ImportedGame] = []
        var errors: [String] = []
        var warnings: [String] = []
    }

    /// Asks the user to pick one entry when an archive holds several candidates.
    /// Returns nil to skip the archive.
    typealias FileChooser = (_ archiveName: String, _ entries: [String]) -> String?

    /// Answer to a yes/no question during import ("to all" applies to the rest of the batch)
    enum Answer { case yes, yesToAll, no }
    /// Asks a yes/no question (unsupported NES mapper, IPS patch, SNES problem game)
    typealias Asker = (_ title: String, _ message: String) -> Answer

    /// Files bigger than this are copied without being read into memory (CE's MaxCompress)
    static let maxInMemorySize = 16 * 1024 * 1024

    private let gamesDirectory: URL
    private let patchesDirectory: URL
    private let cores: CoreCatalog
    private let chooseFile: FileChooser
    private let ask: Asker
    /// "Yes to all" answers given during this batch, by question kind
    private var yesToAll: Set<String> = []

    init(gamesDirectory: URL, patchesDirectory: URL, cores: CoreCatalog,
         chooseFile: @escaping FileChooser, ask: @escaping Asker) {
        self.gamesDirectory = gamesDirectory
        self.patchesDirectory = patchesDirectory
        self.cores = cores
        self.chooseFile = chooseFile
        self.ask = ask
    }

    /// Ask once per kind; "yes to all" skips later questions of the same kind
    private func confirm(_ kind: String, title: String, message: String) -> Bool {
        if yesToAll.contains(kind) { return true }
        switch ask(title, message) {
        case .yes: return true
        case .yesToAll: yesToAll.insert(kind); return true
        case .no: return false
        }
    }

    func importFiles(_ urls: [URL], options: Options) -> Report {
        var report = Report()
        try? FileManager.default.createDirectory(at: gamesDirectory, withIntermediateDirectories: true)

        for url in urls {
            do {
                if let game = try importOne(url, options: options, report: &report) {
                    report.imported.append(game)
                }
            } catch {
                logger.error("Import of \(url.lastPathComponent) failed: \(error.localizedDescription)")
                report.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }

    // MARK: - Dispatch

    private func importOne(_ url: URL, options: Options, report: inout Report) throws -> ImportedGame? {
        let ext = url.pathExtension.lowercased()

        if ext == "desktop" {
            return try importGameFolder(desktopFile: url)
        }
        if ext == "clvg" {
            return try importClvg(url)
        }
        if !options.asIs, ["zip", "7z", "rar"].contains(ext) {
            return try importFromArchive(url, options: options, report: &report)
        }
        return try importRom(url, originalName: url.lastPathComponent, data: nil, options: options, report: &report)
    }

    // MARK: - Archives

    private func importFromArchive(_ url: URL, options: Options, report: inout Report) throws -> ImportedGame? {
        let ext = url.pathExtension.lowercased()
        guard ext != "rar" else { throw ImportError.rarUnsupported }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let entries: [(name: String, data: Data)] = try {
            let raw: [any ContainerEntry] = ext == "zip"
                ? try ZipContainer.open(container: data)
                : try SevenZipContainer.open(container: data)
            return raw.compactMap { entry in
                guard entry.info.type == .regular, let d = entry.data else { return nil }
                return (entry.info.name, d)
            }
        }()
        guard !entries.isEmpty else { throw ImportError.emptyArchive }

        // An archived game folder (contains a .desktop): unpack everything and import the folder
        if let desktop = entries.first(where: { $0.name.lowercased().hasSuffix(".desktop") }) {
            let tempDir = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try Self.write(entries: entries, to: tempDir)
            return try importGameFolder(desktopFile: tempDir.appendingPathComponent(desktop.name))
        }

        // Pick the ROM: known extensions first, then a single file, else ask
        let known = cores.allExtensions
        let candidates = entries.filter { known.contains("." + ($0.name as NSString).pathExtension.lowercased()) }
        let pool = candidates.isEmpty ? entries : candidates
        let chosenName: String
        if pool.count == 1 {
            chosenName = pool[0].name
        } else {
            guard let picked = chooseFile(url.lastPathComponent, pool.map(\.name).sorted()) else { return nil }
            chosenName = picked
        }
        guard let chosen = entries.first(where: { $0.name == chosenName }) else { return nil }

        // Multi-file games (cue/gdi/m3u) and ROMs with sibling art/patches need the files on disk
        let baseName = ((chosenName as NSString).lastPathComponent as NSString).deletingPathExtension
        let chosenExt = (chosenName as NSString).pathExtension.lowercased()
        let needsFolder = ["cue", "gdi", "m3u"].contains(chosenExt) || entries.contains { e in
            let n = (e.name as NSString).lastPathComponent as NSString
            return n.deletingPathExtension == baseName && ["jpg", "png", "ips"].contains(n.pathExtension.lowercased())
        }
        if needsFolder {
            let tempDir = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try Self.write(entries: entries, to: tempDir)
            let file = tempDir.appendingPathComponent(chosenName)
            return try importRom(file, originalName: file.lastPathComponent, data: nil, options: options, report: &report)
        }

        // Single ROM in memory; give it a real path name for naming and lookups
        let virtualURL = url.deletingLastPathComponent().appendingPathComponent((chosenName as NSString).lastPathComponent)
        return try importRom(virtualURL, originalName: virtualURL.lastPathComponent, data: chosen.data,
                             options: options, report: &report)
    }

    // MARK: - ROM import

    private func importRom(_ url: URL, originalName: String, data inputData: Data?,
                           options: Options, report: inout Report) throws -> ImportedGame? {
        let ext = SystemCatalog.normalizedExtension(url.pathExtension)
        let files = inputData == nil ? Self.gameFiles(for: url) : [url]

        var rawData = inputData
        if rawData == nil, files.count == 1,
           let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.maxInMemorySize {
            rawData = try Data(contentsOf: url)
        }

        // Detect the system: system table first, then a unique libretro system
        var system = SystemCatalog.system(forExtension: ext)
        var defaultCoreBin = system.defaultCore
        if system.isUnknown {
            let systems = cores.systems(forExtension: ext).filter { !SystemCatalog.redundantSystems.contains($0) }
            if systems.count == 1, let first = cores.cores(forSystem: systems[0]).first {
                let known = SystemCatalog.system(named: systems[0])
                system = known.isUnknown
                    ? EmulatedSystem(name: systems[0], kind: .libretro, defaultCore: first.bin, legacyApps: [],
                                     extensions: [], prefix: SystemCatalog.availablePrefix(for: systems[0]),
                                     searchSuffix: "game")
                    : known
                defaultCoreBin = known.isUnknown ? first.bin : known.defaultCore
            }
        }

        var core = defaultCoreBin.isEmpty ? nil : cores.core(defaultCoreBin)
        var application = core?.qualifiedBin ?? (ext.count > 2 ? "/bin/" + ext.dropFirst() : "")
        var args = core?.defaultArgs ?? ""
        var prefix: Character = system.isUnknown && !ext.isEmpty
            ? SystemCatalog.availablePrefix(for: ext) : system.prefix
        var saveCount = 0

        var crc32: UInt32 = rawData.map { CRC32.checksum($0) } ?? Self.crc32(of: files)
        var outputFileName = Self.safeFileName(url.lastPathComponent)

        // ROM fixes only when the file is in memory and not imported "as is"
        if var data = rawData, !options.asIs {
            var patch = SystemPatchInput(
                sourceURL: url, inputFileName: url.lastPathComponent, data: data, prefix: prefix, application: application,
                outputFileName: outputFileName, args: args, saveCount: saveCount, crc32: crc32)
            let outcome = applySystemPatch(system: system, input: &patch, options: options, report: &report)
            switch outcome {
            case .skip:
                return nil
            case .patched:
                data = patch.data
                prefix = patch.prefix
                application = patch.application
                outputFileName = patch.outputFileName
                args = patch.args
                saveCount = patch.saveCount
                crc32 = patch.crc32
                if let newCore = cores.core(forExec: application) { core = newCore }
            case .unchanged:
                if let patched = applyIpsPatch(romURL: url, data: data, crc32: crc32, report: &report) {
                    data = patched
                }
            }
            rawData = data
        }

        // Write the game folder (CE replaces an existing folder with the same code)
        let code = Self.generateCode(crc32: crc32, prefix: prefix)
        let gameDir = gamesDirectory.appendingPathComponent(code)
        let fm = FileManager.default
        try? fm.removeItem(at: gameDir)
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)

        let romDest = gameDir.appendingPathComponent(outputFileName)
        if let rawData {
            try rawData.write(to: romDest)
        } else {
            try fm.copyItem(at: url, to: romDest)
        }
        try copyAdditionalFiles(files.dropFirst(), sourceRoot: url.deletingLastPathComponent(), into: gameDir)

        let desktop = DesktopFile()
        desktop.code = code
        desktop.name = Self.nameFromFileName(url.lastPathComponent)
        desktop.exec = "\(application) /var/games/\(code)/\(outputFileName) \(args)"
            .trimmingCharacters(in: .whitespaces)
        desktop.profilePath = "/var/saves"
        desktop.iconPath = "/var/games"
        desktop.iconFilename = "\(code).png"
        desktop.saveCount = saveCount
        desktop.normalizeForSave()
        try desktop.toData().write(to: gameDir.appendingPathComponent("\(code).desktop"))

        let meta = GameMetadata(
            system: system.isUnknown ? "" : system.name,
            core: core?.bin ?? "",
            originalFilename: originalName,
            originalCrc32: crc32)
        try meta.save(gameDirectory: gameDir)

        logger.info("Imported \(originalName) as \(code) (\(system.name), core \(core?.bin ?? "-"))")
        return ImportedGame(code: code, directory: gameDir, sourceFile: url, originalCrc32: crc32,
                            unknownSystem: system.isUnknown)
    }

    // MARK: - System-specific ROM fixes

    struct SystemPatchInput {
        /// Where the ROM came from (sibling .ips patches are looked up here)
        var sourceURL: URL
        var inputFileName: String
        var data: Data
        var prefix: Character
        var application: String
        var outputFileName: String
        var args: String
        var saveCount: Int
        var crc32: UInt32
    }

    enum PatchOutcome {
        /// The system has no fixes; IPS patches may still apply
        case unchanged
        /// Fixes applied; `input` holds the new values
        case patched
        /// The user cancelled the import of this file
        case skip
    }

    /// Per-system fixes (CE's `<Class>.Patch`): NES header check, FDS header strip, SNES → SFROM.
    private func applySystemPatch(system: EmulatedSystem, input: inout SystemPatchInput,
                                  options: Options, report: inout Report) -> PatchOutcome {
        let romURL = input.sourceURL
        let provider: RomPatchProvider = { [self] data, crc in
            ipsPatch(for: romURL, data: data, crc32: crc)
        }

        switch system.kind {
        case .nes:
            let r = NesRom.prepareForImport(data: input.data, fileName: input.inputFileName, patchProvider: provider)
            for warning in r.warnings {
                let message: String
                switch warning {
                case .unsupportedMapper(let mapper):
                    message = "\(input.inputFileName) uses mapper #\(mapper), which the original emulator does not support. The game might not work. Import it anyway?"
                case .fourScreenMirroring:
                    message = "\(input.inputFileName) uses four-screen mirroring, which the original emulator does not support. The game might not work. Import it anyway?"
                }
                guard confirm("nesWarning", title: "Unsupported NES game", message: message) else { return .skip }
            }
            input.data = r.data
            input.crc32 = r.crc32
            if let app = r.application { input.application = app }
            if let args = r.args { input.args = args }
            if let saves = r.saveCount { input.saveCount = saves }
            return r.isValidINES || r.patched ? .patched : .unchanged

        case .fds:
            let r = FdsRom.prepareForImport(data: input.data,
                                            targetIsNesConsole: [.nes, .famicom].contains(options.consoleType),
                                            patchProvider: provider)
            input.data = r.data
            input.crc32 = r.crc32
            if let app = r.application { input.application = app }
            if let args = r.args { input.args = args }
            return .patched

        case .snes:
            do {
                let r = try SnesRom.prepareForImport(data: input.data, fileName: input.inputFileName,
                                                     convertToSfrom: options.convertToSfrom, patchProvider: provider)
                var useCanoe = true
                if r.isProblemGame {
                    // CE asks whether to use a third-party emulator instead of canoe
                    useCanoe = !confirm("snesProblem", title: "Known problem game",
                                        message: "\(input.inputFileName) is known to have problems with the original SNES emulator (canoe). Use a third-party emulator (RetroArch snes9x) instead?")
                }
                input.crc32 = r.crc32
                if useCanoe {
                    input.data = r.data
                    if let ext = r.outputExtension {
                        input.outputFileName = (input.outputFileName as NSString).deletingPathExtension + ext
                    }
                    if let app = r.application { input.application = app }
                    if let args = r.args { input.args = args }
                    if let saves = r.saveCount { input.saveCount = saves }
                } else {
                    // Deliberate fix: CE still wrote a .sfrom here, which snes9x cannot read.
                    // Keep the header-stripped ROM and the system's default core instead.
                    input.data = SnesRom.stripCopierHeader(input.data).0
                }
                return .patched
            } catch {
                report.errors.append("\(input.inputFileName): \(error.localizedDescription)")
                return .skip
            }

        case .megaDrive, .libretro, .other:
            return .unchanged
        }
    }

    /// Apply a matching IPS patch for systems without their own fixes (CE's `FindPatch`)
    private func applyIpsPatch(romURL: URL, data: Data, crc32: UInt32, report: inout Report) -> Data? {
        ipsPatch(for: romURL, data: data, crc32: crc32)
    }

    /// Find an IPS patch in `patches/` or next to the ROM, ask, and apply it
    private func ipsPatch(for romURL: URL, data: Data, crc32: UInt32) -> Data? {
        guard let patchURL = IpsPatch.findPatch(patchesDirectory: patchesDirectory, romURL: romURL, crc32: crc32),
              confirm("ipsPatch", title: "Apply patch?",
                      message: "Found the patch \(patchURL.lastPathComponent) for \(romURL.lastPathComponent). Apply it?"),
              let patch = try? Data(contentsOf: patchURL) else { return nil }
        do {
            return try IpsPatch.apply(patch, to: data)
        } catch {
            logger.error("IPS patch \(patchURL.lastPathComponent) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Game folders

    /// Copy an already prepared game folder (the one holding `desktopFile`) into the library
    private func importGameFolder(desktopFile: URL) throws -> ImportedGame {
        let code = desktopFile.deletingPathExtension().lastPathComponent
        let source = desktopFile.deletingLastPathComponent()
        let target = gamesDirectory.appendingPathComponent(code)
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        try fm.copyItem(at: source, to: target)

        let desktop = DesktopFile(data: (try? Data(contentsOf: target.appendingPathComponent("\(code).desktop"))) ?? Data())
        let meta = GameMetadata.load(gameDirectory: target, exec: desktop.exec)
        if !fm.fileExists(atPath: target.appendingPathComponent(GameMetadata.fileName).path) {
            try? meta.save(gameDirectory: target)
        }
        return ImportedGame(code: code, directory: target, sourceFile: desktopFile,
                            originalCrc32: meta.originalCrc32, unknownSystem: false)
    }

    /// `.clvg` = tar.gz of a game folder (CE's game archive format)
    private func importClvg(_ url: URL) throws -> ImportedGame {
        let tar = try GzipArchive.unarchive(archive: try Data(contentsOf: url))
        let entries = try TarContainer.open(container: tar).compactMap { e -> (name: String, data: Data)? in
            guard e.info.type == .regular, let d = e.data else { return nil }
            var name = e.info.name
            if name.hasPrefix("./") { name.removeFirst(2) }
            return (name, d)
        }
        let desktops = entries.filter { $0.name.lowercased().hasSuffix(".desktop") }
        guard !desktops.isEmpty else { throw ImportError.noDesktopFile }
        let chosen: String
        if desktops.count == 1 {
            chosen = desktops[0].name
        } else {
            guard let picked = chooseFile(url.lastPathComponent, desktops.map(\.name).sorted()) else {
                throw ImportError.cancelled
            }
            chosen = picked
        }

        let tempDir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try Self.write(entries: entries, to: tempDir)
        return try importGameFolder(desktopFile: tempDir.appendingPathComponent(chosen))
    }

    // MARK: - Multi-file games

    /// The game file plus every file it references (.cue tracks, .gdi tracks, .m3u entries)
    static func gameFiles(for url: URL) -> [URL] {
        var result: [URL] = []
        collectGameFiles(url, into: &result)
        return result
    }

    private static func collectGameFiles(_ url: URL, into result: inout [URL]) {
        let std = url.standardizedFileURL
        guard !result.contains(std), FileManager.default.fileExists(atPath: std.path) else { return }
        result.append(std)

        let dir = std.deletingLastPathComponent()
        guard let text = (try? String(contentsOf: std, encoding: .utf8))
                ?? (try? String(contentsOf: std, encoding: .isoLatin1)) else { return }

        switch std.pathExtension.lowercased() {
        case "cue":
            // FILE "track 01.bin" BINARY  (quotes optional)
            let regex = try! NSRegularExpression(pattern: #"^\s*FILE\s+(?:"([^"]+)"|(\S+))"#,
                                                 options: [.anchorsMatchLines, .caseInsensitive])
            for name in matches(regex, in: text, groups: [1, 2]) {
                collectGameFiles(dir.appendingPathComponent(name), into: &result)
            }
        case "gdi":
            let regex = try! NSRegularExpression(
                pattern: #"^(\d+)[ \t]+(\d+)[ \t]+(\d+)[ \t]+(\d+)[ \t]+(?:"([^"]+)"|([^\s]+))[ \t]+(\d+)"#,
                options: .anchorsMatchLines)
            for name in matches(regex, in: text, groups: [5, 6]) {
                collectGameFiles(dir.appendingPathComponent(name), into: &result)
            }
        case "m3u":
            for line in text.components(separatedBy: .newlines) {
                let entry = line.trimmingCharacters(in: .whitespaces)
                guard !entry.isEmpty, !entry.hasPrefix("#") else { continue }
                collectGameFiles(dir.appendingPathComponent(entry), into: &result)
            }
        default:
            break
        }
    }

    private static func matches(_ regex: NSRegularExpression, in text: String, groups: [Int]) -> [String] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            for g in groups where m.range(at: g).location != NSNotFound {
                return ns.substring(with: m.range(at: g))
            }
            return nil
        }
    }

    /// Copy referenced files, keeping their folder relative to the main file
    private func copyAdditionalFiles(_ files: ArraySlice<URL>, sourceRoot: URL, into gameDir: URL) throws {
        let root = sourceRoot.standardizedFileURL.path
        for file in files {
            let dirPath = file.deletingLastPathComponent().standardizedFileURL.path
            guard dirPath.hasPrefix(root) else { continue }
            let relative = String(dirPath.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let destDir = relative.isEmpty ? gameDir : gameDir.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let dest = destDir.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.copyItem(at: file, to: dest)
            }
        }
    }

    // MARK: - Helpers (CE algorithms)

    /// `CLV-<prefix>-` + five letters from the CRC32 (CE's `GenerateCode`)
    static func generateCode(crc32: UInt32, prefix: Character) -> String {
        let letter = { (shift: UInt32) -> Character in
            Character(UnicodeScalar(UInt8(65 + (crc32 >> shift) % 26)))
        }
        return "CLV-\(prefix)-\(letter(0))\(letter(5))\(letter(10))\(letter(15))\(letter(20))"
    }

    /// File name safe for the console (CE's `GenerateSafeFileName`)
    static func safeFileName(_ input: String) -> String {
        let ns = input as NSString
        let ext = ns.pathExtension.isEmpty ? "" : "." + ns.pathExtension
        var f = ns.deletingPathExtension
        f = f.replacingOccurrences(of: #" ?\(.*?\)| ?\[.*?\]"#, with: "", options: .regularExpression)
        f = f.replacingOccurrences(of: #"[^A-Za-z0-9\.\!\-]+"#, with: "_", options: .regularExpression)
        f = f.replacingOccurrences(of: #"_+"#, with: "_", options: .regularExpression)
        let maxLength = 64 - ".sfrom.lzma".count
        if f.count > maxLength { f = String(f.prefix(maxLength)) }
        return f.trimmingCharacters(in: CharacterSet(charactersIn: "_.")) + ext
    }

    /// Game name from a file name: drop (tags) and [tags], underscores → spaces (CE)
    static func nameFromFileName(_ fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension
        name = name.replacingOccurrences(of: #" ?\(.*?\)| ?\[.*?\]"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "  ", with: " ")
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// CRC32 over the concatenation of several files (multi-file games)
    private static func crc32(of files: [URL]) -> UInt32 {
        var crc: uLong = 0
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                crc = chunk.withUnsafeBytes { ptr in
                    zlib.crc32(crc, ptr.baseAddress?.assumingMemoryBound(to: UInt8.self), uInt(chunk.count))
                }
            }
        }
        return UInt32(crc)
    }

    private static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftHakchi-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(entries: [(name: String, data: Data)], to dir: URL) throws {
        for entry in entries {
            // Refuse entries that would escape the folder ("../")
            let dest = dir.appendingPathComponent(entry.name).standardizedFileURL
            guard dest.path.hasPrefix(dir.standardizedFileURL.path) else { continue }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try entry.data.write(to: dest)
        }
    }
}

enum ImportError: LocalizedError {
    case rarUnsupported
    case emptyArchive
    case noDesktopFile
    case cancelled

    var errorDescription: String? {
        switch self {
        case .rarUnsupported: return "RAR archives are not supported. Please extract the file first."
        case .emptyArchive: return "The archive is empty."
        case .noDesktopFile: return "No .desktop file found in the game archive."
        case .cancelled: return "Import cancelled."
        }
    }
}
