import Foundation

/// Famicom Disk System (`.fds`) import, ported from Hakchi2-CE `Apps/FdsGame.cs`.
enum FdsRom {
    /// CE's `FdsGame.DefaultArgs` (note the longer 10,2 fade-in compared with NES)
    static let defaultArgs = "--guest-overscan-dimensions 0,0,9,3 --initial-fadein-durations 10,2 --volume 75 --enable-armet --fds-auto-disk-side-switch-on-keypress"

    /// Size of the fwNES "FDS\x1A" header CE strips
    static let headerSize = 16

    /// Result of preparing an `.fds` file for import
    struct ImportResult: Equatable {
        /// Disk image to write (header removed, patches applied)
        var data: Data
        /// CRC32 for the game code: of the headerless image when a header was
        /// stripped, otherwise of the original file
        var crc32: UInt32
        var headerStripped: Bool
        /// kachikachi binary and arguments on NES/Famicom consoles, nil elsewhere
        /// (the system's default core is kept)
        var application: String?
        var args: String?
    }

    /// Port of CE's `FdsGame.Patch`.
    ///
    /// - Parameters:
    ///   - data: the file contents
    ///   - targetIsNesConsole: true for NES Classic / Famicom Mini, where the
    ///     built-in emulator plays FDS images
    ///   - patchProvider: tried with the file CRC32, and again with the new CRC32
    ///     after the header is stripped
    static func prepareForImport(
        data: Data, targetIsNesConsole: Bool, patchProvider: RomPatchProvider? = nil
    ) -> ImportResult {
        var crc = CRC32.checksum(data)
        var data = patchProvider?(data, crc) ?? data
        var stripped = false

        if data.count >= 3, data.prefix(3).elementsEqual("FDS".utf8) {
            data = Data(data.dropFirst(headerSize))
            crc = CRC32.checksum(data)
            stripped = true
            // Try to find a patch again, using the new CRC
            data = patchProvider?(data, crc) ?? data
        }

        return ImportResult(
            data: data,
            crc32: crc,
            headerStripped: stripped,
            application: targetIsNesConsole ? NesRom.kachikachiApplication : nil,
            args: targetIsNesConsole ? defaultArgs : nil
        )
    }
}
