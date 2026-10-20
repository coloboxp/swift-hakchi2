import Foundation

/// Game Genie support (port of Hakchi2-CE's `GameGenie/` folder and `ApplyGameGenie`).
///
/// A game's active codes live in `gamegenie.txt` in its folder (comma separated).
/// At sync time the ROM is patched in a copy; the library file is never changed.
/// Code suggestions come from `GameGenieDB.xml`: the user's copy in the config folder
/// if it exists, else the bundled one (same as CE).
enum GameGenie {
    static let fileName = "gamegenie.txt"

    // MARK: - Per-game codes

    static func codes(gameDirectory: URL) -> [String] {
        guard let text = try? String(contentsOf: gameDirectory.appendingPathComponent(fileName), encoding: .utf8) else {
            return []
        }
        return splitCodes(text)
    }

    static func setCodes(_ codes: [String], gameDirectory: URL) throws {
        let url = gameDirectory.appendingPathComponent(fileName)
        let cleaned = codes.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
        if cleaned.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try cleaned.joined(separator: ",").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// CE splits on comma, tab, space and semicolon
    static func splitCodes(_ text: String) -> [String] {
        text.split(whereSeparator: { ",\t ;\n\r".contains($0) }).map { String($0).uppercased() }
    }

    /// Format check with CE's rules: NES = 6 or 8 Game Genie letters, SNES = "XXXX-XXXX"
    static func isValidCode(_ raw: String) -> Bool {
        let code = raw.uppercased().trimmingCharacters(in: .whitespaces)
        if (code.count == 6 || code.count == 8) && code.allSatisfy({ nesLetters[$0] != nil }) {
            // The 3rd letter's high bit tells 6 (0) from 8 (1) letter codes
            let flag = nesLetters[Array(code)[2]]!.first!
            return (code.count == 6) == (flag == "0")
        }
        let parts = code.split(separator: "-")
        return parts.count == 2 && parts.allSatisfy { $0.count == 4 }
            && code.replacingOccurrences(of: "-", with: "").allSatisfy { "0123456789ABCDEF".contains($0) }
    }

    // MARK: - Patching

    /// The ROM with the game's codes applied, or nil when it has no codes or the
    /// ROM type is not supported (only uncompressed .nes, .sfrom, .sfc, .smc).
    static func patchedRom(gameDirectory: URL, romFileName: String) throws -> Data? {
        let codes = codes(gameDirectory: gameDirectory)
        guard !codes.isEmpty else { return nil }
        let data = try Data(contentsOf: gameDirectory.appendingPathComponent(romFileName))
        return try patch(data, fileName: romFileName, codes: codes)
    }

    /// Apply codes to ROM file contents according to its type
    static func patch(_ data: Data, fileName: String, codes: [String]) throws -> Data? {
        let name = fileName.lowercased()
        if name.hasSuffix(".nes") {
            var rom = try NesRom(data: data)
            for code in codes { rom.prg = try patchNES(rom.prg, code: code) }
            return rom.rawData()
        }
        let offset: Int
        if name.contains(".sfrom") {
            offset = 48
        } else if name.hasSuffix(".sfc") || name.hasSuffix(".smc") {
            offset = data.count % 1024 != 0 ? 512 : 0
        } else {
            return nil
        }
        var raw = Data(data.dropFirst(offset))
        for code in codes { raw = try patchSNES(raw, code: code) }
        return Data(data.prefix(offset)) + raw
    }

    private static let nesLetters: [Character: String] = [
        "A": "0000", "P": "0001", "Z": "0010", "L": "0011", "G": "0100", "I": "0101", "T": "0110", "Y": "0111",
        "E": "1000", "O": "1001", "X": "1010", "U": "1011", "K": "1100", "S": "1101", "V": "1110", "N": "1111",
    ]

    /// CE's `GameGeniePatcherNes.Patch` on the PRG data
    static func patchNES(_ prg: Data, code rawCode: String) throws -> Data {
        let code = rawCode.uppercased().trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return prg }
        var bits = ""
        for c in code {
            guard let b = nesLetters[c] else { throw GameGenieError.badFormat(code) }
            bits += b
        }
        let b = Array(bits)
        func value(_ indices: [Int]) -> Int { Int(String(indices.map { b[$0] }), radix: 2)! }
        let addressBits = [13, 14, 15, 16, 21, 22, 23, 4, 9, 10, 11, 12, 17, 18, 19]
        var result = [UInt8](prg)
        guard !result.isEmpty else { throw GameGenieError.badFormat(code) }

        if b.count == 24 {
            guard b[8] == "0" else { throw GameGenieError.badFormat(code) }
            let v = UInt8(value([0, 5, 6, 7, 20, 1, 2, 3]))
            let address = value(addressBits)
            if result.count <= 0x8000 {
                result[address % result.count] = v
            } else {
                var pos = address % 0x2000
                while pos < result.count { result[pos] = v; pos += 0x2000 }
            }
        } else if b.count == 32 {
            guard b[8] == "1" else { throw GameGenieError.badFormat(code) }
            let v = UInt8(value([0, 5, 6, 7, 28, 1, 2, 3]))
            let address = value(addressBits)
            let compare = UInt8(value([24, 29, 30, 31, 20, 25, 26, 27]))
            var replaced = false
            var pos = address % 0x2000
            while pos < result.count {
                if result[pos] == compare { result[pos] = v; replaced = true }
                pos += 0x2000
            }
            if !replaced { throw GameGenieError.notFound(code) }
        } else {
            throw GameGenieError.badFormat(code)
        }
        return Data(result)
    }

