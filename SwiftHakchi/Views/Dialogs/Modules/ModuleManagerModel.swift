import AppKit
import SwiftUI

/// Which Module Manager tab is shown
enum ModuleTab: Hashable {
    case installed, library, modHub
}

/// Opens Module Manager tabs and module-related windows from menus
/// (CE's Modules menu items each open their own form).
@MainActor
final class ModuleRouter: ObservableObject {
    static let shared = ModuleRouter()

    @Published var tab: ModuleTab = .installed
    /// Repository to show when the Mod Hub tab opens
    @Published var repository: ModRepository?
    @Published var showRepositoryManager = false
    @Published var showBluetooth = false
}

/// State and actions shared by the Module Manager tabs.
///
/// Changes are staged on the console and applied by hakchi on the next boot
/// (see `HmodService`), so the model tracks pending installs/uninstalls.
@MainActor
final class ModuleManagerModel: ObservableObject {
    // Console state
    @Published var installed: [String] = []
    @Published var pendingInstalls: Set<String> = []
    @Published var pendingUninstalls: Set<String> = []
    @Published var isLoadingInstalled = false

    // Mod Hub state
    @Published var repository: ModRepository?
    @Published var contents: ModRepositoryService.Contents?
    @Published var isFetchingRemote = false
    @Published var busyItems: Set<String> = []

    // Messages
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var isWorking = false

    let library: ModLibrary
    private let repoService = ModRepositoryService()
    private weak var appState: AppState?

    init(appState: AppState, library: ModLibrary? = nil) {
        self.appState = appState
        self.library = library ?? .standard()
        repository = AppConfig.shared.modRepositories.first
    }

    var isConnected: Bool { appState?.deviceManager.isConnected ?? false }
    private var shell: SSHService? { appState?.deviceManager.sshService }

    var hasPendingChanges: Bool { !pendingInstalls.isEmpty || !pendingUninstalls.isEmpty }

    /// Readme for an installed module: local library first, then the loaded repository
    func readme(forInstalled id: String) -> HmodReadme? {
        library.module(named: id)?.readme
            ?? contents?.modules.first { $0.id == id }?.readme
    }

    // MARK: - Console

    func loadInstalled() {
        guard isConnected, let shell else {
            installed = []
            pendingInstalls = []
            pendingUninstalls = []
            return
        }
        isLoadingInstalled = true
        errorMessage = nil
        Task {
            let service = HmodService(ssh: shell)
            do {
                installed = try await service.installedHmods()
                pendingInstalls = Set(try await service.pendingInstalls())
            } catch {
                errorMessage = "Failed to load installed modules: \(error.localizedDescription)"
            }
            isLoadingInstalled = false
        }
    }

    /// Stage local library modules for install on the next boot (CE: "Install extra modules")
    func installFromLibrary(_ modules: [LocalModule]) {
        guard let shell else { errorMessage = "Console not connected."; return }
        isWorking = true
        errorMessage = nil
        Task {
            let service = HmodService(ssh: shell)
            do {
                for module in modules {
                    statusMessage = "Transferring \(module.name)..."
                    let payload = try library.stagingPayload(for: module)
                    if payload.isFolderTar {
                        try await service.stageHmodDirectory(tarData: payload.data)
                    } else {
                        try await service.stageHmod(data: payload.data, name: module.id)
                    }
                    pendingInstalls.insert(HmodService.safeFileName(module.id))
                    pendingUninstalls.remove(module.id)
                }
                statusMessage = "Modules staged. Click Apply & Reboot to install them."
            } catch {
                errorMessage = "Install failed: \(error.localizedDescription)"
                statusMessage = nil
            }
            isWorking = false
        }
    }

    /// Stage installed modules for removal on the next boot (CE: "Uninstall extra modules")
    func uninstall(_ ids: [String]) {
        guard let shell, !ids.isEmpty else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await HmodService(ssh: shell).stageUninstall(ids)
                pendingUninstalls.formUnion(ids)
                statusMessage = "Removal staged. Click Apply & Reboot to uninstall."
            } catch {
                errorMessage = "Uninstall failed: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    func applyAndReboot() {
        guard let shell else { return }
        isWorking = true
        statusMessage = "Rebooting console — hakchi applies the changes during boot (about a minute)."
        Task {
            await HmodService(ssh: shell).applyAndReboot()
            pendingInstalls = []
            pendingUninstalls = []
            installed = []
            isWorking = false
        }
    }

