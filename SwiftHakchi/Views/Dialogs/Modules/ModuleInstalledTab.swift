import SwiftUI

/// Modules installed on the console (CE: "Uninstall extra modules"), with readme info
/// from the local library or the loaded repository.
struct ModuleInstalledTab: View {
    @ObservedObject var model: ModuleManagerModel
    @State private var selection: Set<String> = []

    var body: some View {
        HSplitView {
            Group {
                if model.isLoadingInstalled {
                    ProgressView("Loading installed modules...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.installed.isEmpty && model.pendingInstalls.isEmpty {
                    ContentUnavailableView(
                        "No modules installed", systemImage: "shippingbox",
                        description: Text(model.isConnected ? "" : "Connect a console to view installed modules."))
                } else {
                    List(selection: $selection) {
                        ForEach(model.installed, id: \.self) { id in
                            row(id: id)
                                .tag(id)
                        }
                        ForEach(model.pendingInstalls.sorted(), id: \.self) { id in
                            HStack {
                                Text(model.readme(forInstalled: id)?.name ?? id)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                PendingBadge(text: "Install pending", color: .blue)
                            }
                            .selectionDisabled()
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 280)

            ModuleReadmeView(title: selectedTitle, readme: selection.count == 1 ? model.readme(forInstalled: selection.first!) : nil)
                .frame(minWidth: 220)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Refresh") { model.loadInstalled() }
                    .disabled(!model.isConnected)
                Spacer()
                Button("Uninstall Selected") {
                    model.uninstall(Array(selection))
                    selection = []
                }
                .disabled(selection.isEmpty || !model.isConnected || model.isWorking)
            }
            .padding(8)
        }
    }

    private var selectedTitle: String {
        switch selection.count {
        case 0: return "Select a module"
        case 1: return model.readme(forInstalled: selection.first!)?.name ?? selection.first!
        default: return "\(selection.count) modules selected"
        }
    }

    private func row(id: String) -> some View {
        let readme = model.readme(forInstalled: id)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(readme?.name ?? id)
                    .font(.body.weight(.medium))
                Text([readme?.version.map { "v\($0)" }, readme?.category, id]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if model.pendingUninstalls.contains(id) {
                PendingBadge(text: "Removal pending", color: .red)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

/// Small colored capsule label
struct PendingBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
