import SwiftUI
import AppKit

/// Module (hmod) manager — install, uninstall, and browse modules.
///
/// Changes are staged on the console and applied by hakchi on the next boot
/// (see `HmodService`), so the view tracks pending installs/uninstalls and
/// offers an "Apply & Reboot" action.
struct ModuleManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @State private var selectedTab = 0
    @State private var installedModules: [HmodPackage] = []
    @State private var selectedModules: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isWorking = false

    // Changes staged on the console, applied on next reboot
    @State private var pendingInstalls: Set<String> = []
    @State private var pendingUninstalls: Set<String> = []

    // Browse tab state
    @State private var remoteModules: [ModRepositoryService.RemoteModule] = []
    @State private var isFetchingRemote = false
    @State private var browseError: String?
    @State private var selectedCategory: String = "All"
    @State private var searchText = ""
    @State private var installingModuleIds: Set<String> = []

    private let repoService = ModRepositoryService()

    private var isConnected: Bool { appState.deviceManager.isConnected }

    private var categories: [String] {
        ["All"] + Set(remoteModules.map(\.category)).sorted()
    }

    private var filteredRemoteModules: [ModRepositoryService.RemoteModule] {
        remoteModules.filter { mod in
            (selectedCategory == "All" || mod.category == selectedCategory)
                && (searchText.isEmpty
                    || mod.name.localizedCaseInsensitiveContains(searchText)
                    || mod.id.localizedCaseInsensitiveContains(searchText))
        }
    }

    private var installedIds: Set<String> {
        Set(installedModules.map(\.id))
    }

    private var hasPendingChanges: Bool {
        !pendingInstalls.isEmpty || !pendingUninstalls.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Module Manager")
                    .font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if !isConnected {
                Label("Connect a console with hakchi installed to install or remove modules.",
                      systemImage: "cable.connector.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.1))
            }

            // Tabs
            Picker("", selection: $selectedTab) {
                Text("Installed").tag(0)
                Text("Browse").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Tab content
            if selectedTab == 0 {
                installedTab
            } else {
                browseTab
            }

            messages

            Divider()

            bottomBar
        }
        .frame(width: 620, height: 560)
        .onAppear { loadInstalledModules() }
        .onChange(of: isConnected) { _, _ in loadInstalledModules() }
        .onChange(of: selectedTab) { _, tab in
            if tab == 1 && remoteModules.isEmpty && !isFetchingRemote { fetchRemoteModules() }
        }
    }

    // MARK: - Installed Tab

    private var installedTab: some View {
        Group {
            if isLoading {
                ProgressView("Loading installed modules...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if installedModules.isEmpty && pendingInstalls.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No modules installed")
                        .foregroundStyle(.secondary)
                    if !isConnected {
                        Text("Connect a console to view installed modules.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedModules) {
                    ForEach(installedModules) { mod in
                        HStack {
                            Text(mod.name)
                                .font(.body.weight(.medium))
                            Spacer()
                            if pendingUninstalls.contains(mod.id) {
                                pendingBadge("Removal pending", color: .red)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        .tag(mod.id)
                    }
                    ForEach(pendingInstalls.sorted(), id: \.self) { id in
                        HStack {
                            Text(id)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            pendingBadge("Install pending", color: .blue)
                        }
                        .selectionDisabled()
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Browse Tab

    private var browseTab: some View {
        VStack(spacing: 0) {
            if isFetchingRemote {
                ProgressView("Fetching module repository...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if remoteModules.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Browse community modules")
                        .font(.headline)
                    Button("Load Repository") {
                        fetchRemoteModules()
                    }
                    if let error = browseError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Filters
                HStack {
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Picker("Category:", selection: $selectedCategory) {
                        ForEach(categories, id: \.self) { cat in
                            Text(cat).tag(cat)
                        }
                    }
                    .frame(width: 210)
                    Spacer()
                    Text("\(filteredRemoteModules.count) modules")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        fetchRemoteModules(forceRefresh: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload repository")
                }
                .padding(.horizontal)
                .padding(.vertical, 4)

                List(filteredRemoteModules) { mod in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mod.name)
                                .font(.body.weight(.medium))
                            Text([mod.category, mod.version, mod.creator]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        remoteModuleAction(mod)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func remoteModuleAction(_ mod: ModRepositoryService.RemoteModule) -> some View {
        if pendingInstalls.contains(mod.id) {
            pendingBadge("Install pending", color: .blue)
        } else if installingModuleIds.contains(mod.id) {
            ProgressView()
                .controlSize(.small)
        } else if installedIds.contains(mod.id) && !pendingUninstalls.contains(mod.id) {
            Button("Reinstall") { installRemoteModule(mod) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isConnected)
        } else {
            Button("Install") { installRemoteModule(mod) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isConnected)
                .help(isConnected ? "Download and stage for install" : "Connect a console first")
        }
    }

    private func pendingBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Messages & Bottom Bar

    @ViewBuilder
    private var messages: some View {
        if let error = errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 4)
        } else if let status = statusMessage {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 4)
        }
    }

    private var bottomBar: some View {
        HStack {
            Button("Install from File...") {
                installFromFile()
            }
            .disabled(!isConnected || isWorking)

            if selectedTab == 0 {
                Button("Uninstall Selected") {
                    uninstallSelected()
                }
                .disabled(selectedModules.isEmpty || !isConnected || isWorking)
            }

            Spacer()

            if hasPendingChanges {
                Text("\(pendingInstalls.count + pendingUninstalls.count) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Apply & Reboot") {
                applyAndReboot()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasPendingChanges || !isConnected || isWorking || !installingModuleIds.isEmpty)
            .help("Reboot the console; hakchi installs/removes the pending modules during boot")
        }
        .padding()
    }

    // MARK: - Actions

    private func loadInstalledModules() {
        guard isConnected, let shell = appState.deviceManager.sshService else {
            installedModules = []
            pendingInstalls = []
            pendingUninstalls = []
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            let hmodService = HmodService(ssh: shell)
            do {
                let names = try await hmodService.installedHmods()
                let pending = try await hmodService.pendingInstalls()
                installedModules = names.map { HmodPackage(id: $0, isInstalled: true) }
                pendingInstalls = Set(pending)
                isLoading = false
            } catch {
                errorMessage = "Failed to load installed modules: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    private func fetchRemoteModules(forceRefresh: Bool = false) {
        guard let repoURL = AppConfig.shared.modRepositoryURLs.first else {
            browseError = "No repository URLs configured."
            return
        }

        isFetchingRemote = true
        browseError = nil

        Task {
            do {
                remoteModules = try await repoService.fetchModules(from: repoURL, forceRefresh: forceRefresh)
            } catch {
                browseError = "Could not load repository: \(error.localizedDescription)"
            }
            isFetchingRemote = false
        }
    }

    private func installRemoteModule(_ mod: ModRepositoryService.RemoteModule) {
        guard let shell = appState.deviceManager.sshService else {
            errorMessage = "Console not connected."
            return
        }

        installingModuleIds.insert(mod.id)
        errorMessage = nil
        statusMessage = "Downloading \(mod.name)..."

        Task {
            do {
                let data = try await repoService.downloadModule(mod)
                statusMessage = "Transferring \(mod.name) to console..."
                try await HmodService(ssh: shell).stageHmod(data: data, name: mod.id)
                pendingInstalls.insert(HmodService.safeFileName(mod.id))
                pendingUninstalls.remove(mod.id)
                statusMessage = "\(mod.name) staged. Click Apply & Reboot to install it."
            } catch {
                errorMessage = "Install of \(mod.name) failed: \(error.localizedDescription)"
                statusMessage = nil
            }
            installingModuleIds.remove(mod.id)
        }
    }

    private func installFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Select Module to Install"
        panel.message = "Choose .hmod files or unpacked .hmod folders"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard let shell = appState.deviceManager.sshService else { return }
        let urls = panel.urls

        isWorking = true
        errorMessage = nil

        Task {
            let hmodService = HmodService(ssh: shell)
            do {
                for url in urls {
                    let name = url.deletingPathExtension().lastPathComponent
                    guard url.pathExtension.lowercased() == "hmod" else {
                        throw ModuleManagerError.notAnHmod(url.lastPathComponent)
                    }
                    statusMessage = "Transferring \(name)..."
                    if url.hasDirectoryPath {
                        try await hmodService.stageHmodDirectory(tarData: tarDirectory(url))
                    } else {
                        try await hmodService.stageHmod(data: Data(contentsOf: url), name: name)
                    }
                    pendingInstalls.insert(HmodService.safeFileName(name))
                }
                statusMessage = "Modules staged. Click Apply & Reboot to install them."
            } catch {
                errorMessage = "Install failed: \(error.localizedDescription)"
                statusMessage = nil
            }
            isWorking = false
        }
    }

    private func uninstallSelected() {
        guard let shell = appState.deviceManager.sshService else { return }
        let toUninstall = Array(selectedModules)

        isWorking = true
        errorMessage = nil

        Task {
            do {
                try await HmodService(ssh: shell).stageUninstall(toUninstall)
                pendingUninstalls.formUnion(toUninstall)
                selectedModules = []
                statusMessage = "Removal staged. Click Apply & Reboot to uninstall."
            } catch {
                errorMessage = "Uninstall failed: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    private func applyAndReboot() {
        guard let shell = appState.deviceManager.sshService else { return }
        isWorking = true
        statusMessage = "Rebooting console — hakchi applies the changes during boot (about a minute)."

        Task {
            await HmodService(ssh: shell).applyAndReboot()
            pendingInstalls = []
            pendingUninstalls = []
            installedModules = []
            isWorking = false
        }
    }

    /// Tar an unpacked "<name>.hmod" folder so it extracts as that folder
    private func tarDirectory(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // COPYFILE_DISABLE stops macOS tar from adding ._ AppleDouble files
        process.environment = ["COPYFILE_DISABLE": "1"]
        process.arguments = ["-cf", "-", "-C", url.deletingLastPathComponent().path, url.lastPathComponent]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        // Read before waiting, otherwise a large tar fills the pipe and deadlocks
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ModuleManagerError.tarFailed(url.lastPathComponent)
        }
        return data
    }
}

private enum ModuleManagerError: LocalizedError {
    case notAnHmod(String)
    case tarFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAnHmod(let name): return "\(name) is not an .hmod file or folder"
        case .tarFailed(let name): return "Could not pack folder \(name)"
        }
    }
}
