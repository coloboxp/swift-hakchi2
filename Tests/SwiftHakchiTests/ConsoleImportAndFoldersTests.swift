import Foundation
import Testing
@testable import SwiftHakchi

/// Phase 2: Import from Console parsing and Folders Manager editing rules.
@MainActor
@Suite struct ConsoleImportAndFoldersTests {
    @Test func parsesConsoleDesktopTar() throws {
        var tar = TarWriter()
        // Linked game: menu entry in 001, files in .storage
        tar.addFile(name: "var/lib/hakchi/games/snes-usa/001/CLV-A-AIOFW/CLV-A-AIOFW.desktop", contents: Data("""
        [Desktop Entry]
        Exec=/bin/gba /var/lib/hakchi/games/snes-usa/.storage/CLV-A-AIOFW/Metroid.gba.7z
        Icon=/var/lib/hakchi/games/snes-usa/.storage/CLV-A-AIOFW/CLV-A-AIOFW.png
        Name=Metroid
        [X-CLOVER Game]
        Code=CLV-A-AIOFW
        """.utf8))
        // Stock game and a menu folder: both skipped
        tar.addFile(name: "usr/share/games/CLV-P-STOCK/CLV-P-STOCK.desktop",
                    contents: Data("Exec=/bin/x\nCode=CLV-P-STOCK".utf8))
        tar.addFile(name: "var/lib/hakchi/games/snes-usa/000/CLV-S-00001/CLV-S-00001.desktop",
                    contents: Data("Exec=/bin/chmenu 001 /var/games\nCode=CLV-S-00001".utf8))

        let found = ConsoleGameImporter.parse(desktopTar: tar.finalize(), mountpoint: "", stockCodes: ["CLV-P-STOCK"])
        #expect(found.count == 1)
        let game = try #require(found.first)
        #expect(game.remotePath == "/var/lib/hakchi/games/snes-usa/.storage/CLV-A-AIOFW")
        let desktop = DesktopFile(string: game.desktopText)
        #expect(desktop.exec == "/bin/gba /var/games/CLV-A-AIOFW/Metroid.gba.7z")
        #expect(desktop.iconPath == "/var/games")

        let sizes = ConsoleGameImporter.parseDu("4096\t/var/lib/hakchi/games/snes-usa/.storage/CLV-A-AIOFW\n8\t/x y\n")
        #expect(sizes["/var/lib/hakchi/games/snes-usa/.storage/CLV-A-AIOFW"] == Int64(4096 * 1024))
        #expect(sizes["/x y"] == Int64(8 * 1024))
    }

    private func games(_ n: Int) -> [MenuGame] {
        (1...n).map { i in
            MenuGame(code: "CLV-H-" + String(repeating: "A", count: 4) + String(UnicodeScalar(64 + i)!),
                     name: "Game \(i)", sortName: "game \(i)", isOriginal: false)
        }
    }

    @Test func foldersManagerEditing() {
        let model = FoldersManagerModel(console: .unknown, games: games(3), settings: CollectionSettings(), loadSaved: false)
        #expect(model.root.games.count == 3)

        // New folder, move two games into it
        model.selection = []
        let folder = model.newFolder(in: model.root)
        let ids = Set(model.root.games.prefix(2).map { ObjectIdentifier($0) })
        #expect(model.move(ids, into: folder.child))
        #expect(folder.child.games.count == 2 && model.root.games.count == 1)

        // A folder cannot move into itself
        #expect(!model.move([ObjectIdentifier(folder)], into: folder.child))

        // Delete a game: goes to the Recycle Bin; deleting it there removes it for good
        let game = folder.child.games[0]
        model.delete([ObjectIdentifier(game)])
        let bin = model.root.folders.first { $0.name == MenuFolderNames.trashBin }
        #expect(bin?.child.games.map(\.code) == [game.code])
        model.delete([ObjectIdentifier(game)])
        #expect(bin?.child.games.isEmpty == true)
        #expect(model.deletedGames.map(\.code) == [game.code])
        #expect(model.needsSave)
    }

    @Test func foldersManagerAutoStructure() {
        let model = FoldersManagerModel(console: .unknown, games: games(7),
                                        settings: { var s = CollectionSettings(); s.maxGamesPerFolder = 3; return s }(), loadSaved: false)
        model.autoStructure(.foldersEqual)
        #expect(model.root.folders.count == 3)
        // Back links are not kept in the editor (added again at sync time)
        #expect(model.root.folders.allSatisfy { f in !f.child.folders.contains { $0.child === model.root } })
        #expect(model.nodes.count == 3)
        model.autoStructure(.noSplit)
        #expect(model.root.games.count == 7 && model.root.folders.isEmpty)
    }
}
