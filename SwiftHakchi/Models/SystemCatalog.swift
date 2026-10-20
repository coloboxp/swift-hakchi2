import Foundation

/// An emulated system that games can belong to (port of Hakchi2-CE's `AppTypeCollection.AppInfo`).
///
/// `name` uses libretro database names (e.g. "Nintendo - Game Boy"), so it matches
/// the `database` field of core `.info` files and `metadata.json`'s `System` key.
struct EmulatedSystem: Hashable, Sendable {
    /// How a ROM of this system is prepared at import time
    enum Kind: Hashable, Sendable {
        case nes, fds, snes, megaDrive, libretro, other
    }

    let name: String
    let kind: Kind
    /// Core bin key used when no core was chosen (see `CoreCatalog`)
    let defaultCore: String
    /// Exec prefixes used by older hakchi versions, to classify existing games
    let legacyApps: [String]
    /// Lowercased, with leading dot
    let extensions: [String]
    /// Letter in the game code: CLV-<prefix>-XXXXX
    let prefix: Character
    /// Search hint used for box-art lookups
    let searchSuffix: String

    var isUnknown: Bool { self == SystemCatalog.unknown }
}

/// The list of systems Hakchi2-CE knows about, with the same order and values.
/// Order matters: lookups return the first match (so `.md` → m2engage, like CE).
enum SystemCatalog {
    static let unknown = EmulatedSystem(
        name: "Unknown System", kind: .other, defaultCore: "", legacyApps: [],
        extensions: [], prefix: "Z", searchSuffix: "game")

    static let all: [EmulatedSystem] = [
        EmulatedSystem(name: "Nintendo - Nintendo Entertainment System", kind: .nes, defaultCore: "fceumm",
                       legacyApps: ["/bin/nes", "/bin/clover-kachikachi-wr", "/usr/bin/clover-kachikachi"],
                       extensions: [".nes"], prefix: "H", searchSuffix: "(fds | nes | famicom)"),
        EmulatedSystem(name: "Nintendo - Family Computer Disk System", kind: .fds, defaultCore: "nestopia",
                       legacyApps: ["/bin/fds", "/bin/clover-kachikachi-wr", "/usr/bin/clover-kachikachi"],
                       extensions: [".fds", ".qd"], prefix: "D", searchSuffix: "(fds | nes | famicom)"),
        EmulatedSystem(name: "Nintendo - Super Nintendo Entertainment System", kind: .snes, defaultCore: "snes9x",
                       legacyApps: ["/bin/snes", "/bin/clover-canoe-shvc-wr -rom", "/usr/bin/clover-canoe-shvc -rom"],
                       extensions: [".sfrom", ".smc", ".sfc", ".fig", ".swc"], prefix: "U",
                       searchSuffix: "(snes | super nintendo)"),
        EmulatedSystem(name: "Nintendo - Nintendo 64", kind: .libretro, defaultCore: "glupen64",
                       legacyApps: ["/bin/n64"], extensions: [".n64", ".z64", ".v64"], prefix: "6",
                       searchSuffix: "nintendo 64"),
        EmulatedSystem(name: "Nintendo - Game Boy", kind: .libretro, defaultCore: "gambatte",
                       legacyApps: ["/bin/gb"], extensions: [".gb", ".sgb"], prefix: "B",
                       searchSuffix: "(gameboy | game boy)"),
        EmulatedSystem(name: "Nintendo - Game Boy Color", kind: .libretro, defaultCore: "gambatte",
                       legacyApps: ["/bin/gbc"], extensions: [".gbc"], prefix: "C",
                       searchSuffix: "(gameboy | game boy)"),
        EmulatedSystem(name: "Nintendo - Game Boy Advance", kind: .libretro, defaultCore: "mgba",
                       legacyApps: ["/bin/gba"], extensions: [".gba"], prefix: "A", searchSuffix: "gba"),
        EmulatedSystem(name: "Sega - Master System - Mark III", kind: .libretro, defaultCore: "genesis_plus_gx",
                       legacyApps: ["/bin/sms"], extensions: [".sms"], prefix: "M",
                       searchSuffix: "(sms | sega master system)"),
        EmulatedSystem(name: "Sega - Mega Drive - Genesis", kind: .megaDrive, defaultCore: "m2engage",
                       legacyApps: ["/bin/m2engage"],
                       extensions: [".md", ".mdx", ".smd", ".gen", ".68k", ".bin"], prefix: "G",
                       searchSuffix: "(genesis | mega drive)"),
        EmulatedSystem(name: "Sega - Mega Drive - Genesis", kind: .libretro, defaultCore: "genesis_plus_gx",
                       legacyApps: ["/bin/md"], extensions: [".md", ".mdx", ".smd", ".gen", ".68k"], prefix: "G",
                       searchSuffix: "(genesis | mega drive)"),
        EmulatedSystem(name: "Sega - 32X", kind: .libretro, defaultCore: "picodrive",
                       legacyApps: ["/bin/32x"], extensions: [".32x"], prefix: "3", searchSuffix: "sega 32x"),
        EmulatedSystem(name: "Sega - Game Gear", kind: .libretro, defaultCore: "genesis_plus_gx",
                       legacyApps: ["/bin/gg"], extensions: [".gg", ".sg"], prefix: "R", searchSuffix: "game gear"),
        EmulatedSystem(name: "NEC - PC Engine - TurboGrafx 16", kind: .libretro, defaultCore: "mednafen_pce_fast",
                       legacyApps: ["/bin/pce"], extensions: [".pce"], prefix: "E",
                       searchSuffix: "(pce | pc engine | turbografx 16)"),
        EmulatedSystem(name: "NEC - PC Engine SuperGrafx", kind: .libretro, defaultCore: "mednafen_supergrafx",
                       legacyApps: [], extensions: [".sgx"], prefix: "E",
                       searchSuffix: "(pce | pc engine | supergrafx 16)"),
        EmulatedSystem(name: "Atari - 2600", kind: .libretro, defaultCore: "stella",
                       legacyApps: ["/bin/a26"], extensions: [".a26"], prefix: "T", searchSuffix: "atari 2600"),
        EmulatedSystem(name: "DOS", kind: .libretro, defaultCore: "dosbox",
                       legacyApps: [], extensions: [".bat", ".com", ".exe", ".conf"], prefix: "O",
                       searchSuffix: "(dos | dosbox)"),
        EmulatedSystem(name: "Neo Geo", kind: .libretro, defaultCore: "fbalpha2012_neogeo",
                       legacyApps: [], extensions: [], prefix: "N", searchSuffix: "neo geo"),
        EmulatedSystem(name: "SquashFS", kind: .other, defaultCore: "hsqs",
                       legacyApps: ["/bin/hsqs"], extensions: [".hsqs"], prefix: "L", searchSuffix: ""),
        EmulatedSystem(name: "Shell Script", kind: .other, defaultCore: "sh",
                       legacyApps: ["/bin/sh"], extensions: [".sh"], prefix: "L", searchSuffix: ""),
        EmulatedSystem(name: "Nintendo - Super Nintendo Entertainment System (MSU-1)", kind: .libretro,
                       defaultCore: "msu", legacyApps: ["/bin/snes9x"], extensions: [".msu"], prefix: "U",
                       searchSuffix: "(snes | super nintendo)"),
    ]

