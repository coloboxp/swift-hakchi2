import Foundation

/// Manages hmod installation/uninstallation on the console.
///
/// Uses hakchi's boot-time transfer mechanism (same as hakchi2-CE's
/// "transfer only" mode): modules are staged in `/var/lib/hakchi/transfer/`,
/// names to remove are listed in `/var/lib/hakchi/transfer/uninstall`, and on
/// the next boot hakchi's `p7080_hmods` preinit script runs `packs_uninstall`
/// and `packs_install` on them, then reboots again. So changes only take
/// effect after `applyAndReboot()`.
actor HmodService {
    static let transferPath = "/var/lib/hakchi/transfer"

    private let ssh: SSHService

    init(ssh: SSHService) {
        self.ssh = ssh
    }

    /// Names of installed hmods (hakchi tracks them as hmod/uninstall-<name>)
    func installedHmods() async throws -> [String] {
        let result = try await ssh.execute("hakchi pack_list")
        guard result.succeeded else {
            throw SSHError.commandFailed(command: "hakchi pack_list",
                                         exitCode: result.exitCode,
                                         stderr: result.stderr)
        }
        return result.output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Names of hmods already staged for install on next boot
    func pendingInstalls() async throws -> [String] {
        let result = try await ssh.execute("ls \(Self.quote(Self.transferPath)) 2>/dev/null")
        return result.output.components(separatedBy: .newlines)
            .filter { $0.hasSuffix(".hmod") }
            .map { String($0.dropLast(".hmod".count)) }
    }

    /// Stage a packed .hmod (tar.gz) file for install on next boot
    func stageHmod(data: Data, name: String) async throws {
        try await makeTransferDir()
        let fileName = name.hasSuffix(".hmod") ? name : name + ".hmod"
        try await ssh.upload(data: data, to: "\(Self.transferPath)/\(Self.safeFileName(fileName))")
    }

    /// Stage an unpacked .hmod directory. `tarData` must contain a top-level
    /// "<name>.hmod/" folder.
    func stageHmodDirectory(tarData: Data) async throws {
        try await makeTransferDir()
        try await ssh.uploadTar(data: tarData, to: Self.transferPath)
    }

    /// Mark installed hmods for removal on next boot
    func stageUninstall(_ names: [String]) async throws {
        guard !names.isEmpty else { return }
        try await makeTransferDir()
        let lines = names.map { Self.quote($0) }.joined(separator: " ")
        let cmd = "printf '%s\\n' \(lines) >> \(Self.quote(Self.transferPath + "/uninstall"))"
        let result = try await ssh.execute(cmd)
        guard result.succeeded else {
            throw SSHError.commandFailed(command: cmd, exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Reboot so hakchi processes the staged changes. The SSH connection
    /// drops during the reboot, so errors from this call are ignored.
    func applyAndReboot() async {
        _ = try? await ssh.execute("sync; reboot", timeout: 5000)
    }

    // MARK: - Helpers

    private func makeTransferDir() async throws {
        let result = try await ssh.execute("mkdir -p \(Self.quote(Self.transferPath))")
        guard result.succeeded else {
            throw SSHError.commandFailed(command: "mkdir", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Single-quote a string for the console's shell
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Strip path separators and characters that break hakchi's shell scripts
    /// (packs_install iterates `$(find ...)` unquoted, so spaces are not safe).
    static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}
