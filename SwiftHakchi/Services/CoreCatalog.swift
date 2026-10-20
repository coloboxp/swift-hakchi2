import Foundation
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "CoreCatalog")

/// All emulator cores the app knows about (port of Hakchi2-CE's `CoreCollection`).
///
/// Sources, later ones override earlier ones (same as CE):
/// 1. Cores read from the console's `/etc/libretro/info/*_libretro.info`, cached in
///    `~/Library/Application Support/SwiftHakchi/cores/console/` so they work offline.
///    (CE reads them from its local `user_mods` folder instead; reading the console
///    shows what is really installed.)
/// 2. User `.info` files in `~/Library/Application Support/SwiftHakchi/info/`.
/// 3. Built-in emulators (Canoe, Kachikachi, M2engage, hsqs, sh).
@MainActor
final class CoreCatalog: ObservableObject {
    static let shared = CoreCatalog()

    @Published private(set) var cores: [String: CoreInfo] = [:]
    /// When the console cache was last refreshed
    @Published private(set) var consoleRefreshDate: Date?

    /// Offline cache of the console's .info files and /bin listing
    let consoleCacheDirectory: URL
    /// User-supplied .info files
    let userInfoDirectory: URL

    private static let binListFile = "bin.txt"

    init(consoleCacheDirectory: URL = AppConfig.configDirectory.appendingPathComponent("cores/console", isDirectory: true),
         userInfoDirectory: URL = AppConfig.configDirectory.appendingPathComponent("info", isDirectory: true)) {
        self.consoleCacheDirectory = consoleCacheDirectory
        self.userInfoDirectory = userInfoDirectory
        reload()
    }

    // MARK: - Loading

    /// Rebuild the catalog from the cache, the user folder and the built-ins
    func reload() {
        var result: [String: CoreInfo] = [:]

        let cacheDir = consoleCacheDirectory
        let installed = Self.readInstalledCommands(in: cacheDir)
        for core in Self.loadInfoFiles(in: cacheDir, installedCommands: installed) {
            result[core.bin] = core
        }
        for core in Self.loadInfoFiles(in: userInfoDirectory, installedCommands: installed) {
            result[core.bin] = core
        }
        for core in CoreInfo.builtIn {
            result[core.bin] = core
        }

        cores = result
        consoleRefreshDate = (try? FileManager.default.attributesOfItem(
            atPath: cacheDir.appendingPathComponent(Self.binListFile).path))?[.modificationDate] as? Date
        logger.info("Core catalog: \(result.count) cores")
    }

    /// Read the installed cores from the console and update the offline cache
    func refreshFromConsole(shell: SSHService) async throws {
        // One round trip: every .info file framed by markers, then the /bin listing
        let script = """
        for f in /etc/libretro/info/*_libretro.info; do
          [ -f "$f" ] || continue
          echo "@@INFO@@ $(basename "$f")"; cat "$f"; echo
        done
        echo "@@BIN@@"; ls -1 /bin
        """
        let result = try await shell.execute(script, timeout: 60000)
        let parsed = Self.parseConsoleDump(result.stdout)
        try saveConsoleDump(parsed)
        logger.info("Cached \(parsed.infoFiles.count) core info files from console")
        reload()
    }

    /// Replace the offline cache with a parsed console dump
    func saveConsoleDump(_ parsed: (infoFiles: [String: String], binCommands: Set<String>)) throws {
        let dir = consoleCacheDirectory
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in parsed.infoFiles {
            try Data(text.utf8).write(to: dir.appendingPathComponent(name))
        }
        try Data(parsed.binCommands.sorted().joined(separator: "\n").utf8)
            .write(to: dir.appendingPathComponent(Self.binListFile))
    }

    /// Split the output of the refresh script into info files and /bin entries
    nonisolated static func parseConsoleDump(_ output: String) -> (infoFiles: [String: String], binCommands: Set<String>) {
        var infoFiles: [String: String] = [:]
        var binCommands: Set<String> = []
        var currentName: String?
        var currentLines: [String] = []
        var inBin = false

        func flush() {
            if let name = currentName { infoFiles[name] = currentLines.joined(separator: "\n") }
            currentName = nil
            currentLines = []
        }

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("@@INFO@@ ") {
                flush()
                currentName = String(line.dropFirst("@@INFO@@ ".count)).trimmingCharacters(in: .whitespaces)
            } else if line == "@@BIN@@" {
                flush()
                inBin = true
            } else if inBin {
                let cmd = line.trimmingCharacters(in: .whitespaces)
                if !cmd.isEmpty { binCommands.insert(cmd) }
            } else if currentName != nil {
                currentLines.append(line)
            }
        }
        flush()
        return (infoFiles, binCommands)
    }

    private static func readInstalledCommands(in dir: URL) -> Set<String> {
        guard let text = try? String(contentsOf: dir.appendingPathComponent(binListFile), encoding: .utf8) else {
            return []
        }
        return Set(text.components(separatedBy: .newlines).filter { !$0.isEmpty })
    }

    private static func loadInfoFiles(in dir: URL, installedCommands: Set<String>) -> [CoreInfo] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { url in
            guard url.lastPathComponent.lowercased().hasSuffix("_libretro.info"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return CoreInfo.parseInfo(text, fileName: url.lastPathComponent, installedCommands: installedCommands)
        }
    }

    // MARK: - Lookups

    func core(_ bin: String) -> CoreInfo? {
        cores[bin]
    }

    /// Core whose launcher starts `exec`. Uses a whole-token match and prefers the
    /// longest launcher, so "/bin/mame2003-plus …" never matches "/bin/mame2003".
    func core(forExec exec: String) -> CoreInfo? {
        let normalized = exec.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cores.values
            .filter { core in
                let qb = core.qualifiedBin.lowercased()
                return normalized == qb || normalized.hasPrefix(qb + " ")
            }
            .max { $0.qualifiedBin.count < $1.qualifiedBin.count }
    }

    func cores(forSystem system: String) -> [CoreInfo] {
        let s = system.lowercased()
        return sorted(cores.values.filter { $0.systems.contains { $0.lowercased() == s } })
    }

    func cores(forExtension ext: String) -> [CoreInfo] {
        let e = SystemCatalog.normalizedExtension(ext)
        return sorted(cores.values.filter { $0.extensions.contains(e) })
    }

    /// Every system name that some core can run for this extension
    func systems(forExtension ext: String) -> [String] {
        Array(Set(cores(forExtension: ext).flatMap(\.systems))).sorted()
    }

    /// All systems: from cores plus the built-in system table
    var allSystems: [String] {
        Array(Set(cores.values.flatMap(\.systems)).union(SystemCatalog.all.map(\.name))).sorted()
    }

    /// Every extension any core or system supports (used to find ROMs inside archives)
    var allExtensions: Set<String> {
        Set(cores.values.flatMap(\.extensions)).union(SystemCatalog.all.flatMap(\.extensions))
    }

    var allCores: [CoreInfo] {
        sorted(Array(cores.values))
    }

    private func sorted(_ list: [CoreInfo]) -> [CoreInfo] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
