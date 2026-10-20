import SwiftUI
import AppKit

/// Remote file browser (replaces CE's "Open FTP client"): browse, download,
/// upload, create folders and delete, over the SSH session.
struct FileBrowserView: View {
    @EnvironmentObject var appState: AppState

    @State private var path = "/"
    @State private var pathField = "/"
    @State private var files: [ConsoleTools.RemoteFile] = []
    @State private var selection: Set<String> = []
    @State private var isBusy = false
    @State private var status: String?
    @State private var error: String?

    private var tools: ConsoleToolsService? {
        appState.deviceManager.sshService.map { ConsoleToolsService(shell: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { go((path as NSString).deletingLastPathComponent) } label: { Image(systemName: "arrow.up") }
                    .help("Parent folder")
                    .disabled(path == "/")
                TextField("Path", text: $pathField).textFieldStyle(.roundedBorder).onSubmit { go(pathField) }
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
            .padding(8)

            Table(files, selection: $selection) {
                TableColumn("Name") { file in
                    Label(file.name, systemImage: file.isDirectory ? "folder" : (file.isLink ? "link" : "doc"))
                }
                TableColumn("Size") { file in
                    Text(file.isDirectory ? "—" : ConsoleTools.sizeString(file.size))
                }
                .width(90)
            }
            .contextMenu(forSelectionType: String.self) { _ in
                Button("Download...") { download() }
                Button("Delete...", role: .destructive) { delete() }
            } primaryAction: { names in
                if let name = names.first, let file = files.first(where: { $0.name == name }), file.isDirectory {
                    go((path as NSString).appendingPathComponent(name))
                }
            }
            .overlay { if isBusy { ProgressView() } }

            if let message = error ?? status {
                Text(message).font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).textSelection(.enabled)
            }

            HStack {
                Button("New Folder...") { newFolder() }
                Spacer()
                Button("Upload...") { upload() }
                Button("Download...") { download() }.disabled(selection.isEmpty)
                Button("Delete...", role: .destructive) { delete() }.disabled(selection.isEmpty)
            }
            .padding(8)
            .disabled(isBusy || tools == nil)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { load() }
    }

    // MARK: - Actions

    private func run(_ message: String? = nil, _ work: @escaping (ConsoleToolsService) async throws -> Void) {
        guard let tools else { error = "Console not connected."; return }
        isBusy = true
        error = nil
        status = message
        Task {
            do { try await work(tools) } catch { self.error = error.localizedDescription }
            isBusy = false
        }
    }

    private func go(_ newPath: String) {
        path = newPath.isEmpty ? "/" : newPath
        pathField = path
        selection = []
        load()
    }

    private func load() {
        run { tools in
            files = try await tools.list(path)
            status = "\(files.count) items"
        }
    }

    private func download() {
        let chosen = files.filter { selection.contains($0.name) }
        guard !chosen.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Download Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let base = path
        run("Downloading...") { tools in
            for file in chosen {
                let remote = (base as NSString).appendingPathComponent(file.name)
                if file.isDirectory {
                    try await tools.downloadFolder(remote, to: dir)
                } else {
                    try await tools.downloadFile(remote, to: dir.appendingPathComponent(file.name))
                }
            }
            status = "Downloaded \(chosen.count) item(s)"
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls.filter { !$0.hasDirectoryPath }
        let base = path
        run("Uploading...") { tools in
            for url in urls { try await tools.uploadFile(url, toFolder: base) }
            files = try await tools.list(base)
            status = "Uploaded \(urls.count) file(s)"
        }
    }

    private func delete() {
        let names = Array(selection)
        guard KernelDialogs.confirm(title: "Delete from the console?",
                                    message: "Permanently delete \(names.count == 1 ? names[0] : "\(names.count) items")? This cannot be undone.")
        else { return }
        let base = path
        run { tools in
            for name in names { try await tools.delete((base as NSString).appendingPathComponent(name)) }
            selection = []
            files = try await tools.list(base)
        }
    }

    private func newFolder() {
        let alert = NSAlert()
        alert.messageText = "New folder"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let target = (path as NSString).appendingPathComponent(field.stringValue)
        let base = path
        run { tools in
            try await tools.makeFolder(target)
            files = try await tools.list(base)
        }
    }
}
