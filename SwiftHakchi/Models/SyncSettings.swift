import Foundation

/// Menu structure modes (port of Hakchi2-CE's `NesMenuCollection.SplitStyle`, same raw values)
enum SplitStyle: Int, Codable, CaseIterable, Sendable {
    case noSplit = 0
    case originalNoSplit = 1
    case auto = 2
    case originalAuto = 3
    case pagesEqual = 4
    case originalPagesEqual = 5
    case foldersEqual = 6
    case originalFoldersEqual = 7
    case foldersAlphabeticFoldersEqual = 8
    case originalFoldersAlphabeticFoldersEqual = 9
    case foldersAlphabeticPagesEqual = 10
    case originalFoldersAlphabeticPagesEqual = 11
    case foldersGroupByApp = 12
    case foldersGroupByGenre = 13
    case foldersGroupByRegion = 14
    case custom = 99

    /// Modes offered in CE's "Structure" menu, in its order, with its labels
    static let menuModes: [(SplitStyle, String)] = [
        (.noSplit, "Disable page/folders"),
        (.custom, "Custom - Use folders manager"),
        (.auto, "Automatic"),
        (.originalAuto, "Original games in root -> Automatic in subfolder"),
        (.pagesEqual, "Pages, split games equally"),
        (.originalPagesEqual, "Original games in root -> Pages, split games equally"),
        (.foldersEqual, "Folders, split games equally"),
        (.originalFoldersEqual, "Original games in root -> Folders, split games equally"),
        (.foldersAlphabeticFoldersEqual, "Folders, split by first letter"),
        (.originalFoldersAlphabeticFoldersEqual, "Original games in root -> Folders, split by first letter"),
    ]
}

/// Sort position of a menu folder (port of `NesMenuFolder.Priority`, same raw values)
enum FolderPriority: Int, Codable, CaseIterable, Sendable {
    case leftmost = 0
    case left = 1
    case right = 3
    case rightmost = 4
    case back = 5
    case leftBack = 6

    var label: String {
        switch self {
        case .leftmost: return "Leftmost"
        case .left: return "Left"
        case .right: return "Right"
        case .rightmost: return "Rightmost"
        case .back: return "Rightmost (back)"
        case .leftBack: return "Leftmost (back)"
        }
    }
}

/// Settings for one games collection (one per console type, CE's `GamesCollectionSetting`)
struct CollectionSettings: Codable, Equatable, Sendable {
    /// Selected (checked) custom game codes
    var selectedGames: [String] = []
    /// Selected stock game codes
    var originalGames: [String] = []
    /// Every code seen so far; codes not listed here are new and start selected
    var knownGames: [String] = []
    var folderImagesSet: String = ""
    var maxGamesPerFolder: Int = 30
    var backFolderPosition: FolderPriority = .back
    var homeFolder: Bool = false
    var foldersMode: SplitStyle = .originalAuto
    /// Preset name → game codes (custom and stock)
    var presets: [String: [String]] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CollectionSettings.defaults
        selectedGames = try c.decodeIfPresent([String].self, forKey: .selectedGames) ?? d.selectedGames
        originalGames = try c.decodeIfPresent([String].self, forKey: .originalGames) ?? d.originalGames
        knownGames = try c.decodeIfPresent([String].self, forKey: .knownGames) ?? d.knownGames
        folderImagesSet = try c.decodeIfPresent(String.self, forKey: .folderImagesSet) ?? d.folderImagesSet
        maxGamesPerFolder = try c.decodeIfPresent(Int.self, forKey: .maxGamesPerFolder) ?? d.maxGamesPerFolder
        backFolderPosition = try c.decodeIfPresent(FolderPriority.self, forKey: .backFolderPosition) ?? d.backFolderPosition
        homeFolder = try c.decodeIfPresent(Bool.self, forKey: .homeFolder) ?? d.homeFolder
        foldersMode = try c.decodeIfPresent(SplitStyle.self, forKey: .foldersMode) ?? d.foldersMode
        presets = try c.decodeIfPresent([String: [String]].self, forKey: .presets) ?? d.presets
    }

    private static let defaults = CollectionSettings()
}

