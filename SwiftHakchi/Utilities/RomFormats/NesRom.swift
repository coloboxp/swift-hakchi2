import Foundation
import CryptoKit

/// A callback that looks for an IPS patch for a ROM and applies it.
///
/// Hakchi2-CE's `FindPatch` searches the `patches/` folder by CRC32 or by file
/// name and asks the user before applying. The ROM handlers stay UI-free, so the
/// caller supplies this closure: it receives the current ROM data and the CRC32 to
/// search by, and returns the patched data, or `nil` when no patch was applied.
typealias RomPatchProvider = (_ data: Data, _ crc32: UInt32) -> Data?

/// iNES (`.nes`) ROM file, ported from Hakchi2-CE `Apps/NesFile.cs`.
///
/// Only the original iNES header fields are used, like CE. Headers with junk in
/// bytes 12–15 ("archaic iNES", e.g. "DiskDude!") have bytes 7–15 cleared before
/// parsing, which also drops NES 2.0 extensions. `isNes20` reports whether the
/// header *was* NES 2.0, for information only.
struct NesRom: Equatable {
    /// Nametable mirroring, as in CE's `MirroringType` (raw values match).
    enum Mirroring: UInt8, Equatable {
        case horizontal = 0
        case vertical = 1
        case fourScreen = 2
    }

    /// Fixes applied by `correct()`, as in CE's `NesFixType` flags.
    struct Fixes: OptionSet, Equatable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }
        static let mapper = Fixes(rawValue: 1)
        static let mirroring = Fixes(rawValue: 2)
        static let battery = Fixes(rawValue: 4)
        static let noChr = Fixes(rawValue: 8)
    }

    var prg: Data
    var chr: Data
    /// 512-byte trainer, if the header flag is set
    var trainer: Data?
    var mapper: UInt8
    var mirroring: Mirroring
    var isPal: Bool
    var battery: Bool
    var vsUnisystem: Bool
    var playChoice10: Bool
    /// True when the original header used the NES 2.0 format (bits 2–3 of byte 7 = 0b10)
    let isNes20: Bool

    /// Mappers the NES/Famicom Mini emulator (kachikachi) supports
    static let supportedMappers: Set<UInt8> = [0, 1, 2, 3, 4, 5, 7, 9, 10, 86, 87, 184]

    enum ParseError: Error, Equatable {
        case notINES
    }

    /// Parse an iNES file. Short files are zero-padded like CE does ("bad ROMs").
    init(data input: Data) throws {
        var d = [UInt8](input)
        guard d.count >= 16, d[0] == 0x4E, d[1] == 0x45, d[2] == 0x53, d[3] == 0x1A else {
            throw ParseError.notINES
        }
        isNes20 = (d[7] & 0x0C) == 0x08
        if !(d[12] == 0 && d[13] == 0 && d[14] == 0 && d[15] == 0) {
            // Archaic iNES: ignore everything after byte 6
            for i in 7...15 { d[i] = 0 }
        }

        let prgSize = Int(d[4]) * 16384
        let chrSize = Int(d[5]) * 8192
        var mirroring: Mirroring = (d[6] & 1) != 0 ? .vertical : .horizontal
        battery = (d[6] & 0x02) != 0
        let hasTrainer = (d[6] & 0x04) != 0
        if (d[6] & 0x08) != 0 { mirroring = .fourScreen }
        self.mirroring = mirroring
        mapper = (d[6] >> 4) | (d[7] & 0xF0)
        vsUnisystem = (d[7] & 1) != 0
        playChoice10 = (d[7] & 0x02) != 0
        isPal = (d[9] & 1) != 0

        var offset = 16
        if hasTrainer {
            trainer = Self.slice(d, offset, 512)
            offset += 512
        } else {
            trainer = nil
        }
        prg = Self.slice(d, offset, prgSize)
        offset += prgSize
        chr = Self.slice(d, offset, chrSize)
    }

    /// Copy `count` bytes from `offset`, zero-padding past the end (CE behaviour)
    private static func slice(_ d: [UInt8], _ offset: Int, _ count: Int) -> Data {
        var out = Data(count: count)
        let available = max(0, min(count, d.count - offset))
        if available > 0 {
            out.replaceSubrange(0..<available, with: d[offset..<(offset + available)])
        }
        return out
    }

    /// CRC32 of PRG + CHR (what CE uses for codes, the fix table and patches)
    var crc32: UInt32 {
        CRC32.checksum(prg + chr)
    }

    /// MD5 of PRG + CHR
    var md5: [UInt8] {
        Array(Insecure.MD5.hash(data: prg + chr))
    }

    /// Serialize with a clean iNES 1.0 header (bytes 8–15 zero except the PAL flag).
    ///
    /// Deliberate difference from CE: CE's `GetRaw()` appends the trainer *after*
    /// CHR, which produces a broken file. The trainer is written right after the
    /// header here, where the iNES format expects it. Output is identical to CE for
    /// every ROM without a trainer.
    func rawData() -> Data {
        var header = [UInt8](repeating: 0, count: 16)
        header[0] = 0x4E; header[1] = 0x45; header[2] = 0x53; header[3] = 0x1A
        header[4] = UInt8(truncatingIfNeeded: prg.count / 16384)
        header[5] = UInt8(truncatingIfNeeded: chr.count / 8192)
        if mirroring == .vertical { header[6] |= 1 }
        if battery { header[6] |= 0x02 }
        if trainer != nil { header[6] |= 0x04 }
        if mirroring == .fourScreen { header[6] |= 0x08 }
        header[6] |= UInt8(truncatingIfNeeded: Int(mapper) << 4)
        if vsUnisystem { header[7] |= 1 }
        if playChoice10 { header[7] |= 0x02 }
        header[7] |= mapper & 0xF0
        if isPal { header[9] |= 1 }

        var out = Data(header)
        if let trainer { out += trainer }
        out += prg
        out += chr
        return out
    }

    /// Fix known bad headers (wrong mapper or mirroring, missing CHR removal,
    /// missing battery flag). Port of CE's `CorrectRom()`.
    @discardableResult
    mutating func correct() -> Fixes {
        var fixes: Fixes = []
        let crc = crc32
        for row in Self.fixTable where row.crc == crc {
            if row.mapper >= 0 {
                if (row.mapper & 0x800) != 0 && !chr.isEmpty {
                    chr = Data()
                    fixes.insert(.noChr)
                }
                let wanted = UInt8(row.mapper & 0xFF)
                if mapper != wanted {
                    mapper = wanted
                    fixes.insert(.mapper)
                }
            }
            if row.mirroring >= 0 {
                // 8 = anything but hard-wired four-screen
                if row.mirroring == 8 && mirroring == .fourScreen {
                    mirroring = .horizontal
                    fixes.insert(.mirroring)
                }
                let needed: Mirroring?
                switch row.mirroring {
                case 0: needed = .horizontal
                case 1: needed = .vertical
                case 2: needed = .fourScreen
                default: needed = nil
                }
                if let needed, needed != mirroring {
                    mirroring = needed
                    fixes.insert(.mirroring)
                }
            }
        }

        // Partial MD5 = last 8 bytes, read big-endian
        let hash = md5
        var partial: UInt64 = 0
        for x in 0..<8 {
            partial |= UInt64(hash[15 - x]) << (UInt64(x) * 8)
        }
        if !battery && Self.batteryGames.contains(partial) {
            battery = true
            fixes.insert(.battery)
        }
        return fixes
    }
}

