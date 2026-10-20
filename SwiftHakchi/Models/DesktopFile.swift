import Foundation

/// Parser/serializer for .desktop files used by the NES/SNES Classic
final class DesktopFile {
    /// Full command line. `bin` and `args` are derived from it.
    var exec: String = ""
    var profilePath: String = ""
    var name: String = ""
    var cePrefix: String = ""
    var iconPath: String = ""
    var iconFilename: String?
    var code: String = ""
    var testId: Int = 0
    var status: String = ""
    var players: Int = 1
    var simultaneous: Bool = false
    var releaseDate: String = "1900-01-01"
    var saveCount: Int = 0
    var sortName: String = ""
    var publisher: String = "UNKNOWN"
    var copyright: String = ""
    var genre: String = ""
    var index: String = ""
    var demoTime: String = ""
    var country: String = ""
    var regionTag: String = ""
    var description: String = ""

    var hasUnsavedChanges: Bool = false

    /// Whether to include SNES-specific fields (Status, MyPlayDemoTime)
    var snesExtraFields: Bool = false

    /// Whether to omit /{code} from Path= line
    var omitProfilePathCode: Bool = false

    init() {}

    /// Load from a .desktop file's contents
    init(data: Data) {
        guard let content = String(data: data, encoding: .utf8) else { return }
        load(from: content)
    }

    init(string: String) {
        load(from: string)
    }

    // MARK: - Parsing

    func load(from content: String) {
        let lines = content.components(separatedBy: .newlines)
        var inDescription = false
        var descriptionLines: [String] = []

        for line in lines {
            if inDescription {
                // Skip the "Text = " marker line
                if descriptionLines.isEmpty && line.trimmingCharacters(in: .whitespaces) == "Text =" {
                    continue
                }
                descriptionLines.append(line)
                continue
            }

            if line.trimmingCharacters(in: .whitespaces) == "[Description]" {
                inDescription = true
                continue
            }

            // Skip section headers
            if line.hasPrefix("[") { continue }

            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "exec":
                exec = value
            case "path":
                let normalized = value.replacingOccurrences(of: "\\", with: "/")
                    .replacingOccurrences(of: "//", with: "/")
                profilePath = (normalized as NSString).deletingLastPathComponent
            case "name":
                name = value
            case "ceprefix":
                cePrefix = value
            case "icon":
                let normalized = value.replacingOccurrences(of: "\\", with: "/")
                // iconPath = grandparent directory
                let parent = (normalized as NSString).deletingLastPathComponent
                iconPath = (parent as NSString).deletingLastPathComponent
                iconFilename = (normalized as NSString).lastPathComponent
            case "code":
                code = value
            case "testid":
                testId = Int(value) ?? 0
            case "status":
                status = value
            case "players":
                players = Int(value) ?? 1
            case "simultaneous":
                simultaneous = (Int(value) ?? 0) != 0
            case "releasedate":
                releaseDate = value
            case "savecount":
                saveCount = Int(value) ?? 0
            case "sortrawtitle":
                sortName = value
            case "sortrawpublisher":
                publisher = value
            case "copyright":
                copyright = value
            case "sortrawgenre":
                genre = value
            case "index":
                index = value
            case "demo_time":
                demoTime = value
            case "country":
                country = value
            case "regiontag":
                regionTag = value
            default:
                break
            }
        }

