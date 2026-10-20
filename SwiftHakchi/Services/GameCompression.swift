import Foundation

/// 7z compression of game files (CE's `NesApplication.Compress` / `Decompress`).
///
/// Placeholder: the 7z encoder is ported separately and replaces this file.
/// Callers check `isAvailable` so imports keep working until then.
enum GameCompression {
    /// False until the 7z encoder is in place
    static let isAvailable = false

    /// Compress the files named in the game's Exec into `<file>.7z` and update Exec
    static func compress(gameDirectory: URL, code: String) throws {
        throw GameCompressionError.notImplemented
    }

    /// Unpack single-entry `.7z`/`.zip` files named in Exec and update Exec
    static func decompress(gameDirectory: URL, code: String) throws {
        throw GameCompressionError.notImplemented
    }

    /// True when Exec points at a compressed file
    static func isCompressed(exec: String) -> Bool {
        DesktopFile.splitExec(exec).args.contains { $0.lowercased().hasSuffix(".7z") || $0.lowercased().hasSuffix(".zip") }
    }
}

enum GameCompressionError: LocalizedError {
    case notImplemented

    var errorDescription: String? {
        "Compressing games is not available yet."
    }
}
