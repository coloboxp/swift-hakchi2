import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// Pure helpers behind the Tools and Kernel menus (ported from Hakchi2-CE).
/// Nothing here talks to the console, so it can be unit-tested.
enum ConsoleTools {
    // MARK: - Shell quoting

    /// CE's `Shared.EscapeShellArgument`: backslash every non-alphanumeric character
    static func escapeShellArgument(_ s: String) -> String {
        s.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "\\\\$0", options: .regularExpression)
    }

    /// Single-quote a string for the console's shell
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Save states (CE SaveStateManager)

    /// Script CE runs with `sh` to list saves: one line per game, "code sizeKB flags name"
    static let listSavesScript = """
    #!/bin/sh
    savespath=/var/saves
    gamestorage=$(hakchi findGameSyncStorage)
    find -L $savespath -mindepth 1 -maxdepth 1 -type d -name "CLV-*" | sed 's#.*/##' | while read code ; do
      flags=F
      [ -f $savespath/$code/save.sram ] && flags=${flags}-S
      [ -f $savespath/$code/cartridge.sram ] && [ $(wc -c <$savespath/$code/cartridge.sram) -gt 20 ] && flags=${flags}-S
      [ -f $savespath/$code/1.state ] && flags=${flags}-1
      [ -d $savespath/$code/suspendpoint1  ] && flags=${flags}-1
      [ -f $savespath/$code/2.state ] && flags=${flags}-2
      [ -d $savespath/$code/suspendpoint2 ] && flags=${flags}-2
      [ -f $savespath/$code/3.state ] && flags=${flags}-3
      [ -d $savespath/$code/suspendpoint3 ] && flags=${flags}-3
      [ -f $savespath/$code/4.state ] && flags=${flags}-4
      [ -d $savespath/$code/suspendpoint4 ] && flags=${flags}-4
      if [ "$flags" != "F" ]; then
        size=$(du -d 0 $savespath/$code | awk '{ print $1 }')
        name=$(find -L "$gamestorage" -type f -name "$code.desktop" -exec cat {} + | sed -n 's/Name=\\(.*\\)/\\1/p' | head -n 1)
        [ -z "$name" ] && name=UNKNOWN
        echo $code $size $flags $name
        unset flags
        unset name
      fi
    done
    """

    /// Folder holding every game's saves on the console
    static let profilesPath = "/var/lib/clover/profiles/0"

    struct SaveState: Identifiable, Hashable {
        let code: String
        /// Size in KB, as printed by `du`
        let sizeKB: Int
        /// Save slots, e.g. "S 1 2" (S = battery save)
        let flags: String
        /// Game name, nil when the console doesn't know it
        let name: String?
        var id: String { code }
    }

    /// Parse the output of `listSavesScript` (same field splitting as CE)
    static func parseSaveStates(_ output: String) -> [SaveState] {
        output.components(separatedBy: .newlines).compactMap { raw in
            let parts = raw.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, let size = Int(parts[1]) else { return nil }
            let flags = parts[2].replacingOccurrences(of: "F-", with: "")
                .replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
            let name = parts[3].trimmingCharacters(in: .whitespaces)
            return SaveState(code: parts[0], sizeKB: size, flags: flags == "F" ? "" : flags,
                             name: name == "UNKNOWN" || name.isEmpty ? nil : name)
        }
    }

    // MARK: - Screenshot

    static let framebufferWidth = 1280
    static let framebufferHeight = 720

    /// Turn a raw 32-bit BGRA framebuffer (`cat /dev/fb0`) into an opaque image.
    /// Same pixel order as CE: bytes 0,1,2 are B,G,R; the 4th byte is ignored.
    static func image(fromFramebuffer raw: Data, width: Int = framebufferWidth,
                      height: Int = framebufferHeight) -> CGImage? {
        let pixels = width * height
        guard raw.count >= pixels * 4 else { return nil }
        var rgba = [UInt8](repeating: 255, count: pixels * 4)
        raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            for i in 0..<pixels {
                rgba[i * 4] = src[i * 4 + 2]     // R
                rgba[i * 4 + 1] = src[i * 4 + 1] // G
                rgba[i * 4 + 2] = src[i * 4]     // B
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// PNG bytes of an image
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: - Boot splash

    /// CE's boot image rule: anything that is not already a 1280×720 PNG is
    /// stretched to 1280×720 (no aspect ratio kept) and saved as a 24-bit PNG.
    static func bootSplashPNG(from imageData: Data, isPNG: Bool) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        if isPNG && image.width == framebufferWidth && image.height == framebufferHeight {
            return imageData
        }
        let w = framebufferWidth, h = framebufferHeight
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().flatMap(pngData)
    }

    // MARK: - Memory stats (CE MemoryStats)

    struct MemoryStats: Equatable {
        var storageTotal: Int64 = -1
        var storageUsed: Int64 = -1
        var storageFree: Int64 = -1
        var externalSaves = false
        var saveStatesSize: Int64 = -1
        var allGamesSize: Int64 = 0
        var nonMultibootGamesSize: Int64 = 0
        var extraFilesSize: Int64 = 0
        /// Size per system-code folder (multiboot collections), e.g. "snes-usa"
        var collections: [String: Int64] = [:]

        /// Space games may use (CE's AvailableForGames)
        func availableForGames(separateGameStorage: Bool, currentSystemCode: String) -> Int64 {
            if separateGameStorage {
                return storageFree + (collections[currentSystemCode] ?? 0) + nonMultibootGamesSize + extraFilesSize
            }
            return storageFree + allGamesSize
        }
    }

    /// Commands CE runs for the stats (findGameSyncStorage resolved on the console)
    static let dfCommand = "df \"$(hakchi findGameSyncStorage)\" | tail -n 1 | awk '{ print $2 \" | \" $3 \" | \" $4 }'"
    static let externalSavesCommand = "mount | grep /var/lib/clover/profiles"
    static let saveSizeCommand = "du -s \"$(readlink /var/saves)\" | awk '{ print $1 }'"
    static func collectionsCommand(syncPath: String) -> String {
        "du -d 1 \"\(syncPath)\" | head -n -1 | awk '{ print $2 \" | \" $1 }'"
    }

    /// System codes CE recognizes as multiboot collection folders
    static let systemCodes: Set<String> = [
        "nes-usa", "nes-jpn", "snes-usa", "snes-eur", "snes-jpn", "hvcj-jpn",
        "md-jpn", "md-usa", "md-eur", "md-asia",
    ]

    /// Parse "total | used | free" from `dfCommand` (KB → bytes)
    static func parseDf(_ output: String, into stats: inout MemoryStats) -> Bool {
        let parts = output.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count >= 3, let total = Int64(parts[0]), let used = Int64(parts[1]),
              let free = Int64(parts[2]) else { return false }
        stats.storageTotal = total * 1024
        stats.storageUsed = used * 1024
        stats.storageFree = free * 1024
        return true
    }

    /// Parse "path | sizeKB" lines from `collectionsCommand`
    static func parseCollections(_ output: String, into stats: inout MemoryStats) {
        stats.allGamesSize = 0
        stats.nonMultibootGamesSize = 0
        stats.extraFilesSize = 0
        stats.collections = [:]
        for line in output.split(whereSeparator: { "\n\r\u{0C}".contains($0) }) {
            let cols = line.components(separatedBy: " | ")
            guard cols.count == 2, let kb = Int64(cols[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let dir = (cols[0] as NSString).lastPathComponent
            let size = kb * 1024
            if dir == ".storage" || dir.range(of: "^[0-9]{3}$", options: .regularExpression) != nil {
                stats.nonMultibootGamesSize += size
            } else if systemCodes.contains(dir) {
                stats.collections[dir] = size
            } else {
                stats.extraFilesSize += size
            }
            stats.allGamesSize += size
        }
    }

    /// "1.2 MB" style sizes (CE's SizeSuffix), "-" for unknown
    static func sizeString(_ bytes: Int64) -> String {
        bytes < 0 ? "-" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    // MARK: - NAND layout (CE Sunxi.NandInfo)

    struct PartitionInfo: Equatable {
        let device: String
        let label: String
        let blockCount: Int64
        var size: Int64 { blockCount * 512 }
    }

    struct NandInfo: Equatable {
        let pageSize: Int64
        let pagesPerBlock: Int64
        let blockCount: Int64
        let partitions: [PartitionInfo]
        var nandSize: Int64 { pageSize * pagesPerBlock * blockCount }
        var rootfs: PartitionInfo? { partitions.first { $0.label == "rootfs" } }
        var data: PartitionInfo? { partitions.first { ["data", "rootfs_data"].contains($0.label) } }
    }

    /// Parse `sunxi-part` and `sunxi-flash nandinfo` output
    static func parseNandInfo(sunxiPart: String, nandInfo: String) -> NandInfo {
        let fields = nandInfo.split(separator: " ").map { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard fields.count >= 3, let page = fields[0], let ppb = fields[1], let blocks = fields[2] else {
            return NandInfo(pageSize: 0, pagesPerBlock: 0, blockCount: 0, partitions: [])
        }
        let regex = try! NSRegularExpression(pattern: #"(mbr|nand[a-z]):(.*?):(\d+)"#)
        let ns = sunxiPart as NSString
        let parts = regex.matches(in: sunxiPart, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            Int64(ns.substring(with: m.range(at: 3))).map {
                PartitionInfo(device: ns.substring(with: m.range(at: 1)), label: ns.substring(with: m.range(at: 2)),
                              blockCount: $0)
            }
        }
        return NandInfo(pageSize: page, pagesPerBlock: ppb, blockCount: blocks, partitions: parts)
    }

    /// CE's `ShellTasks.FormatDevice` command
    static func formatDeviceCommand(_ device: String) -> String {
        "yes | mke2fs -t ext4 -L data -b 4K -m 0 -J size=4 -E stripe-width=32 -O ^huge_file,^metadata_csum \(escapeShellArgument(device))"
    }

    // MARK: - Image file types (CE Files.CheckFileType)

    static func isTar(_ data: Data) -> Bool {
        data.count >= 262 && data[data.startIndex + 257 ..< data.startIndex + 262].elementsEqual("ustar".utf8)
    }

    /// SquashFS images start with "hsqs"
    static func isSquashFs(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual("hsqs".utf8)
    }

    /// ext2/3/4 superblock check, same tests as CE
    static func isExtFs(_ data: Data) -> Bool {
        func int32(_ offset: Int) -> Int32 {
            guard data.count >= offset + 4 else { return 0 }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }.littleEndian
        }
        guard data.count >= 0x468,
              data[data.startIndex + 0x438] == 0x53, data[data.startIndex + 0x439] == 0xEF else { return false }
        let c = int32(0x45c)
        if (c | 0x04) == 0x04 { return true }
        if (c & 0x04) == 0x04 {
            let i = int32(0x460)
            if i < 0x40 {
                let r = int32(0x464)
                // CE's condition is always true; kept for parity
                if r < 0x08 || r > 0x07 { return true }
            }
            if i > 0x3f { return true }
        }
        return false
    }

    // MARK: - Kernels (CE Shared.CorrectKernels)

    /// MD5 of every known stock kernel, by console
    static let correctKernels: [ConsoleType: [String]] = [
        .nes: ["5cfdca351484e7025648abc3b20032ff", "07bfb800beba6ef619c29990d14b5158",
               "90eec1e2b4f00e53dc2dd53a9e7334c1"],
        .famicom: ["ac8144c3ea4ab32e017648ee80bdc230", "cf5fd8e5ad0835bbf9dbd9bdc198a369"],
        .snesEur: ["d76c2a091ebe7b4614589fc6954653a5", "c2b57b550f35d64d1c6ce66f9b5180ce",
                   "0f890bc78cbd9ede43b83b015ba4c022"],
        .snesUsa: ["5296e64818bf2d1dbdc6b594f3eefd17", "449b711238575763c6701f5958323d48",
                   "228967ab1035a347caa9c880419df487"],
        .superFamicom: ["632e179db63d9bcd42281f776a030c14", "c3378edfc1b96a5268a066d5fbe12d89"],
        .superFamicomShonenJump: ["8a6731a5aebea36293f076fad9afa600"],
    ]

    /// Max size of a kernel image (CE's Fel.kernel_max_size)
    static let kernelMaxSize = 0x00800000

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True when `data` is a known stock kernel of any console
    static func isValidatedStockKernel(_ data: Data) -> Bool {
        guard data.count <= kernelMaxSize else { return false }
        let hash = md5Hex(data)
        return correctKernels.values.contains { $0.contains(hash) }
    }

    // MARK: - Mega Drive rootfs check (CE CheckMdRootfs)

    /// "md5  version" of known stock Mega Drive Mini system trees
    static let moonHashes: [String] = [
        "27132f57f5e2848c6a6f93ff1bce4804  MOON-mass-moon-es1-v0.8.1-1080US-e0c1975",
        "80e6df2cdf27e024f19cf3804ca956cb  MOON-mass-moon-es1-v0.8.3-1080US-0d16385",
        "e9f1ed8378db818f477a75c462916782  MOON-mass-moon-es1-v0.8.3-1085AS-1f2365d",
        "4d0dc84296b576f3b7fa30772b36a71b  MOON-mass-moon-es1-v0.8.3-1085EU-1f2365d",
        "010cb247983ebcfc245aa68da7221846  MOON-mass-moon-es1-v0.8.3-1085JP-1f2365d",
        "253d28b886595fa8369faabbbc751b3d  MOON-rework-moon-es1-v0.8.3-1080US-7c6101c",
        "ec5bb349eb675d65da91bfe3b5a2b31c  _MOON-mass-moon-es1-v0.8.0-1062US-d9de80c",
        "102e1104a9af8fc88c6cc2f521c70584  _MOON-mass-moon-es1-v0.8.1-1080US-e0c1975",
        "fbcae55f319b5c6300a87e360e3af92a  _MOON-rework-moon-es1-v0.8.1-1080US-71571fe",
        "b047d3c6bfa764483af09b0336a77069  MOON-mass-moon-es1-v0.8.1-1080US-e0c1975",
        "7d24875fd69a8690e6b7bf298eac5d0e  MOON-mass-moon-es1-v0.8.3-1080US-0d16385",
        "67342a75cf192c361f57e6a3bdbe0682  MOON-mass-moon-es1-v0.8.3-1085AS-1f2365d",
        "121babdd900ba8573e36c98ae51c48bf  MOON-mass-moon-es1-v0.8.3-1085EU-1f2365d",
        "8454dd4c8fdcdbed5563d68992248976  MOON-mass-moon-es1-v0.8.3-1085JP-1f2365d",
        "87ae9e15a0dfd72aa91e55c5583ef92c  MOON-rework-moon-es1-v0.8.3-1080US-7c6101c",
        "94cecd773757ff570f945ac9b375d261  _MOON-mass-moon-es1-v0.8.0-1062US-d9de80c",
        "c5d31c389940744ac94153935b949503  _MOON-mass-moon-es1-v0.8.1-1080US-e0c1975",
        "63a5f47e844ac6cc604f575e496e9ee9  _MOON-rework-moon-es1-v0.8.1-1080US-71571fe",
    ]

    enum MdRootfsVerdict: Equatable {
        case known
        /// The version is known but the files differ
        case modified
        case unknownVersion
    }

    static func checkMdRootfs(hash: String, version: String) -> MdRootfsVerdict {
        var knownHash = false
        var knownVersion = false
        for moon in moonHashes {
            if String(moon.prefix(32)) == hash { knownHash = true }
            if String(moon.dropFirst(34)) == version { knownVersion = true }
        }
        if !knownVersion { return .unknownVersion }
        return knownHash ? .known : .modified
    }

    // MARK: - hakchi.hmod version (var/version)

    struct HakchiVersion: Equatable {
        var boot = ""
        var kernel = ""
        var script = ""
    }

    /// Parse `var/version`: bootVersion='1.0.3' kernelVersion='…' hakchiVersion='v1.0.4-126'
    static func parseHakchiVersion(_ text: String) -> HakchiVersion {
        var v = HakchiVersion()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\" \t"))
            switch parts[0].trimmingCharacters(in: .whitespaces) {
            case "bootVersion": v.boot = value
            case "kernelVersion": v.kernel = value
            case "hakchiVersion": v.script = value
            default: break
            }
        }
        return v
    }

    /// True when `candidate` is newer than `current` (script, then kernel, then boot)
    static func isNewer(_ candidate: HakchiVersion, than current: HakchiVersion) -> Bool {
        for (a, b) in [(candidate.script, current.script), (candidate.kernel, current.kernel),
                       (candidate.boot, current.boot)] {
            let va = VersionTuple.parse(a), vb = VersionTuple.parse(b)
            if va != vb { return va > vb }
        }
        return false
    }

    // MARK: - Firmware (CE SelectFirmwareDialog)

    /// `.hsqs` paths from `find "/media/" "/var/lib/hakchi/" -iname "*.hsqs"`
    static func parseFirmwareList(_ output: String) -> [String] {
        // "\r\n" is one Character in Swift, so split on newline characters, not "\n"
        output.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    // MARK: - MOTD

    /// The date CE stamps into motd.md as "<!--- DATE --->"
    static func motdStamp(_ text: String) -> String? {
        guard let range = text.range(of: #"<!-+\s*(.*?)\s*-+>"#, options: .regularExpression) else { return nil }
        return String(text[range])
            .replacingOccurrences(of: #"^<!-+\s*|\s*-+>$"#, with: "", options: .regularExpression)
    }

    /// Cache is fresh for 6 hours, like CE
    static func isCacheFresh(modified: Date?, now: Date = Date(), maxAge: TimeInterval = 6 * 3600) -> Bool {
        guard let modified else { return false }
        return now.timeIntervalSince(modified) < maxAge
    }

    // MARK: - File browser

    struct RemoteFile: Identifiable, Hashable {
        let name: String
        let isDirectory: Bool
        let isLink: Bool
        let size: Int64
        var id: String { name }
    }

    /// Lists a folder: one line per entry "<type>|<size>|<name>" (busybox-friendly)
    static func listCommand(_ path: String) -> String {
        "cd \(quote(path)) && for f in .* *; do [ \"$f\" = . ] || [ \"$f\" = .. ] || [ ! -e \"$f\" -a ! -L \"$f\" ] && continue; "
            + "t=f; [ -L \"$f\" ] && t=l; [ -d \"$f\" ] && t=d; s=$(stat -c %s \"$f\" 2>/dev/null || echo 0); "
            + "echo \"$t|$s|$f\"; done"
    }

    static func parseListing(_ output: String) -> [RemoteFile] {
        output.components(separatedBy: .newlines).compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[2].isEmpty else { return nil }
            return RemoteFile(name: parts[2], isDirectory: parts[0] == "d", isLink: parts[0] == "l",
                              size: Int64(parts[1]) ?? 0)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }
}