// MARK: - Import (NesGame.Patch)

extension NesRom {
    /// kachikachi binary used by the NES/Famicom Mini
    static let kachikachiApplication = "/bin/clover-kachikachi-wr"
    /// CE's `NesGame.DefaultArgs`
    static let defaultArgs = "--guest-overscan-dimensions 0,0,9,3 --initial-fadein-durations 3,2 --volume 75 --enable-armet"

    /// Problems CE asks the user about before importing (it aborts on "No")
    enum ImportWarning: Equatable {
        case unsupportedMapper(UInt8)
        case fourScreenMirroring
    }

    /// Result of preparing a `.nes` file for import
    struct ImportResult: Equatable {
        /// ROM data to write (rebuilt header, fixes and patches applied)
        var data: Data
        /// CRC32 for the game code. PRG+CHR before fixes when the file is valid iNES,
        /// otherwise the CRC32 of the original file.
        var crc32: UInt32
        /// False when the file has no iNES header; CE then imports it unchanged and
        /// keeps the system's default core.
        var isValidINES: Bool
        /// Emulator binary and arguments, or nil to keep the system default
        var application: String?
        var args: String?
        /// 3 when the game uses battery saves, nil to keep the default
        var saveCount: Int?
        /// File name contains "(J)": use the Japanese blank cover
        var useJapaneseCover: Bool
        var warnings: [ImportWarning]
        var fixes: Fixes
        /// An IPS patch was applied
        var patched: Bool
    }

    /// Port of CE's `NesGame.Patch`.
    ///
    /// - Parameters:
    ///   - data: the file contents
    ///   - fileName: original file name (only used for the "(J)" cover hint)
    ///   - patchProvider: finds and applies an IPS patch; tried first with the file's
    ///     CRC32, then with the PRG+CHR CRC32 if the first try found nothing
    static func prepareForImport(
        data: Data, fileName: String, patchProvider: RomPatchProvider? = nil
    ) -> ImportResult {
        let fileCrc = CRC32.checksum(data)
        var data = data
        var patched = false
        if let p = patchProvider?(data, fileCrc) {
            data = p
            patched = true
        }

        guard var rom = try? NesRom(data: data) else {
            return ImportResult(data: data, crc32: fileCrc, isValidINES: false,
                                application: nil, args: nil, saveCount: nil,
                                useJapaneseCover: false, warnings: [], fixes: [], patched: patched)
        }
        let crc = rom.crc32

        // Also search for a patch by the internal CRC32
        if !patched, let p = patchProvider?(data, crc), let reparsed = try? NesRom(data: p) {
            data = p
            rom = reparsed
            patched = true
        }
        let fixes = rom.correct()

        var warnings: [ImportWarning] = []
        if !supportedMappers.contains(rom.mapper) {
            warnings.append(.unsupportedMapper(rom.mapper))
        }
        if rom.mirroring == .fourScreen {
            warnings.append(.fourScreenMirroring)
        }

        return ImportResult(
            data: rom.rawData(),
            crc32: crc,
            isValidINES: true,
            application: kachikachiApplication,
            args: defaultArgs,
            saveCount: rom.battery ? 3 : nil,
            useJapaneseCover: fileName.contains("(J)"),
            warnings: warnings,
            fixes: fixes,
            patched: patched
        )
    }
}
