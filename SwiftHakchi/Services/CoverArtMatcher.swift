import Foundation
import SWCompression
import os

/// Finds box art for a game in the local `art/` library
/// (port of Hakchi2-CE's `FindCover`, `FindCoverMatch` and `PuzzleMatch`).
///
/// Order, as in CE:
/// 1. `art/**/<CRC32 hex>*.<image>` (most precise)
/// 2. Bundled Mega Drive Mini art (`original_art.tar`, `<file name>_mdmini.png`)
/// 3. An image with the ROM's name next to the ROM
/// 4. Fuzzy word match in `art/<System>/` (or `art/`): first on the file name, then on
///    the title with (tags) removed. Exactly one precise match is applied automatically;
///    otherwise the candidates are returned so the user can choose.
struct CoverArtMatcher {
    enum Result: Equatable {
        /// Image to apply
        case found(URL)
        /// Bundled Mega Drive Mini art, already composed
        case mdMini(Data)
        /// Several or only partial matches: let the user pick
        case ambiguous([URL])
        case none
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "bmp", "gif", "tif", "tiff"]

    let artDirectory: URL
    /// Bundled original_art.tar (nil in tests)
    var originalArtTar: URL?

    init(artDirectory: URL = LibraryStorage.artDirectory,
         originalArtTar: URL? = Bundle.appBundle.url(forResource: "original_art", withExtension: "tar")) {
        self.artDirectory = artDirectory
        self.originalArtTar = originalArtTar
    }

    func findCover(romFileName: String, sourceDirectory: URL?, crc32: UInt32, system: String,
                   alternateTitle: String?) -> Result {
        let fm = FileManager.default
        try? fm.createDirectory(at: artDirectory, withIntermediateDirectories: true)
        let baseName = (romFileName as NSString).deletingPathExtension
        let allFiles = imageFiles(in: artDirectory)

        // 1. CRC32 prefix anywhere under art/
        if crc32 != 0 {
            let prefix = String(format: "%08X", crc32)
            if let hit = allFiles.first(where: { $0.lastPathComponent.uppercased().hasPrefix(prefix) }) {
                return .found(hit)
            }
        }

        // 2. Bundled Mega Drive Mini art
        if let tar = originalArtTar, let data = Self.originalArt(named: "\(baseName)_mdmini.png", in: tar) {
            return .mdMini(data)
        }

        // 3. Image next to the ROM
        if let sourceDirectory, !baseName.isEmpty {
            for ext in Self.imageExtensions.sorted() {
                let url = sourceDirectory.appendingPathComponent("\(baseName).\(ext)")
                if fm.fileExists(atPath: url.path) { return .found(url) }
            }
        }

        // 4. Fuzzy matches, in art/<System>/ when it exists
        var searchFiles = allFiles
        let systemDir = artDirectory.appendingPathComponent(system, isDirectory: true)
        if !system.isEmpty, fm.fileExists(atPath: systemDir.path) { searchFiles = imageFiles(in: systemDir) }

        var candidates: [URL] = []
        for (name, strip) in [(baseName, false), (alternateTitle ?? "", true)] where !name.isEmpty {
            let results = Self.findCoverMatch(name: name, files: searchFiles, stripCodes: strip)
            let precise = results.filter { !$0.partial }
            candidates.append(contentsOf: results.map(\.url))
            if precise.count == 1 { return .found(precise[0].url) }
        }
        var seen = Set<URL>()
        candidates = candidates.filter { seen.insert($0).inserted }
        return candidates.isEmpty ? .none : .ambiguous(candidates)
    }

    // MARK: - Fuzzy matching (CE)

