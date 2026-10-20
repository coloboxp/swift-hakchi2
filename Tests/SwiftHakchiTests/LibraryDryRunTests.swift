import Foundation
import Testing
@testable import SwiftHakchi

/// Opt-in check of the legacy-library migration against a real library, on a copy.
/// Run with: HAKCHI_LIBRARY_DRYRUN=/path/to/games ./scripts/test.sh --filter LibraryDryRun
@MainActor
@Suite struct LibraryDryRunTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HAKCHI_LIBRARY_DRYRUN"] != nil))
    func migrateCopyOfRealLibrary() throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HAKCHI_LIBRARY_DRYRUN"]!)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("dryrun-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        func execs(_ dir: URL) -> [String: String] {
            var result: [String: String] = [:]
            for game in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let url = dir.appendingPathComponent(game).appendingPathComponent("\(game).desktop")
                if let data = try? Data(contentsOf: url) { result[game] = DesktopFile(data: data).exec }
            }
            return result
        }
        func files(_ dir: URL) -> Int {
            (FileManager.default.enumerator(atPath: dir.path)?.allObjects.count) ?? 0
        }

        let before = execs(copy)
        let fileCountBefore = files(copy)
        let catalog = CoreCatalog(consoleCacheDirectory: copy.appendingPathComponent(".none"),
                                  userInfoDirectory: copy.appendingPathComponent(".none"))
        GameRepair.migrateLegacyGames(in: copy, cores: catalog)
        let after = execs(copy)

        for (code, old) in before.sorted(by: { $0.key < $1.key }) where after[code] != old {
            print("\(code)\n  - \(old)\n  + \(after[code] ?? "<missing>")")
        }
        // Migration must never lose a game or a file (it only adds metadata.json)
        #expect(after.count == before.count)
        #expect(files(copy) == fileCountBefore + before.count)
        #expect(after.values.allSatisfy { !$0.contains("/var/lib/hakchi/games") })
    }
}
