import Foundation

/// Extra per-game data stored next to the `.desktop` file as `metadata.json`.
/// Keys match Hakchi2-CE's `AppMetadata`, so game folders can move between both apps.
struct GameMetadata: Codable, Equatable, Sendable {
    /// libretro system name, e.g. "Nintendo - Game Boy" ("" = unknown)
    var system: String = ""
    /// Core bin key, e.g. "km_mgba" ("" = none chosen)
    var core: String = ""
    var originalFilename: String = ""
    var originalCrc32: UInt32 = 0
    var customCoverArt: Bool = false

    static let fileName = "metadata.json"

    enum CodingKeys: String, CodingKey {
        case system = "System", core = "Core", originalFilename = "OriginalFilename"
        case originalCrc32 = "OriginalCrc32", customCoverArt = "CustomCoverArt"
    }

    init(system: String = "", core: String = "", originalFilename: String = "",
         originalCrc32: UInt32 = 0, customCoverArt: Bool = false) {
        self.system = system
        self.core = core
        self.originalFilename = originalFilename
        self.originalCrc32 = originalCrc32
        self.customCoverArt = customCoverArt
    }

    init(from decoder: Decoder) throws {
        // Every key is optional: CE writes all of them, older files may not
        let c = try decoder.container(keyedBy: CodingKeys.self)
        system = try c.decodeIfPresent(String.self, forKey: .system) ?? ""
        core = try c.decodeIfPresent(String.self, forKey: .core) ?? ""
        originalFilename = try c.decodeIfPresent(String.self, forKey: .originalFilename) ?? ""
        originalCrc32 = try c.decodeIfPresent(UInt32.self, forKey: .originalCrc32) ?? 0
        customCoverArt = try c.decodeIfPresent(Bool.self, forKey: .customCoverArt) ?? false
    }

    /// Load `metadata.json` from a game folder. If it is missing or has no system,
    /// the system is guessed from the Exec line like CE does.
    static func load(gameDirectory: URL, exec: String) -> GameMetadata {
        var meta = (try? Data(contentsOf: gameDirectory.appendingPathComponent(fileName)))
            .flatMap { try? JSONDecoder().decode(GameMetadata.self, from: $0) } ?? GameMetadata()
        if meta.system.isEmpty {
            let guessed = SystemCatalog.system(forExec: exec)
            if !guessed.isUnknown { meta.system = guessed.name }
        }
        return meta
    }

    func save(gameDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: gameDirectory.appendingPathComponent(Self.fileName))
    }
}
