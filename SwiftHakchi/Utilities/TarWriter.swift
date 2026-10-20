import Foundation

/// Simple POSIX (ustar) tar archive builder for streaming files to the console
struct TarWriter {
    private var data = Data()

    /// Bytes written so far (headers, contents and padding)
    var byteCount: Int { data.count }

    /// Add a file entry to the tar archive.
    /// `modified` is stored as the file's mtime; incremental sync compares it later.
    mutating func addFile(name: String, contents: Data, mode: UInt32 = 0o100644, modified: Date = Date()) {
        var header = makeHeader(name: name, mode: mode, size: UInt64(contents.count),
                                modified: modified, typeFlag: 0x30)  // '0' = regular file
        finishHeader(&header)
        data.append(header)
        data.append(contents)

        // Pad to 512-byte boundary
        let remainder = contents.count % 512
        if remainder > 0 {
            data.append(Data(count: 512 - remainder))
        }
    }

    /// Add a directory entry
    mutating func addDirectory(name: String, mode: UInt32 = 0o040755, modified: Date = Date()) {
        let dirName = name.hasSuffix("/") ? name : name + "/"
        var header = makeHeader(name: dirName, mode: mode, size: 0, modified: modified, typeFlag: 0x35)  // '5'
        finishHeader(&header)
        data.append(header)
    }

    /// Finalize the archive (adds end-of-archive marker)
    mutating func finalize() -> Data {
        // Two 512-byte zero blocks
        data.append(Data(count: 1024))
        return data
    }

    // MARK: - Helpers

    private func makeHeader(name: String, mode: UInt32, size: UInt64, modified: Date, typeFlag: UInt8) -> Data {
        var header = Data(count: 512)
        let (prefix, shortName) = Self.splitName(name)

        writeString(&header, offset: 0, value: shortName, maxLen: 100)        // name
        writeOctal(&header, offset: 100, value: UInt64(mode), width: 8)      // mode
        writeOctal(&header, offset: 108, value: 0, width: 8)                 // uid (root)
        writeOctal(&header, offset: 116, value: 0, width: 8)                 // gid (root)
        writeOctal(&header, offset: 124, value: size, width: 12)             // size
        writeOctal(&header, offset: 136, value: UInt64(max(0, modified.timeIntervalSince1970)), width: 12)  // mtime
        header[156] = typeFlag
        writeString(&header, offset: 257, value: "ustar", maxLen: 6)         // magic
        header[263] = 0x30                                                   // version "00"
        header[264] = 0x30
        writeString(&header, offset: 345, value: prefix, maxLen: 155)        // ustar prefix
        return header
    }

    /// Checksum (148-155) - calculated over header with checksum field as spaces
    private func finishHeader(_ header: inout Data) {
        for i in 148..<156 { header[i] = 0x20 }
        var checksum: UInt64 = 0
        for byte in header { checksum += UInt64(byte) }
        writeOctal(&header, offset: 148, value: checksum, width: 7)
        header[155] = 0x20  // trailing space
    }

    /// Split a path for ustar: names over 100 bytes go to the 155-byte prefix field,
    /// cut at a "/" (paths in game folders easily exceed 100 characters)
    static func splitName(_ name: String) -> (prefix: String, name: String) {
        let bytes = Array(name.utf8)
        guard bytes.count > 100 else { return ("", name) }
        // Last "/" such that the rest fits in 100 bytes and the prefix in 155
        for i in stride(from: min(bytes.count - 1, 155), through: 1, by: -1) where bytes[i] == UInt8(ascii: "/") {
            if bytes.count - i - 1 <= 100 {
                let prefix = String(decoding: bytes[..<i], as: UTF8.self)
                let rest = String(decoding: bytes[(i + 1)...], as: UTF8.self)
                return (prefix, rest)
            }
        }
        return ("", name)  // cannot split: truncated by writeString
    }

    private func writeString(_ data: inout Data, offset: Int, value: String, maxLen: Int) {
        let bytes = Array(value.utf8.prefix(maxLen))
        for (i, byte) in bytes.enumerated() {
            data[offset + i] = byte
        }
    }

    private func writeOctal(_ data: inout Data, offset: Int, value: UInt64, width: Int) {
        let str = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, width - 1 - str.count)) + str
        let bytes = Array(padded.utf8.prefix(width - 1))
        for (i, byte) in bytes.enumerated() {
            data[offset + i] = byte
        }
        data[offset + width - 1] = 0  // null terminator
    }
}
