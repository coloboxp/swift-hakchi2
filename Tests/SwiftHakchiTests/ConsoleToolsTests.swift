import Foundation
import Testing
import CoreGraphics
import ImageIO
import SWCompression
@testable import SwiftHakchi

/// Phases 5–6: Tools and recovery helpers (pure logic, no console needed)
@Suite struct ConsoleToolsTests {
    final class TempDir {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConsoleToolsTests-\(UUID().uuidString)", isDirectory: true)
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Save states

    @Test func parsesSaveStateListing() {
        let output = """
        CLV-H-ABCDE 128 F-S-1-2 Super Mario Bros. 3
        CLV-U-QWERT 64 F-1 UNKNOWN
        garbage line
        """
        let saves = ConsoleTools.parseSaveStates(output)
        #expect(saves.count == 2)
        #expect(saves[0] == .init(code: "CLV-H-ABCDE", sizeKB: 128, flags: "S 1 2", name: "Super Mario Bros. 3"))
        #expect(saves[1].name == nil)
        #expect(saves[1].flags == "1")
    }

    // MARK: - Screenshot

    @Test func convertsBGRAFramebuffer() throws {
        // 2×1 pixels: blue, then red (BGRA byte order, alpha ignored)
        let raw = Data([255, 0, 0, 7, 0, 0, 255, 9])
        let image = try #require(ConsoleTools.image(fromFramebuffer: raw, width: 2, height: 1))
        let png = try #require(ConsoleTools.pngData(image))
        let decoded = try #require(CGImageSourceCreateWithData(png as CFData, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        var pixels = [UInt8](repeating: 0, count: 8)
        let ctx = try #require(CGContext(data: &pixels, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(decoded, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        #expect(Array(pixels[0..<3]) == [0, 0, 255])   // blue
        #expect(Array(pixels[4..<7]) == [255, 0, 0])   // red
        #expect(ConsoleTools.image(fromFramebuffer: Data(count: 10)) == nil)
    }

    @Test func bootSplashIsStretchedTo1280x720() throws {
        let small = try #require(ConsoleTools.image(fromFramebuffer: Data(repeating: 128, count: 4 * 4 * 4), width: 4, height: 4))
        let png = try #require(ConsoleTools.pngData(small))
        let out = try #require(ConsoleTools.bootSplashPNG(from: png, isPNG: true))
        let image = try #require(CGImageSourceCreateWithData(out as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 1280 && image.height == 720)
        // A correct 1280×720 PNG is uploaded unchanged
        #expect(ConsoleTools.bootSplashPNG(from: out, isPNG: true) == out)
    }

    // MARK: - Memory stats

    @Test func parsesMemoryStats() {
        var stats = ConsoleTools.MemoryStats()
        #expect(ConsoleTools.parseDf("1000 | 400 | 600\n", into: &stats))
        #expect(stats.storageTotal == 1_024_000 && stats.storageFree == 614_400)
        #expect(!ConsoleTools.parseDf("nonsense", into: &stats))

        ConsoleTools.parseCollections("""
        /var/lib/hakchi/games/.storage | 100
        /var/lib/hakchi/games/000 | 10
        /var/lib/hakchi/games/snes-usa | 50
        /var/lib/hakchi/games/other | 5
        """, into: &stats)
        #expect(stats.nonMultibootGamesSize == 110 * 1024)
        #expect(stats.collections == ["snes-usa": 50 * 1024])
        #expect(stats.extraFilesSize == 5 * 1024)
        #expect(stats.allGamesSize == 165 * 1024)
        #expect(stats.availableForGames(separateGameStorage: false, currentSystemCode: "snes-usa") == 614_400 + 165 * 1024)
        #expect(stats.availableForGames(separateGameStorage: true, currentSystemCode: "snes-usa")
                == 614_400 + 50 * 1024 + 110 * 1024 + 5 * 1024)
    }

    // MARK: - NAND layout and image types

