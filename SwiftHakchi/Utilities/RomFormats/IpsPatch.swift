import Foundation

/// IPS patch support, ported from Hakchi2-CE `IpsPatcher.cs` and `NesApplication.FindPatch`.
///
/// Format: "PATCH", then records of a 3-byte big-endian offset and a 2-byte size
/// followed by that many bytes; size 0 means an RLE record (2-byte count, 1 byte
/// value). The patch ends with "EOF", optionally followed by a 3-byte size to
/// truncate the output to (a common extension).
///
/// Deliberate differences from CE, which only matter for unusual patches:
/// - CE grows the ROM by doubling it whenever a record writes past the end, so the
///   output keeps the doubled size. Here the ROM grows exactly as far as records write.
/// - CE stops on the "EOF" marker only by running out of bytes, and ignores the
///   truncation extension. Here "EOF" ends the patch and the extension is applied.
/// For ordinary patches that stay inside the ROM, the output is identical.
enum IpsPatch {
    enum IpsError: Error, Equatable {
        /// Missing "PATCH" signature
        case invalidSignature
        /// A record runs past the end of the patch file
        case truncated
    }

    /// Apply an IPS patch to `data`
    static func apply(_ patch: Data, to data: Data) throws -> Data {
        let p = [UInt8](patch)
        guard p.count >= 5, p[0..<5].elementsEqual("PATCH".utf8) else {
            throw IpsError.invalidSignature
        }
        var out = [UInt8](data)
        var pos = 5

        func ensureSize(_ size: Int) {
            if size > out.count { out.append(contentsOf: [UInt8](repeating: 0, count: size - out.count)) }
        }

        while pos + 3 <= p.count {
            // "EOF" marker
            if p[pos] == 0x45, p[pos + 1] == 0x4F, p[pos + 2] == 0x46 {
                pos += 3
                if pos + 3 <= p.count {
                    let truncateTo = Int(p[pos]) << 16 | Int(p[pos + 1]) << 8 | Int(p[pos + 2])
                    if truncateTo < out.count { out.removeSubrange(truncateTo...) }
                }
                return Data(out)
            }
            guard pos + 5 <= p.count else { throw IpsError.truncated }
            let address = Int(p[pos]) << 16 | Int(p[pos + 1]) << 8 | Int(p[pos + 2])
            let length = Int(p[pos + 3]) << 8 | Int(p[pos + 4])
            pos += 5

            if length > 0 {
                guard pos + length <= p.count else { throw IpsError.truncated }
                ensureSize(address + length)
                out.replaceSubrange(address..<(address + length), with: p[pos..<(pos + length)])
                pos += length
            } else {
                guard pos + 3 <= p.count else { throw IpsError.truncated }
                let count = Int(p[pos]) << 8 | Int(p[pos + 1])
                let value = p[pos + 2]
                ensureSize(address + count)
                for i in address..<(address + count) { out[i] = value }
                pos += 3
            }
        }
        // No "EOF" marker: keep what was applied, like CE
        return Data(out)
    }

    /// Find a patch for a ROM, using CE's search order. Later rules win:
    /// 1. `patchesDirectory/<CRC32 as 8 hex digits>*.*` (searched recursively, first match)
    /// 2. `patchesDirectory/<file name without extension>.ips`
    /// 3. `<folder of the ROM>/<file name without extension>.ips`
    ///
    /// - Parameters:
    ///   - crc32: CRC32 to search by; 0 skips rule 1 (CE does the same)
    static func findPatch(patchesDirectory: URL, romURL: URL, crc32: UInt32) -> URL? {
        let fm = FileManager.default
        var found: URL?

        if crc32 != 0, let enumerator = fm.enumerator(at: patchesDirectory, includingPropertiesForKeys: nil) {
            let prefix = String(format: "%08X", crc32).lowercased()
            let matches = enumerator.compactMap { $0 as? URL }
                .filter { $0.lastPathComponent.lowercased().hasPrefix(prefix) && !$0.hasDirectoryPath }
                .sorted { $0.path < $1.path }
            found = matches.first
        }

        let baseName = romURL.deletingPathExtension().lastPathComponent
        let inPatches = patchesDirectory.appendingPathComponent(baseName + ".ips")
        if fm.fileExists(atPath: inPatches.path) { found = inPatches }
        let besideRom = romURL.deletingLastPathComponent().appendingPathComponent(baseName + ".ips")
        if fm.fileExists(atPath: besideRom.path) { found = besideRom }
        return found
    }
}
