import Foundation
import Testing
@testable import SwiftHakchi

/// Tests for the ROM handlers ported from Hakchi2-CE (NesFile, NesGame, FdsGame,
/// SnesGame, IpsPatcher). ROMs are synthesized in code.
@Suite struct RomFormatTests {

    // MARK: - Helpers

    /// iNES file: header bytes 4–7 as given, then PRG/CHR filled with a pattern
    private func makeNes(prgBanks: UInt8 = 1, chrBanks: UInt8 = 1, flags6: UInt8, flags7: UInt8 = 0,
                         tail: [UInt8] = [0, 0, 0, 0], trainer: Bool = false) -> Data {
        var d: [UInt8] = [0x4E, 0x45, 0x53, 0x1A, prgBanks, chrBanks, flags6 | (trainer ? 0x04 : 0), flags7,
                          0, 0, 0, 0] + tail
        if trainer { d += [UInt8](repeating: 0xEE, count: 512) }
        d += (0..<(Int(prgBanks) * 16384)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        d += (0..<(Int(chrBanks) * 8192)).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) }
        return Data(d)
    }

    /// 64 KiB SNES image with an internal header written at `offset`
    private func makeSnes(headerAt offset: Int, title: String, romType: UInt8, sram: UInt8,
                          makeup: UInt8 = 0x20, size: Int = 0x10000) -> Data {
        var d = [UInt8](repeating: 0, count: size)
        for i in 0..<size where i < offset || i >= offset + 32 { d[i] = UInt8(truncatingIfNeeded: i &* 31) }
        var t = Array(title.utf8)
        t += [UInt8](repeating: 0x20, count: 21 - t.count)
        d.replaceSubrange(offset..<(offset + 21), with: t)
        d[offset + 21] = makeup
        d[offset + 22] = romType
        d[offset + 24] = sram
        // checksum 0x1234, complement 0xEDCB (little-endian, complement first)
        d[offset + 28] = 0xCB; d[offset + 29] = 0xED
        d[offset + 30] = 0x34; d[offset + 31] = 0x12
        return Data(d)
    }

    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }

    // MARK: - NES

    @Test func parsesINESHeader() throws {
        let file = makeNes(flags6: 0x40 | 0x02 | 0x01)  // mapper 4, battery, vertical
        let rom = try NesRom(data: file)
        #expect(rom.mapper == 4)
        #expect(rom.battery)
        #expect(rom.mirroring == .vertical)
        #expect(rom.prg.count == 16384 && rom.chr.count == 8192)
        #expect(rom.trainer == nil)
        #expect(rom.crc32 == CRC32.checksum(file.dropFirst(16)))
        #expect(rom.rawData() == file)  // round trip with a clean header
    }

    @Test func fourScreenAndHighMapperNibble() throws {
        let rom = try NesRom(data: makeNes(flags6: 0x58, flags7: 0xB0))  // mapper 0xB5, four-screen
        #expect(rom.mapper == 0xB5)
        #expect(rom.mirroring == .fourScreen)
    }

    @Test func archaicHeaderClearsByte7() throws {
        // "DiskDude!" junk in bytes 12-15 means bytes 7-15 are ignored
        let rom = try NesRom(data: makeNes(flags6: 0x10, flags7: 0x40, tail: Array("Dude".utf8)))
        #expect(rom.mapper == 1)
        #expect(try NesRom(data: makeNes(flags6: 0x10, flags7: 0x08)).isNes20)
    }

    @Test func trainerIsKeptAfterHeader() throws {
        let file = makeNes(flags6: 0, trainer: true)
        let rom = try NesRom(data: file)
        #expect(rom.trainer == Data(repeating: 0xEE, count: 512))
        #expect(rom.rawData() == file)
    }

    @Test func shortRomIsZeroPadded() throws {
        let file = makeNes(flags6: 0).prefix(16 + 100)
        let rom = try NesRom(data: Data(file))
        #expect(rom.prg.count == 16384)
        #expect(rom.prg.suffix(10) == Data(repeating: 0, count: 10))
        #expect(throws: NesRom.ParseError.notINES) { try NesRom(data: Data("NOPE".utf8)) }
    }

    @Test func fixTableMatchesCE() {
        #expect(NesRom.fixTable.count == 262)
        #expect(NesRom.batteryGames.count == 32)
        #expect(NesRom.fixTable.contains { $0.crc == 0xa912b064 && $0.mapper == (51 | 0x800) })
        // Deadly Towers: CE comments out the mapper-34 row and keeps the mapper-241 one
        #expect(NesRom.fixTable.filter { $0.crc == 0xc2730c30 }.map(\.mapper) == [241])
        #expect(NesRom.fixTable.contains { $0.crc == 0x243a8735 && $0.mirroring == (0x10 | 4) })
    }

    @Test func nesImportSupportedMapper() {
        let file = makeNes(flags6: 0x40 | 0x02)
        let result = NesRom.prepareForImport(data: file, fileName: "Game (J).nes")
        #expect(result.isValidINES)
        #expect(result.application == "/bin/clover-kachikachi-wr")
        #expect(result.args == "--guest-overscan-dimensions 0,0,9,3 --initial-fadein-durations 3,2 --volume 75 --enable-armet")
        #expect(result.saveCount == 3)
        #expect(result.useJapaneseCover)
        #expect(result.warnings.isEmpty)
        #expect(result.crc32 == CRC32.checksum(file.dropFirst(16)))
    }

    @Test func nesImportWarnings() {
        let result = NesRom.prepareForImport(data: makeNes(flags6: 0xE8, flags7: 0x10), fileName: "x.nes")  // mapper 30, 4-screen
        #expect(result.warnings == [.unsupportedMapper(30), .fourScreenMirroring])
        #expect(result.saveCount == nil)
    }

    @Test func nesImportInvalidFileKeepsDefaults() {
        let junk = Data(repeating: 0x42, count: 64)
        let result = NesRom.prepareForImport(data: junk, fileName: "x.nes")
        #expect(!result.isValidINES)
        #expect(result.application == nil)
        #expect(result.data == junk)
        #expect(result.crc32 == CRC32.checksum(junk))
    }

    @Test func nesImportTriesFileCrcThenInternalCrc() {
        let file = makeNes(flags6: 0)
        let internalCrc = CRC32.checksum(file.dropFirst(16))
        var asked: [UInt32] = []
        let result = NesRom.prepareForImport(data: file, fileName: "x.nes") { data, crc in
            asked.append(crc)
            guard crc == internalCrc else { return nil }
            var d = data
            d[16] = 0xAA
            return d
        }
        #expect(asked == [CRC32.checksum(file), internalCrc])
        #expect(result.patched)
        #expect(result.data[16] == 0xAA)
        #expect(result.crc32 == internalCrc)  // CRC from before the patch, like CE
    }

    // MARK: - FDS

    @Test func fdsHeaderStripped() {
        let disk = Data((0..<65500).map { UInt8(truncatingIfNeeded: $0) })
        let file = Data("FDS".utf8) + Data([0x1A, 2]) + Data(count: 11) + disk
        let nes = FdsRom.prepareForImport(data: file, targetIsNesConsole: true)
        #expect(nes.headerStripped)
        #expect(nes.data == disk)
        #expect(nes.crc32 == CRC32.checksum(disk))
        #expect(nes.application == "/bin/clover-kachikachi-wr")
        #expect(nes.args?.hasSuffix("--fds-auto-disk-side-switch-on-keypress") == true)
        #expect(nes.args?.contains("--initial-fadein-durations 10,2") == true)

        let snes = FdsRom.prepareForImport(data: disk, targetIsNesConsole: false)
        #expect(!snes.headerStripped)
        #expect(snes.application == nil && snes.args == nil)
        #expect(snes.crc32 == CRC32.checksum(disk))
    }

    // MARK: - SNES

    @Test func detectsLoRomWithKnownPreset() throws {
        let rom = makeSnes(headerAt: 0x7FC0, title: "SUPER MARIOWORLD", romType: 0x02, sram: 1)
        let detected = try SnesRom.detectHeader(rom)
        #expect(detected.type == .loRom)
        #expect(detected.title == "SUPER MARIOWORLD")

        let s = try SnesRom.makeSfrom(rom)
        #expect(s.presetID == 0x1011)
        #expect(s.chip == 0)
        #expect(s.saveCount == 3)
        #expect(!s.isProblemGame)
        #expect(s.data.count == 48 + rom.count + 48)

        // Header 1, derived field by field from CE's SfromHeader1(romSize)
        let size = UInt32(rom.count)
        var h1: [UInt8] = []
        h1 += le32(0x100); h1 += le32(size + 96); h1 += le32(0x30); h1 += le32(48 + size)
        h1 += le32(size + 96); h1 += le32(48 + size); h1 += le32(size + 96); h1 += le32(0)
        h1 += le32(48 + size + 27); h1 += Array("WUP-XXXX".utf8); h1 += le32(0)
        #expect([UInt8](s.data.prefix(48)) == h1)
        #expect(s.data[48..<(48 + rom.count)] == rom)

        // Header 2, packed: fps, romSize, pcm, footer, preset, controllers, volume, type, chip, ...
        var h2: [UInt8] = [60]
        h2 += le32(size); h2 += le32(0); h2 += le32(0); h2 += [0x11, 0x10]; h2 += [2, 0x5A, 0x14]
        h2 += le32(0); h2 += [UInt8](repeating: 0, count: 5); h2 += le32(1); h2 += le32(1)
        h2 += [UInt8](repeating: 0, count: 13)
        #expect([UInt8](s.data.suffix(48)) == h2)
    }

    @Test func detectsHiRomSa1AndSuperFx() throws {
        let sa1 = makeSnes(headerAt: 0xFFC0, title: "SOME SA1 GAME", romType: 0x34, sram: 0)
        let s = try SnesRom.makeSfrom(sa1)
        #expect(s.romType == .hiRom)
        #expect(s.presetID == SnesRom.sa1Preset)
        #expect(s.saveCount == 0)
        #expect(s.data[s.data.count - 48 + 0x11] == 0x15)

        let dsp = try SnesRom.makeSfrom(makeSnes(headerAt: 0x7FC0, title: "RACER", romType: 0x03, sram: 0))
        #expect(dsp.presetID == SnesRom.dsp1Preset)

        let fx = try SnesRom.makeSfrom(makeSnes(headerAt: 0x7FC0, title: "FX GAME", romType: 0x13, sram: 0))
        #expect(fx.chip == 0x0C)
        #expect(fx.data[fx.data.count - 48 + 0x12] == 0x0C)
    }

    @Test func problemGameAndNonAsciiTitle() throws {
        let p = try SnesRom.makeSfrom(makeSnes(headerAt: 0x7FC0, title: "UNIRACERS", romType: 0, sram: 0))
        #expect(p.isProblemGame)

        var bytes = [UInt8](makeSnes(headerAt: 0x7FC0, title: "SD", romType: 0, sram: 0))
        bytes.replaceSubrange((0x7FC0 + 2)..<(0x7FC0 + 8), with: [UInt8](repeating: 0xB0, count: 6))
        bytes.replaceSubrange((0x7FC0 + 8)..<(0x7FC0 + 10), with: Array("GX".utf8))
        #expect(try SnesRom.detectHeader(Data(bytes)).title == "SD??????GX")
        #expect(try SnesRom.makeSfrom(Data(bytes)).isProblemGame)
    }

    @Test func undetectableAndTooSmallRoms() {
        #expect(throws: SnesRom.SnesError.romTooSmall) { try SnesRom.makeSfrom(Data(count: 0x8000)) }
        // Both headers invalid and both titles empty or equal with mismatched makeup bits
        var d = [UInt8](repeating: 0, count: 0x10000)
        d[0x7FC0 + 21] = 1   // LoROM makeup odd
        d[0xFFC0 + 21] = 0   // HiROM makeup even
        #expect(throws: SnesRom.SnesError.cannotDetectRomType) { try SnesRom.detectHeader(Data(d)) }
    }

    @Test func snesImportPipeline() throws {
        let rom = makeSnes(headerAt: 0x7FC0, title: "SUPER MARIOWORLD", romType: 0x02, sram: 0)
        let withCopier = Data(count: 512) + rom
        var patchCrc: UInt32?
        let r = try SnesRom.prepareForImport(data: withCopier, fileName: "Mario (E).smc", convertToSfrom: true) { _, crc in
            patchCrc = crc
            return nil
        }
        #expect(r.crc32 == CRC32.checksum(rom))
        #expect(patchCrc == CRC32.checksum(rom))
        #expect(r.outputExtension == "sfrom")
        #expect(r.application == "/bin/clover-canoe-shvc-wr -rom")
        #expect(r.args == "--volume 100 -rollback-snapshot-period 600")
        #expect(r.saveCount == 0)
        #expect(r.coverHint == .europeJapan)

        let plain = try SnesRom.prepareForImport(data: withCopier, fileName: "Mario.smc", convertToSfrom: false) { _, _ in
            Issue.record("CE applies no patch when conversion is off")
            return nil
        }
        #expect(plain.data == rom)
        #expect(plain.application == nil)
        #expect(plain.outputExtension == nil)

        let sfrom = try SnesRom.prepareForImport(data: r.data, fileName: "Mario.sfrom", convertToSfrom: true)
        #expect(sfrom.data == r.data)
        #expect(sfrom.application == SnesRom.canoeApplication)
    }

    @Test func sfromPresetEditor() throws {
        let s = try SnesRom.makeSfrom(makeSnes(headerAt: 0x7FC0, title: "SUPER MARIOWORLD", romType: 0, sram: 0))
        #expect(try SnesRom.readPreset(s.data) == (0x1011, 0))
        let edited = try SnesRom.writePreset(s.data, presetID: 0xBEEF, chip: 0x0C)
        #expect(try SnesRom.readPreset(edited) == (0xBEEF, 0x0C))
        #expect(edited.count == s.data.count)
        #expect(edited.prefix(s.data.count - 48) == s.data.prefix(s.data.count - 48))
        #expect(throws: SnesRom.SnesError.invalidSfrom) { try SnesRom.readPreset(Data(count: 10)) }
    }

    // MARK: - IPS

    private func ips(_ records: [[UInt8]], eof: [UInt8] = Array("EOF".utf8)) -> Data {
        Data(Array("PATCH".utf8) + records.flatMap { $0 } + eof)
    }

    @Test func ipsRecordsAndRle() throws {
        let rom = Data(repeating: 0, count: 16)
        let patch = ips([
            [0, 0, 2, 0, 3, 0xAA, 0xBB, 0xCC],   // write 3 bytes at 2
            [0, 0, 8, 0, 0, 0, 4, 0x77],         // RLE: 4 × 0x77 at 8
        ])
        let out = try IpsPatch.apply(patch, to: rom)
        #expect([UInt8](out) == [0, 0, 0xAA, 0xBB, 0xCC, 0, 0, 0, 0x77, 0x77, 0x77, 0x77, 0, 0, 0, 0])
    }

    @Test func ipsGrowsAndTruncates() throws {
        let rom = Data(repeating: 1, count: 4)
        let grown = try IpsPatch.apply(ips([[0, 0, 6, 0, 2, 9, 9]]), to: rom)
        #expect([UInt8](grown) == [1, 1, 1, 1, 0, 0, 9, 9])

        let truncated = try IpsPatch.apply(ips([], eof: Array("EOF".utf8) + [0, 0, 2]), to: rom)
        #expect([UInt8](truncated) == [1, 1])

        #expect(throws: IpsPatch.IpsError.invalidSignature) { try IpsPatch.apply(Data("NOPE!".utf8), to: rom) }
        #expect(throws: IpsPatch.IpsError.truncated) {
            try IpsPatch.apply(Data(Array("PATCH".utf8) + [0, 0, 1, 0, 5, 1]), to: rom)
        }
    }

    @Test func findPatchOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ipsTest-\(UUID().uuidString)")
        let patches = root.appendingPathComponent("patches/sub", isDirectory: true)
        let roms = root.appendingPathComponent("roms", isDirectory: true)
        try FileManager.default.createDirectory(at: patches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: roms, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let patchesDir = root.appendingPathComponent("patches")
        let rom = roms.appendingPathComponent("Game.nes")
        #expect(IpsPatch.findPatch(patchesDirectory: patchesDir, romURL: rom, crc32: 0xDEADBEEF) == nil)

        let byCrc = patches.appendingPathComponent("DEADBEEF Game fix.ips")
        try Data().write(to: byCrc)
        #expect(IpsPatch.findPatch(patchesDirectory: patchesDir, romURL: rom, crc32: 0xDEADBEEF)?.lastPathComponent == byCrc.lastPathComponent)
        #expect(IpsPatch.findPatch(patchesDirectory: patchesDir, romURL: rom, crc32: 0) == nil)

        let byName = patchesDir.appendingPathComponent("Game.ips")
        try Data().write(to: byName)
        #expect(IpsPatch.findPatch(patchesDirectory: patchesDir, romURL: rom, crc32: 0xDEADBEEF)?.path == byName.path)

        let beside = roms.appendingPathComponent("Game.ips")
        try Data().write(to: beside)
        #expect(IpsPatch.findPatch(patchesDirectory: patchesDir, romURL: rom, crc32: 0xDEADBEEF)?.path == beside.path)
    }
}