    /// Files whose sanitized name contains every word of `name`, in any order.
    /// `partial` is true when the file name has extra words.
    static func findCoverMatch(name: String, files: [URL], stripCodes: Bool) -> [(url: URL, partial: Bool)] {
        let sanitizedName = sanitize(name)
        guard !sanitizedName.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        // Word alternatives, as in CE
        var words: [[String]] = []
        for word in sanitizedName.split(separator: " ").map(String.init) {
            if word == "&" || word == "and" {
                words.append(["&", "and", ""])
            } else if word == "the" {
                words.append(["the", ""])
            } else if word.range(of: #"^[0-9]{1,2}$"#, options: .regularExpression) != nil, let n = Int(word) {
                words.append([word, integerToRoman(n).lowercased()])
            } else if word.range(of: #"^[ivx]+$"#, options: .regularExpression) != nil {
                words.append([word, String(romanToInteger(word))])
            } else if word.count == 1 {
                words.append([word, ""])
            } else {
                words.append([word])
            }
        }

        var results: [(URL, Bool)] = []
        for file in files where imageExtensions.contains(file.pathExtension.lowercased()) {
            var fileName = file.deletingPathExtension().lastPathComponent
            if stripCodes {
                fileName = fileName.replacingOccurrences(of: #"\s?\(.*?\)|\s?\[.*?\]"#, with: "",
                                                         options: .regularExpression)
            }
            let (match, partial) = puzzleMatch(words[...], sanitize(fileName))
            if match { results.append((file, partial)) }
        }
        return results
    }

    /// " word word " lowercased, letters/digits/& only
    static func sanitize(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: #"[^\p{L}\p{Nd}0-9\&]"#, with: " ", options: .regularExpression)
            .lowercased()
        return (" " + cleaned + " ").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Remaining text counts as "iteration" (a sequel number) when it holds a number
    private static let iterationPattern = #"\s[ivx]+\s|[0-9]{1,2}"#

    /// CE's recursive match: every piece must be found (one alternative each);
    /// leftovers make it partial, and leftover sequel numbers make it fail.
    static func puzzleMatch(_ pieces: ArraySlice<[String]>, _ puzzle: String) -> (match: Bool, partial: Bool) {
        if pieces.isEmpty {
            if puzzle.trimmingCharacters(in: .whitespaces).isEmpty { return (true, false) }
            if puzzle.range(of: iterationPattern, options: .regularExpression) == nil { return (true, true) }
            return (false, false)
        }
        if puzzle.trimmingCharacters(in: .whitespaces).isEmpty {
            let words = " " + pieces.map { $0.joined(separator: " ") }.joined(separator: " ") + " "
            if words.range(of: iterationPattern, options: .regularExpression) == nil { return (true, true) }
            return (false, false)
        }

        let rest = pieces.dropFirst()
        for alt in pieces.first! {
            if alt.isEmpty {
                let r = puzzleMatch(rest, puzzle)
                if r.match { return r }
                continue
            }
            var searchStart = puzzle.startIndex
            while searchStart < puzzle.endIndex, let range = puzzle.range(of: alt, range: searchStart..<puzzle.endIndex) {
                var remaining = puzzle
                remaining.removeSubrange(range)
                let r = puzzleMatch(rest, remaining)
                if r.match { return r }
                searchStart = puzzle.index(after: range.lowerBound)
            }
        }
        return (false, false)
    }

    static func integerToRoman(_ number: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = number, out = ""
        for (value, numeral) in table {
            while n >= value { out += numeral; n -= value }
        }
        return out
    }

    static func romanToInteger(_ roman: String) -> Int {
        let map: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]
        let chars = Array(roman.lowercased())
        var number = 0
        for i in chars.indices {
            let value = map[chars[i]] ?? 0
            if i + 1 < chars.count, value < (map[chars[i + 1]] ?? 0) { number -= value } else { number += value }
        }
        return number
    }

    // MARK: - Helpers

    private func imageFiles(in dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
    }

    /// Parsed original_art.tar, by entry name without "./" (loaded once)
    private static let originalArtIndex = OSAllocatedUnfairLock<(URL, [String: Data])?>(initialState: nil)

    /// Entry `./<name>` of the bundled original art tar
    static func originalArt(named name: String, in tar: URL) -> Data? {
        let index: [String: Data] = originalArtIndex.withLock { cached in
            if let cached, cached.0 == tar { return cached.1 }
            var map: [String: Data] = [:]
            if let data = try? Data(contentsOf: tar, options: .mappedIfSafe),
               let entries = try? TarContainer.open(container: data) {
                for entry in entries {
                    var key = entry.info.name
                    if key.hasPrefix("./") { key.removeFirst(2) }
                    if let d = entry.data { map[key] = d }
                }
            }
            cached = (tar, map)
            return map
        }
        return index[name]
    }
}
