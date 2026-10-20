import Foundation
import Testing
import SWCompression
@testable import SwiftHakchi

/// 7z writer and game compression (CE's Compress / Decompress)
@Suite struct CompressionTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("7zTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Extract with macOS's libarchive (an independent 7z reader)
    private func extractWithSystemTar(_ archive: URL, into dir: URL) throws -> Int32 {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", archive.path, "-C", dir.path]
        try tar.run()
        tar.waitUntilExit()
        return tar.terminationStatus
    }

    private func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    @Test(arguments: [0, 1, 1000, 1 << 20])
    func roundTripRandom(size: Int) throws {
        try roundTrip(randomData(size), name: "rom-\(size).bin")
    }

    @Test func roundTripCompressible() throws {
        let data = Data(repeating: 0x41, count: 3 << 20)
        let archive = try roundTrip(data, name: "zeros.nes")
        #expect(archive.count < 10_000)
    }

    @discardableResult
    private func roundTrip(_ data: Data, name: String) throws -> Data {
        let archive = try SevenZipWriter.archive(data: data, fileName: name)
        #expect(archive.prefix(6) == Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]))

        // SWCompression
        let entries = try SevenZipContainer.open(container: archive)
        #expect(entries.count == 1)
        #expect(entries.first?.info.name == name)
        #expect((entries.first?.data ?? Data()) == data)

        // libarchive (bsdtar)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.7z")
        try archive.write(to: url)
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        #expect(try extractWithSystemTar(url, into: out) == 0)
        #expect((try? Data(contentsOf: out.appendingPathComponent(name))) == data)
        return archive
    }

    @Test func numberEncoding() {
        func enc(_ v: UInt64) -> [UInt8] {
            var d = Data()
            SevenZipWriter.writeNumber(v, to: &d)
            return [UInt8](d)
        }
        #expect(enc(0) == [0x00])
        #expect(enc(0x7F) == [0x7F])
        #expect(enc(0x80) == [0x80, 0x80])
        #expect(enc(0x3FFF) == [0xBF, 0xFF])
        #expect(enc(0x4000) == [0xC0, 0x00, 0x40])
    }

    // MARK: - Game folders

    private func makeGame(_ dir: URL, code: String, rom: String, size: Int, exec: String? = nil) throws {
        try randomData(size).write(to: dir.appendingPathComponent(rom))
        try Data([1, 2]).write(to: dir.appendingPathComponent("\(code).png"))
        let line = exec ?? "/bin/gba /var/games/\(code)/\(rom) --opt"
        try Data("[Desktop Entry]\nExec=\(line)\nName=Game\n[X-CLOVER Game]\nCode=\(code)\n".utf8)
            .write(to: dir.appendingPathComponent("\(code).desktop"))
    }

    private func exec(_ dir: URL, _ code: String) throws -> String {
        DesktopFile(data: try Data(contentsOf: dir.appendingPathComponent("\(code).desktop"))).exec
    }

    @Test func compressAndDecompressGame() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let code = "CLV-A-ABCDE"
        try makeGame(dir, code: code, rom: "Game.gba", size: 5000)
        let original = try Data(contentsOf: dir.appendingPathComponent("Game.gba"))

        #expect(GameCompression.canCompress(gameDirectory: dir, code: code))
        try GameCompression.compress(gameDirectory: dir, code: code)
        #expect(try exec(dir, code) == "/bin/gba /var/games/\(code)/Game.gba.7z --opt")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Game.gba").path))
        #expect(!GameCompression.canCompress(gameDirectory: dir, code: code))
        #expect(GameCompression.canDecompress(gameDirectory: dir, code: code))

        try GameCompression.decompress(gameDirectory: dir, code: code)
        #expect(try exec(dir, code) == "/bin/gba /var/games/\(code)/Game.gba --opt")
        #expect(try Data(contentsOf: dir.appendingPathComponent("Game.gba")) == original)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Game.gba.7z").path))
    }

    @Test func compressRules() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Not named in Exec → skipped; cover art never compressed
        try makeGame(dir, code: "CLV-A-AAAAA", rom: "a.gba", size: 10, exec: "/bin/gba /var/games/CLV-A-AAAAA/other.gba")
        #expect(!GameCompression.canCompress(gameDirectory: dir, code: "CLV-A-AAAAA"))

        // Excluded extension
        let d2 = dir.appendingPathComponent("2")
        try FileManager.default.createDirectory(at: d2, withIntermediateDirectories: true)
        try makeGame(d2, code: "CLV-Z-AAAAA", rom: "game.cue", size: 10)
        #expect(!GameCompression.canCompress(gameDirectory: d2, code: "CLV-Z-AAAAA"))

        // Over 16 MiB
        let d3 = dir.appendingPathComponent("3")
        try FileManager.default.createDirectory(at: d3, withIntermediateDirectories: true)
        try makeGame(d3, code: "CLV-6-AAAAA", rom: "big.z64", size: 0)
        let handle = try FileHandle(forWritingTo: d3.appendingPathComponent("big.z64"))
        try handle.truncate(atOffset: UInt64(GameCompression.maxCompressSize + 1))
        try handle.close()
        #expect(!GameCompression.canCompress(gameDirectory: d3, code: "CLV-6-AAAAA"))
    }

    @Test func replaceOnlyWholeFileNames() {
        let exec = "/bin/x /var/games/CLV-A-AAAAA/a.gba --save /tmp/xa.gba"
        #expect(GameCompression.replaceFileName(in: exec, old: "a.gba", new: "a.gba.7z")
                == "/bin/x /var/games/CLV-A-AAAAA/a.gba.7z --save /tmp/xa.gba")
    }
}