    @Test func parsesNandInfo() {
        let info = ConsoleTools.parseNandInfo(
            sunxiPart: "mbr:mbr:32768 nanda:bootloader:65536 nandb:rootfs:262144 nandc:data:1048576",
            nandInfo: "2048 64 4096")
        #expect(info.nandSize == 2048 * 64 * 4096)
        #expect(info.rootfs == .init(device: "nandb", label: "rootfs", blockCount: 262_144))
        #expect(info.data?.device == "nandc")
        #expect(ConsoleTools.parseNandInfo(sunxiPart: "", nandInfo: "").partitions.isEmpty)
        #expect(ConsoleTools.formatDeviceCommand("/dev/nandc").hasSuffix("\\/dev\\/nandc"))
    }

    @Test func detectsImageTypes() {
        var tar = Data(count: 600)
        tar.replaceSubrange(257..<262, with: Data("ustar".utf8))
        #expect(ConsoleTools.isTar(tar))
        #expect(!ConsoleTools.isTar(Data(count: 100)))
        #expect(ConsoleTools.isSquashFs(Data("hsqs....".utf8)))
        var ext = Data(count: 0x500)
        ext[0x438] = 0x53
        ext[0x439] = 0xEF
        #expect(ConsoleTools.isExtFs(ext)) // feature flags 0 → ext2
        #expect(!ConsoleTools.isExtFs(Data(count: 0x500)))
    }

    // MARK: - Kernels, hmod versions, MD rootfs

    @Test func validatesKernelsAndVersions() {
        #expect(!ConsoleTools.isValidatedStockKernel(Data("not a kernel".utf8)))
        let v = ConsoleTools.parseHakchiVersion("bootVersion='1.0.3'\nhakchiVersion='v1.0.4-126'\nkernelVersion='3.4.113.29-madmonkey'\n")
        #expect(v == .init(boot: "1.0.3", kernel: "3.4.113.29-madmonkey", script: "v1.0.4-126"))
        var newer = v
        newer.script = "v1.0.4-130"
        #expect(ConsoleTools.isNewer(newer, than: v))
        #expect(!ConsoleTools.isNewer(v, than: newer))
        #expect(!ConsoleTools.isNewer(v, than: v))
    }

    @Test func checksMegaDriveRootfs() {
        let version = "MOON-mass-moon-es1-v0.8.1-1080US-e0c1975"
        #expect(ConsoleTools.checkMdRootfs(hash: "27132f57f5e2848c6a6f93ff1bce4804", version: version) == .known)
        #expect(ConsoleTools.checkMdRootfs(hash: String(repeating: "0", count: 32), version: version) == .modified)
        #expect(ConsoleTools.checkMdRootfs(hash: "27132f57f5e2848c6a6f93ff1bce4804", version: "MOON-other") == .unknownVersion)
    }

    // MARK: - MOTD, quoting, listings, terminal

