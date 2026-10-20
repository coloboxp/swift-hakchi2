import SwiftUI

/// "Prepare art folders" (port of Hakchi2-CE's `SelectSystemDialog`): create one
/// `art/<System>/` folder per checked system. Cover matching prefers the game's
/// system folder when it exists. Unchecked folders are removed only when empty.
struct PrepareArtFoldersView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<String> = []
    @State private var systems: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prepare Art Folders")
                .font(.title2.bold())
            Text("Put box art in art/<System>/ to keep matches within one system. Images can also be named after the ROM's CRC32.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(systems, id: \.self) { system in
                Toggle(system, isOn: Binding(
                    get: { checked.contains(system) },
                    set: { if $0 { checked.insert(system) } else { checked.remove(system) } }
                ))
            }
            .frame(minHeight: 280)

            HStack {
                Button("Check All") { checked = Set(systems) }
                Button("Uncheck All") { checked = [] }
                Button("Open Art Folder") {
                    try? FileManager.default.createDirectory(at: LibraryStorage.artDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(LibraryStorage.artDirectory)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    Self.apply(checked: checked, systems: systems, artDirectory: LibraryStorage.artDirectory)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520, height: 520)
        .onAppear {
            systems = CoreCatalog.shared.allSystems
            let fm = FileManager.default
            checked = Set(systems.filter {
                fm.fileExists(atPath: LibraryStorage.artDirectory.appendingPathComponent($0).path)
            })
        }
    }

    /// Create checked folders; remove unchecked ones that are empty (CE behaviour)
    static func apply(checked: Set<String>, systems: [String], artDirectory: URL) {
        let fm = FileManager.default
        for system in systems {
            let dir = artDirectory.appendingPathComponent(system, isDirectory: true)
            if checked.contains(system) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } else if let contents = try? fm.contentsOfDirectory(atPath: dir.path),
                      contents.filter({ !$0.hasPrefix(".") }).isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
    }
}
