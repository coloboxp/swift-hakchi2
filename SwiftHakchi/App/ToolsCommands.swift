import SwiftUI
import AppKit

/// Window identifiers for the tool windows
enum ToolWindow: String {
    case saveStates = "save-states"
    case screenshot = "screenshot"
    case terminal = "terminal"
    case files = "files"
    case techInfo = "tech-info"
    case firmware = "firmware"
    case formatSD = "format-sd"
    case export = "export"
    case motd = "motd"
}

/// Tool windows (non-modal, so the main window stays usable)
struct ToolWindowScenes: Scene {
    let appState: AppState

    var body: some Scene {
        Window("Save-State Manager", id: ToolWindow.saveStates.rawValue) {
            SaveStateManagerView().environmentObject(appState)
        }
        Window("Screenshot", id: ToolWindow.screenshot.rawValue) {
            ScreenshotView().environmentObject(appState)
        }
        Window("Terminal", id: ToolWindow.terminal.rawValue) {
            TerminalView().environmentObject(appState)
        }
        Window("Console Files", id: ToolWindow.files.rawValue) {
            FileBrowserView().environmentObject(appState)
        }
        Window("Technical Information", id: ToolWindow.techInfo.rawValue) {
            TechInfoView().environmentObject(appState)
        }
        Window("Switch Running Firmware", id: ToolWindow.firmware.rawValue) {
            FirmwareView().environmentObject(appState)
        }
        .windowResizability(.contentSize)
        Window("Format SD Card", id: ToolWindow.formatSD.rawValue) {
            FormatSDView().environmentObject(appState)
        }
        .windowResizability(.contentSize)
        Window("Export Games", id: ToolWindow.export.rawValue) {
            ExportGamesView().environmentObject(appState)
        }
        .windowResizability(.contentSize)
        Window("Important Message", id: ToolWindow.motd.rawValue) {
            MotdView()
        }
    }
}

/// Tools menu (port of Hakchi2-CE's Tools menu)
struct ToolsCommands: Commands {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    private var connected: Bool { appState.deviceManager.isConnected }

    var body: some Commands {
        CommandMenu("Tools") {
            Button("Select Emulation Core...") {
                appState.openCoreDialog(for: appState.selectedGames)
            }
            .disabled(appState.selectedGames.allSatisfy { $0.source != .local })

            Button("Scraper...") {
                appState.showScraper = true
            }

            Divider()

            Button("Save-State Manager...") { openWindow(id: ToolWindow.saveStates.rawValue) }
                .disabled(!connected)
            Button("Take Screenshot...") { openWindow(id: ToolWindow.screenshot.rawValue) }
                .disabled(!connected)
            Button("Save dmesg Output...") { appState.saveDmesg() }
                .disabled(!connected)

            Divider()

            Button("Terminal") { openWindow(id: ToolWindow.terminal.rawValue) }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!connected)
            Button("Console Files...") { openWindow(id: ToolWindow.files.rawValue) }
                .disabled(!connected)

            Divider()

            Menu("Boot Splash") {
                Button("Change...") { appState.changeBootSplash() }
                Button("Disable") { appState.disableBootSplash() }
                Button("Reset to Default") { appState.resetBootSplash() }
            }
            .disabled(!connected)

            Button("Switch Running Firmware...") { openWindow(id: ToolWindow.firmware.rawValue) }
                .disabled(!connected)

            Divider()

            Button("Export Games...") { openWindow(id: ToolWindow.export.rawValue) }
            Button("Format SD Card...") { openWindow(id: ToolWindow.formatSD.rawValue) }

            Divider()

            Button("Dump Stock Kernel") {
                appState.requestFlash(.dumpStockKernel)
            }
            .disabled(!connected)
        }
    }
}

/// Help menu: in-app help plus Hakchi2-CE's links and info windows
struct HelpCommands: Commands {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    private static let links: [(String, String)] = [
        ("Swift Hakchi2 Releases", "https://github.com/mattackerman808/swift-hakchi2/releases"),
        ("Hakchi2 CE FAQ", "https://github.com/TeamShinkansen/hakchi2/wiki/FAQ"),
        ("Discord: Rockin' The Classics", "https://discord.gg/C9EDFyg"),
        ("Reddit: r/RockinTheClassics", "https://www.reddit.com/r/RockinTheClassics/"),
    ]

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Swift Hakchi2 Help") {
                appState.showHelp = true
            }
            .keyboardShortcut("?")

            Button("Important Message...") { openWindow(id: ToolWindow.motd.rawValue) }
            Button("Technical Information...") { openWindow(id: ToolWindow.techInfo.rawValue) }

            Divider()

            ForEach(Self.links, id: \.1) { title, url in
                Button(title) {
                    if let url = URL(string: url) { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}
