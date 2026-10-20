import Foundation
import CoreGraphics
import ImageIO
import SWCompression
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "ConsoleTools")

/// Tools menu operations on a connected console (ports of Hakchi2-CE's
/// SaveStateManager, ScreenshotForm, boot splash, SelectFirmwareDialog, TechInfo,
/// MemoryStats and the dmesg command). Commands match CE's.
struct ConsoleToolsService: Sendable {
    let shell: SSHService

    enum ToolsError: LocalizedError {
        case badScreenshot(Int)
        case commandFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .badScreenshot(let n): return "The console sent an incomplete screenshot (\(n) bytes)."
            case .commandFailed(let cmd, let err): return "\(cmd) failed: \(err)"
            }
        }
    }

    // MARK: - Splash screen (CE hakchi.ShowSplashScreen)

    /// Stop the UI and show hakchi's "please wait" picture while a tool runs
    func showSplashScreen() async {
        _ = try? await shell.execute("uistop")
        if let splash = try? PayloadService.shared.bundledFile("splash.gz") {
            _ = try? await shell.execute("gunzip -c - > /dev/fb0", input: splash, idleTimeout: 3000)
        }
    }

    // MARK: - Save states

    func listSaveStates() async throws -> [ConsoleTools.SaveState] {
        await showSplashScreen()
        let result = try await shell.execute("sh", input: Data(ConsoleTools.listSavesScript.utf8))
        return ConsoleTools.parseSaveStates(result.stdout)
    }

    /// Export one game's saves as a .clvs file (tar.gz of the profile folder)
    func exportSave(code: String, to url: URL) async throws {
        try await shell.download(command: "cd \(ConsoleTools.profilesPath) && tar -cz \(ConsoleTools.escapeShellArgument(code))",
                                 to: url)
    }

    /// Import .clvs files back into the profile folder
    func importSaves(_ urls: [URL]) async throws {
        for url in urls {
            let result = try await shell.upload(fileURL: url, command: "cd \(ConsoleTools.profilesPath) && tar -xvz")
            guard result.succeeded else { throw ToolsError.commandFailed("tar -xvz", result.stderr) }
        }
    }

    func deleteSaves(codes: [String]) async throws {
        for code in codes {
            _ = try await shell.execute("rm -rf \(ConsoleTools.profilesPath)/\(ConsoleTools.escapeShellArgument(code))",
                                        timeout: 3000)
        }
    }

    /// Screenshots stored inside a game's save (CE shows them on hover)
    func saveScreenshots(code: String) async throws -> [CGImage] {
        let data = try await shell.downloadData(
            command: "cd \(ConsoleTools.profilesPath) && tar -cz \(ConsoleTools.escapeShellArgument(code))")
        let tar = try GzipArchive.unarchive(archive: data)
        return try TarContainer.open(container: tar).compactMap { entry in
            guard entry.info.name.lowercased().hasSuffix(".png"), let png = entry.data,
                  let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    /// Restart the console UI when the save manager closes
    func restartUI() async {
        _ = try? await shell.execute("uistart", timeout: 2000)
    }

    // MARK: - Screenshot

    func screenshot() async throws -> CGImage {
        _ = try await shell.execute("hakchi uipause")
        let raw: Data
        do {
            raw = try await shell.downloadData(command: "cat /dev/fb0")
        } catch {
            _ = try? await shell.execute("hakchi uiresume")
            throw error
        }
        _ = try await shell.execute("hakchi uiresume")
        guard let image = ConsoleTools.image(fromFramebuffer: raw) else {
            throw ToolsError.badScreenshot(raw.count)
        }
        return image
    }

    // MARK: - dmesg

    func dmesg() async throws -> String {
        try await shell.execute("dmesg", timeout: 10000).stdout
    }

    // MARK: - Boot splash

    /// Upload a new boot picture (already a 1280×720 PNG, see `ConsoleTools.bootSplashPNG`)
    func setBootSplash(_ png: Data) async throws {
        let result = try await shell.execute(
            "hakchi unset cfg_boot_logo; cat > \"$(hakchi get rootfs)/etc/boot.png\"", input: png)
        guard result.succeeded else { throw ToolsError.commandFailed("boot.png upload", result.stderr) }
        let usbHost = try await shell.execute("if [ -d /media/hakchi/ ]; then echo 1; else echo 0; fi;")
        if usbHost.output == "1" {
            _ = try await shell.execute("cat > \"/media/hakchi/boot.png\"", input: png)
        }
    }

    /// Blank boot picture (CE's data/blankBoot.png)
    func disableBootSplash() async throws {
        try await setBootSplash(try PayloadService.shared.bundledFile("blankBoot.png"))
    }

    func resetBootSplash() async throws {
        _ = try await shell.execute("hakchi unset cfg_boot_logo; rm \"$(hakchi get rootfs)/etc/boot.png\"")
        _ = try await shell.execute("rm \"/media/hakchi/boot.png\"")
    }

    // MARK: - Firmware

    struct FirmwareList {
        /// Output of `hakchi currentFirmware` ("_nand_" for the stock NAND firmware)
        let current: String
        let paths: [String]
    }

    func firmwares() async throws -> FirmwareList {
        let current = try await shell.execute("hakchi currentFirmware", timeout: 1000).output
        let list = try await shell.execute("find \"/media/\" \"/var/lib/hakchi/\" -iname \"*.hsqs\"", timeout: 10000)
        return FirmwareList(current: current, paths: ConsoleTools.parseFirmwareList(list.stdout))
    }

    /// Switch to a firmware image (nil = stock NAND). The console reboots into it.
    func switchFirmware(to path: String?) async {
        let target = path.map { "\"\($0)\"" } ?? "_nand_"
        _ = try? await shell.execute("/bin/detached hsqs \(target)", timeout: 5000)
    }

    // MARK: - Memory stats

    func memoryStats() async -> ConsoleTools.MemoryStats {
        var stats = ConsoleTools.MemoryStats()
        guard let df = try? await shell.execute(ConsoleTools.dfCommand),
              ConsoleTools.parseDf(df.output, into: &stats) else { return stats }
        stats.externalSaves = !((try? await shell.execute(ConsoleTools.externalSavesCommand))?.output.isEmpty ?? true)
        if let saves = try? await shell.execute(ConsoleTools.saveSizeCommand), let kb = Int64(saves.output) {
            stats.saveStatesSize = kb * 1024
        }
        if let sync = try? await shell.execute("hakchi findGameSyncStorage"), !sync.output.isEmpty,
           let du = try? await shell.execute(ConsoleTools.collectionsCommand(syncPath: sync.output)) {
            ConsoleTools.parseCollections(du.stdout, into: &stats)
        }
        return stats
    }

    // MARK: - Technical information

    /// Remote paths CE shows in TechInfo, as (label, value)
    func remotePaths() async -> [(String, String)] {
        let commands: [(String, String)] = [
            ("Remote sync", "hakchi findGameSyncStorage"),
            ("System code", "hakchi eval 'echo \"$sftype-$sfregion\"'"),
            ("Current firmware", "hakchi currentFirmware"),
            ("Games (gamepath)", "hakchi get gamepath"),
            ("RootFS", "hakchi get rootfs"),
            ("SquashFS", "hakchi get squashfs"),
        ]
        var result: [(String, String)] = [("Config", "/etc/preinit.d/p0000_config"), ("Media", "/media"),
                                          ("Games", "/var/games"), ("Profile", "/var/saves")]
        for (label, cmd) in commands {
            let value = (try? await shell.execute(cmd, timeout: 5000))?.output ?? ""
            result.append((label, value.isEmpty ? "-" : value))
        }
        return result
    }

    /// Console-side settings (`cfg_*` keys from p0000_config)
    func consoleSettings() async -> [(String, String)] {
        guard let text = try? await shell.execute("cat /etc/preinit.d/p0000_config").stdout else { return [] }
        let regex = try! NSRegularExpression(pattern: #"cfg_([^=]+)=("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let value = ns.substring(with: m.range(at: 2))
            return (ns.substring(with: m.range(at: 1)), String(value.dropFirst().dropLast()))
        }
    }

    // MARK: - File browser

    func list(_ path: String) async throws -> [ConsoleTools.RemoteFile] {
        let result = try await shell.execute(ConsoleTools.listCommand(path), timeout: 15000)
        return ConsoleTools.parseListing(result.stdout)
    }

    func downloadFile(_ remotePath: String, to url: URL,
                      progress: SSHService.TransferProgress? = nil) async throws {
        try await shell.download(command: "cat \(ConsoleTools.quote(remotePath))", to: url, progress: progress)
    }

    /// Download a folder as a tar stream and unpack it locally
    func downloadFolder(_ remotePath: String, to directory: URL) async throws {
        let parent = (remotePath as NSString).deletingLastPathComponent
        let name = (remotePath as NSString).lastPathComponent
        let tarURL = directory.appendingPathComponent(".\(name)-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tarURL) }
        try await shell.download(command: "tar -cC \(ConsoleTools.quote(parent.isEmpty ? "/" : parent)) \(ConsoleTools.quote(name))",
                                 to: tarURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", tarURL.path, "-C", directory.path]
        try process.run()
        process.waitUntilExit()
    }

    func uploadFile(_ url: URL, toFolder remoteFolder: String,
                    progress: SSHService.TransferProgress? = nil) async throws {
        let dest = (remoteFolder as NSString).appendingPathComponent(url.lastPathComponent)
        let result = try await shell.upload(fileURL: url, command: "cat > \(ConsoleTools.quote(dest))", progress: progress)
        guard result.succeeded else { throw ToolsError.commandFailed("upload", result.stderr) }
    }

    func delete(_ remotePath: String) async throws {
        let result = try await shell.execute("rm -rf \(ConsoleTools.quote(remotePath))", timeout: 30000)
        guard result.succeeded else { throw ToolsError.commandFailed("rm", result.stderr) }
    }

    func makeFolder(_ remotePath: String) async throws {
        let result = try await shell.execute("mkdir -p \(ConsoleTools.quote(remotePath))")
        guard result.succeeded else { throw ToolsError.commandFailed("mkdir", result.stderr) }
    }
}
