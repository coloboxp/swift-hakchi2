import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// Console screenshot (port of CE's ScreenshotForm): refresh, auto refresh,
/// copy to the clipboard, save, open in Preview.
struct ScreenshotView: View {
    @EnvironmentObject var appState: AppState

    @State private var image: CGImage?
    @State private var isBusy = false
    @State private var autoRefresh = false
    @State private var error: String?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(16 / 9, contentMode: .fit)
                } else if let error {
                    Text(error).foregroundStyle(.white).padding()
                }
                if isBusy && image == nil { ProgressView().colorScheme(.dark) }
            }
            HStack {
                Button("Refresh") { capture() }.keyboardShortcut("r")
                Toggle("Auto refresh", isOn: $autoRefresh)
                Spacer()
                Button("Copy") { copy() }.disabled(image == nil)
                Button("Open in Preview") { openInPreview() }.disabled(image == nil)
                Button("Save...") { save() }.disabled(image == nil)
            }
            .padding()
        }
        .frame(minWidth: 660, minHeight: 440)
        .onAppear { capture() }
        .onReceive(timer) { _ in if autoRefresh && !isBusy { capture() } }
    }

    private func capture() {
        guard let shell = appState.deviceManager.sshService else { error = "Console not connected."; return }
        isBusy = true
        Task {
            do {
                image = try await ConsoleToolsService(shell: shell).screenshot()
                error = nil
            } catch {
                self.error = error.localizedDescription
                autoRefresh = false
            }
            isBusy = false
        }
    }

    private func copy() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
    }

    private func save() {
        guard let image, let png = ConsoleTools.pngData(image) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "screenshot-\(Int(Date().timeIntervalSince1970)).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? png.write(to: url)
    }

    private func openInPreview() {
        guard let image, let png = ConsoleTools.pngData(image) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hakchi-screenshot.png")
        try? png.write(to: url)
        NSWorkspace.shared.open(url)
    }
}
