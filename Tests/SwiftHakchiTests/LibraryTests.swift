import Foundation
import CoreGraphics
import Testing
@testable import SwiftHakchi

/// Phase 3: library commands, cover art, Game Genie, view grouping.
@MainActor
@Suite struct LibraryTests {
    final class TempDir {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryTests-\(UUID().uuidString)", isDirectory: true)
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
        func sub(_ name: String) -> URL {
            let u = url.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
    }

    /// Repository Resources folder (tests read bundled files from source)
    static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SwiftHakchi/Resources")

    /// Solid-color test image as PNG
    private func pngImage(width: Int, height: Int, alpha: CGFloat = 1) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: alpha)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return CoverArt.pngData(ctx.makeImage()!)!
    }

    // MARK: - Genres and regions

    @Test func genreMapping() {
        #expect(GenreCatalog.genre(forGamesDbIds: [4])?.desktopName == "RPG")
        #expect(GenreCatalog.genre(forGamesDbIds: [99, 11])?.desktopName == "Sports")
        // Older versions stored TheGamesDB ID lists
        #expect(GenreCatalog.normalized("1, 8") == "Action")
        #expect(GenreCatalog.normalized("rpg") == "RPG")
        #expect(GenreCatalog.normalized("Platformer") == "Platformer")
        #expect(GenreCatalog.region(forName: "Germany")?.desktopName == "eu")
        #expect(GenreCatalog.region(desktopName: "JP")?.englishName == "Japan")
    }

    // MARK: - .desktop edits

    @Test func prefixEditsFollowCE() {
        let d = DesktopFile(string: "Name=The Legend\nCode=CLV-H-AAAAA")
        GameManagerService.addPrefix(" ZE ", to: d)
        #expect(d.name == "ZE: The Legend")
        #expect(d.sortName == "ze: legend")
        GameManagerService.removePrefix("ZE", from: d)
        #expect(d.name == "The Legend")
        #expect(d.sortName == "legend")
    }

    @Test func playerOptions() {
        #expect(PlayerOption(players: 2, simultaneous: false) == .twoAlternating)
        #expect(PlayerOption(players: 2, simultaneous: true) == .twoSimultaneous)
        #expect(PlayerOption.three.players == 3 && PlayerOption.three.simultaneous)
        #expect(!PlayerOption.one.simultaneous)
    }

    // MARK: - Storage and archives

    @Test func separateStorageFolders() {
        #expect(LibraryStorage.gamesFolderName(for: .snesUsa, separate: false) == "games")
        #expect(LibraryStorage.gamesFolderName(for: .snesEur, separate: true) == "games_snes")
        #expect(LibraryStorage.gamesFolderName(for: .megaDrive, separate: true) == "games_md")
        #expect(LibraryStorage.gamesFolderName(for: .famicom, separate: true) == "games")
    }

    @Test func clvgRoundTrip() throws {
        let tmp = TempDir()
        let code = "CLV-H-ABCDE"
        let source = tmp.sub("src").appendingPathComponent(code)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("autoplay"), withIntermediateDirectories: true)
        try Data("Exec=/bin/x /var/games/\(code)/game.nes\nCode=\(code)\nName=Game".utf8)
            .write(to: source.appendingPathComponent("\(code).desktop"))
        try Data([1, 2, 3, 4]).write(to: source.appendingPathComponent("game.nes"))
        try Data([9]).write(to: source.appendingPathComponent("autoplay/demo.bin"))

        let archive = tmp.url.appendingPathComponent(GameManagerService.archiveFileName(code: code, name: "Game"))
        try GameManagerService.archive(gameDirectory: source, to: archive)
        #expect(archive.lastPathComponent == "CLV-H-ABCDE - Game.clvg")

        let games = tmp.sub("games")
        let importer = GameImporter(gamesDirectory: games, patchesDirectory: tmp.sub("patches"),
                                    cores: CoreCatalog(consoleCacheDirectory: tmp.sub("c"), userInfoDirectory: tmp.sub("i")),
                                    chooseFile: { _, e in e.first }, ask: { _, _ in .yes })
        let report = importer.importFiles([archive], options: .init())
        #expect(report.errors.isEmpty)
        let imported = games.appendingPathComponent(code)
        #expect(try Data(contentsOf: imported.appendingPathComponent("game.nes")) == Data([1, 2, 3, 4]))
        #expect(try Data(contentsOf: imported.appendingPathComponent("autoplay/demo.bin")) == Data([9]))
    }

    @Test func customApps() throws {
        let tmp = TempDir()
        let code = GameManagerService.customAppCode(for: "My App")
        #expect(GameManagerService.isValidCustomCode(code))
        #expect(!GameManagerService.isValidCustomCode("CLV-H-ABC"))
        try GameManagerService.createCustomApp(name: "My App", code: code, in: tmp.url, options: .init())
        let desktop = DesktopFile(data: try Data(contentsOf: tmp.url.appendingPathComponent("\(code)/\(code).desktop")))
        #expect(desktop.exec == "/bin/enter-custom-command-here")
        #expect(desktop.name == "My App")
        #expect(throws: LibraryError.self) {
            try GameManagerService.createCustomApp(name: "Again", code: code, in: tmp.url, options: .init())
        }
    }

    @Test func originalEntriesFromBundledTar() {
        let tar = Self.resources.appendingPathComponent("desktop_entries.tar")
        let snes = GameManagerService.originalDesktopEntries(systemCode: "snes-usa", tar: tar)
        #expect(snes.count == 21)
        #expect(snes.allSatisfy { $0.code.hasPrefix("CLV-P-") && $0.content.contains("[Desktop Entry]") })
        #expect(GameManagerService.originalDesktopEntries(systemCode: "nope", tar: tar).isEmpty)
    }

    @Test func gameSizeRoundsToBlocks() throws {
        let tmp = TempDir()
        try Data(count: 10).write(to: tmp.url.appendingPathComponent("rom.nes"))
        try Data(count: 5000).write(to: tmp.url.appendingPathComponent("CLV-H-AAAAA_original.png"))
        #expect(GameManagerService.gameSize(gameDirectory: tmp.url, code: "CLV-H-AAAAA") == 4096)
    }

    // MARK: - Cover art

    @Test func ceResizeRules() throws {
        let wide = CoverArt.loadImage(pngImage(width: 400, height: 100))!
        let cover = try #require(CoverArt.resize(wide, width: 228, height: 204, upscale: true, expandHeight: false))
        #expect(cover.width == 228 && cover.height == 58) // 57 rounded up to even
        let small = try #require(CoverArt.resize(wide, width: 40, height: 40, upscale: false, expandHeight: true))
        #expect(small.width == 40 && small.height == 40) // centered canvas
        let tiny = CoverArt.loadImage(pngImage(width: 20, height: 10))!
        let kept = try #require(CoverArt.resize(tiny, width: 40, height: 40, upscale: false, expandHeight: false))
        #expect(kept.width == 20 && kept.height == 10) // no upscaling for thumbnails
    }

    @Test func setCoverWritesCEFiles() throws {
        let tmp = TempDir()
        let code = "CLV-U-AAAAA"
        try CoverArt.setCover(pngImage(width: 300, height: 400), gameDirectory: tmp.url, code: code,
                              options: .init(quantize: true, centerThumbnail: false))
        let cover = try #require(CoverArt.loadImage(url: CoverArt.coverURL(tmp.url, code)))
        #expect(cover.height == 204)
        let thumb = try #require(CoverArt.loadImage(url: CoverArt.thumbnailURL(tmp.url, code)))
        #expect(thumb.height == 40 && thumb.width == 30)
        #expect(FileManager.default.fileExists(atPath: CoverArt.originalURL(tmp.url, code).path))
        #expect(FileManager.default.fileExists(atPath: CoverArt.mdMiniURL(tmp.url, code).path))
    }

    @Test func palettePNGDecodes() throws {
        let image = CoverArt.loadImage(pngImage(width: 64, height: 32, alpha: 0.5))!
        let data = try #require(PalettePNG.encode(image))
        let decoded = try #require(CoverArt.loadImage(data))
        #expect(decoded.width == 64 && decoded.height == 32)
        // Indexed color type in IHDR
        #expect(data[25] == 3)
    }

    @Test func mdMiniLayoutDetection() {
        let ctx = CGContext(data: nil, width: 182, height: 216, bitsPerComponent: 8, bytesPerRow: 182 * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 1, y: 1, width: 28, height: 214))   // spine
        ctx.fill(CGRect(x: 31, y: 1, width: 150, height: 214)) // front
        #expect(CoverArt.isMdMiniLayout(ctx.makeImage()!))
        ctx.fill(CGRect(x: 0, y: 0, width: 182, height: 216))
        #expect(!CoverArt.isMdMiniLayout(ctx.makeImage()!))
    }

    @Test func defaultCoverNames() {
        #expect(CoverArt.defaultCoverName(system: "Nintendo - Super Nintendo Entertainment System", fileName: "x (E).sfc")
                == "blank_snes-eu-jp")
        #expect(CoverArt.defaultCoverName(system: "Nintendo - Nintendo Entertainment System", fileName: "y (J).nes") == "blank_jp")
        #expect(CoverArt.defaultCoverName(system: "", fileName: "") == "blank_app")
        #expect(FileManager.default.fileExists(atPath: Self.resources.appendingPathComponent("BlankCovers/blank_gba.png").path))
    }

    // MARK: - Cover matching

    @Test func fuzzyMatchingFollowsCE() {
        let files = ["Super Mario Bros. 3 (USA).png", "Super Mario Bros. 2 (USA).png", "Super Mario Bros. (World).png",
                     "Mario & Luigi.jpg"].map { URL(fileURLWithPath: "/art/\($0)") }
        // "III" matches "3", the other sequels are rejected
        let r = CoverArtMatcher.findCoverMatch(name: "Super Mario Bros III", files: files, stripCodes: true)
        #expect(r.map(\.url.lastPathComponent) == ["Super Mario Bros. 3 (USA).png"])
        #expect(r.first?.partial == false)
        // "and" and "&" are interchangeable
        let m = CoverArtMatcher.findCoverMatch(name: "Mario and Luigi", files: files, stripCodes: false)
        #expect(m.map(\.url.lastPathComponent) == ["Mario & Luigi.jpg"])
        #expect(CoverArtMatcher.integerToRoman(14) == "XIV" && CoverArtMatcher.romanToInteger("xiv") == 14)
    }

    @Test func findCoverOrder() throws {
        let tmp = TempDir()
        let art = tmp.sub("art")
        let png = pngImage(width: 8, height: 8)
        try png.write(to: art.appendingPathComponent("1234ABCD - whatever.png"))
        try png.write(to: tmp.sub("art/Nintendo - Game Boy").appendingPathComponent("Tetris (World).png"))
        try png.write(to: tmp.sub("art/Nintendo - Game Boy").appendingPathComponent("Tetris 2 (USA).png"))
        let matcher = CoverArtMatcher(artDirectory: art, originalArtTar: nil)

        if case .found(let url) = matcher.findCover(romFileName: "x.gb", sourceDirectory: nil, crc32: 0x1234ABCD,
                                                    system: "", alternateTitle: nil) {
            #expect(url.lastPathComponent.hasPrefix("1234ABCD"))
        } else { Issue.record("CRC match expected") }

        if case .found(let url) = matcher.findCover(romFileName: "Tetris.gb", sourceDirectory: nil, crc32: 1,
                                                    system: "Nintendo - Game Boy", alternateTitle: "Tetris") {
            #expect(url.lastPathComponent == "Tetris (World).png")
        } else { Issue.record("fuzzy match expected") }

        // Sibling image wins over fuzzy matching
        let src = tmp.sub("src")
        try png.write(to: src.appendingPathComponent("Tetris.png"))
        #expect(matcher.findCover(romFileName: "Tetris.gb", sourceDirectory: src, crc32: 1, system: "",
                                  alternateTitle: nil) == .found(src.appendingPathComponent("Tetris.png")))
    }

    @Test func originalArtLookup() {
        let tar = Self.resources.appendingPathComponent("original_art.tar")
        #expect(CoverArtMatcher.originalArt(named: "CLV-M2-as_en_Alien_Soldier_mdmini.png", in: tar) != nil)
        #expect(CoverArtMatcher.originalArt(named: "missing.png", in: tar) == nil)
    }

    // MARK: - Game Genie

    /// Standard NES Game Genie decoding (independent of the CE-style bit strings)
    private func decodeNES(_ code: String) -> (address: Int, value: UInt8, compare: UInt8?) {
        let n = code.map { Int("APZLGITYEOXUKSVN".firstIndex(of: $0)!.utf16Offset(in: "APZLGITYEOXUKSVN")) }
        let address = ((n[3] & 7) << 12) | ((n[5] & 7) << 8) | ((n[4] & 8) << 8)
            | ((n[2] & 7) << 4) | ((n[1] & 8) << 4) | (n[4] & 7) | (n[3] & 8)
        if code.count == 6 {
            let value = ((n[1] & 7) << 4) | ((n[0] & 8) << 4) | (n[0] & 7) | (n[5] & 8)
            return (address, UInt8(value), nil)
        }
        let value = ((n[1] & 7) << 4) | ((n[0] & 8) << 4) | (n[0] & 7) | (n[7] & 8)
        let compare = ((n[7] & 7) << 4) | ((n[6] & 8) << 4) | (n[6] & 7) | (n[5] & 8)
        return (address, UInt8(value), UInt8(compare))
    }

    @Test func nesGameGenieSixLetters() throws {
        let prg = Data(count: 0x8000)
        for code in ["OLZNEE", "ZEEXIPIE".prefix(6).description, "GXXZZLVI".prefix(6).description]
        where GameGenie.isValidCode(code) {
            let expected = decodeNES(code)
            let patched = try GameGenie.patchNES(prg, code: code)
            #expect(patched[expected.address % prg.count] == expected.value, "\(code)")
        }
        #expect(throws: GameGenieError.self) { try GameGenie.patchNES(prg, code: "QQQQQQ") }
        #expect(GameGenie.isValidCode("OLZNEE"))
        #expect(!GameGenie.isValidCode("OLENEE")) // 3rd letter (E) marks an 8-letter code
        #expect(GameGenie.isValidCode("C2DF-A7B4"))
    }

    @Test func nesCompareCode() throws {
        // 8-letter code: value replaces only bytes equal to the compare value
        let code = "SZXLKEVK"
        let expected = decodeNES(code)
        let compare = try #require(expected.compare)
        var prg = [UInt8](repeating: 0, count: 0x4000)
        prg[expected.address % 0x2000] = compare
        let patched = try GameGenie.patchNES(Data(prg), code: code)
        #expect(patched[expected.address % 0x2000] == expected.value)
        #expect(throws: GameGenieError.self) { try GameGenie.patchNES(Data(count: 0x4000), code: code) }
    }

    @Test func snesGameGenieValueAndBounds() throws {
        let rom = Data(count: 0x400000)
        let patched = try GameGenie.patchSNES(rom, code: "C2DF-6DDD")
        #expect(patched.count == rom.count)
        #expect(patched.contains(0xC2))
        #expect(throws: GameGenieError.self) { try GameGenie.patchSNES(rom, code: "C2DF6DDD") }
    }

    @Test func gameGenieFilesAndDatabase() throws {
        let tmp = TempDir()
        try GameGenie.setCodes(["olzneE", " ", "AEUSGZAP"], gameDirectory: tmp.url)
        #expect(GameGenie.codes(gameDirectory: tmp.url) == ["OLZNEE", "AEUSGZAP"])
        try GameGenie.setCodes([], gameDirectory: tmp.url)
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent("gamegenie.txt").path))

        let user = tmp.url.appendingPathComponent("db.xml")
        let db = GameGenieDatabase(userURL: user, bundledURL: Self.resources.appendingPathComponent("GameGenieDB.xml"))
        #expect(db.codes(forGameCode: "CLV-H-THQIF").contains { $0.code == "SZXLKEVK" })
        db.setCode(GameGenieCode(code: "AAAAAA", description: "Test"), gameCode: "CLV-H-NEWGM", gameName: "New", crc32: 0xAB)
        try db.save()
        let reloaded = GameGenieDatabase(userURL: user, bundledURL: nil)
        #expect(reloaded.codes(forGameCode: "CLV-H-NEWGM") == [GameGenieCode(code: "AAAAAA", description: "Test")])
        reloaded.removeCode("AAAAAA", gameCode: "CLV-H-NEWGM")
        #expect(reloaded.codes(forGameCode: "CLV-H-NEWGM").isEmpty)
    }

    // MARK: - Folders and grouping

    @Test func prepareArtFolders() throws {
        let tmp = TempDir()
        let keep = tmp.sub("Keep")
        try Data([1]).write(to: keep.appendingPathComponent("a.png"))
        _ = tmp.sub("Empty")
        PrepareArtFoldersView.apply(checked: ["New"], systems: ["New", "Keep", "Empty"], artDirectory: tmp.url)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path))
        #expect(names == ["New", "Keep"]) // non-empty folders are never removed
    }

    @Test func explorerGrouping() {
        func game(_ id: String, _ name: String, stock: Bool = false, system: String = "", country: String = "") -> Game {
            var g = Game(code: id, desktopContent: "Name=\(name)\nCode=\(id)", consoleType: .snesUsa,
                         source: stock ? .stock : .local)
            g.system = system
            g.country = country
            return g
        }
        let games = [game("A", "Zelda", system: "SNES"), game("B", "Mario", stock: true),
                     game("C", "Axelay", system: "GBA", country: "jp")]
        var settings = LibrarySettings.Values()
        settings.originalGamesPosition = .atBottom
        var sections = ExplorerGrouping.sections(for: games, settings: settings) { _ in "core" }
        #expect(sections.map(\.title) == ["Custom Games", "Original Games"])
        #expect(sections[0].games.map(\.name) == ["Axelay", "Zelda"])

        settings.gamesSorting = .system
        settings.originalGamesPosition = .hidden
        sections = ExplorerGrouping.sections(for: games, settings: settings) { _ in "core" }
        #expect(sections.map(\.title) == ["GBA", "SNES"])

        settings.gamesSorting = .region
        settings.originalGamesPosition = .sorted
        sections = ExplorerGrouping.sections(for: games, settings: settings) { _ in "core" }
        #expect(sections.map(\.title) == ["Japan", "Unknown Region"])
    }

    // MARK: - Spines

    @Test func spineTemplatesRender() throws {
        let templates = SpineTemplate.load(from: Self.resources.appendingPathComponent("SpineTemplates"))
        #expect(templates.count == 8)
        let template = try #require(templates.first { $0.name == "Custom (Black Grid)" })
        let logo = CoverArt.loadImage(pngImage(width: 200, height: 60))!
        let spine = try #require(template.render(logo: logo))
        #expect(spine.width == 56 && spine.height == 428)
        let rotated = try #require(SpineTemplate.rotate(logo, degrees: 90))
        #expect(rotated.width == 60 && rotated.height == 200)
    }
}
