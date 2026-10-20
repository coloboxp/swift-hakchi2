import Foundation
import Testing
import SWCompression
@testable import SwiftHakchi

/// Phase 7: readmes, repositories, local module library, report, Bluetooth parsing
@MainActor
@Suite struct ModulesTests {
    final class TempDir {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModulesTests-\(UUID().uuidString)", isDirectory: true)
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
        func sub(_ name: String) -> URL {
            let u = url.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
    }

    // MARK: - Readme

    @Test func readmeFrontMatterKeepsOrder() {
        let readme = HmodReadme("""
        -----------------------
        Name: 2048
        Creator: Gabriele Cirulli|Libretro
        Category: KMFD Cores
        Emulated System: 2048
        Category: duplicate ignored
        -----------------------
        Body *text*
        """, isMarkdown: true)
        #expect(readme.frontMatter.map(\.key) == ["Name", "Creator", "Category", "Emulated System"])
        #expect(readme.category == "KMFD Cores")
        #expect(readme.emulatedSystem == "2048")
        #expect(readme.body == "Body *text*")
        #expect(HmodReadme("plain text only").frontMatter.isEmpty)
        #expect(HmodReadme("plain text only").body == "plain text only")
        // CE's heading order: Creator, Version, then the rest without Name
        #expect(ModuleReadmeView.headingFields(readme).map(\.key) == ["Creator", "Category", "Emulated System"])
    }

    // MARK: - Repositories

    @Test func parsesHrepo() {
        let repo = ModRepository.parseHrepo("---\nName: My Repo\nLink: https://example.com/mods/\n---\n")
        #expect(repo?.name == "My Repo")
        #expect(repo?.url == "https://example.com/mods/")
        #expect(ModRepository.parseHrepo("---\nName: No link\n---") == nil)
        #expect(ModRepository.parseHrepo("---\nLink: https://h.net/x/.repo/\n---")?.name == "h.net/x")
    }

    @Test func migratesLegacyRepositoryURLs() throws {
        let legacy = #"{"modRepositoryURLs":["https://hakchi.net/KMFDManic/NESC-SNESC-Modifications/.repo/","https://example.com/other/"]}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(legacy.utf8))
        #expect(config.modRepositories.map(\.name) == ["KMFD's Mod Hub", "example.com/other"])

        // New format round-trips
        let encoded = try JSONEncoder().encode(config)
        let again = try JSONDecoder().decode(AppConfig.self, from: encoded)
        #expect(again.modRepositories.map(\.url) == config.modRepositories.map(\.url))
        #expect(String(decoding: encoded, as: UTF8.self).contains("modRepositories"))

        // Missing key: CE's default repository
        let empty = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(empty.modRepositories == [ModRepository.kmfd] || empty.modRepositories.map(\.url) == [ModRepository.kmfd.url])
    }

    // MARK: - Library

    private func makeLibrary(_ tmp: TempDir) -> ModLibrary {
        ModLibrary(directory: tmp.sub("user_mods"), cacheFile: tmp.url.appendingPathComponent("cache.json"))
    }

    /// A packed module: tar.gz with a readme
    private func packedModule(name: String, category: String) throws -> Data {
        let readme = "---\nName: \(name)\nCategory: \(category)\nCreator: me\n---\nHello"
        let tar = TarContainer.create(from: [
            TarEntry(info: TarEntryInfo(name: "./readme.md", type: .regular), data: Data(readme.utf8)),
            TarEntry(info: TarEntryInfo(name: "./bin/tool", type: .regular), data: Data("#!/bin/sh".utf8)),
        ])
        return try GzipArchive.archive(data: tar)
    }