/// Console-side settings synced to `/etc/preinit.d/p0000_config` (CE's `ConsoleSetting`)
struct ConsoleSettings: Codable, Equatable, Sendable {
    /// 0 = epilepsy protection on, 2 = disabled (CE's AntiArmetLevel)
    var antiArmetLevel: Int = 0
    var autofireHack: Bool = false
    var autofireXYHack: Bool = false
    var autofireInterval: Int = 8
    var fcStart: Bool = false
    var resetHack: Bool = true
    /// Button bitmask (`ControllerButtons`); default Down + Select
    var resetCombination: UInt32 = ControllerButtons.down.rawValue | ControllerButtons.select.rawValue
    var extraArgsKachikachi: String = ""
    var extraArgsCanoe: String = ""
    var extraArgsRetroarch: String = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConsoleSettings()
        antiArmetLevel = try c.decodeIfPresent(Int.self, forKey: .antiArmetLevel) ?? d.antiArmetLevel
        autofireHack = try c.decodeIfPresent(Bool.self, forKey: .autofireHack) ?? d.autofireHack
        autofireXYHack = try c.decodeIfPresent(Bool.self, forKey: .autofireXYHack) ?? d.autofireXYHack
        autofireInterval = try c.decodeIfPresent(Int.self, forKey: .autofireInterval) ?? d.autofireInterval
        fcStart = try c.decodeIfPresent(Bool.self, forKey: .fcStart) ?? d.fcStart
        resetHack = try c.decodeIfPresent(Bool.self, forKey: .resetHack) ?? d.resetHack
        resetCombination = try c.decodeIfPresent(UInt32.self, forKey: .resetCombination) ?? d.resetCombination
        extraArgsKachikachi = try c.decodeIfPresent(String.self, forKey: .extraArgsKachikachi) ?? ""
        extraArgsCanoe = try c.decodeIfPresent(String.self, forKey: .extraArgsCanoe) ?? ""
        extraArgsRetroarch = try c.decodeIfPresent(String.self, forKey: .extraArgsRetroarch) ?? ""
    }

    /// The `cfg_*` values pushed to the console (CE's `GetConfigDictionary`)
    func configDictionary(isFamicom: Bool) -> [String: String] {
        [
            "clovercon_home_combination": resetHack ? String(format: "0x%04X", resetCombination) : "0x7FFF",
            "clovercon_autofire": autofireHack ? "1" : "0",
            "clovercon_autofire_xy": autofireXYHack ? "1" : "0",
            "clovercon_autofire_interval": String(autofireInterval),
            "clovercon_fc_start": fcStart && isFamicom ? "1" : "0",
            "disable_armet": antiArmetLevel > 0 ? "y" : "n",
            "nes_extra_args": extraArgsKachikachi,
            "snes_extra_args": extraArgsCanoe,
            "retroarch_extra_args": extraArgsRetroarch,
        ]
    }

    /// Apply values read from the console (CE's `SetConfigDictionary`); unknown keys are ignored
    mutating func apply(_ config: [String: String]) {
        for (key, value) in config {
            switch key {
            case "clovercon_home_combination":
                resetHack = value != "0x7FFF"
                if resetHack, value.lowercased().hasPrefix("0x"), let v = UInt32(value.dropFirst(2), radix: 16) {
                    resetCombination = v
                }
            case "clovercon_autofire": autofireHack = value == "1"
            case "clovercon_autofire_xy": autofireXYHack = value == "1"
            case "clovercon_autofire_interval": autofireInterval = Int(value) ?? autofireInterval
            case "clovercon_fc_start": fcStart = value == "1"
            case "disable_armet": antiArmetLevel = value == "y" ? 2 : 0
            case "nes_extra_args": extraArgsKachikachi = value
            case "snes_extra_args": extraArgsCanoe = value
            case "retroarch_extra_args": extraArgsRetroarch = value
            default: break
            }
        }
    }

    /// Parse `p0000_config` (CE's regex: cfg_name="value" or cfg_name='value')
    static func parseConfigFile(_ text: String) -> [String: String] {
        let pattern = #"cfg_([^=]+)=("(?:[^"\\]*(?:\\.[^"\\]*)*)"|'(?:[^'\\]*(?:\\.[^'\\]*)*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive]) else {
            return [:]
        }
        let ns = text as NSString
        var result: [String: String] = [:]
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1))
            var value = ns.substring(with: m.range(at: 2))
            value = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\'", with: "'")
                .replacingOccurrences(of: "\\\"", with: "\"")
            result[key] = value
        }
        return result
    }

    /// Script for `hakchi eval` stdin: one `cfg_key='value'` line per setting.
    /// Values use POSIX quoting ('\'' for apostrophes); CE wrote \' which the shell
    /// does not understand inside single quotes.
    static func evalScript(for config: [String: String]) -> String {
        config.keys.sorted().map { key in
            let value = config[key]!.replacingOccurrences(of: "'", with: "'\\''")
            return "cfg_\(key)='\(value)'"
        }.joined(separator: "\n") + "\n"
    }
}

