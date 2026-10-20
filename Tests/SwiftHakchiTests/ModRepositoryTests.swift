import Foundation
import Testing
import SWCompression
@testable import SwiftHakchi

/// Tests for the hakchi2-CE repository format parser and hmod helpers.
@Suite struct ModRepositoryTests {
    private let repoURL = URL(string: "https://example.com/mods/.repo/")!

    @Test func normalizesRepositoryURL() throws {
        let expected = "https://example.com/mods/.repo/"
        #expect(try ModRepositoryService.normalizedRepoURL("https://example.com/mods").absoluteString == expected)
        #expect(try ModRepositoryService.normalizedRepoURL("https://example.com/mods/").absoluteString == expected)
        #expect(try ModRepositoryService.normalizedRepoURL("https://example.com/mods/.repo/").absoluteString == expected)
        #expect(throws: ModRepositoryError.self) { try ModRepositoryService.normalizedRepoURL("not a url") }
    }

    @Test func parsesReadmeFrontMatter() {
        let readme = """
        -----------------------
        Name: Curl
        Version: September 14th 2021\r
        Creator: madmonkey
        Category: System
        -----------------------
        Body text: not part of the front matter
        """
        let meta = ModRepositoryService.parseFrontMatter(readme)
        #expect(meta["Name"] == "Curl")
        #expect(meta["Version"] == "September 14th 2021")
        #expect(meta["Category"] == "System")
        #expect(meta["Body text"] == nil)
        #expect(ModRepositoryService.parseFrontMatter("no front matter").isEmpty)
    }

    @Test func listKeepsOnlyHmods() {
        let list = "2048_2048.clvg\ncurl.hmod\r\nnosaves.hmod\n\n"
        #expect(ModRepositoryService.parseList(list) == ["curl.hmod", "nosaves.hmod"])
    }

    @Test func parsesPackArchive() throws {
        let files: [(String, String)] = [
            ("./list", "curl.hmod\nGame.clvg\nnosaves.hmod\n"),
            ("./curl.hmod/link", "https://example.com/files/curl.hmod\n"),
            ("./curl.hmod/md5", "bbb28a561fd97f72f9d80d6781890a44\n"),
            ("./curl.hmod/readme.md", "---\nName: Curl\nCategory: System\nCreator: madmonkey\n---\n"),
            ("./nosaves.hmod/link", "https://example.com/files/nosaves.hmod"),
            ("./Game.clvg/link", "https://example.com/files/Game.clvg"),
            // Folder not in the list: must be ignored
            ("./stale.hmod/link", "https://example.com/files/stale.hmod"),
        ]
        let entries = files.map { path, text in
            TarEntry(info: TarEntryInfo(name: path, type: .regular), data: Data(text.utf8))
        }
        let pack = try GzipArchive.archive(data: TarContainer.create(from: entries))

        let modules = try ModRepositoryService.parsePack(pack, repoURL: repoURL)
        #expect(modules.map(\.id) == ["curl", "nosaves"])

        let curl = try #require(modules.first)
        #expect(curl.name == "Curl")
        #expect(curl.category == "System")
        #expect(curl.creator == "madmonkey")
        #expect(curl.md5 == "bbb28a561fd97f72f9d80d6781890a44")
        #expect(curl.downloadURL?.absoluteString == "https://example.com/files/curl.hmod")

        let nosaves = modules[1]
        #expect(nosaves.name == "Nosaves")
        #expect(nosaves.category == "Other")
        #expect(nosaves.itemURL.absoluteString == "https://example.com/mods/.repo/nosaves.hmod/")
    }

    @Test func shellHelpers() {
        #expect(HmodService.quote("it's") == "'it'\\''s'")
        #expect(HmodService.safeFileName("my mod/../x.hmod") == "my_mod_.._x.hmod")
        #expect(HmodService.safeFileName("_km_snes9x_xtreme.hmod") == "_km_snes9x_xtreme.hmod")
    }

    /// Hits the real KMFD repository. Run with: HAKCHI_LIVE_TESTS=1 swift test
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HAKCHI_LIVE_TESTS"] == "1"))
    func liveKMFDRepository() async throws {
        let service = ModRepositoryService()
        let modules = try await service.fetchModules(
            from: "https://hakchi.net/KMFDManic/NESC-SNESC-Modifications/.repo/", forceRefresh: true)
        #expect(modules.count > 100)
        #expect(modules.allSatisfy { $0.downloadURL != nil })

        // Small module: download and checksum verification end to end
        let curl = try #require(modules.first { $0.id == "curl" })
        let data = try await service.downloadModule(curl)
        #expect(data.count > 1000)
    }
}
