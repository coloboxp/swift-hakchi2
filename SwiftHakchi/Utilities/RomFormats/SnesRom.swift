import Foundation

/// SNES ROM handling and SFROM conversion, ported from Hakchi2-CE `Apps/SnesGame.cs`.
///
/// The SNES Classic's emulator (canoe) only runs `.sfrom` files: the raw ROM
/// wrapped between a 48-byte header and a 48-byte footer ("header 2") that tells
/// canoe the ROM type, a per-game preset and enhancement chips.
enum SnesRom {
    enum RomType: UInt8, Equatable {
        case loRom = 0x14
        case hiRom = 0x15
    }

    /// canoe binary used by the SNES Classic
    static let canoeApplication = "/bin/clover-canoe-shvc-wr -rom"
    /// CE's `DefaultCanoeArgs`
    static let defaultCanoeArgs = "--volume 100 -rollback-snapshot-period 600"

    static let superFxTypes: Set<UInt8> = [0x13, 0x14, 0x15, 0x1A]
    static let dsp1Types: Set<UInt8> = [0x03, 0x05]
    static let sa1Types: Set<UInt8> = [0x34, 0x35]

    /// canoe preset IDs for games Nintendo shipped, keyed by internal header title.
    /// Entries CE commented out (to let hacks and translations work) are left out.
    static let knownPresets: [String: UInt16] = [
        "SUPER MARIOWORLD": 0x1011,
        "F-ZERO": 0x1018,
        "SUPER MARIO KART": 0x10BD,
        "Super Metroid": 0x1040,
        "EARTH BOUND": 0x1070,
        "Kirby's Dream Course": 0x1058,
        "DONKEY KONG COUNTRY": 0x1077,
        "KIRBY SUPER DELUXE": 0x109F,
        "Super Punch-Out!!": 0x10A9,
        "MEGAMAN X": 0x1109,
        "SUPER GHOULS'N GHOST": 0x1003,
        "Street Fighter2 Turb": 0x1065,
        "SUPER MARIO RPG": 0x109E,
        "FINAL FANTASY 3": 0x10DC,
        "SUPER CASTLEVANIA 4": 0x1030,
        "CONTRA3 THE ALIEN WA": 0x1036,
        "STAR FOX": 0x1242,
        "STARFOX2": 0x123C,
        "SHVC FIREEMBLEM": 0x102B,
        "SUPER DONKEY KONG": 0x1023,
        "ROCKMAN X": 0x110A,
        "CHOHMAKAIMURA": 0x1004,
        "SeikenDensetsu 2": 0x10B2,
        "FINAL FANTASY 6": 0x10DD,
        "CONTRA SPIRITS": 0x1037,
        "ganbare goemon": 0x1048,
        "SUPER FORMATION SOCC": 0x1240,
        "YOSSY'S ISLAND": 0x1243,
        "FINAL FIGHT": 0x100E,
        "DIDDY'S KONG QUEST": 0x105D,
        "BREATH OF FIRE 2": 0x1068,
        "FINAL FIGHT 2": 0x10E1,
        "MEGAMAN X2": 0x1117,
        "FINAL FIGHT 3": 0x10E3,
        "GENGHIS KHAN 2": 0x10C4,
        "CASTLEVANIA DRACULA": 0x1131,
        "STREET FIGHTER ALPHA": 0x10DF,
        "MEGAMAN 7": 0x113A,
        "MEGAMAN X3": 0x113D,
        "Breath of Fire": 0x1144,
    ]

    /// Preset used for DSP-1 games without a known preset (Super Mario Kart's)
    static let dsp1Preset: UInt16 = 0x10BD
    /// Preset used for SA-1 games without a known preset (Super Mario RPG's)
    static let sa1Preset: UInt16 = 0x109C
    /// Chip byte for Super FX games
    static let superFxChip: UInt8 = 0x0C

