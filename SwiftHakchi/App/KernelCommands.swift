import SwiftUI

/// Kernel menu (port of Hakchi2-CE's Kernel menu).
/// CE's Shift variants are separate items here; the developer U-Boot items are
/// hidden until "Show Developer Tools" (⌃⌥⌘D) is turned on, like CE's Ctrl+F12.
struct KernelCommands: Commands {
    @ObservedObject var appState: AppState
    @AppStorage("showDeveloperTools") private var showDeveloperTools = false

    private var connected: Bool { appState.deviceManager.isConnected }

    var body: some Commands {
        CommandMenu("Kernel") {
            Button("Install / Repair") {
                appState.requestFlash(.installHakchi)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button("Reset...") { appState.kernelReset() }

            Divider()

            Button("Uninstall...") { appState.kernelUninstall(withKernelFile: false) }
            Button("Uninstall and Flash Kernel File...") { appState.kernelUninstall(withKernelFile: true) }

            Divider()

            Button("Factory Reset...") { appState.kernelFactoryReset(withKernelFile: false) }
            Button("Factory Reset with Kernel File...") { appState.kernelFactoryReset(withKernelFile: true) }

            Divider()

            Menu("Advanced") {
                Button("Boot Original Kernel from RAM") { appState.kernelBootOriginal() }
                Button("Boot Custom Kernel from RAM") { appState.kernelBootCustom() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Boot Recovery Kernel from RAM") { appState.kernelBootRecovery() }
                Divider()
                Button("Dump Original Kernel (Legacy)...") { appState.kernelDumpStockKernelLegacy() }
                Button("Dump the Whole NAND Flash...") { appState.kernelNand(.dumpNand) }
                Divider()
                Button("Dump Decrypted System Software...") { appState.kernelNand(.dumpSystem) }
                Button("Flash Decrypted System Software...") { appState.kernelNand(.flashSystem) }
                Divider()
                Button("Dump User Data Partition...") { appState.kernelNand(.dumpUserData) }
                Button("Flash User Data Partition...") { appState.kernelNand(.flashUserData) }
                Button("Format User Data Partition...") { appState.kernelFormatUserData() }
            }

            if showDeveloperTools {
                Menu("Flash U-Boot") {
                    Button("Normal Mode...") { appState.kernelFlashUboot(sdMode: false) }
                    Button("SD Mode...") { appState.kernelFlashUboot(sdMode: true) }
                }
            }

            Divider()

            Button("Reboot") { appState.kernelReboot() }
                .disabled(!connected)

            Button("Shutdown") {
                Task { await appState.shutdownConsole() }
            }
            .disabled(!connected)

            Divider()

            Toggle("Show Developer Tools", isOn: $showDeveloperTools)
                .keyboardShortcut("d", modifiers: [.command, .option, .control])
        }
    }
}