/// Controller buttons for the reset combination (CE's NesButtons / SnesButtons bitmask)
struct ControllerButtons: OptionSet, Hashable, Sendable {
    let rawValue: UInt32
    static let a = ControllerButtons(rawValue: 0x01)
    static let b = ControllerButtons(rawValue: 0x02)
    static let select = ControllerButtons(rawValue: 0x04)
    static let start = ControllerButtons(rawValue: 0x08)
    static let up = ControllerButtons(rawValue: 0x10)
    static let down = ControllerButtons(rawValue: 0x20)
    static let left = ControllerButtons(rawValue: 0x40)
    static let right = ControllerButtons(rawValue: 0x80)
    static let x = ControllerButtons(rawValue: 0x100)
    static let y = ControllerButtons(rawValue: 0x200)
    static let l = ControllerButtons(rawValue: 0x400)
    static let r = ControllerButtons(rawValue: 0x800)

    /// Buttons of the NES controller, then the extra SNES ones
    static let nesButtons: [(ControllerButtons, String)] = [
        (.up, "Up"), (.down, "Down"), (.left, "Left"), (.right, "Right"),
        (.select, "Select"), (.start, "Start"), (.b, "B"), (.a, "A"),
    ]
    static let snesButtons: [(ControllerButtons, String)] = nesButtons + [(.y, "Y"), (.x, "X"), (.l, "L"), (.r, "R")]
}

/// Sync and console settings (Phase 2 port of CE's `ConfigIni` sync options)
struct SyncSettings: Codable, Equatable, Sendable {
    /// Collection settings keyed by `ConsoleType.rawValue`
    var collections: [String: CollectionSettings] = [:]
    var console = ConsoleSettings()
    /// Upload game files to `.storage` and only menu entries to the menu folders (CE: SyncLinked)
    var syncLinked = true
    /// Keep each console's games in `<sync>/<system code>` (CE: SeparateGameStorage)
    var separateGamesForMultiboot = true
    /// Upload stock games instead of pointing at the squashfs copy (CE: AlwaysCopyOriginalGames)
    var alwaysCopyOriginalGames = false
    /// Developer option: upload to /tmp/upload-test instead of the real games folder
    var uploadToTmp = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collections = try c.decodeIfPresent([String: CollectionSettings].self, forKey: .collections) ?? [:]
        console = try c.decodeIfPresent(ConsoleSettings.self, forKey: .console) ?? ConsoleSettings()
        syncLinked = try c.decodeIfPresent(Bool.self, forKey: .syncLinked) ?? true
        separateGamesForMultiboot = try c.decodeIfPresent(Bool.self, forKey: .separateGamesForMultiboot) ?? true
        alwaysCopyOriginalGames = try c.decodeIfPresent(Bool.self, forKey: .alwaysCopyOriginalGames) ?? false
        uploadToTmp = try c.decodeIfPresent(Bool.self, forKey: .uploadToTmp) ?? false
    }

    /// Settings for a console type (defaults when never used)
    func collection(for console: ConsoleType) -> CollectionSettings {
        collections[console.rawValue] ?? CollectionSettings()
    }

    mutating func updateCollection(for console: ConsoleType, _ change: (inout CollectionSettings) -> Void) {
        var c = collection(for: console)
        change(&c)
        collections[console.rawValue] = c
    }

    /// CE's "Sync structure settings for all games collections"
    mutating func copyStructureToAllCollections(from console: ConsoleType) {
        let source = collection(for: console)
        for type in ConsoleType.allCases where type != .unknown {
            updateCollection(for: type) { c in
                c.folderImagesSet = source.folderImagesSet
                c.maxGamesPerFolder = source.maxGamesPerFolder
                c.backFolderPosition = source.backFolderPosition
                c.homeFolder = source.homeFolder
                c.foldersMode = source.foldersMode
            }
        }
    }
}
