import Foundation

/// Saves and loads Folders Manager trees in Hakchi2-CE's format
/// (`config/folders<suffix>.htm`, plus the legacy `/Tree/Folder/Game` XML).
///
/// htm layout (CE's TreeToXml):
/// ```
/// <!DOCTYPE html>
/// <html lang=""><head><title>Swift Hakchi2 Games - X</title><style>…</style></head>
/// <body><h1>X</h1><ul>
///   <li data-type="folder" data-icon="folder_a" data-position="3">Name<ul>…</ul></li>
///   <li data-type="application" class="icon-0" data-code="CLV-H-ABCDE">Game</li>
/// </ul></body></html>
/// ```
enum FolderTreeStore {
    /// File name suffix per console (CE's FoldersXmlPathBase)
    static func suffix(for console: ConsoleType) -> String {
        switch console {
        case .famicom: return "_famicom"
        case .superFamicomShonenJump: return "_shonen_jump"
        case .snesEur: return "_snes_eur"
        case .snesUsa: return "_snes_usa"
        case .superFamicom: return "_super_famicom"
        case .megaDrive: return "_md_usa"
        default: return ""
        }
    }

    static func fileURL(for console: ConsoleType, extension ext: String = "htm") -> URL {
        AppConfig.configDirectory.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("folders\(suffix(for: console)).\(ext)")
    }

    // MARK: - Save

    static func save(_ root: MenuCollection, console: ConsoleType) throws {
        let url = fileURL(for: console)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(htm(for: root, title: console.displayName).utf8).write(to: url)
        try? FileManager.default.removeItem(at: fileURL(for: console, extension: "xml"))
    }

    /// The htm document for a tree (back folders are not written)
    static func htm(for root: MenuCollection, title: String) -> String {
        var body = ""
        var visited: [MenuCollection] = [root]
        writeItems(root, into: &body, visited: &visited)
        let t = escape(title)
        return "<!DOCTYPE html>\n<html lang=\"\"><head><title>Swift Hakchi2 Games - \(t)</title>"
            + "<style>\(css)</style></head><body><h1>\(t)</h1><ul>\(body)</ul></body></html>"
    }

    private static func writeItems(_ menu: MenuCollection, into out: inout String, visited: inout [MenuCollection]) {
        for element in menu.elements {
            switch element {
            case .folder(let f):
                if visited.contains(where: { $0 === f.child }) { continue }  // back links
                visited.append(f.child)
                out += "<li data-type=\"folder\" data-icon=\"\(escape(f.imageId))\" data-position=\"\(f.position.rawValue)\">"
                out += escape(f.name) + "<ul>"
                writeItems(f.child, into: &out, visited: &visited)
                out += "</ul></li>"
            case .game(let g):
                out += "<li data-type=\"application\" class=\"icon-0\" data-code=\"\(escape(g.code))\">\(escape(g.name))</li>"
            }
        }
    }

    private static let css = "body{font-family:Arial,Helvetica,sans-serif;font-size:12px;margin:1em}"
        + "ul{list-style:none;padding:0}li{display:inline-block;margin:3px 0;padding:0 0 0 20px;width:100%}"
        + "li ul{margin-left:1em}"

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Load

    /// Load the saved tree for a console, placing `games` into it. Games the file does
    /// not mention go into an "Unsorted" folder (CE's XmlToTree). Nil when no file exists.
    static func load(console: ConsoleType, games: [MenuGame]) throws -> (root: MenuCollection, unsorted: Int)? {
        let htmURL = fileURL(for: console)
        let xmlURL = fileURL(for: console, extension: "xml")
        let url = FileManager.default.fileExists(atPath: htmURL.path) ? htmURL : xmlURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try parse(text, games: games)
    }

    /// Parse htm or legacy xml text into a tree
    static func parse(_ text: String, games: [MenuGame]) throws -> (root: MenuCollection, unsorted: Int) {
        let doc = try XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever])
        let list: XMLNode? = try doc.nodes(forXPath: "/Tree").first ?? doc.nodes(forXPath: "/html/body/ul").first
        guard let list else { throw FolderTreeError.invalidFile }

        var remaining = games
        let root = MenuCollection()
        addChildren(of: list, to: root, remaining: &remaining)

        if !remaining.isEmpty {
            let unsorted: MenuFolder
            if let existing = root.folders.first(where: { $0.name == MenuFolderNames.unsorted }) {
                unsorted = existing
            } else {
                unsorted = MenuFolder(name: MenuFolderNames.unsorted, position: .leftmost)
                root.add(.folder(unsorted))
            }
            remaining.forEach { unsorted.child.add(.game($0)) }
        }
        return (root, remaining.count)
    }

    private static func addChildren(of node: XMLNode, to menu: MenuCollection, remaining: inout [MenuGame]) {
        for child in node.children ?? [] {
            guard let element = child as? XMLElement else { continue }
            let type = element.attribute(forName: "data-type")?.stringValue ?? ""
            switch (element.name ?? "", type) {
            case ("Folder", _), ("li", "folder"):
                let name = element.attribute(forName: "name")?.stringValue
                    ?? element.children?.first(where: { $0.kind == .text })?.stringValue?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? MenuFolderNames.newFolder
                let icon = element.attribute(forName: "data-icon")?.stringValue
                    ?? element.attribute(forName: "icon")?.stringValue ?? "folder"
                let positionText = element.attribute(forName: "data-position")?.stringValue
                    ?? element.attribute(forName: "position")?.stringValue ?? "3"
                let folder = MenuFolder(name: name, imageId: icon,
                                        position: FolderPriority(rawValue: Int(positionText) ?? 3) ?? .right)
                menu.add(.folder(folder))
                let content = element.name == "li" ? element.elements(forName: "ul").first : element
                if let content { addChildren(of: content, to: folder.child, remaining: &remaining) }
            case ("Game", _), ("li", "application"):
                let code = element.attribute(forName: "data-code")?.stringValue
                    ?? element.attribute(forName: "code")?.stringValue ?? ""
                if let i = remaining.firstIndex(where: { $0.code == code }) {
                    menu.add(.game(remaining.remove(at: i)))
                }
            default:
                continue
            }
        }
    }
}

enum FolderTreeError: LocalizedError {
    case invalidFile

    var errorDescription: String? { "The folders file is not a valid folders file." }
}
