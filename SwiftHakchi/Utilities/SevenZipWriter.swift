import Foundation
import LzmaSDK
import zlib

/// Writes single-file `.7z` archives with LZMA compression.
///
/// Matches what Hakchi2-CE's tiny7z produces for "Compress games": one folder
/// with one LZMA coder (method 03 01 01, SDK default level 5) and a plain
/// (not compressed) header. This is the simplest 7z layout and is readable by
/// 7-Zip, libarchive and the console's tiny7zx.
///
/// Layout: 32-byte signature header · packed LZMA stream · header.
enum SevenZipWriter {
    enum WriterError: LocalizedError {
        case encoderFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .encoderFailed(let code): return "LZMA compression failed (error \(code))"
            }
        }
    }

    /// 7z property IDs used here (7zFormat.txt)
    private enum ID: UInt8 {
        case end = 0x00, header = 0x01, mainStreamsInfo = 0x04, filesInfo = 0x05
        case packInfo = 0x06, unpackInfo = 0x07, subStreamsInfo = 0x08, size = 0x09
        case crc = 0x0A, folder = 0x0B, codersUnpackSize = 0x0C, emptyStream = 0x0E
        case emptyFile = 0x0F, name = 0x11, mTime = 0x14
    }

    private static let signature: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
    private static let lzmaMethod: [UInt8] = [0x03, 0x01, 0x01]

    /// Build a 7z archive holding `data` as a file called `fileName`.
    static func archive(data: Data, fileName: String, modificationDate: Date = Date()) throws -> Data {
        var packed = Data()
        var props = [UInt8](repeating: 0, count: Int(LZMA_SHIM_PROPS_SIZE))
        if !data.isEmpty {
            packed = try encode(data, props: &props)
        }

        var header = Data()
        header.append(ID.header.rawValue)
        if !data.isEmpty {
            writeStreamsInfo(into: &header, packedSize: packed.count, unpackedSize: data.count,
                             props: props, crc: crc32(data))
        }
        writeFilesInfo(into: &header, fileName: fileName, isEmpty: data.isEmpty, date: modificationDate)
        header.append(ID.end.rawValue)

        // Start header: where the header is (relative to the end of the signature header)
        var start = Data()
        append(UInt64(packed.count), littleEndianTo: &start)
        append(UInt64(header.count), littleEndianTo: &start)
        append(crc32(header), littleEndianTo: &start)

        var out = Data(signature)
        out.append(contentsOf: [0, 4])  // format version 0.4, as 7-Zip writes
        append(crc32(start), littleEndianTo: &out)
        out.append(start)
        out.append(packed)
        out.append(header)
        return out
    }

    // MARK: - Header parts

    private static func writeStreamsInfo(into h: inout Data, packedSize: Int, unpackedSize: Int,
                                         props: [UInt8], crc: UInt32) {
        h.append(ID.mainStreamsInfo.rawValue)

        // One packed stream right after the signature header
        h.append(ID.packInfo.rawValue)
        writeNumber(0, to: &h)  // pack position
        writeNumber(1, to: &h)  // number of pack streams
        h.append(ID.size.rawValue)
        writeNumber(UInt64(packedSize), to: &h)
        h.append(ID.end.rawValue)

        // One folder with one LZMA coder
        h.append(ID.unpackInfo.rawValue)
        h.append(ID.folder.rawValue)
        writeNumber(1, to: &h)  // number of folders
        h.append(0)             // not external
        writeNumber(1, to: &h)  // number of coders
        h.append(UInt8(lzmaMethod.count) | 0x20)  // id size + "has properties"
        h.append(contentsOf: lzmaMethod)
        writeNumber(UInt64(props.count), to: &h)
        h.append(contentsOf: props)
        h.append(ID.codersUnpackSize.rawValue)
        writeNumber(UInt64(unpackedSize), to: &h)
        h.append(ID.end.rawValue)

        // File CRC goes in the substreams info (one stream per folder, so no count)
        h.append(ID.subStreamsInfo.rawValue)
        h.append(ID.crc.rawValue)
        h.append(1)  // all defined
        append(crc, littleEndianTo: &h)
        h.append(ID.end.rawValue)

        h.append(ID.end.rawValue)
    }

    private static func writeFilesInfo(into h: inout Data, fileName: String, isEmpty: Bool, date: Date) {
        h.append(ID.filesInfo.rawValue)
        writeNumber(1, to: &h)  // number of files

        if isEmpty {
            // A 0-byte file has no stream: mark it as an empty stream that is a file
            for id in [ID.emptyStream, ID.emptyFile] {
                h.append(id.rawValue)
                writeNumber(1, to: &h)
                h.append(0x80)  // bit vector: file 0
            }
        }

        var name = Data()
        name.append(0)  // not external
        for unit in fileName.utf16 { append(unit, littleEndianTo: &name) }
        name.append(contentsOf: [0, 0])
        h.append(ID.name.rawValue)
        writeNumber(UInt64(name.count), to: &h)
        h.append(name)

        // Modification time as a Windows FILETIME (100 ns since 1601-01-01)
        let fileTime = UInt64(max(0, (date.timeIntervalSince1970 + 11_644_473_600) * 10_000_000))
        h.append(ID.mTime.rawValue)
        writeNumber(10, to: &h)
        h.append(1)  // all defined
        h.append(0)  // not external
        append(fileTime, littleEndianTo: &h)

        h.append(ID.end.rawValue)
    }

    // MARK: - Encoding helpers

    private static func encode(_ data: Data, props: inout [UInt8]) throws -> Data {
        // LZMA can expand incompressible input slightly; leave generous room
        var capacity = data.count + data.count / 2 + 1024
        var out = Data(count: capacity)
        let res: Int32 = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                props.withUnsafeMutableBufferPointer { propsPtr in
                    lzma_shim_encode(inPtr.bindMemory(to: UInt8.self).baseAddress, data.count,
                                     outPtr.bindMemory(to: UInt8.self).baseAddress, &capacity,
                                     propsPtr.baseAddress)
                }
            }
        }
        guard res == 0 else { throw WriterError.encoderFailed(res) }
        out.count = capacity
        return out
    }

    /// 7z variable-length number (7-Zip's WriteNumber)
    static func writeNumber(_ value: UInt64, to data: inout Data) {
        var first: UInt8 = 0
        var mask: UInt8 = 0x80
        var i = 0
        while i < 8 {
            if value < (UInt64(1) << (7 * UInt64(i + 1))) {
                first |= UInt8(truncatingIfNeeded: value >> (8 * UInt64(i)))
                break
            }
            first |= mask
            mask >>= 1
            i += 1
        }
        data.append(first)
        var v = value
        for _ in 0..<i {
            data.append(UInt8(truncatingIfNeeded: v))
            v >>= 8
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, littleEndianTo data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { ptr in
            UInt32(zlib.crc32(0, ptr.bindMemory(to: UInt8.self).baseAddress, uInt(data.count)))
        }
    }
}
