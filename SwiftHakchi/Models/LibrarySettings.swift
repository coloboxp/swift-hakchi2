import Foundation
import Combine

/// PC-side library and view settings from Hakchi2-CE's `ConfigIni` (Settings and View menus).
/// Saved as `library-settings.json` next to `config.json`; every change is saved at once.
@MainActor
final class LibrarySettings: ObservableObject {
    static let shared = LibrarySettings()

    /// Where original (stock) games appear in the explorer (CE: View > Original games)
    enum OriginalGamesPosition: Int, Codable, CaseIterable, Identifiable {
        case atTop = 0, atBottom, sorted, hidden
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .atTop: return "At the Top"
            case .atBottom: return "At the Bottom"
            case .sorted: return "Sorted with Others"
            case .hidden: return "Hidden"
            }
        }
    }

    /// CE: View > Sort by
    enum GamesSorting: Int, Codable, CaseIterable, Identifiable {
        case name = 0, core, system, region
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .name: return "Name"
            case .core: return "Core"
            case .system: return "Console"
            case .region: return "Region"
            }
        }
    }

    struct Values: Codable, Equatable {
        /// Compress ROMs into .7z when adding (CE: Compress, default on)
        var compressGames = true
        /// 8-bit quantize box art when adding (CE: CompressCover, default on)
        var compressCoverArt = true
        /// Center the 40×40 thumbnail vertically (CE: CenterThumbnail)
        var centerThumbnail = false
        /// Hide "Done" pop-ups (CE: DisablePopups)
        var disablePopups = false
        /// Look up names/covers on TheGamesDB after importing (CE: EnableImportScraper)
        var enableImportScraper = true
        /// Keep SNES and Mega Drive games in games_snes/ and games_md/ (CE: SeparateGameLocalStorage)
        var separateGameLocalStorage = false
        var originalGamesPosition: OriginalGamesPosition = .atTop
        var gamesSorting: GamesSorting = .name
        /// Put games without box art in their own group (CE: ShowGamesWithoutCoverArt)
        var groupGamesWithoutCoverArt = false

        init() {}

        init(from decoder: Decoder) throws {
            // Every key optional so older files keep working when settings are added
            let d = Values()
            let c = try decoder.container(keyedBy: CodingKeys.self)
            compressGames = try c.decodeIfPresent(Bool.self, forKey: .compressGames) ?? d.compressGames
            compressCoverArt = try c.decodeIfPresent(Bool.self, forKey: .compressCoverArt) ?? d.compressCoverArt
            centerThumbnail = try c.decodeIfPresent(Bool.self, forKey: .centerThumbnail) ?? d.centerThumbnail
            disablePopups = try c.decodeIfPresent(Bool.self, forKey: .disablePopups) ?? d.disablePopups
            enableImportScraper = try c.decodeIfPresent(Bool.self, forKey: .enableImportScraper) ?? d.enableImportScraper
            separateGameLocalStorage = try c.decodeIfPresent(Bool.self, forKey: .separateGameLocalStorage)
                ?? d.separateGameLocalStorage
            originalGamesPosition = try c.decodeIfPresent(OriginalGamesPosition.self, forKey: .originalGamesPosition)
                ?? d.originalGamesPosition
            gamesSorting = try c.decodeIfPresent(GamesSorting.self, forKey: .gamesSorting) ?? d.gamesSorting
            groupGamesWithoutCoverArt = try c.decodeIfPresent(Bool.self, forKey: .groupGamesWithoutCoverArt)
                ?? d.groupGamesWithoutCoverArt
        }
    }

    @Published var values: Values {
        didSet {
            guard values != oldValue else { return }
            LibraryStorage.separateLocalStorage = values.separateGameLocalStorage
            save()
        }
    }

    let fileURL: URL

    init(fileURL: URL = AppConfig.configDirectory.appendingPathComponent("library-settings.json")) {
        self.fileURL = fileURL
        values = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Values.self, from: $0) } ?? Values()
        LibraryStorage.separateLocalStorage = values.separateGameLocalStorage
    }

    func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(values).write(to: fileURL)
    }
}