    // MARK: - Mod Hub

    func fetchRepository(forceRefresh: Bool = false) {
        guard let repository else {
            errorMessage = "No repositories configured. Add one with Manage Repositories."
            return
        }
        isFetchingRemote = true
        errorMessage = nil
        Task {
            do {
                contents = try await repoService.fetchRepository(from: repository.url, forceRefresh: forceRefresh)
            } catch {
                contents = nil
                errorMessage = "Could not load \(repository.name): \(error.localizedDescription)"
            }
            isFetchingRemote = false
        }
    }

    /// CE's "Download": save into the local library (unpacked when the item has `extract`)
    func download(_ item: ModRepositoryService.RemoteModule) {
        run(item, status: "Downloading \(item.name)...") { [self] data in
            try library.saveDownload(id: item.id, data: data, extract: item.extract)
            statusMessage = "\(item.name) saved to the module library."
        }
    }

    /// CE's "Download and install": download, keep a library copy, and stage it on the console
    func downloadAndInstall(_ item: ModRepositoryService.RemoteModule) {
        guard let shell else { errorMessage = "Console not connected."; return }
        run(item, status: "Downloading \(item.name)...") { [self] data in
            try library.saveDownload(id: item.id, data: data, extract: item.extract)
            statusMessage = "Transferring \(item.name) to console..."
            let service = HmodService(ssh: shell)
            if let module = library.module(named: ModLibrary.cleanName(item.id)) {
                let payload = try library.stagingPayload(for: module)
                if payload.isFolderTar {
                    try await service.stageHmodDirectory(tarData: payload.data)
                } else {
                    try await service.stageHmod(data: payload.data, name: module.id)
                }
            } else {
                try await service.stageHmod(data: data, name: item.id)
            }
            pendingInstalls.insert(HmodService.safeFileName(ModLibrary.cleanName(item.id)))
            pendingUninstalls.remove(item.id)
            statusMessage = "\(item.name) staged. Click Apply & Reboot to install it."
        }
    }

    /// Games tab: download a .clvg and import it into the games library
    func downloadGame(_ item: ModRepositoryService.RemoteModule) {
        run(item, status: "Downloading \(item.name)...") { [self] data in
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftHakchi-clvg-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent(item.fileName)
            try data.write(to: file)
            appState?.importGames(urls: [file])
            statusMessage = "\(item.name) added to the games library."
        }
    }

    private func run(_ item: ModRepositoryService.RemoteModule, status: String,
                     _ work: @escaping @MainActor (Data) async throws -> Void) {
        busyItems.insert(item.id)
        errorMessage = nil
        statusMessage = status
        Task {
            do {
                let data = try await repoService.downloadModule(item)
                try await work(data)
            } catch {
                errorMessage = "\(item.name): \(error.localizedDescription)"
                statusMessage = nil
            }
            busyItems.remove(item.id)
        }
    }

    // MARK: - Library

    /// Add modules (or .hrepo repositories) from files
    func addToLibrary(urls: [URL]) {
        errorMessage = nil
        let repos = urls.filter { $0.pathExtension.lowercased() == "hrepo" }
        let modules = urls.filter { $0.pathExtension.lowercased() != "hrepo" }
        for url in repos {
            if let text = try? String(contentsOf: url, encoding: .utf8), let repo = ModRepository.parseHrepo(text) {
                AppConfig.shared.modRepositories.append(repo)
                AppConfig.shared.save()
                statusMessage = "Added repository \(repo.name)."
            } else {
                errorMessage = "\(url.lastPathComponent) is not a valid .hrepo file."
            }
        }
        guard !modules.isEmpty else { return }
        do {
            let added = try library.add(urls: modules)
            statusMessage = "Added \(added.count) module(s) to the library."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.title = "Add Modules"
        panel.message = "Choose .hmod files or folders, or archives that contain them"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        addToLibrary(urls: panel.urls)
    }

    func deleteFromLibrary(_ modules: [LocalModule]) {
        do {
            for module in modules { try library.delete(module) }
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}