    /// Titles canoe is known to run badly; CE offers a third-party emulator instead.
    /// Titles are as decoded by .NET ASCII (non-ASCII bytes become "?").
    static let problemGames: Set<String> = [
        "ActRaiser-2 USA", "ALIEN vs. PREDATOR", "ASTERIX", "BATMAN--REVENGE JOKER",
        "???????S???????????", "CHAMPIONSHIP POOL", "ClayFighter 2", "CLOCK TOWER SFX",
        "COOL WORLD", "CRYSTAL BEANS", "CYBER KNIGHT 2", "ASCII DARK LAW", "DIRT TRAX FX",
        "DBZ HYPER DIMENSION", "DRAGON BALL Z HD", "DRAGONBALL Z 2", "SFX DRAGONBALLZ2",
        "SFX SUPERBUTOUDEN2", "DUNGEON MASTER", "EARTHWORM JIM 2", "F1 WORLD CHAMP EDTION",
        "FACEBALL 2000", "THE FIREMEN     PAL", "HAMMERIN' HARRY (JPN)", "HARMELUNNOBAIOLINHIKI",
        "HOME ALONE", "HUMAN GRANDPRIX", "HUMAN GRANDPRIX 3", "ILLUSION OF GAIA USA",
        "ILLUSION OF TIME ENG", "JumpinDerby", "KRUSTYS SUPERFUNHOUSE", "Mario's Time Machine",
        "MARKOS MAGIC FOOTBALL", "POWER RANGERS FIGHT", "MOMOTETSU HAPPY", "NHL HOCKEY 1998",
        "RENDERING RANGER R2", "ROBOTREK 1 USA", "ROMANCING SAGA3", "SD??????GX",
        "SECRET OF EVERMORE", "SIM CITY 2000", "SMASH TENNIS", "Star Ocean",
        "STREET FIGHTER ALPHA2", "SUPER BASES LOADED 2", "PANIC BOMBER WORLD",
        "TALES OF PHANTASIA", "TERRANIGMA P", "TOP GEAR 3000", "UNIRACERS", "WARIO'S WOODS",
        "WORLD CLASS RUGBY", "WORLD CUP STRIKER", "WORLD MASTERS GOLF", "WWF SUPER WRESTLEMANI",
        "WRESTLEMANIA", "SENSIBLE SOCCER",
    ]

    enum SnesError: Error, Equatable {
        /// The ROM is too small to hold a header at 0xFFC0
        case romTooSmall
        /// Neither LoROM nor HiROM header looks valid (CE: "seems like ROM is corrupted")
        case cannotDetectRomType
        /// Not an SFROM file (too short for its headers)
        case invalidSfrom
    }

    // MARK: - Internal ROM header

    /// The 32-byte internal header at 0x7FC0 (LoROM) or 0xFFC0 (HiROM)
    struct RomHeader: Equatable {
        static let size = 32

        var titleBytes: [UInt8]   // 21 bytes
        var romMakeup: UInt8      // $xFD5
        var romType: UInt8        // $xFD6 (chipset)
        var romSize: UInt8        // $xFD7
        var sramSize: UInt8       // $xFD8
        var country: UInt8        // $xFD9
        var license: UInt8        // $xFDA
        var version: UInt8        // $xFDB
        var checksumComplement: UInt16 // $xFDC
        var checksum: UInt16      // $xFDE

        /// Read at `offset`; throws if the buffer is too short (CE throws too)
        init(_ d: [UInt8], at offset: Int) throws {
            guard d.count >= offset + Self.size else { throw SnesError.romTooSmall }
            titleBytes = Array(d[offset..<(offset + 21)])
            romMakeup = d[offset + 21]
            romType = d[offset + 22]
            romSize = d[offset + 23]
            sramSize = d[offset + 24]
            country = d[offset + 25]
            license = d[offset + 26]
            version = d[offset + 27]
            checksumComplement = UInt16(d[offset + 28]) | UInt16(d[offset + 29]) << 8
            checksum = UInt16(d[offset + 30]) | UInt16(d[offset + 31]) << 8
        }

        /// Game title as CE reads it: empty when it contains 0x00 or 0xFF or starts
        /// with a space; trailing spaces removed; non-ASCII bytes become "?".
        var title: String {
            if titleBytes.contains(0) || titleBytes.contains(0xFF) || titleBytes.first == 0x20 {
                return ""
            }
            var bytes = titleBytes
            while let last = bytes.last, last == 0x20 { bytes.removeLast() }
            return String(bytes.map { $0 < 0x80 ? Character(UnicodeScalar($0)) : "?" })
        }

        var checksumValid: Bool { (checksum ^ 0xFFFF) == checksumComplement }
        var checksumInvalidOrZero: Bool { !checksumValid || checksum == 0 || checksumComplement == 0 }
    }

