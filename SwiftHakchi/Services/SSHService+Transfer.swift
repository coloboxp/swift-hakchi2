import Foundation
import SWCompression

/// Higher-level transfers built on `SSHService.execute`/`upload` (no new C code needed:
/// exec output is binary-safe and the read timeout is an idle timeout).
extension SSHService {
    /// Run a shell script by uploading it to /tmp first (CE's RunTemporaryScript).
    /// Avoids command-length limits for long scripts such as file cleanup lists.
    @discardableResult
    func runScript(_ script: String, name: String, timeout: Int = 120_000) async throws -> SSHResult {
        let path = "/tmp/\(name)"
        try upload(data: Data(script.utf8), to: path)
        defer { _ = try? execute("rm -f \(SyncPlan.shellQuote(path))", timeout: 5000) }
        return try execute("sh \(SyncPlan.shellQuote(path))", timeout: timeout)
    }

    /// Run `command` with `input` on its stdin, via a temporary file (e.g. `hakchi eval`)
    @discardableResult
    func execute(_ command: String, input: Data, name: String, timeout: Int = 30_000) async throws -> SSHResult {
        let path = "/tmp/\(name)"
        try upload(data: input, to: path)
        defer { _ = try? execute("rm -f \(SyncPlan.shellQuote(path))", timeout: 5000) }
        return try execute("\(command) < \(SyncPlan.shellQuote(path))", timeout: timeout)
    }

    /// Download one file exactly (binary-safe; works for large ROMs)
    func download(path: String, timeout: Int = 60_000) throws -> Data {
        let result = try execute("cat \(SyncPlan.shellQuote(path))", timeout: timeout)
        guard result.succeeded else {
            throw SSHError.commandFailed(command: "cat \(path)", exitCode: result.exitCode, stderr: result.stderr)
        }
        return result.stdoutData
    }

    /// Download a folder as a tar stream and unpack it into `destination`
    /// (subfolders and file names kept; symlinks are skipped). Returns the files written.
    @discardableResult
    func downloadDirectory(_ remotePath: String, to destination: URL, timeout: Int = 60_000) throws -> [URL] {
        let result = try execute("cd \(SyncPlan.shellQuote(remotePath)) && tar -cf - .", timeout: timeout)
        guard result.succeeded || !result.stdoutData.isEmpty else {
            throw SSHError.commandFailed(command: "tar \(remotePath)", exitCode: result.exitCode, stderr: result.stderr)
        }
        return try Self.unpackTar(result.stdoutData, to: destination)
    }

    /// Unpack tar data into a folder, refusing entries that would escape it
    static func unpackTar(_ data: Data, to destination: URL) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL.path
        var written: [URL] = []
        for entry in try TarContainer.open(container: data) {
            var name = entry.info.name
            while name.hasPrefix("./") { name.removeFirst(2) }
            guard !name.isEmpty, name != "." else { continue }
            let target = destination.appendingPathComponent(name).standardizedFileURL
            guard target.path.hasPrefix(root + "/") else { continue }
            switch entry.info.type {
            case .directory:
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case .regular:
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (entry.data ?? Data()).write(to: target)
                if let mtime = entry.info.modificationTime {
                    try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: target.path)
                }
                written.append(target)
            default:
                continue
            }
        }
        return written
    }
}
