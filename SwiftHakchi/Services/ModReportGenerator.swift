import Foundation

/// Builds the "Generate modules report" HTML page (port of Hakchi2-CE's
/// `generateModulesReportToolStripMenuItem_Click` + `addModInfoToReport`).
enum ModReportGenerator {
    /// One module row: package name plus its readme front matter
    struct Entry: Sendable {
        let rawName: String
        let frontMatter: [(key: String, value: String)]
    }

    /// - Parameters:
    ///   - installed: modules on the console, or nil when no console is connected
    ///   - available: modules in the local library
    static func html(installed: [Entry]?, available: [Entry]) -> String {
        var out: [String] = []
        if let installed {
            out.append("<h1>Installed Mods</h1>")
            out.append("<div class=\"ModList\">")
            append(installed, to: &out)
            out.append("</div>")
        } else {
            out.append("<h1>System Not Online</h1>")
        }
        out.append("<h1>Available Mods</h1>")
        out.append("<div class=\"ModList\">")
        append(available, to: &out)
        out.append("</div>")

        return ModReportTemplate.html.replacingOccurrences(of: "<body></body>",
                                                          with: "<body>\(out.joined())</body>")
    }

    private static func append(_ entries: [Entry], to out: inout [String]) {
        for entry in entries.sorted(by: { $0.rawName < $1.rawName }) {
            out.append("<div class=\"Mod\">")
            out.append("<h2>\(escape(entry.rawName))</h2>")
            for (key, value) in entry.frontMatter {
                out.append("<div><strong>\(escape(key)):</strong> \(escape(value))</div>")
            }
            out.append("</div>")
        }
    }

    /// HTML-encode like .NET's WebUtility.HtmlEncode for the characters that matter
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
