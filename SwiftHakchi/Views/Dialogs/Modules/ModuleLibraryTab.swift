import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The local module library (CE: "Install extra modules" with `user_mods`):
/// grouped list, readme pane, add/delete, install to console.
struct ModuleLibraryTab: View {
    @ObservedObject var model: ModuleManagerModel
    @ObservedObject var library: ModLibrary
    @AppStorage("moduleLibraryGrouping") private var grouping: ModGrouping = .category
    @State private var selection: Set<String> = []
    @State private var confirmDelete = false
    @State private var isDropTargeted = false

    init(model: ModuleManagerModel) {
        self.model = model
        self.library = model.library
    }

    private var selectedModules: [LocalModule] {
        library.modules.filter { selection.contains($0.id) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("Group by:", selection: $grouping) {
                        ForEach(ModGrouping.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 240)
                    Spacer()
                    Text("\(library.modules.count) modules")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                if library.modules.isEmpty {
                    ContentUnavailableView(
                        "Library is empty", systemImage: "tray",
                        description: Text("Add .hmod files or folders, download them from the Mod Hub, or drop them here."))
                } else {
                    List(selection: $selection) {
                        ForEach(library.grouped(by: grouping), id: \.group) { group in
                            Section(group.group) {
                                ForEach(group.modules) { module in
                                    row(module).tag(module.id)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 300)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                loadURLs(from: providers) { model.addToLibrary(urls: $0) }
                return true
            }

            ModuleReadmeView(title: selectedModules.count == 1 ? selectedModules[0].name : "Select a module",
                             readme: selectedModules.count == 1 ? selectedModules[0].readme : nil)
                .frame(minWidth: 220)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Add...") { model.chooseFilesToAdd() }
                Button("Delete from Disk...") { confirmDelete = true }
                    .disabled(selection.isEmpty)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        selectedModules.isEmpty ? [library.directory] : selectedModules.map(\.url))
                }
                Spacer()
                Button("Install Selected") {
                    model.installFromLibrary(selectedModules)
                }
                .disabled(selection.isEmpty || !model.isConnected || model.isWorking)
                .help(model.isConnected ? "Transfer to the console; applied on the next reboot" : "Connect a console first")
            }
            .padding(8)
        }
        .onAppear { library.reload() }
        .alert("Delete \(selection.count) module(s) from disk?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.deleteFromLibrary(selectedModules)
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes them from the module library on this Mac. Modules installed on the console are not affected.")
        }
    }

    private func row(_ module: LocalModule) -> some View {
        HStack {
            Image(systemName: module.isDirectory ? "folder" : "shippingbox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.name).font(.body.weight(.medium))
                Text([module.version.isEmpty ? nil : "v\(module.version)", module.creator, module.id]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if model.installed.contains(module.id) {
                Text("Installed").font(.caption).foregroundStyle(.green)
            } else if model.pendingInstalls.contains(module.id) {
                PendingBadge(text: "Install pending", color: .blue)
            }
        }
    }
}

/// Collect file URLs from drag-and-drop providers, then call `completion` on the main actor
@MainActor
func loadURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let box = URLBox()
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { box.append(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        MainActor.assumeIsolated { completion(box.urls) }
    }
}

/// Thread-safe collector for drop results
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.withLock { storage.append(url) } }
    var urls: [URL] { lock.withLock { storage } }
}