    private static let snesLetters: [Character: String] = [
        "D": "0000", "F": "0001", "4": "0010", "7": "0011", "0": "0100", "9": "0101", "1": "0110", "5": "0111",
        "6": "1000", "B": "1001", "C": "1010", "8": "1011", "A": "1100", "2": "1101", "3": "1110", "E": "1111",
    ]

    /// CE's `GameGeniePatcherSnes.Patch` on the headerless ROM
    static func patchSNES(_ data: Data, code rawCode: String) throws -> Data {
        var code = rawCode.uppercased().trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return data }
        guard code.count == 9, Array(code)[4] == "-" else { throw GameGenieError.badFormat(code) }
        code = code.filter { "0123456789ABCDEF".contains($0) }
        guard code.count == 8, let value = UInt8(code.prefix(2), radix: 16) else { throw GameGenieError.badFormat(code) }

        var bits = ""
        for c in code.dropFirst(2) {
            guard let b = snesLetters[c] else { throw GameGenieError.badFormat(code) }
            bits += b
        }
        // Unscramble: bit i of the code goes to position clearSeq.index(of: codeSeq[i])
        let codeSeq = Array("ijklqrstopabcduvwxefghmn"), clearSeq = Array("abcdefghijklmnopqrstuvwx")
        var decoded = [Character](repeating: "0", count: bits.count)
        for (i, bit) in bits.enumerated() {
            decoded[clearSeq.firstIndex(of: codeSeq[i])!] = bit
        }
        var address = (UInt32(String(decoded), radix: 2) ?? 0) & 0x3FFFFF
        if (try? SnesRom.detectHeader(data).type) == .loRom { address &= 0x3FFFF }

        var result = [UInt8](data)
        guard Int(address) < result.count else { throw GameGenieError.badFormat(code) }
        result[Int(address)] = value
        return Data(result)
    }
}

/// A suggested code from the database
struct GameGenieCode: Hashable, Identifiable {
    var code: String
    var description: String
    var id: String { code }
}

/// `GameGenieDB.xml`: suggested codes per game code (CE's `GameGenieDataBase`)
final class GameGenieDatabase {
    let userURL: URL
    private let document: XMLDocument

    init(userURL: URL = AppConfig.configDirectory.appendingPathComponent("GameGenieDB.xml"),
         bundledURL: URL? = Bundle.appBundle.url(forResource: "GameGenieDB", withExtension: "xml")) {
        self.userURL = userURL
        let source = FileManager.default.fileExists(atPath: userURL.path) ? userURL : bundledURL
        document = source.flatMap { try? XMLDocument(contentsOf: $0) }
            ?? XMLDocument(rootElement: XMLElement(name: "database"))
    }

    func codes(forGameCode code: String) -> [GameGenieCode] {
        guard let game = gameElement(code) else { return [] }
        return (game.elements(forName: "gamegenie")).compactMap { node in
            guard let c = node.attribute(forName: "code")?.stringValue else { return nil }
            return GameGenieCode(code: c, description: node.attribute(forName: "description")?.stringValue ?? "")
        }
    }

    /// Add or update a code for a game (creates the game entry like CE)
    func setCode(_ entry: GameGenieCode, gameCode: String, gameName: String, crc32: UInt32) {
        let game = gameElement(gameCode) ?? {
            let el = XMLElement(name: "game")
            el.addAttribute(XMLNode.attribute(withName: "code", stringValue: gameCode) as! XMLNode)
            el.addAttribute(XMLNode.attribute(withName: "name", stringValue: gameName) as! XMLNode)
            el.addAttribute(XMLNode.attribute(withName: "crc", stringValue: String(format: "%X", crc32)) as! XMLNode)
            document.rootElement()?.addChild(el)
            return el
        }()
        if let existing = game.elements(forName: "gamegenie").first(where: {
            $0.attribute(forName: "code")?.stringValue == entry.code
        }) {
            existing.attribute(forName: "description")?.stringValue = entry.description
        } else {
            let el = XMLElement(name: "gamegenie")
            el.addAttribute(XMLNode.attribute(withName: "code", stringValue: entry.code) as! XMLNode)
            el.addAttribute(XMLNode.attribute(withName: "description", stringValue: entry.description) as! XMLNode)
            game.addChild(el)
        }
    }

    func removeCode(_ code: String, gameCode: String) {
        guard let game = gameElement(gameCode) else { return }
        for el in game.elements(forName: "gamegenie") where el.attribute(forName: "code")?.stringValue == code {
            el.detach()
        }
        if game.elements(forName: "gamegenie").isEmpty { game.detach() }
    }

    /// Write the user copy (the bundled file is never changed)
    func save() throws {
        try FileManager.default.createDirectory(at: userURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.xmlData(options: .nodePrettyPrint).write(to: userURL)
    }

    private func gameElement(_ code: String) -> XMLElement? {
        document.rootElement()?.elements(forName: "game").first { $0.attribute(forName: "code")?.stringValue == code }
    }
}

enum GameGenieError: LocalizedError {
    case badFormat(String), notFound(String)

    var errorDescription: String? {
        switch self {
        case .badFormat(let c): return "\"\(c)\" is not a valid Game Genie code."
        case .notFound(let c): return "The value to replace for \"\(c)\" was not found in the ROM."
        }
    }
}
