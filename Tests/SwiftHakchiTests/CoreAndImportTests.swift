import Foundation
import Testing
import SWCompression
@testable import SwiftHakchi

/// Phase 1: system table, core catalog, .desktop Exec handling, import, core assignment, repair.
@MainActor
@Suite struct CoreAndImportTests {
    /// Real info file shipped by KMFD's _km_mgba.hmod (trimmed)
    static let mgbaInfo = """
    display_name = "Nintendo - GBA (km_mGBA)"
    supported_extensions = "gb|gbc|gba"
    corename = "mGBA"
    systemname = "Game Boy/Game Boy Color/Game Boy Advance"
    database = "Nintendo - Game Boy|Nintendo - Game Boy Color|Nintendo - Game Boy Advance|Nintendo - Game Boy Advance (e-Cards)"
    """

    /// Temporary folder that is deleted when the test object goes away
    final class TempDir {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftHakchiTests-\(UUID().uuidString)", isDirectory: true)
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
        func sub(_ name: String) -> URL {
            let u = url.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
    }

    private func makeCatalog(_ tmp: TempDir, infos: [String: String] = [:], bin: Set<String> = []) throws -> CoreCatalog {
        let catalog = CoreCatalog(consoleCacheDirectory: tmp.sub("cores"), userInfoDirectory: tmp.sub("info"))
        try catalog.saveConsoleDump((infos, bin))
        catalog.reload()
        return catalog
    }

    // MARK: - System table

    @Test func systemLookups() {
        #expect(SystemCatalog.system(forExtension: "NES").name == "Nintendo - Nintendo Entertainment System")
        // First match wins, like CE: .md → the m2engage entry
        #expect(SystemCatalog.system(forExtension: ".md").defaultCore == "m2engage")
        #expect(SystemCatalog.system(forExtension: ".xyz").isUnknown)
        #expect(SystemCatalog.system(forExec: "/bin/clover-canoe-shvc-wr -rom /var/games/CLV-U-AAAAA/a.sfrom --volume 100").kind == .snes)
        #expect(SystemCatalog.system(forExec: "/bin/gba /var/games/CLV-A-AAAAA/a.gba").name == "Nintendo - Game Boy Advance")
        #expect(SystemCatalog.availablePrefix(for: "Bandai - WonderSwan") == "I") // B, A, N, D are taken
        // Every letter of "HUB" is a used prefix: walk forward from H until a free one
        #expect(SystemCatalog.availablePrefix(for: "HUB") == "I")
    }

    // MARK: - Cores

