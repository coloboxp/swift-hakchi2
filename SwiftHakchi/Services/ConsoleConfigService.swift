import Foundation
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "ConsoleConfig")

/// Reads and writes hakchi's console settings in `/etc/preinit.d/p0000_config`
/// (port of CE's `hakchi.LoadConfig` / `hakchi.SyncConfig`)
enum ConsoleConfigService {
    static let configPath = "/etc/preinit.d/p0000_config"

    /// Read all `cfg_*` values from the console
    static func read(shell: SSHService) async throws -> [String: String] {
        let result = try await shell.execute("cat \(configPath)", timeout: 10_000)
        guard result.succeeded else { return [:] }
        return ConsoleSettings.parseConfigFile(result.stdout)
    }

    /// Push settings through `hakchi eval` (stdin = `cfg_key='value'` lines), optionally rebooting
    static func push(_ config: [String: String], shell: SSHService, reboot: Bool = false) async throws {
        let script = ConsoleSettings.evalScript(for: config)
        let result = try await shell.execute("hakchi eval", input: Data(script.utf8), name: "hakchi_cfg.sh", timeout: 10_000)
        if !result.succeeded {
            logger.warning("hakchi eval returned \(result.exitCode): \(result.stderr)")
        }
        if reboot {
            _ = try? await shell.execute("reboot", timeout: 2000)
        }
    }

    /// Set the SEGA (Mega Drive) UI theme: "auto", "us", "eu" or "jp" (CE's SEGA UI Theme menu)
    static func setSegaTheme(_ region: String, shell: SSHService) async throws {
        _ = try await shell.execute("uistop; hakchi set cfg_mdui_region \(SyncPlan.shellQuote(region)); uistart", timeout: 20_000)
    }

    /// Current SEGA UI theme ("" when unset)
    static func segaTheme(shell: SSHService) async -> String {
        (try? await shell.execute("hakchi get cfg_mdui_region", timeout: 5000))?.output ?? ""
    }
}