    @Test func motdHelpers() {
        #expect(ConsoleTools.motdStamp("<!--- 2022-11-09T12:59:00.0000000-05:00 -->\nHello")
                == "2022-11-09T12:59:00.0000000-05:00")
        #expect(ConsoleTools.motdStamp("no stamp") == nil)
        let now = Date()
        #expect(ConsoleTools.isCacheFresh(modified: now.addingTimeInterval(-3600), now: now))
        #expect(!ConsoleTools.isCacheFresh(modified: now.addingTimeInterval(-7 * 3600), now: now))
        #expect(!ConsoleTools.isCacheFresh(modified: nil, now: now))
    }

    @Test func shellQuotingAndListings() {
        #expect(ConsoleTools.escapeShellArgument("CLV-H-AB C") == "CLV\\-H\\-AB\\ C")
        #expect(ConsoleTools.quote("it's") == "'it'\\''s'")
        let files = ConsoleTools.parseListing("f|10|b.txt\nd|0|games\nl|5|link\nbad\n")
        #expect(files.map(\.name) == ["games", "b.txt", "link"])
        #expect(files[0].isDirectory && files[2].isLink && files[1].size == 10)
        #expect(ConsoleTools.parseFirmwareList("/media/a.hsqs\r\n/var/lib/hakchi/b.hsqs\n") ==
                ["/media/a.hsqs", "/var/lib/hakchi/b.hsqs"])
    }

    @Test func terminalTextProcessing() {
        var buffer = ""
        TerminalText.append("\u{1B}[1;32mroot@hakchi\u{1B}[0m:~# ls\r\n", to: &buffer)
        #expect(buffer == "root@hakchi:~# ls\n")
        TerminalText.append("abc\u{08}d", to: &buffer)
        #expect(buffer.hasSuffix("abd"))
        TerminalText.append("\rxy", to: &buffer)
        #expect(buffer.hasSuffix("\nxy"))
        var long = ""
        TerminalText.append(String(repeating: "a", count: 50), to: &long, limit: 10)
        #expect(long.count == 10)
    }

    // MARK: - Export

    @Test func flatExportLayoutAndDiff() throws {
        let tmp = TempDir()
        let gameDir = tmp.url.appendingPathComponent("CLV-A-AAAAA")
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try Data("rom".utf8).write(to: gameDir.appendingPathComponent("game.gba"))
        try Data("{}".utf8).write(to: gameDir.appendingPathComponent("metadata.json"))
        try Data("x".utf8).write(to: gameDir.appendingPathComponent("CLV-A-AAAAA_logo.png"))
        try Data("Exec=/bin/gba /var/games/CLV-A-AAAAA/game.gba\nCode=CLV-A-AAAAA".utf8)
            .write(to: gameDir.appendingPathComponent("CLV-A-AAAAA.desktop"))

        let layout = FlatExportLayout(consoleType: .snesUsa)
        let plan = layout.plan(games: [
            ExportGame(code: "CLV-A-AAAAA", kind: .local(directory: gameDir)),
            ExportGame(code: "CLV-U-STOCK", kind: .stock(desktop: "Exec=/bin/x /usr/share/games/CLV-U-STOCK/a.sfrom")),
        ])
        #expect(Set(plan.keys) == ["000/CLV-A-AAAAA/CLV-A-AAAAA.desktop", "000/CLV-A-AAAAA/game.gba",
                                   "000/CLV-U-STOCK/CLV-U-STOCK.desktop"])
        if case .data(let stock)? = plan["000/CLV-U-STOCK/CLV-U-STOCK.desktop"] {
            #expect(String(decoding: stock, as: UTF8.self).contains("/var/squashfs/usr/share/games/CLV-U-STOCK"))
        }

        let root = tmp.url.appendingPathComponent("usb/hakchi/games/snes-usa")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("stale"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: root.appendingPathComponent("stale/old.txt"))
        let written = try GameExporter.export(plan: plan, to: root) { _, _ in }
        #expect(written == 3)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("stale").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("000/CLV-A-AAAAA/game.gba").path))
        // Second run: nothing changed
        #expect(try GameExporter.export(plan: plan, to: root) { _, _ in } == 0)

        var linked = FlatExportLayout(consoleType: .snesUsa)
        linked.linkedMediaPath = "/media/games"
        let linkedPlan = linked.plan(games: [ExportGame(code: "CLV-A-AAAAA", kind: .local(directory: gameDir))])
        #expect(linkedPlan.count == 1)
        if case .data(let d)? = linkedPlan.values.first {
            #expect(String(decoding: d, as: UTF8.self).contains("/media/games/CLV-A-AAAAA/game.gba"))
        }
    }

    // MARK: - Recovery helpers

    @Test func extractsCompressedImages() throws {
        let tmp = TempDir()
        let payload = Data("hsqs-image".utf8)
        let gz = tmp.url.appendingPathComponent("system.hsqs.gz")
        try GzipArchive.archive(data: payload).write(to: gz)
        let out = try RecoveryService.extractIfCompressed(gz, into: tmp.url)
        #expect(try Data(contentsOf: out) == payload)
        let plain = tmp.url.appendingPathComponent("system.hsqs")
        #expect(try RecoveryService.extractIfCompressed(plain, into: tmp.url) == plain)
    }
}