    @Test func libraryAddsPackedAndFolderModules() throws {
        let tmp = TempDir()
        let library = makeLibrary(tmp)
        let src = tmp.sub("src")

        try packedModule(name: "Curl Tool", category: "System").write(to: src.appendingPathComponent("curl.hmod"))
        let folder = src.appendingPathComponent("my mod.hmod", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\nName: Folder Mod\nCategory: Themes\n---".utf8).write(to: folder.appendingPathComponent("readme.txt"))

        let added = try library.add(urls: [src.appendingPathComponent("curl.hmod"), folder])
        #expect(added.sorted() == ["curl", "my_mod"])  // CE's BadCharsRegex cleans the name
        #expect(library.modules.map(\.name) == ["Curl Tool", "Folder Mod"])
        #expect(library.module(named: "curl")?.category == "System")
        #expect(library.module(named: "my_mod")?.isDirectory == true)
        #expect(library.grouped(by: .category).map(\.group) == ["System", "Themes"])

        // Packed readme comes from the cache on reload
        library.reload()
        #expect(library.module(named: "curl")?.readme?.creator == "me")

        // Staging payloads: packed file as-is, folder as a tar holding "<id>.hmod/"
        let packed = try library.stagingPayload(for: try #require(library.module(named: "curl")))
        #expect(!packed.isFolderTar)
        #expect(ModRepositoryService.isGzip(packed.data))
        let tarred = try library.stagingPayload(for: try #require(library.module(named: "my_mod")))
        #expect(tarred.isFolderTar)
        let names = try TarContainer.open(container: tarred.data).map(\.info.name)
        #expect(names.contains { $0.hasPrefix("my_mod.hmod/") && $0.hasSuffix("readme.txt") })

        try library.delete(try #require(library.module(named: "curl")))
        #expect(library.module(named: "curl") == nil)
    }

    @Test func libraryExtractsModulesFromZip() throws {
        let tmp = TempDir()
        let library = makeLibrary(tmp)
        let content = tmp.sub("zipcontent")
        try packedModule(name: "Packed", category: "A").write(to: content.appendingPathComponent("packed.hmod"))
        let folder = content.appendingPathComponent("loose.hmod/etc", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("file"))

        let zipURL = tmp.url.appendingPathComponent("mods.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = content
        zip.arguments = ["-rq", zipURL.path, "packed.hmod", "loose.hmod"]
        try zip.run()
        zip.waitUntilExit()

        let added = try library.add(urls: [zipURL])
        #expect(added.sorted() == ["loose", "packed"])
        #expect(FileManager.default.fileExists(atPath: library.directory.appendingPathComponent("loose.hmod/etc/file").path))
        #expect(throws: (any Error).self) { try library.add(urls: [tmp.url.appendingPathComponent("cache.json")]) }
    }

    @Test func librarySavesDownloads() throws {
        let tmp = TempDir()
        let library = makeLibrary(tmp)
        let data = try packedModule(name: "Borders", category: "KMFD Xtras")

        try library.saveDownload(id: "_km_ra_custom_borders", data: data, extract: false)
        #expect(library.module(named: "_km_ra_custom_borders")?.isDirectory == false)

        // CE's `extract`: unpack into a folder
        try library.saveDownload(id: "_km_ra_custom_borders", data: data, extract: true)
        let module = try #require(library.module(named: "_km_ra_custom_borders"))
        #expect(module.isDirectory)
        #expect(module.name == "Borders")
        #expect(FileManager.default.fileExists(atPath: module.url.appendingPathComponent("bin/tool").path))
    }

    // MARK: - Report

    @Test func reportMatchesCE() {
        let html = ModReportGenerator.html(
            installed: [.init(rawName: "curl", frontMatter: [("Name", "Curl"), ("Creator", "<madmonkey>")])],
            available: [.init(rawName: "b", frontMatter: []), .init(rawName: "a", frontMatter: [])])
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<body><h1>Installed Mods</h1><div class=\"ModList\"><div class=\"Mod\"><h2>curl</h2>"))
        #expect(html.contains("<div><strong>Creator:</strong> &lt;madmonkey&gt;</div>"))
        #expect(html.range(of: "<h2>a</h2>")!.lowerBound < html.range(of: "<h2>b</h2>")!.lowerBound)
        #expect(ModReportGenerator.html(installed: nil, available: []).contains("<h1>System Not Online</h1>"))
    }

    // MARK: - Bluetooth

    @Test func parsesBluetoothctlOutput() {
        let esc = "\u{1B}[0;94m"
        let output = """
        Agent registered
        [bluetooth]# list
        Controller 00:1A:7D:DA:71:13 hakchi [default]
        [bluetooth]# scan on
        Discovery started
        [CHG] Controller 00:1A:7D:DA:71:13 Discovering: yes
        \(esc)[NEW]\u{1B}[0m Device 11:22:33:44:55:66 Wireless Controller
        [NEW] Device AA:BB:CC:DD:EE:FF 8BitDo SN30
        [NEW] Device 99:88:77:66:55:44 99-88-77-66-55-44
        [DEL] Device 99:88:77:66:55:44 99-88-77-66-55-44
        [bluetooth]# devices
        Device 11:22:33:44:55:66 Wireless Controller
        Device AA:BB:CC:DD:EE:FF 8BitDo SN30
        Device 11:22:33:44:55:66 (public)
        \tName: Wireless Controller
        \tPaired: yes
        \tTrusted: yes
        \tConnected: yes
        Device AA:BB:CC:DD:EE:FF (public)
        \tName: 8BitDo SN30
        \tPaired: no
        \tTrusted: yes
        """
        let devices = BluetoothOutputParser.parse(output)
        let controller = devices.first { $0.kind == .controller }
        #expect(controller?.address == "00:1A:7D:DA:71:13")
        #expect(controller?.name == "hakchi")

        let ds4 = devices.first { $0.address == "11:22:33:44:55:66" }
        #expect(ds4?.name == "Wireless Controller")
        #expect(ds4?.paired == true && ds4?.connected == true)

        let sn30 = devices.first { $0.address == "AA:BB:CC:DD:EE:FF" }
        #expect(sn30?.paired == false && sn30?.trusted == true)
        #expect(sn30?.label == "8BitDo SN30 (AA:BB:CC:DD:EE:FF)")

        #expect(!devices.contains { $0.address == "99:88:77:66:55:44" })  // [DEL] removes it
    }
}