    /// libretro systems that are ignored when guessing a system from an extension,
    /// because they duplicate a main system (CE's `SystemCollection.RedundancyList`)
    static let redundantSystems: Set<String> = [
        "Bandai - WonderSwan Color", "Microsoft - MSX2", "NEC - PC Engine CD - TurboGrafx-CD",
        "Nintendo - Game Boy Advance (e-Cards)", "Nintendo - Nintendo 64DD", "Nintendo - Sufami Turbo",
        "Nintendo - Super Nintendo Entertainment System Hacks", "Sega - PICO", "Sinclair - ZX Spectrum +3",
        "SNK - Neo Geo Pocket Color",
    ]

    private static let usedPrefixes: Set<Character> = Set(all.map(\.prefix))

    /// First system that lists `ext` (with or without the dot), or `unknown`
    static func system(forExtension ext: String) -> EmulatedSystem {
        let e = normalizedExtension(ext)
        return all.first { $0.extensions.contains(e) } ?? unknown
    }

    /// System by its libretro name (case-insensitive), or `unknown`
    static func system(named name: String) -> EmulatedSystem {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        return all.first { $0.name.lowercased() == n } ?? unknown
    }

    /// Classify an existing game by its Exec line using the legacy app list
    static func system(forExec exec: String) -> EmulatedSystem {
        // Same normalization as CE: drop quotes and ".7z", pad with a space
        let cleaned = exec.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"['"]|(\.7z)"#, with: " ", options: .regularExpression) + " "
        for system in all {
            for bin in system.legacyApps where cleaned.hasPrefix(bin + " ") {
                if system.extensions.isEmpty { return system }
                if system.extensions.contains(where: { cleaned.contains($0 + " ") }) { return system }
            }
        }
        return unknown
    }

    /// A code prefix not used by any known system, derived from `source` (CE's `GetAvailablePrefix`)
    static func availablePrefix(for source: String) -> Character {
        let letters = source.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if let free = letters.first(where: { !usedPrefixes.contains($0) }) { return free }

        var letter: Character = letters.first ?? "Z"
        while usedPrefixes.contains(letter) {
            let next = (letter.asciiValue ?? 90) + 1
            letter = next > 90 ? "A" : Character(UnicodeScalar(next))
        }
        return letter
    }

    static func normalizedExtension(_ ext: String) -> String {
        let e = ext.lowercased().trimmingCharacters(in: .whitespaces)
        return e.hasPrefix(".") ? e : "." + e
    }
}
