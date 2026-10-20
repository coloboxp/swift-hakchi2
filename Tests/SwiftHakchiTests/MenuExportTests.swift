import Foundation
import Testing
@testable import SwiftHakchi

/// Export to a USB/SD volume uses the sync engine's menu structure
@MainActor
@Suite struct MenuExportTests {
    private func makeGames(count: Int, in dir: URL) throws -> [Game] {
        try (0..<count).map { i in
            let code = String(format: "CLV-H-AA%03d", i).replacingOccurrences(of: "0", with: "A")
                .replacingOccurrences(of: "1", with: "B").replacingOccurrences(of: "2", with: "C")
                .replacingOccurrences(of: "3", with: "D").replacingOccurrences(of: "4", with: "E")
            let gameDir = dir.appendingPathComponent(code)
            try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: gameDir.appendingPathComponent("game\(i).nes"))
            let desktop = DesktopFile()
            desktop.code = code
            desktop.name = "Game \(i)"
            desktop.exec = "/bin/clover-kachikachi-wr /var/games/\(code)/game\(i).nes --volume 75"
            desktop.profilePath = "/var/saves"
            desktop.iconPath = "/var/games"
            desktop.iconFilename = "\(code).png"
            try desktop.toData().write(to: gameDir.appendingPathComponent("\(code).desktop"))
            return Game(desktopFile: desktop, consoleType: .nes, basePath: dir.path, source: .local)
        }
    }

    @Test func flatModeWritesGamesIntoRootMenu() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let games = try makeGames(count: 2, in: tmp)
        var collection = CollectionSettings()
        collection.foldersMode = .noSplit

        let plan = MenuExportLayout(consoleType: .nes, collection: collection)
            .plan(customGames: games, stockGames: [])

        let code = games[0].code
        let desktopKey = "000/\(code)/\(code).desktop"
        guard case .data(let data)? = plan[desktopKey] else {
            Issue.record("missing \(desktopKey) in \(plan.keys.sorted())")
            return
        }
        #expect(DesktopFile(data: data).exec == "/bin/clover-kachikachi-wr /var/games/\(code)/game0.nes --volume 75")
        #expect(plan["000/\(code)/game0.nes"] != nil)
        #expect(!plan.keys.contains { $0.hasPrefix(".storage") })
    }

    @Test func folderModeCreatesFolderEntries() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let games = try makeGames(count: 30, in: tmp)
        var collection = CollectionSettings()
        collection.foldersMode = .foldersEqual
        collection.maxGamesPerFolder = 20

        let plan = MenuExportLayout(consoleType: .nes, collection: collection)
            .plan(customGames: games, stockGames: [])

        // Folders are CLV-S-NNNNN entries in the root menu, games live in sub-menus
        #expect(plan.keys.contains { $0.hasPrefix("000/CLV-S-") && $0.hasSuffix(".desktop") })
        #expect(plan.keys.contains { $0.hasPrefix("001/CLV-H-") })
    }
}