        // Join description lines
        description = descriptionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        hasUnsavedChanges = false
    }

    // MARK: - Exec helpers

    /// Program part of Exec, including any " -rom" suffix (CE's `Bin`),
    /// e.g. "/bin/clover-canoe-shvc-wr -rom"
    var bin: String {
        Self.splitExec(exec).bin
    }

    /// Arguments after the program, split on spaces (CE's `Args`); `args[0]` is the ROM path
    var args: [String] {
        Self.splitExec(exec).args
    }

    /// ROM path on the console (first argument), if any
    var romPath: String? {
        args.first
    }

    static func splitExec(_ exec: String) -> (bin: String, args: [String]) {
        let value = exec.trimmingCharacters(in: .whitespaces)
        guard let match = value.range(of: #"^[^\s]+(?:\s+-rom)*"#, options: .regularExpression) else {
            return (value, [])
        }
        let remainder = String(value[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (String(value[match]), remainder.split(separator: " ").map(String.init))
    }

    /// Replace only the leading program, keeping the ROM path and all arguments.
    /// (CE used `exec.Replace(bin, new)`, which also replaced matches inside paths.)
    func replaceBin(with newBin: String) {
        let parts = Self.splitExec(exec)
        exec = ([newBin] + parts.args).joined(separator: " ")
    }

    /// Point every argument that contains "…/<code>/" at `base/<code>/`, leaving the
    /// program untouched. Used to normalize console paths to "/var/games" on import
    /// and to point at the upload location at sync time (CE does the same per arg).
    func rebaseGamePaths(to base: String) {
        guard !code.isEmpty else { return }
        let parts = Self.splitExec(exec)
        let pattern = "^[^\\s]*/" + NSRegularExpression.escapedPattern(for: code) + "/"
        let template = NSRegularExpression.escapedTemplate(for: base + "/" + code + "/")
        let regex = try! NSRegularExpression(pattern: pattern)
        let newArgs = parts.args.map { arg -> String in
            let range = NSRange(arg.startIndex..., in: arg)
            return regex.stringByReplacingMatches(in: arg, range: range, withTemplate: template)
        }
        exec = ([parts.bin] + newArgs).joined(separator: " ")
    }

    /// CE's fixes applied before every save: an apostrophe followed by a digit
    /// crashes the console menu, and an empty sort name is derived from the name.
    func normalizeForSave() {
        name = name.replacingOccurrences(of: #"'(\d)"#, with: "`$1", options: .regularExpression)
        sortName = sortName.replacingOccurrences(of: #"'(\d)"#, with: "`$1", options: .regularExpression)
        if sortName.isEmpty {
            var s = name.lowercased()
            if s.hasPrefix("the ") { s.removeFirst(4) }
            sortName = s
        }
    }

    // MARK: - Serialization

    func serialize() -> String {
        var lines: [String] = []

        lines.append("[Desktop Entry]")
        lines.append("Type=Application")
        lines.append("Exec=\(exec)")

        if omitProfilePathCode {
            lines.append("Path=\(profilePath)")
        } else {
            lines.append("Path=\(profilePath)/\(code)")
        }

        lines.append("Name=\(name.isEmpty ? code : name)")
        lines.append("CePrefix=\(cePrefix)")
        lines.append("Icon=\(iconPath)/\(code)/\(iconFilename ?? "\(code).png")")

        lines.append("")
        lines.append("[X-CLOVER Game]")
        lines.append("Code=\(code)")
        lines.append("TestID=\(testId)")

        if snesExtraFields {
            lines.append("Status=\(status)")
        }

        lines.append("ID=0")
        lines.append("Players=\(players)")
        lines.append("Simultaneous=\(simultaneous ? 1 : 0)")
        lines.append("ReleaseDate=\(releaseDate)")
        lines.append("SaveCount=\(saveCount)")
        lines.append("SortRawTitle=\(sortName)")
        lines.append("SortRawPublisher=\(publisher.uppercased())")
        lines.append("Copyright=\(copyright)")

        if snesExtraFields {
            lines.append("MyPlayDemoTime=45")
        }

        lines.append("")
        lines.append("[m2engage]")
        lines.append("regionTag=\(regionTag)")
        lines.append("sortRawGenre=\(genre)")
        lines.append("index=\(index)")
        lines.append("demo_time=\(demoTime)")
        lines.append("country=\(country)")

        lines.append("")
        lines.append("[Description]")
        lines.append("Text = ")
        // Normalize line endings
        let descText = description.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(descText)

        return lines.joined(separator: "\n") + "\n"
    }

    func toData() -> Data {
        serialize().data(using: .utf8) ?? Data()
    }
}