    @Test func parsesLibretroInfo() throws {
        let core = try #require(CoreInfo.parseInfo(Self.mgbaInfo, fileName: "km_mgba_libretro.info",
                                                   installedCommands: ["km_mgba", "gba"]))
        #expect(core.bin == "km_mgba")
        #expect(core.name == "mGBA")
        #expect(core.extensions == [".gb", ".gbc", ".gba"])
        #expect(core.systems.contains("Nintendo - Game Boy Advance"))
        #expect(core.qualifiedBin == "/bin/km_mgba")
        #expect(CoreInfo.parseInfo("x = 1", fileName: "readme.txt") == nil)
        // CE translation table when /bin has the translated name only
        #expect(CoreInfo.resolveCommand(bin: "genesis_plus_gx", installedCommands: ["genesis-plus-gx"]) == "genesis-plus-gx")
        #expect(CoreInfo.resolveCommand(bin: "genesis_plus_gx", installedCommands: []) == "genesis-plus-gx")
        #expect(CoreInfo.resolveCommand(bin: "km_mgba", installedCommands: []) == "km_mgba")
        // Seen on a real console: km_snes9x_bright has no km_ launcher
        #expect(CoreInfo.resolveCommand(bin: "km_snes9x_bright", installedCommands: ["snes9x-bright", "snes9x_bright"])
                == "snes9x-bright") // CE translation of snes9x_bright
    }

    @Test func parsesConsoleDump() {
        let dump = """
        @@INFO@@ km_mgba_libretro.info
        corename = "mGBA"

        @@INFO@@ km_gw_libretro.info
        corename = "Game & Watch"

        @@BIN@@
        km_mgba
        km_gw
        sh
        """
        let parsed = CoreCatalog.parseConsoleDump(dump)
        #expect(parsed.infoFiles.keys.sorted() == ["km_gw_libretro.info", "km_mgba_libretro.info"])
        #expect(parsed.infoFiles["km_mgba_libretro.info"]?.contains("mGBA") == true)
        #expect(parsed.binCommands == ["km_mgba", "km_gw", "sh"])
    }

    @Test func catalogLookups() throws {
        let tmp = TempDir()
        let catalog = try makeCatalog(tmp, infos: [
            "km_mgba_libretro.info": Self.mgbaInfo,
            "mame2003_libretro.info": "corename = \"MAME 2003\"\ndatabase = \"MAME\"",
            "mame2003_plus_libretro.info": "corename = \"MAME 2003-Plus\"\ndatabase = \"MAME\"",
        ], bin: ["km_mgba", "mame2003", "mame2003-plus"])

        #expect(catalog.core("km_mgba")?.name == "mGBA")
        #expect(catalog.core("clover-kachikachi-wr")?.kind == .builtIn)
        #expect(catalog.cores(forExtension: "gba").map(\.bin) == ["km_mgba"])
        #expect(catalog.systems(forExtension: ".gbc").contains("Nintendo - Game Boy Color"))
        // Whole-token, longest match (CE's prefix match picked the wrong MAME core)
        #expect(catalog.core(forExec: "/bin/mame2003-plus /var/games/CLV-Z-AAAAA/a.zip")?.bin == "mame2003_plus")
        #expect(catalog.core(forExec: "/bin/mame2003 /var/games/CLV-Z-AAAAA/a.zip")?.bin == "mame2003")
        #expect(catalog.core(forExec: "/bin/clover-canoe-shvc-wr -rom /x/y.sfrom")?.name == "Canoe")
    }

    // MARK: - .desktop Exec

    @Test func desktopExecHelpers() {
        let d = DesktopFile(string: """
        [Desktop Entry]
        Exec=/bin/clover-canoe-shvc-wr -rom /var/games/CLV-U-ABCDE/game.sfrom --volume 100
        [X-CLOVER Game]
        Code=CLV-U-ABCDE
        """)
        #expect(d.bin == "/bin/clover-canoe-shvc-wr -rom")
        #expect(d.args == ["/var/games/CLV-U-ABCDE/game.sfrom", "--volume", "100"])
        #expect(d.romPath == "/var/games/CLV-U-ABCDE/game.sfrom")

        d.replaceBin(with: "/bin/snes9x")
        #expect(d.exec == "/bin/snes9x /var/games/CLV-U-ABCDE/game.sfrom --volume 100")

        d.rebaseGamePaths(to: "/var/lib/hakchi/games/snes-usa/.storage")
        #expect(d.exec == "/bin/snes9x /var/lib/hakchi/games/snes-usa/.storage/CLV-U-ABCDE/game.sfrom --volume 100")

        d.name = "Rock'n Roll Racing '93"
        d.sortName = ""
        d.normalizeForSave()
        #expect(d.name == "Rock'n Roll Racing `93")
        #expect(d.sortName == "rock'n roll racing `93")
    }

    @Test func metadataUsesCEKeys() throws {
        let json = #"{"System":"Nintendo - Game Boy","Core":"km_mgba","OriginalFilename":"a.gb","OriginalCrc32":123,"CustomCoverArt":true}"#
        let meta = try JSONDecoder().decode(GameMetadata.self, from: Data(json.utf8))
        #expect(meta == GameMetadata(system: "Nintendo - Game Boy", core: "km_mgba", originalFilename: "a.gb",
                                     originalCrc32: 123, customCoverArt: true))
        let encoded = String(decoding: try JSONEncoder().encode(meta), as: UTF8.self)
        #expect(encoded.contains("\"OriginalCrc32\":123"))
    }

    // MARK: - Import

    @Test func ceNameAndCodeHelpers() {
        #expect(GameImporter.safeFileName("Super Mario Bros. (USA) [!].nes") == "Super_Mario_Bros.nes")
        #expect(GameImporter.nameFromFileName("Super_Mario_Bros (USA).nes") == "Super Mario Bros")
        #expect(GameImporter.generateCode(crc32: 0, prefix: "H") == "CLV-H-AAAAA")
        #expect(GameImporter.generateCode(crc32: 0x12345678, prefix: "U").count == 11)
    }

    private func makeImporter(_ tmp: TempDir, catalog: CoreCatalog,
                              answer: GameImporter.Answer = .yes) -> (GameImporter, URL) {
        let games = tmp.sub("games")
        let importer = GameImporter(gamesDirectory: games, patchesDirectory: tmp.sub("patches"), cores: catalog,
                                    chooseFile: { _, entries in entries.first }, ask: { _, _ in answer })
        return (importer, games)
    }

    /// Minimal valid iNES file: mapper 0, 16 KiB PRG, 8 KiB CHR
    private func inesRom() -> Data {
        var data = Data([0x4E, 0x45, 0x53, 0x1A, 1, 1, 0, 0] + [UInt8](repeating: 0, count: 8))
        data.append(Data((0..<(16384 + 8192)).map { UInt8($0 & 0xFF) }))
        return data
    }

    @Test func importsNesRomWithKachikachi() throws {
        let tmp = TempDir()
        let catalog = try makeCatalog(tmp)
        let (importer, games) = makeImporter(tmp, catalog: catalog)
        let src = tmp.sub("src").appendingPathComponent("My Game (USA).nes")
        try inesRom().write(to: src)

        let report = importer.importFiles([src], options: .init(consoleType: .nes))
        #expect(report.errors.isEmpty)
        let game = try #require(report.imported.first)
        #expect(game.code.hasPrefix("CLV-H-"))
        #expect(!game.unknownSystem)

        let desktop = DesktopFile(data: try Data(contentsOf: games.appendingPathComponent("\(game.code)/\(game.code).desktop")))
        #expect(desktop.exec.hasPrefix("/bin/clover-kachikachi-wr /var/games/\(game.code)/My_Game.nes"))
        #expect(desktop.name == "My Game")
        let meta = GameMetadata.load(gameDirectory: games.appendingPathComponent(game.code), exec: desktop.exec)
        #expect(meta.system == "Nintendo - Nintendo Entertainment System")
        #expect(meta.core == "clover-kachikachi-wr")
        #expect(meta.originalFilename == "My Game (USA).nes")
    }

    @Test func importFallsBackToExtensionLauncher() throws {
        let tmp = TempDir()
        let catalog = try makeCatalog(tmp) // no mgba installed
        let (importer, games) = makeImporter(tmp, catalog: catalog)
        let src = tmp.sub("src").appendingPathComponent("Pocket.gba")
        try Data(repeating: 7, count: 1024).write(to: src)

        let game = try #require(importer.importFiles([src], options: .init()).imported.first)
        #expect(game.code.hasPrefix("CLV-A-"))
        let desktop = DesktopFile(data: try Data(contentsOf: games.appendingPathComponent("\(game.code)/\(game.code).desktop")))
        // CE: no core known → "/bin/<ext>" (KMFD cores install /bin/gba)
        #expect(desktop.exec == "/bin/gba /var/games/\(game.code)/Pocket.gba")
    }

    @Test func importPicksRomFromZip() throws {
        let tmp = TempDir()
        let catalog = try makeCatalog(tmp)
        let (importer, games) = makeImporter(tmp, catalog: catalog)
        // SWCompression only reads zip files; build one with macOS's zip tool
        let content = tmp.sub("zipcontent")
        try Data("hi".utf8).write(to: content.appendingPathComponent("readme.txt"))
        try inesRom().write(to: content.appendingPathComponent("Zipped.nes"))
        let zipURL = tmp.sub("src").appendingPathComponent("Zipped.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-jq", zipURL.path, content.appendingPathComponent("readme.txt").path,
                         content.appendingPathComponent("Zipped.nes").path]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)

        let game = try #require(importer.importFiles([zipURL], options: .init()).imported.first)
        let files = try FileManager.default.contentsOfDirectory(atPath: games.appendingPathComponent(game.code).path)
        #expect(files.contains("Zipped.nes"))
        #expect(!files.contains("readme.txt"))
    }

    // MARK: - Core assignment

    @Test func buildExecForCoreChange() throws {
        let tmp = TempDir()
        let catalog = try makeCatalog(tmp, infos: ["km_mgba_libretro.info": Self.mgbaInfo], bin: ["km_mgba"])
        let core = try #require(catalog.core("km_mgba"))
        let d = DesktopFile(string: "Exec=/bin/gba /var/games/CLV-A-AAAAA/a.gba --fast\nCode=CLV-A-AAAAA")

        #expect(GameManagerService.buildExec(desktop: d, command: .core(core, resetArgs: false), romFallback: nil)
                == "/bin/km_mgba /var/games/CLV-A-AAAAA/a.gba --fast")
        #expect(GameManagerService.buildExec(desktop: d, command: .core(core, resetArgs: true), romFallback: nil)
                == "/bin/km_mgba /var/games/CLV-A-AAAAA/a.gba")
        #expect(GameManagerService.buildExec(desktop: d, command: .keep, romFallback: nil) == d.exec)
        #expect(GameManagerService.buildExec(desktop: d, command: .custom(" /bin/x y "), romFallback: nil) == "/bin/x y")
        // Empty Exec (CE crashed): use the ROM found in the folder
        let empty = DesktopFile(string: "Exec=/bin/broken")
        #expect(GameManagerService.buildExec(desktop: empty, command: .core(core, resetArgs: false),
                                             romFallback: "/var/games/CLV-A-AAAAA/a.gba")
                == "/bin/km_mgba /var/games/CLV-A-AAAAA/a.gba")
    }

    // MARK: - Repair / migration

    @Test func migratesLegacyGameWithSpaces() throws {
        let tmp = TempDir()
        let catalog = try makeCatalog(tmp)
        let games = tmp.sub("games")
        let code = "CLV-H-ABCDE"
        let dir = games.appendingPathComponent(code)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("Contra - Hard Corps (USA).nes"))
        try Data("""
        [Desktop Entry]
        Exec=/bin/clover-kachikachi-wr /var/games/\(code)/Contra - Hard Corps (USA).nes --volume 75 --rollback-snapshot-period 720
        Name=Contra
        [X-CLOVER Game]
        Code=\(code)
        """.utf8).write(to: dir.appendingPathComponent("\(code).desktop"))

        GameRepair.migrateLegacyGames(in: games, cores: catalog)

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains("Contra_-_Hard_Corps.nes"))
        let desktop = DesktopFile(data: try Data(contentsOf: dir.appendingPathComponent("\(code).desktop")))
        #expect(desktop.exec == "/bin/clover-kachikachi-wr /var/games/\(code)/Contra_-_Hard_Corps.nes --volume 75 --rollback-snapshot-period 720")
        let meta = GameMetadata.load(gameDirectory: dir, exec: desktop.exec)
        #expect(meta.system == "Nintendo - Nintendo Entertainment System")
        #expect(meta.core == "clover-kachikachi-wr")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("metadata.json").path))
    }

    @Test func migratesBrokenUnknownSystemExec() throws {
        let tmp = TempDir()
        let catalog = try makeCatalog(tmp)
        let games = tmp.sub("games")
        let code = "CLV-P-QWERT"
        let dir = games.appendingPathComponent(code)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("Sonic.gen"))
        try Data("Exec=/bin/Sonic.gen\nCode=\(code)".utf8).write(to: dir.appendingPathComponent("\(code).desktop"))

        GameRepair.migrateLegacyGames(in: games, cores: catalog)

        let desktop = DesktopFile(data: try Data(contentsOf: dir.appendingPathComponent("\(code).desktop")))
        #expect(desktop.exec == "/bin/m2engage /var/games/\(code)/Sonic.gen")
    }

    /// Shape of games imported from a console by older versions: console paths,
    /// CE-compressed .7z ROMs, and some games whose ROM never reached the Mac
    @Test func migrationKeepsArchivesAndMissingRoms() throws {
        let tmp = TempDir()
        let catalog = try makeCatalog(tmp)
        let games = tmp.sub("games")
        let console = "/var/lib/hakchi/games/snes-usa/.storage"

        let withRom = games.appendingPathComponent("CLV-A-ABVJT")
        try FileManager.default.createDirectory(at: withRom, withIntermediateDirectories: true)
        try Data([0x37, 0x7A]).write(to: withRom.appendingPathComponent("DBZ.gba.7z"))
        try Data("Exec=/bin/gba \(console)/CLV-A-ABVJT/DBZ.gba.7z\nCode=CLV-A-ABVJT".utf8)
            .write(to: withRom.appendingPathComponent("CLV-A-ABVJT.desktop"))

        let noRom = games.appendingPathComponent("CLV-A-AIOFW")
        try FileManager.default.createDirectory(at: noRom, withIntermediateDirectories: true)
        try Data("Exec=/bin/gba \(console)/CLV-A-AIOFW/Metroid.gba.7z --x 1\nCode=CLV-A-AIOFW".utf8)
            .write(to: noRom.appendingPathComponent("CLV-A-AIOFW.desktop"))

        GameRepair.migrateLegacyGames(in: games, cores: catalog)

        let d1 = DesktopFile(data: try Data(contentsOf: withRom.appendingPathComponent("CLV-A-ABVJT.desktop")))
        #expect(d1.exec == "/bin/gba /var/games/CLV-A-ABVJT/DBZ.gba.7z")
        #expect(FileManager.default.fileExists(atPath: withRom.appendingPathComponent("DBZ.gba.7z").path))

        let d2 = DesktopFile(data: try Data(contentsOf: noRom.appendingPathComponent("CLV-A-AIOFW.desktop")))
        #expect(d2.exec == "/bin/gba /var/games/CLV-A-AIOFW/Metroid.gba.7z --x 1")
        #expect(GameMetadata.load(gameDirectory: noRom, exec: d2.exec).system == "Nintendo - Game Boy Advance")
    }
}
