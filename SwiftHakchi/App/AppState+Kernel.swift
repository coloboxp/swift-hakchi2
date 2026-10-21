import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Simple AppKit dialogs used by the Kernel and Tools menus
@MainActor
enum KernelDialogs {
    /// Yes/No question (CE's "Are you sure?" boxes). Returns true for Yes.
    static func confirm(title: String, message: String, yes: String = "Yes", no: String = "No") -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: yes)
        alert.addButton(withTitle: no)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func info(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Stock kernel image (*.img), starting in the dump folder like CE
    static func pickKernelFile() -> URL? {
        openFile(title: "Select the original kernel", extensions: ["img"], directory: AppConfig.shared.dumpDirectory)
    }

    static func openFile(title: String, extensions: [String], directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveFile(title: String, suggestedName: String, directory: URL? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = directory ?? AppConfig.shared.dumpDirectory
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Kernel menu actions (CE's kernel/recovery commands), run in the task progress sheet.
extension AppState {
    /// Run a recovery task. If the console is neither running hakchi nor in FEL
    /// mode, wait for one of them first (cancellable), like CE's WaitingFelForm.
    func runRecovery(_ title: String,
                     _ work: @escaping @Sendable (RecoveryService, @escaping RecoveryService.Progress) async throws -> Void) {
        let deviceManager = self.deviceManager
        showTaskProgress = true
        taskRunner.run(name: title) { runner in
            let ready: @Sendable () async -> Bool = {
                await MainActor.run { deviceManager.isConnected || deviceManager.felDevicePresent }
            }
            if await !ready() {
                runner.updateProgress(status: "Waiting for the console: connect it running hakchi, or hold RESET while plugging in USB (FEL mode)...",
                                      fraction: 0)
                while await !ready() {
                    try await Task.sleep(for: .seconds(1))
                }
            }
            let service = RecoveryService(deviceManager: deviceManager)
            try await work(service) { status, fraction in
                runner.updateProgress(status: status, fraction: fraction)
            }
        }
    }

    // MARK: - Menu commands (texts follow CE's warnings)

    func kernelReset() {
        guard KernelDialogs.confirm(title: "Are you sure?",
                                    message: "Are you sure you want to reset and repair hakchi on your mini?") else { return }
        runRecovery("Resetting hakchi") { svc, p in try await svc.resetHakchi(progress: p) }
    }

    func kernelUninstall(withKernelFile: Bool) {
        guard KernelDialogs.confirm(title: "Are you sure?",
                                    message: "Do you really want to remove all traces of hakchi and return your mini to its original state?")
        else { return }
        runRecovery(withKernelFile ? "Uninstall and flash kernel file" : "Uninstalling hakchi") { svc, p in
            try await svc.uninstall(ignoreBackupKernel: withKernelFile,
                                    pickKernel: { KernelDialogs.pickKernelFile() }, progress: p)
        }
    }

    func kernelFactoryReset(withKernelFile: Bool) {
        guard KernelDialogs.confirm(title: "Warning",
                                    message: "Are you sure you want to restore factory settings?\n\nAll data will be erased and the stock kernel will be flashed.\n\nContinue?")
        else { return }
        runRecovery(withKernelFile ? "Factory reset with kernel file" : "Factory reset") { svc, p in
            try await svc.factoryReset(ignoreBackupKernel: withKernelFile,
                                       pickKernel: { KernelDialogs.pickKernelFile() }, progress: p)
        }
    }

    func kernelBootOriginal() {
        runRecovery("Boot original kernel from RAM") { svc, p in
            try await svc.bootOriginalKernel(pickKernel: { KernelDialogs.pickKernelFile() }, progress: p)
        }
    }

    func kernelBootCustom() {
        runRecovery("Boot custom kernel from RAM") { svc, p in try await svc.bootCustomKernel(progress: p) }
    }

    /// ⌥ forces a reload when already in recovery (CE uses Shift)
    func kernelBootRecovery() {
        var force = false
        if deviceManager.isConnected && deviceManager.isRecoveryMode {
            force = NSEvent.modifierFlags.contains(.option)
                || KernelDialogs.confirm(title: "Already in recovery",
                                         message: "You're already in recovery mode, do you want to reload the recovery image?")
        }
        let forceReload = force
        runRecovery("Recovery kernel") { svc, p in
            try await svc.bootRecoveryKernel(forceReload: forceReload, progress: p)
        }
    }

    func kernelDumpStockKernelLegacy() {
        guard let url = KernelDialogs.saveFile(title: "Dump original kernel", suggestedName: "kernel.img") else { return }
        runRecovery("Dump original kernel") { svc, p in try await svc.dumpStockKernel(to: url, progress: p) }
    }

    func kernelNand(_ task: RecoveryService.NandTask) {
        let url: URL?
        switch task {
        case .dumpNand:
            url = KernelDialogs.saveFile(title: "Dump the whole NAND flash", suggestedName: "nand.bin")
        case .dumpSystem:
            url = KernelDialogs.saveFile(title: "Dump decrypted system software", suggestedName: "system_software.hsqs")
        case .dumpUserData:
            url = KernelDialogs.saveFile(title: "Dump user data partition", suggestedName: "user_data.tar")
        case .flashSystem:
            url = KernelDialogs.openFile(title: "Flash decrypted system software",
                                         extensions: ["bin", "bz2", "gz", "hsqs", "tar", "tgz", "xz"],
                                         directory: AppConfig.shared.dumpDirectory)
        case .flashUserData:
            guard KernelDialogs.confirm(title: "Are you sure?",
                                        message: "Do you want to flash the user data? It will replace all user data.") else { return }
            url = KernelDialogs.openFile(title: "Flash user data partition",
                                         extensions: ["bz2", "gz", "hsqs", "tar", "xz"],
                                         directory: AppConfig.shared.dumpDirectory)
        }
        guard let url else { return }
        let title: String
        switch task {
        case .dumpNand: title = "Dumping NAND"
        case .dumpSystem: title = "Dumping system software"
        case .dumpUserData: title = "Dumping user data"
        case .flashSystem: title = "Flashing system software"
        case .flashUserData: title = "Flashing user data"
        }
        runRecovery(title) { svc, p in try await svc.processNand(task, file: url, progress: p) }
    }

    func kernelFormatUserData() {
        guard KernelDialogs.confirm(title: "Are you sure?",
                                    message: "Do you want to format the user data partition? It will erase all user data.")
        else { return }
        runRecovery("Formatting user data") { svc, p in try await svc.formatUserData(progress: p) }
    }

    func kernelFlashUboot(sdMode: Bool) {
        let message = sdMode ? "Do you really want to flash the SD MODE uboot?"
                             : "Do you really want to flash the NORMAL MODE uboot?"
        guard KernelDialogs.confirm(title: "Are you sure?", message: message) else { return }
        runRecovery("Flashing U-Boot") { svc, p in try await svc.flashUboot(sdMode: sdMode, progress: p) }
    }

    /// CE's Reboot: in recovery, offer to finish the boot sequence instead
    func kernelReboot() {
        if deviceManager.isRecoveryMode,
           KernelDialogs.confirm(title: "Recovery mode",
                                 message: "The console is in recovery mode. Do you want to finish the boot sequence (start hakchi) instead of rebooting?") {
            runRecovery("Booting hakchi") { svc, p in try await svc.continueBoot(progress: p) }
            return
        }
        Task { await rebootConsole() }
    }
}
