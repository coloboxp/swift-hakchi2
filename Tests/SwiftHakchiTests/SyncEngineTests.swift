import Foundation
import Testing
import SWCompression
@testable import SwiftHakchi

/// Phase 2: sync diff, memory stats, console config, menu split, file building, folders files.
@MainActor
@Suite struct SyncEngineTests {
    final class TempDir {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncEngineTests-\(UUID().uuidString)", isDirectory: true)
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private func game(_ n: Int, original: Bool = false, sort: String? = nil, genre: String = "",
                      country: String = "") -> MenuGame {
        let code = String(format: "CLV-%@-%05d", original ? "P" : "H", n).replacingOccurrences(of: "0", with: "A")
        let name = sort ?? "Game \(n)"
        return MenuGame(code: code, name: name, sortName: name.lowercased(), isOriginal: original,
                        genre: genre, country: country)
    }

    // MARK: - Remote diff

    @Test func parsesListing() {
        let out = "1024 1700000000 ./.storage/CLV-H-ABCDE/game.nes\n12 1700000001 ./000/CLV-H-ABCDE/My Game.desktop\nbad line\n"
        let files = SyncPlan.parseListing(out)
        #expect(files == [
            RemoteFile(path: "./.storage/CLV-H-ABCDE/game.nes", size: 1024, modified: 1_700_000_000),
            RemoteFile(path: "./000/CLV-H-ABCDE/My Game.desktop", size: 12, modified: 1_700_000_001),
        ])
    }

    @Test func diffUsesSizeAndMtimeWithLeeway() {
        let same = SyncFile(path: "./a", size: 10, modified: 100, source: .data(Data(count: 10)))
        let near = SyncFile(path: "./b", size: 10, modified: 102, source: .data(Data(count: 10)))
        let old = SyncFile(path: "./c", size: 10, modified: 200, source: .data(Data(count: 10)))
        let new = SyncFile(path: "./d", size: 1, modified: 1, source: .data(Data(count: 1)))
        let remote = [
            RemoteFile(path: "./a", size: 10, modified: 100),
            RemoteFile(path: "./b", size: 10, modified: 100),
            RemoteFile(path: "./c", size: 10, modified: 100),
            RemoteFile(path: "./gone", size: 5, modified: 1),
        ]
        let diff = SyncPlan.diff(local: [same, near, old, new], remote: remote, protectedCodes: [])
        #expect(diff.upload.map(\.path) == ["./c", "./d"])
        #expect(diff.delete == ["./gone"])
    }

    @Test func diffKeepsFilesOfGamesWithoutLocalRom() {
        let remote = [
            RemoteFile(path: "./.storage/CLV-A-AIOFW/Metroid.gba.7z", size: 4_000_000, modified: 1),
            RemoteFile(path: "./001/CLV-A-AIOFW/CLV-A-AIOFW.desktop", size: 300, modified: 1),
            RemoteFile(path: "./.storage/CLV-A-ZZZZZ/old.gba", size: 10, modified: 1),
        ]
        let diff = SyncPlan.diff(local: [], remote: remote, protectedCodes: ["CLV-A-AIOFW"])
        #expect(diff.protected.count == 2)
        #expect(diff.delete == ["./.storage/CLV-A-ZZZZZ/old.gba"])
        #expect(SyncPlan.gameCode(inPath: "./000/CLV-S-00001/CLV-S-00001.png") == "CLV-S-00001")
        #expect(SyncPlan.gameCode(inPath: "./000/title.fnt") == nil)
    }

    @Test func contentTimestampIsStable() {
        let a = SyncFile.generated(path: "./x", data: Data("hello".utf8))
        let b = SyncFile.generated(path: "./x", data: Data("hello".utf8))
        let c = SyncFile.generated(path: "./x", data: Data("hellp".utf8))
        #expect(a.modified == b.modified)
        #expect(a.modified != c.modified)
        #expect(SyncPlan.padded(1) == 4096 && SyncPlan.padded(4096) == 4096 && SyncPlan.padded(0) == 0)
    }

    @Test func batchesAndScripts() {
        let files = [5, 5, 30, 1].map { SyncFile(path: "./\($0)", size: Int64($0), modified: 0, source: .data(Data())) }
        #expect(SyncPlan.batches(files, limit: 10).map { $0.map(\.size) } == [[5, 5], [30], [1]])
        let script = SyncPlan.deleteScript(paths: ["./a b/it's.nes"], uploadPath: "/var/lib/hakchi/games")
        #expect(script.contains("rm -f './a b/it'\\''s.nes'"))
        #expect(SyncPlan.layoutCleanupCommand(syncRoot: "/s", separateMultiboot: true).contains("grep -vEe"))
        #expect(SyncPlan.layoutCleanupCommand(syncRoot: "/s", separateMultiboot: false).contains("grep -Ee"))
    }

    // MARK: - Memory stats

    @Test func parsesMemoryStats() throws {
        let stats = try #require(MemoryStats.parse(
            df: "460000 | 100000 | 360000\n", saves: "2048\n",
            collections: "/var/lib/hakchi/games/.storage | 1000\n/var/lib/hakchi/games/000 | 24\n/var/lib/hakchi/games/snes-usa | 50000\n/var/lib/hakchi/games/junk | 7\n"))
        #expect(stats.storageFree == 360_000 * 1024)
        #expect(stats.saveStatesSize == 2048 * 1024)
        #expect(stats.nonMultibootGamesSize == 1024 * 1024)
        #expect(stats.collections["snes-usa"] == Int64(50_000 * 1024))
        #expect(stats.extraFilesSize == 7 * 1024)
        #expect(stats.availableForGames(separateMultiboot: true, systemCode: "snes-usa")
                == (360_000 + 50_000 + 1024 + 7) * 1024)
        #expect(stats.availableForGames(separateMultiboot: false, systemCode: "snes-usa")
                == (360_000 + 51_031) * 1024)
        #expect(MemoryStats.parse(df: "garbage", saves: "", collections: "") == nil)
    }

    // MARK: - Console config

    @Test func consoleConfigRoundTrip() {
        var settings = ConsoleSettings()
        #expect(settings.resetCombination == 0x24)  // Down + Select
        var dict = settings.configDictionary(isFamicom: false)
        #expect(dict["clovercon_home_combination"] == "0x0024")
        #expect(dict["disable_armet"] == "n")
        #expect(dict["clovercon_fc_start"] == "0")

        settings.fcStart = true
        settings.antiArmetLevel = 2
        settings.extraArgsCanoe = "--x 'y'"
        dict = settings.configDictionary(isFamicom: true)
        #expect(dict["clovercon_fc_start"] == "1")
        #expect(dict["disable_armet"] == "y")

        var other = ConsoleSettings()
        other.apply(dict)
        #expect(other == settings)

        other.apply(["clovercon_home_combination": "0x7FFF"])
        #expect(!other.resetHack)
    }

    @Test func parsesP0000Config() {
        let file = """
        cfg_clovercon_home_combination='0x0028'
        cfg_disable_armet="y"
        cfg_snes_extra_args='--a \\'b\\''
        not_cfg=1
        """
        let config = ConsoleSettings.parseConfigFile(file)
        #expect(config["clovercon_home_combination"] == "0x0028")
        #expect(config["disable_armet"] == "y")
        #expect(config["snes_extra_args"] == "--a 'b'")
        #expect(config["not_cfg"] == nil)

        let script = ConsoleSettings.evalScript(for: ["snes_extra_args": "it's"])
        #expect(script == "cfg_snes_extra_args='it'\\''s'\n")
    }

    @Test func settingsDecodeWithDefaults() throws {
        let s = try JSONDecoder().decode(SyncSettings.self, from: Data("{}".utf8))
        #expect(s.syncLinked && s.separateGamesForMultiboot && !s.alwaysCopyOriginalGames)
        let c = try JSONDecoder().decode(CollectionSettings.self, from: Data(#"{"maxGamesPerFolder":40}"#.utf8))
        #expect(c.maxGamesPerFolder == 40 && c.foldersMode == .originalAuto && c.backFolderPosition == .back)
        var all = SyncSettings()
        all.updateCollection(for: .nes) { $0.maxGamesPerFolder = 50; $0.foldersMode = .custom }
        all.copyStructureToAllCollections(from: .nes)
        #expect(all.collection(for: .snesUsa).maxGamesPerFolder == 50)
        #expect(all.collection(for: .snesUsa).foldersMode == .custom)
    }

    // MARK: - Menu split

    @Test func noSplitWhenSmall() {
        let root = MenuCollection((1...5).map { .game(game($0)) })
        root.split(.auto, maxElements: 30)
        #expect(root.folders.isEmpty && root.count == 5)
        root.split(.foldersEqual, maxElements: 30)
        #expect(root.folders.isEmpty)
    }

    @Test func foldersEqualSplitsWithBackFolders() {
        let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf"]
        let root = MenuCollection(names.enumerated().map { .game(game($0.offset, sort: $0.element)) })
        root.split(.foldersEqual, maxElements: 3)
        // 7 games, 3 per part → 3 parts of 3, 3, 1
        #expect(root.folders.count == 3)
        #expect(root.games.isEmpty)
        let first = root.folders[0]
        #expect(first.child.games.map(\.name) == ["Alpha", "Bravo", "Charlie"])
        #expect(first.child.folders.last?.name == MenuFolderNames.back)
        #expect(first.child.folders.last?.child === root)
        // Trimmed "first - last" names
        #expect(first.name == "ALP - CHA")
        #expect(root.folders[2].name == "GOL - GOL")
    }

    @Test func pagesEqualLinksPages() {
        let root = MenuCollection((1...6).map { .game(game($0)) })
        root.split(.pagesEqual, maxElements: 3)
        // Root keeps page 1 and gets a folder (Right) to page 2
        #expect(root.games.count == 3)
        #expect(root.folders.count == 1 && root.folders[0].position == .right)
        let page2 = root.folders[0].child
        #expect(page2.folders.count == 1 && page2.folders[0].position == .left && page2.folders[0].child === root)
    }

    @Test func originalGamesStayInRoot() {
        let root = MenuCollection([.game(game(1, original: true)), .game(game(2, original: true))]
                                  + (3...5).map { .game(game($0)) })
        root.split(.originalAuto, maxElements: 30)
        #expect(root.games.count == 2)
        let more = try! #require(root.folders.first)
        #expect(more.name == MenuFolderNames.moreGames && more.position == .rightmost)
        #expect(more.child.games.count == 3)
        #expect(more.child.folders.last?.name == MenuFolderNames.originalGames)
        #expect(more.child.folders.last?.child === root)
    }

    @Test func alphabeticFolders() {
        let root = MenuCollection([.game(game(1, sort: "Zelda")), .game(game(2, sort: "Mario")),
                                   .game(game(3, sort: "1942")), .game(game(4, sort: "Metroid"))])
        root.split(.foldersAlphabeticFoldersEqual, maxElements: 30)
        #expect(root.folders.map(\.name) == ["M", "Z", "#"])
        #expect(root.folders.map(\.imageId) == ["folder_m", "folder_z", "folder_number"])
        #expect(root.folders[0].child.games.count == 2)
    }

    @Test func groupByGenreAndRegion() {
        let root = MenuCollection([.game(game(1, genre: "RPG")), .game(game(2, genre: "RPG")),
                                   .game(game(3, genre: "ActionShooting")), .game(game(4))])
        root.split(.foldersGroupByGenre, maxElements: 30)
        #expect(root.folders.map(\.name) == ["Action / Shooting", "RPG", "Unknown Genre"])
        #expect(root.folders[0].imageId == "genre_shooting")
        #expect(root.folders[1].child.games.count == 2)

        let regions = MenuCollection([.game(game(1, country: "jp")), .game(game(2, country: "us"))])
        regions.split(.foldersGroupByRegion, maxElements: 30)
        #expect(regions.folders.map(\.name) == ["Japan", "United States"])
    }

    @Test func addBackAndHome() {
        let inner = MenuFolder(name: "Inner")
        inner.child.add(.game(game(1)))
        let outer = MenuFolder(name: "Outer")
        outer.child.add(.folder(inner))
        let root = MenuCollection([.folder(outer)])
        root.addBack(options: MenuOptions(backPosition: .leftBack, homeFolder: true))
        #expect(outer.child.folders.map(\.name) == ["Inner", "Back"])  // no Home in the first level
        #expect(inner.child.folders.map(\.name) == ["Back", "Home"])
        #expect(inner.child.folders[1].child === root)
        #expect(inner.child.folders[0].position == .leftBack)

        root.unsplit()
        #expect(root.games.count == 1 && root.folders.isEmpty)
    }

    @Test func folderDesktopMatchesCE() {
        let folder = MenuFolder(name: "More games...", position: .rightmost)
        folder.childIndex = 1
        let d = folder.desktopFile()
        let text = d.serialize()
        #expect(text.contains("Exec=/bin/chmenu 001 /var/games"))
        #expect(text.contains("Path=/var/saves/FOLDER\n"))
        #expect(text.contains("Icon=/var/games/CLV-S-00001/CLV-S-00001.png"))
        #expect(text.contains("TestID=777"))
        #expect(text.contains("ReleaseDate=8888-88-88"))
        #expect(text.contains("SortRawPublisher=ZZZZZZZZZY"))
        #expect(text.contains("SortRawTitle=Юmore games..."))

        folder.position = .leftBack
        #expect(folder.desktopFile().sortName.hasPrefix("\u{01}"))
        #expect(folder.desktopFile().releaseDate == "0000-00-00")
    }

    // MARK: - File building

    @Test func buildsLinkedFileSet() throws {
        let tmp = TempDir()
        let code = "CLV-H-ABCDE"
        let dir = tmp.url.appendingPathComponent(code)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("autoplay"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("game.nes"))
        try Data([9]).write(to: dir.appendingPathComponent("autoplay/demo.bin"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("metadata.json"))
        let desktop = DesktopFile(string: "Exec=/bin/clover-kachikachi-wr /var/games/\(code)/game.nes --volume 75\nCode=\(code)\nName=My Game")

        let stockCode = "CLV-P-STOCK"
        let stockDesktop = DesktopFile(string: """
        Exec=/bin/clover-kachikachi-wr /usr/share/games/nes/kachikachi/\(stockCode)/\(stockCode).nes
        Icon=/usr/share/games/nes/kachikachi/\(stockCode)/\(stockCode).png
        Code=\(stockCode)
        """)
        let sources = [
            code: SyncGameSource(code: code, directory: dir, desktop: desktop, isOriginal: false),
            stockCode: SyncGameSource(code: stockCode, directory: nil, desktop: stockDesktop, isOriginal: true),
        ]
        let root = MenuCollection([.game(MenuGame(code: stockCode, name: "Stock", sortName: "", isOriginal: true))])
        let more = MenuFolder(name: MenuFolderNames.moreGames, position: .rightmost)
        more.child.add(.game(MenuGame(code: code, name: "My Game", sortName: "", isOriginal: false)))
        root.add(.folder(more))

        let context = SyncContext(uploadPath: "/var/lib/hakchi/games/nes-usa",
                                  squashfsGamesPath: "/var/squashfs/usr/share/games/nes/kachikachi",
                                  consoleType: .nes)
        let result = SyncFileBuilder(context: context, games: sources).build(root: root)
        let paths = Set(result.files.map(\.path))

        #expect(paths.contains("./.storage/\(code)/game.nes"))
        #expect(paths.contains("./.storage/\(code)/autoplay/demo.bin"))
        #expect(paths.contains("./.storage/\(code)/\(code).png"))        // placeholder cover
        #expect(paths.contains("./001/\(code)/\(code).desktop"))
        #expect(paths.contains("./000/\(stockCode)/\(stockCode).desktop"))
        #expect(paths.contains("./000/CLV-S-00001/CLV-S-00001.desktop"))
        #expect(!paths.contains { $0.hasSuffix("metadata.json") })
        #expect(result.menus.count == 2 && result.missingRoms.isEmpty && result.gameCount == 2)

        let gameDesktop = try DesktopFile(data: #require(result.files.first { $0.path == "./001/\(code)/\(code).desktop" }).contents())
        #expect(gameDesktop.exec == "/bin/clover-kachikachi-wr /var/lib/hakchi/games/nes-usa/.storage/\(code)/game.nes --volume 75")
        #expect(gameDesktop.iconPath == "/var/lib/hakchi/games/nes-usa/.storage")

        let stock = try DesktopFile(data: #require(result.files.first { $0.path == "./000/\(stockCode)/\(stockCode).desktop" }).contents())
        #expect(stock.exec.hasPrefix("/bin/clover-kachikachi-wr /var/squashfs/usr/share/games/nes/kachikachi/\(stockCode)/"))

        // Links: stock game from squashfs, custom game because it has autoplay
        #expect(result.linkScript.contains("src=\"/var/squashfs/usr/share/games/nes/kachikachi/\(stockCode)\""))
        #expect(result.linkScript.contains("dst=\"/var/lib/hakchi/games/nes-usa/001/\(code)\""))
        #expect(result.linkScript.contains("pixelart"))
    }

    @Test func reportsMissingRom() throws {
        let tmp = TempDir()
        let code = "CLV-A-AIOFW"
        let dir = tmp.url.appendingPathComponent(code)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let desktop = DesktopFile(string: "Exec=/bin/gba /var/games/\(code)/Metroid.gba.7z\nCode=\(code)")
        let sources = [code: SyncGameSource(code: code, directory: dir, desktop: desktop, isOriginal: false)]
        let root = MenuCollection([.game(MenuGame(code: code, name: "Metroid", sortName: "", isOriginal: false))])
        let context = SyncContext(uploadPath: "/u", squashfsGamesPath: "/s", linked: false, consoleType: .snesUsa)
        let result = SyncFileBuilder(context: context, games: sources).build(root: root)
        #expect(result.missingRoms == [code])
        // Normal (not linked) sync keeps game files next to the menu entry
        #expect(result.files.contains { $0.path == "./000/\(code)/\(code).png" })
    }

    // MARK: - Folders Manager files

    @Test func folderTreeHtmRoundTrip() throws {
        let a = game(1, sort: "Alpha"), b = game(2, sort: "Beta"), c = game(3, sort: "Gamma")
        let folder = MenuFolder(name: "My <Folder> & co", imageId: "folder_a", position: .leftmost)
        folder.child.add(.game(a))
        let root = MenuCollection([.folder(folder), .game(b)])
        root.addBack(options: MenuOptions())
        let htm = FolderTreeStore.htm(for: root, title: "NES Classic")
        #expect(htm.hasPrefix("<!DOCTYPE html>"))
        #expect(!htm.contains(">Back<"))

        let fresh = [game(1, sort: "Alpha"), game(2, sort: "Beta"), c]
        let (loaded, unsorted) = try FolderTreeStore.parse(htm, games: fresh)
        #expect(unsorted == 1)
        let loadedFolder = try #require(loaded.folders.first { $0.name == "My <Folder> & co" })
        #expect(loadedFolder.imageId == "folder_a" && loadedFolder.position == .leftmost)
        #expect(loadedFolder.child.games.map(\.code) == [a.code])
        #expect(loaded.games.map(\.code) == [b.code])
        #expect(loaded.folders.first { $0.name == MenuFolderNames.unsorted }?.child.games.map(\.code) == [c.code])
    }

    @Test func readsLegacyXml() throws {
        let g = game(7)
        let xml = "<Tree><Folder name=\"Old\" icon=\"folder_b\" position=\"1\"><Game code=\"\(g.code)\" /></Folder></Tree>"
        let (root, unsorted) = try FolderTreeStore.parse(xml, games: [g])
        #expect(unsorted == 0)
        #expect(root.folders.first?.name == "Old" && root.folders.first?.position == .left)
        #expect(root.folders.first?.child.games.first?.code == g.code)
    }

    // MARK: - Tar

    @Test func tarStoresMtimeAndLongPaths() throws {
        let long = "./.storage/CLV-H-ABCDE/" + String(repeating: "x", count: 90) + "/rom.nes"
        #expect(long.utf8.count > 100)
        var tar = TarWriter()
        tar.addFile(name: long, contents: Data([1, 2]), modified: Date(timeIntervalSince1970: 1_234_567_890))
        let entries = try TarContainer.open(container: tar.finalize())
        #expect(entries.count == 1)
        #expect(entries[0].info.name == long)
        #expect(entries[0].info.modificationTime == Date(timeIntervalSince1970: 1_234_567_890))
        #expect(TarWriter.splitName("short").prefix == "")
    }
}
