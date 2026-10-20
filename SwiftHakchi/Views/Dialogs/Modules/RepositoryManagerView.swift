import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Manage module repositories (port of Hakchi2-CE's `RepoManagementForm`):
/// add, edit, delete and reorder name + URL; import `.hrepo` files.
struct RepositoryManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var config = AppConfig.shared
    @State private var selection: ModRepository.ID?
    @State private var editName = ""
    @State private var editURL = ""
    @State private var error: String?

    private var selectedIndex: Int? {
        config.modRepositories.firstIndex { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Module Repositories")
                .font(.title2.bold())

            List(selection: $selection) {
                ForEach(config.modRepositories) { repo in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.name).font(.body.weight(.medium))
                        Text(repo.url).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(repo.id)
                }
                .onMove { from, to in
                    config.modRepositories.move(fromOffsets: from, toOffset: to)
                    config.save()
                }
            }
            .frame(minHeight: 180)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                loadURLs(from: providers) { importHrepos($0) }
                return true
            }

            HStack {
                Button("Move Up") { move(by: -1) }
                    .disabled((selectedIndex ?? 0) == 0)
                Button("Move Down") { move(by: 1) }
                    .disabled(selectedIndex.map { $0 >= config.modRepositories.count - 1 } ?? true)
                Spacer()
                Button("Delete") { delete() }
                    .disabled(selectedIndex == nil)
                Button("Import .hrepo...") { chooseHrepo() }
            }

            GroupBox(selectedIndex == nil ? "Add repository" : "Edit repository") {
                Grid(alignment: .leading) {
                    GridRow {
                        Text("Name:")
                        TextField("e.g. KMFD's Mod Hub", text: $editName)
                    }
                    GridRow {
                        Text("URL:")
                        TextField("https://example.com/mods/", text: $editURL)
                    }
                }
                HStack {
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Spacer()
                    if selectedIndex != nil {
                        Button("New") { selection = nil }
                    }
                    Button(selectedIndex == nil ? "Add" : "Save") { saveEdit() }
                        .disabled(editURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560, height: 520)
        .onChange(of: selection) { _, _ in
            error = nil
            if let i = selectedIndex {
                editName = config.modRepositories[i].name
                editURL = config.modRepositories[i].url
            } else {
                editName = ""
                editURL = ""
            }
        }
    }

    // MARK: - Actions

    private func saveEdit() {
        let url = editURL.trimmingCharacters(in: .whitespaces)
        guard (try? ModRepositoryService.normalizedRepoURL(url)) != nil else {
            error = "Invalid URL"
            return
        }
        let name = editName.trimmingCharacters(in: .whitespaces).isEmpty ? ModRepository.displayName(for: url) : editName
        if let i = selectedIndex {
            config.modRepositories[i].name = name
            config.modRepositories[i].url = url
        } else {
            let repo = ModRepository(name: name, url: url)
            config.modRepositories.append(repo)
            selection = repo.id
        }
        config.save()
        error = nil
    }

    private func delete() {
        guard let i = selectedIndex else { return }
        config.modRepositories.remove(at: i)
        config.save()
        selection = nil
    }

    private func move(by offset: Int) {
        guard let i = selectedIndex else { return }
        let j = i + offset
        guard config.modRepositories.indices.contains(j) else { return }
        config.modRepositories.swapAt(i, j)
        config.save()
    }

    private func chooseHrepo() {
        let panel = NSOpenPanel()
        panel.title = "Import Repositories"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "hrepo") ?? .data]
        guard panel.runModal() == .OK else { return }
        importHrepos(panel.urls)
    }

    private func importHrepos(_ urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "hrepo" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let repo = ModRepository.parseHrepo(text) else {
                error = "\(url.lastPathComponent) is not a valid .hrepo file"
                continue
            }
            config.modRepositories.append(repo)
            selection = repo.id
        }
        config.save()
    }
}
