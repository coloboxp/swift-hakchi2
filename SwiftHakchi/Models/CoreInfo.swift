import Foundation

/// An emulator core that can run games (port of Hakchi2-CE's `CoreCollection.CoreInfo`).
struct CoreInfo: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case builtIn, libretro
    }

    /// Key that identifies the core, e.g. "km_mgba" (from `km_mgba_libretro.info`)
    /// or "clover-canoe-shvc-wr -rom" for built-in emulators. Stored in metadata.json.
    let bin: String
    var name: String
    var displayName: String
    /// Lowercased, with leading dot
    var extensions: [String]
    /// libretro system names this core can emulate
    var systems: [String]
    var kind: Kind
    var defaultArgs: String = ""
    /// File name of the launcher in /bin on the console
    var command: String

    var id: String { bin }

    /// Program to put at the start of the Exec line
    var qualifiedBin: String { "/bin/" + command }

    /// Name shown in pickers
    var label: String { displayName.isEmpty ? name : displayName }

    // MARK: - Built-in emulators (CE's BuiltInCores.List)

    static let builtIn: [CoreInfo] = [
        CoreInfo(bin: "clover-canoe-shvc-wr -rom", name: "Canoe",
                 displayName: "Nintendo - Super Nintendo Entertainment System (Canoe)",
                 extensions: [".sfrom", ".smc", ".sfc"],
                 systems: ["Nintendo - Super Nintendo Entertainment System"], kind: .builtIn,
                 defaultArgs: "--volume 100 -rollback-snapshot-period 600",
                 command: "clover-canoe-shvc-wr -rom"),
        CoreInfo(bin: "clover-kachikachi-wr", name: "Kachikachi",
                 displayName: "Nintendo - Nintendo Entertainment System (Kachikachi)",
                 extensions: [".nes", ".fds", ".qd"],
                 systems: ["Nintendo - Nintendo Entertainment System", "Nintendo - Family Computer Disk System"],
                 kind: .builtIn,
                 defaultArgs: "--guest-overscan-dimensions 0,0,9,3 --initial-fadein-durations 10,2 --volume 75 --enable-armet",
                 command: "clover-kachikachi-wr"),
        CoreInfo(bin: "m2engage", name: "M2engage", displayName: "Sega - Genesis / Mega Drive (M2engage)",
                 extensions: [".bin"], systems: ["Sega - Mega Drive - Genesis"], kind: .builtIn,
                 command: "m2engage"),
        CoreInfo(bin: "hsqs", name: "SquashFS", displayName: "SquashFS Image Mount",
                 extensions: [".hsqs"], systems: ["SquashFS"], kind: .builtIn, command: "hsqs"),
        CoreInfo(bin: "sh", name: "Bash", displayName: "Bash Script Runner",
                 extensions: [".sh"], systems: ["Shell Script"], kind: .builtIn, command: "sh"),
    ]

    /// libretro core key → launcher name installed by the RetroArch hmods (CE's `CoreCommands`)
    static let commandTranslation: [String: String] = [
        "bsnes_mercury_performance": "bsnes", "dosbox_svn": "dosbox-svn", "emux_chip8": "ch8",
        "fbalpha": "fba2016", "fbalpha2012": "fba2012", "fbalpha2012_cps1": "cps1",
        "fbalpha2012_cps2": "cps2", "fbalpha2012_cps3": "cps3", "fbalpha2012_neogeo": "neo",
        "genesis_plus_gx": "genesis-plus-gx", "mame2003_plus": "mame2003-plus", "mednafen_ngp": "ngp",
        "mednafen_pce_fast": "pce", "mednafen_pcfx": "pcfx", "mednafen_saturn": "mednafen-saturn",
        "mednafen_supergrafx": "sgfx", "mednafen_vb": "vb", "mednafen_wswan": "ws", "msu": "snes9x",
        "pcsx_rearmed_neon": "pcsx", "snes9x2002": "snes02", "snes9x2005": "snes05",
        "snes9x2010": "snes10", "snes9x_bright": "snes9x-bright", "vba_next": "vba-next",
        "vice_x64": "c64",
    ]

    // MARK: - .info parsing

    /// Parse a libretro `.info` file. `fileName` must end in `_libretro.info`.
    /// `installedCommands` (the console's /bin listing, if known) picks the launcher name.
    static func parseInfo(_ text: String, fileName: String, installedCommands: Set<String> = []) -> CoreInfo? {
        guard let range = fileName.range(of: "_libretro.info", options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        let bin = String(fileName[..<range.lowerBound])
        guard !bin.isEmpty else { return nil }

        // key = "value" (quotes optional), same as CE's regex
        var values: [String: String] = [:]
        let regex = try! NSRegularExpression(pattern: #"^([^\s]+)\s+=\s+"?([^"\r\n]*)"?"#, options: .anchorsMatchLines)
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            values[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: m.range(at: 2))
        }

        let split = { (s: String?) -> [String] in
            (s ?? "").split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        var systems = split(values["database"])
        if systems.isEmpty, let systemName = values["systemname"], !systemName.isEmpty {
            systems = [systemName]
        }

        return CoreInfo(
            bin: bin,
            name: values["corename"] ?? bin,
            displayName: values["display_name"] ?? "",
            extensions: split(values["supported_extensions"]).map { "." + $0.lowercased() },
            systems: systems,
            kind: .libretro,
            command: resolveCommand(bin: bin, installedCommands: installedCommands)
        )
    }

    /// Launcher name for a core. Candidates, first one present in /bin wins:
    /// the key, CE's translation, and for KMFD cores the name without "km_"
    /// (plain and with dashes, e.g. km_snes9x_bright → snes9x-bright).
    /// Without a /bin listing: the translation if CE has one, else the key.
    static func resolveCommand(bin: String, installedCommands: Set<String>) -> String {
        let stripped = bin.hasPrefix("km_") ? String(bin.dropFirst(3)) : bin
        let candidates = [bin, commandTranslation[bin], commandTranslation[stripped], stripped,
                          stripped.replacingOccurrences(of: "_", with: "-")].compactMap { $0 }
        if let found = candidates.first(where: { installedCommands.contains($0) }) {
            return found
        }
        return installedCommands.isEmpty ? (commandTranslation[bin] ?? bin) : bin
    }
}