    /// Detect LoROM vs HiROM and return the matching header and title.
    /// Port of CE's `GetCorrectHeader`, including its fallback rules.
    static func detectHeader(_ rom: Data) throws -> (header: RomHeader, type: RomType, title: String) {
        let d = [UInt8](rom)
        let lo = try RomHeader(d, at: 0x7FC0)
        let hi = try RomHeader(d, at: 0xFFC0)
        let titleLo = lo.title
        let titleHi = hi.title

        let type: RomType
        if lo.checksumValid && hi.checksumInvalidOrZero {
            type = .loRom
        } else if lo.checksumInvalidOrZero && hi.checksumValid {
            type = .hiRom
        } else if !titleLo.isEmpty && titleHi.isEmpty {
            type = .loRom
        } else if titleLo.isEmpty && !titleHi.isEmpty {
            type = .hiRom
        } else if titleLo == titleHi && (lo.romMakeup & 1) == 0 {
            type = .loRom
        } else if titleLo == titleHi && (hi.romMakeup & 1) == 1 {
            type = .hiRom
        } else {
            // CE's gamesLoRom/gamesHiRom lists are empty, so go straight to the
            // printable-title test
            let printable = { (s: String) in s.unicodeScalars.allSatisfy { $0.value >= 31 && $0.value <= 127 } }
            let loOk = printable(titleLo)
            let hiOk = printable(titleHi)
            if loOk && !hiOk {
                type = .loRom
            } else if !loOk && hiOk {
                type = .hiRom
            } else {
                throw SnesError.cannotDetectRomType
            }
        }
        return type == .loRom ? (lo, .loRom, titleLo) : (hi, .hiRom, titleHi)
    }

    // MARK: - SFROM headers

    /// 48-byte SFROM header at offset 0. Port of CE's `SfromHeader1`.
    struct SfromHeader1: Equatable {
        static let size = 48

        var unknown1: UInt32 = 0x0000_0100
        var fileSize: UInt32
        var unknown2: UInt32 = 0x0000_0030
        var romEnd: UInt32
        var footerStart: UInt32
        /// Offset of `SfromHeader2`
        var header2: UInt32
        var header3: UInt32
        var unknown3: UInt32 = 0
        var flags: UInt32
        var vcGameID: [UInt8]  // 8 bytes, "WUP-XXXX"
        var unknown4: UInt32 = 0

        init(romSize: UInt32) {
            fileSize = romSize + UInt32(Self.size) + UInt32(SfromHeader2.size)
            romEnd = UInt32(Self.size) + romSize
            footerStart = fileSize
            header2 = romEnd
            header3 = fileSize
            flags = romEnd + 27
            vcGameID = Array("WUP-XXXX".utf8)
        }

        /// Read from a buffer; missing bytes read as zero (CE behaviour)
        init(_ data: Data, at offset: Int = 0) {
            let b = Self.padded(data, offset, Self.size)
            unknown1 = b.u32(0); fileSize = b.u32(4); unknown2 = b.u32(8); romEnd = b.u32(12)
            footerStart = b.u32(16); header2 = b.u32(20); header3 = b.u32(24); unknown3 = b.u32(28)
            flags = b.u32(32); vcGameID = Array(b[36..<44]); unknown4 = b.u32(44)
        }

        func bytes() -> Data {
            var w = ByteWriter()
            w.u32(unknown1); w.u32(fileSize); w.u32(unknown2); w.u32(romEnd)
            w.u32(footerStart); w.u32(header2); w.u32(header3); w.u32(unknown3)
            w.u32(flags); w.bytes(vcGameID, count: 8); w.u32(unknown4)
            return w.data
        }

