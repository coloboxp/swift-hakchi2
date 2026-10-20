import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "Tools")

/// Tools menu actions that need no window of their own
extension AppState {
    /// Tools service for the connected console, or nil (with an alert) when offline
    func consoleTools() -> ConsoleToolsService? {
        guard deviceManager.isConnected, let shell = deviceManager.sshService else {
            KernelDialogs.info(title: "Not connected", message: "Connect a console running hakchi first.")
            return nil
        }
        return ConsoleToolsService(shell: shell)
    }

    // MARK: - dmesg

    func saveDmesg() {
        guard let tools = consoleTools(),
              let url = KernelDialogs.saveFile(title: "Save dmesg output", suggestedName: "dmesg.txt",
                                               directory: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first)
        else { return }
        Task {
            do {
                try Data(try await tools.dmesg().utf8).write(to: url)
            } catch {
                KernelDialogs.info(title: "dmesg failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: - Boot splash (CE: Tools > Boot splash)

    func changeBootSplash() {
        guard let tools = consoleTools() else { return }
        let panel = NSOpenPanel()
        panel.title = "Select a boot image"
        panel.allowedContentTypes = [.bmp, .gif, .jpeg, .png, .tiff]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let png = ConsoleTools.bootSplashPNG(from: data, isPNG: url.pathExtension.lowercased() == "png") else {
            return
        }
        runBootSplash("Changing boot splash") { try await tools.setBootSplash(png) }
    }

    func disableBootSplash() {
        guard let tools = consoleTools() else { return }
        runBootSplash("Disabling boot splash") { try await tools.disableBootSplash() }
    }

    func resetBootSplash() {
        guard let tools = consoleTools() else { return }
        runBootSplash("Resetting boot splash") { try await tools.resetBootSplash() }
    }

    private func runBootSplash(_ title: String, _ work: @escaping @Sendable () async throws -> Void) {
        showTaskProgress = true
        taskRunner.run(name: title) { runner in
            try await work()
            runner.updateProgress(status: "Done! The new boot splash shows on the next boot.", fraction: 1)
        }
    }

    // MARK: - Startup updates (CE: hakchi + romfiles.xml update at startup)

    /// Download a newer hakchi.hmod and romfiles.xml in the background, once per launch
    func runStartupUpdates() async {
        let updates = UpdateService()
        do {
            let bundledText = try PayloadService.shared.hmodFile("var/version")
            let bundled = ConsoleTools.parseHakchiVersion(String(decoding: bundledText, as: UTF8.self))
            if let newer = try await updates.checkHakchiUpdate(bundled: bundled) {
                statusMessage = "Downloaded hakchi \(newer.script)"
            }
        } catch {
            logger.info("hakchi update check skipped: \(error.localizedDescription)")
        }
        do {
            try await updates.updateRomFiles()
        } catch {
            logger.info("romfiles.xml update skipped: \(error.localizedDescription)")
        }
    }
}
