import SwiftUI

/// Mod Hub browser (port of CE's ModHub form): one repository at a time, with a
/// Welcome page, one tab per category, and a Games tab for `.clvg` items.
struct ModHubTab: View {
    @ObservedObject var model: ModuleManagerModel
    @ObservedObject private var config = AppConfig.shared
    @State private var page = Self.welcome
    @State private var search = ""
    @State private var selection: ModRepositoryService.RemoteModule.ID?

    private static let welcome = "Welcome"
    private static let games = "Games"

    private var pages: [String] {
        guard let contents = model.contents else { return [Self.welcome] }
        let categories = Set(contents.modules.map(\.category)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return [Self.welcome] + categories + (contents.games.isEmpty ? [] : [Self.games])
    }

    private var items: [ModRepositoryService.RemoteModule] {
        guard let contents = model.contents else { return [] }
        let base = page == Self.games ? contents.games : contents.modules.filter { $0.category == page }
        guard !search.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search) }
    }

    private var selectedItem: ModRepositoryService.RemoteModule? {
        items.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Repository:", selection: Binding(
                    get: { model.repository?.id },
                    set: { id in
                        model.repository = config.modRepositories.first { $0.id == id }
                        page = Self.welcome
                        model.fetchRepository()
                    }
                )) {
                    ForEach(config.modRepositories) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(maxWidth: 280)
                Button {
                    model.fetchRepository(forceRefresh: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload repository")
                .disabled(model.repository == nil || model.isFetchingRemote)
                Button("Manage...") { ModuleRouter.shared.showRepositoryManager = true }
                Spacer()
                Picker("Show:", selection: $page) {
                    ForEach(pages, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 240)
                if page != Self.welcome {
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            if model.isFetchingRemote {
                ProgressView("Fetching \(model.repository?.name ?? "repository")...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.contents == nil {
                ContentUnavailableView {
                    Label("Browse community modules", systemImage: "globe")
                } actions: {
                    Button("Load Repository") { model.fetchRepository() }
                        .disabled(model.repository == nil)
                }
            } else if page == Self.welcome {
                ModuleReadmeView(title: model.repository?.name ?? "",
                                 readme: model.contents?.readme.map { HmodReadme($0, isMarkdown: true) })
            } else {
                HSplitView {
                    List(items, selection: $selection) { item in
                        row(item).tag(item.id)
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 300)

                    ModuleReadmeView(title: selectedItem?.name ?? "Select an item", readme: selectedItem?.readme)
                        .frame(minWidth: 220)
                }
            }
        }
        .onAppear {
            if let wanted = ModuleRouter.shared.repository {
                model.repository = wanted
                ModuleRouter.shared.repository = nil
                model.fetchRepository()
            } else if model.contents == nil, !model.isFetchingRemote {
                model.fetchRepository()
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ModRepositoryService.RemoteModule) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.weight(.medium))
                Text([item.version, item.creator, item.emulatedSystem].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if model.busyItems.contains(item.id) {
                ProgressView().controlSize(.small)
            } else if item.kind == .game {
                Button("Add to Library") { model.downloadGame(item) }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                if model.installed.contains(item.id) {
                    Text("Installed").font(.caption).foregroundStyle(.green)
                } else if model.pendingInstalls.contains(item.id) {
                    PendingBadge(text: "Install pending", color: .blue)
                }
                Button("Download") { model.download(item) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Save to the module library on this Mac")
                Button("Install") { model.downloadAndInstall(item) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!model.isConnected)
                    .help(model.isConnected ? "Download and stage for install" : "Connect a console first")
            }
        }
    }
}
