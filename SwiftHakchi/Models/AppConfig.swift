import Foundation

/// User settings, persisted as JSON in Application Support
final class AppConfig: ObservableObject, Codable {
    static let shared = AppConfig.load()

    @Published var lastConsoleType: ConsoleType = .nes
    @Published var lastDeviceId: String = ""
    @Published var installedGameCodes: [String] = []
    @Published var separateGameStorage: Bool = false
    @Published var forceNetwork: Bool = false
    @Published var uploadCompressed: Bool = true
    @Published var exportLinked: Bool = false
    @Published var maxGameSize: Int = 300  // MB
    @Published var theGamesDbApiKey: String = ""
    /// Module repositories (CE: repos). Older configs stored only URLs (`modRepositoryURLs`).
    @Published var modRepositories: [ModRepository] = [.kmfd]
    /// Convert SNES ROMs to Canoe's .sfrom format on import (CE: ConvertToSFROM, default on)
    @Published var convertToSfrom: Bool = true

    enum CodingKeys: String, CodingKey {
        case lastConsoleType, lastDeviceId, installedGameCodes, separateGameStorage, forceNetwork
        case uploadCompressed, exportLinked, maxGameSize
        case theGamesDbApiKey, modRepositoryURLs, modRepositories, convertToSfrom
    }

    init() {}

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastConsoleType = try container.decodeIfPresent(ConsoleType.self, forKey: .lastConsoleType) ?? .nes
        lastDeviceId = try container.decodeIfPresent(String.self, forKey: .lastDeviceId) ?? ""
        installedGameCodes = try container.decodeIfPresent([String].self, forKey: .installedGameCodes) ?? []
        separateGameStorage = try container.decodeIfPresent(Bool.self, forKey: .separateGameStorage) ?? false
        forceNetwork = try container.decodeIfPresent(Bool.self, forKey: .forceNetwork) ?? false
        uploadCompressed = try container.decodeIfPresent(Bool.self, forKey: .uploadCompressed) ?? true
        exportLinked = try container.decodeIfPresent(Bool.self, forKey: .exportLinked) ?? false
        maxGameSize = try container.decodeIfPresent(Int.self, forKey: .maxGameSize) ?? 300
        theGamesDbApiKey = try container.decodeIfPresent(String.self, forKey: .theGamesDbApiKey) ?? ""
        if let repos = try container.decodeIfPresent([ModRepository].self, forKey: .modRepositories) {
            modRepositories = repos
        } else if let urls = try container.decodeIfPresent([String].self, forKey: .modRepositoryURLs) {
            modRepositories = urls.map(ModRepository.init(legacyURL:))
        }
        convertToSfrom = try container.decodeIfPresent(Bool.self, forKey: .convertToSfrom) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lastConsoleType, forKey: .lastConsoleType)
        try container.encode(lastDeviceId, forKey: .lastDeviceId)
        try container.encode(installedGameCodes, forKey: .installedGameCodes)
        try container.encode(separateGameStorage, forKey: .separateGameStorage)
        try container.encode(forceNetwork, forKey: .forceNetwork)
        try container.encode(uploadCompressed, forKey: .uploadCompressed)
        try container.encode(exportLinked, forKey: .exportLinked)
        try container.encode(maxGameSize, forKey: .maxGameSize)
        try container.encode(theGamesDbApiKey, forKey: .theGamesDbApiKey)
        try container.encode(modRepositories, forKey: .modRepositories)
        try container.encode(convertToSfrom, forKey: .convertToSfrom)
    }

    // MARK: - Persistence

    static var configDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("SwiftHakchi", isDirectory: true)
    }

    static var configFile: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        guard FileManager.default.fileExists(atPath: configFile.path),
              let data = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else {
            return AppConfig()
        }
        return config
    }

    func save() {
        let dir = Self.configDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.configFile)
        }
    }

    /// Base path for game data on disk
    var gamesDirectory: URL {
        Self.configDirectory.appendingPathComponent("games", isDirectory: true)
    }

    /// Path for downloaded data files
    var dataDirectory: URL {
        Self.configDirectory.appendingPathComponent("data", isDirectory: true)
    }

    /// Local module library (CE's user_mods): .hmod files or folders
    var userModsDirectory: URL {
        Self.configDirectory.appendingPathComponent("user_mods", isDirectory: true)
    }

    /// IPS patches matched to ROMs at import time (by CRC32 or file name)
    var patchesDirectory: URL {
        Self.configDirectory.appendingPathComponent("patches", isDirectory: true)
    }

    /// Path for kernel/dump backups
    var dumpDirectory: URL {
        Self.configDirectory.appendingPathComponent("dump", isDirectory: true)
    }
}