        fileprivate static func padded(_ data: Data, _ offset: Int, _ size: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: size)
            let d = [UInt8](data)
            let n = max(0, min(size, d.count - offset))
            if n > 0 { out.replaceSubrange(0..<n, with: d[offset..<(offset + n)]) }
            return out
        }
    }

    /// 48-byte SFROM footer ("header 2"), packed. Port of CE's `SfromHeader2`.
    struct SfromHeader2: Equatable {
        static let size = 48

        var fps: UInt8 = 60
        var romSize: UInt32
        var pcmSize: UInt32 = 0
        var footerSize: UInt32 = 0
        var presetID: UInt16
        var maxControllers: UInt8 = 2
        var volume: UInt8 = 0x5A
        var romType: UInt8
        /// Enhancement chip (CE stores it as UInt32; the editor shows the low byte)
        var chip: UInt32
        var padding1: [UInt8] = Array(repeating: 0, count: 5)
        var unknown3: UInt32 = 1
        var unknown4: UInt32 = 1
        var padding2: [UInt8] = Array(repeating: 0, count: 13)

        init(romSize: UInt32, presetID: UInt16, romType: RomType, chip: UInt8) {
            self.romSize = romSize
            self.presetID = presetID
            self.romType = romType.rawValue
            self.chip = UInt32(chip)
        }

        /// Read from a buffer; missing bytes read as zero (CE behaviour)
        init(_ data: Data, at offset: Int) {
            let b = SfromHeader1.padded(data, offset, Self.size)
            fps = b[0]; romSize = b.u32(1); pcmSize = b.u32(5); footerSize = b.u32(9)
            presetID = UInt16(b[13]) | UInt16(b[14]) << 8
            maxControllers = b[15]; volume = b[16]; romType = b[17]; chip = b.u32(18)
            padding1 = Array(b[22..<27]); unknown3 = b.u32(27); unknown4 = b.u32(31)
            padding2 = Array(b[35..<48])
        }

        func bytes() -> Data {
            var w = ByteWriter()
            w.u8(fps); w.u32(romSize); w.u32(pcmSize); w.u32(footerSize)
            w.u16(presetID); w.u8(maxControllers); w.u8(volume); w.u8(romType)
            w.u32(chip); w.bytes(padding1, count: 5); w.u32(unknown3); w.u32(unknown4)
            w.bytes(padding2, count: 13)
            return w.data
        }
    }

    // MARK: - Conversion

    /// Result of `makeSfrom`
    struct SfromResult: Equatable {
        var data: Data
        var romType: RomType
        var title: String
        var presetID: UInt16
        var chip: UInt8
        /// 3 when the game has SRAM, else 0
        var saveCount: Int
        /// Title is in `problemGames`
        var isProblemGame: Bool
    }

    /// Wrap a headerless ROM into SFROM. Port of CE's `MakeSfrom`.
    static func makeSfrom(_ rom: Data) throws -> SfromResult {
        let (header, type, title) = try detectHeader(rom)
        var preset: UInt16 = 0
        var chip: UInt8 = 0
        if superFxTypes.contains(header.romType) {
            chip = superFxChip
        }
        if let known = knownPresets[title] {
            preset = known
        } else {
            if dsp1Types.contains(header.romType) { preset = dsp1Preset }
            if sa1Types.contains(header.romType) { preset = sa1Preset }
        }

        let size = UInt32(rom.count)
        let out = SfromHeader1(romSize: size).bytes()
            + rom
            + SfromHeader2(romSize: size, presetID: preset, romType: type, chip: chip).bytes()

        return SfromResult(
            data: out, romType: type, title: title, presetID: preset, chip: chip,
            saveCount: header.sramSize > 0 ? 3 : 0,
            isProblemGame: problemGames.contains(title)
        )
    }

    /// Remove a 512-byte copier header (present when size % 1024 != 0)
    static func stripCopierHeader(_ data: Data) -> (data: Data, stripped: Bool) {
        guard data.count % 1024 != 0, data.count >= 512 else { return (data, false) }
        return (Data(data.dropFirst(512)), true)
    }

    // MARK: - Import (SnesGame.Patch)

    /// Blank cover CE picks from the file name
    enum CoverHint: Equatable {
        case standard
        /// "(E)" or "(J)" in the file name
        case europeJapan
    }

    /// Result of preparing a SNES ROM for import
    struct ImportResult: Equatable {
        /// Data to write: `.sfrom` when converted, else the (header-stripped) ROM
        var data: Data
        /// CRC32 for the game code: of the header-stripped ROM, before any patch
        var crc32: UInt32
        /// New file extension (".sfrom") when converted, nil to keep the original
        var outputExtension: String?
        /// canoe binary and arguments, nil to keep the system default
        var application: String?
        var args: String?
        /// 3 / 0 from the SRAM size when converted, nil to keep the default
        var saveCount: Int?
        var coverHint: CoverHint
        /// canoe has trouble with this game. `application` is still canoe; CE asks
        /// whether to keep the system default (e.g. snes9x) instead.
        var isProblemGame: Bool
        var sfrom: SfromResult?
    }

    /// Port of CE's `SnesGame.Patch` (built-in conversion; SFROM Tool is Windows-only).
    ///
    /// - Parameters:
    ///   - data: the file contents
    ///   - fileName: original file name (extension and cover hint)
    ///   - convertToSfrom: CE's "Convert SNES ROMs to SFROM" setting. When off, CE
    ///     only strips the copier header and applies no IPS patch.
    ///   - patchProvider: tried once with the header-stripped CRC32 before conversion
    static func prepareForImport(
        data: Data, fileName: String, convertToSfrom: Bool, patchProvider: RomPatchProvider? = nil
    ) throws -> ImportResult {
        let hint: CoverHint = (fileName.contains("(E)") || fileName.contains("(J)")) ? .europeJapan : .standard

        if (fileName as NSString).pathExtension.lowercased() == "sfrom" {
            return ImportResult(data: data, crc32: CRC32.checksum(data), outputExtension: nil,
                                application: canoeApplication, args: defaultCanoeArgs,
                                saveCount: nil, coverHint: hint, isProblemGame: false, sfrom: nil)
        }

        let (rom, _) = stripCopierHeader(data)
        let crc = CRC32.checksum(rom)
        guard convertToSfrom else {
            return ImportResult(data: rom, crc32: crc, outputExtension: nil, application: nil,
                                args: nil, saveCount: nil, coverHint: hint, isProblemGame: false, sfrom: nil)
        }

        let patched = patchProvider?(rom, crc) ?? rom
        let sfrom = try makeSfrom(patched)
        return ImportResult(
            data: sfrom.data, crc32: crc, outputExtension: "sfrom",
            application: canoeApplication, args: defaultCanoeArgs,
            saveCount: sfrom.saveCount, coverHint: hint,
            isProblemGame: sfrom.isProblemGame, sfrom: sfrom
        )
    }

    // MARK: - SFROM header editor (SnesPresetEditor)

    /// Read the footer of an `.sfrom` file (its offset comes from header 1)
    static func readSfromHeader2(_ sfrom: Data) throws -> SfromHeader2 {
        guard sfrom.count >= SfromHeader1.size else { throw SnesError.invalidSfrom }
        let h1 = SfromHeader1(sfrom)
        return SfromHeader2(sfrom, at: Int(h1.header2))
    }

    /// Write a footer back into an `.sfrom` file at the offset from header 1
    static func writeSfromHeader2(_ header: SfromHeader2, into sfrom: Data) throws -> Data {
        let h1 = SfromHeader1(sfrom)
        let offset = Int(h1.header2)
        guard sfrom.count >= SfromHeader1.size, offset >= 0, offset + SfromHeader2.size <= sfrom.count else {
            throw SnesError.invalidSfrom
        }
        var out = sfrom
        out.replaceSubrange(offset..<(offset + SfromHeader2.size), with: header.bytes())
        return out
    }

    /// Preset ID and chip byte, as the CE preset editor shows them
    static func readPreset(_ sfrom: Data) throws -> (presetID: UInt16, chip: UInt8) {
        let h2 = try readSfromHeader2(sfrom)
        return (h2.presetID, UInt8(truncatingIfNeeded: h2.chip))
    }

    /// Change the preset ID and chip byte (the editor's "extra" field)
    static func writePreset(_ sfrom: Data, presetID: UInt16, chip: UInt8) throws -> Data {
        var h2 = try readSfromHeader2(sfrom)
        h2.presetID = presetID
        h2.chip = UInt32(chip)
        return try writeSfromHeader2(h2, into: sfrom)
    }
}

// MARK: - Little-endian helpers

private struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { for i in 0..<4 { data.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    /// Exactly `count` bytes: truncated or zero-padded
    mutating func bytes(_ b: [UInt8], count: Int) {
        data.append(contentsOf: b.prefix(count))
        if b.count < count { data.append(contentsOf: [UInt8](repeating: 0, count: count - b.count)) }
    }
}

private extension Array where Element == UInt8 {
    func u32(_ i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
