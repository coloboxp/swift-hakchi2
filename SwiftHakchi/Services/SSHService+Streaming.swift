import Foundation
import USBBridge
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "SSHStream")

/// Streaming transfers and the interactive shell (see `ssh_exec_stream` and
/// `ssh_shell_*` in ssh_bridge.c).
extension SSHService {
    /// Progress callback: bytes done, bytes expected (0 when unknown)
    typealias TransferProgress = @Sendable (_ done: UInt64, _ total: UInt64) -> Void

    /// Context passed through the C callbacks; lives for the duration of one call
    private final class StreamContext {
        let onData: (Data) -> Bool
        let onProgress: TransferProgress?
        init(onData: @escaping (Data) -> Bool, onProgress: TransferProgress?) {
            self.onData = onData
            self.onProgress = onProgress
        }
    }

    /// Run a command and hand stdout to `onData` in chunks (return false to stop).
    /// `stdin` is piped in when given; `onUploadProgress` reports how much was sent.
    /// The timeout only fires when no data moves for `idleTimeout` milliseconds.
    /// The returned result has empty stdout.
    func executeStreaming(_ command: String, stdin: Data? = nil, idleTimeout: Int = 60000,
                          onUploadProgress: TransferProgress? = nil,
                          onData: @escaping (Data) -> Bool) throws -> SSHResult {
        guard let s = sessionHandle else { throw SSHError.notConnected }
        logger.info("Stream exec: \(command)")

        let context = StreamContext(onData: onData, onProgress: onUploadProgress)
        let ctx = Unmanaged.passUnretained(context).toOpaque()
        var result = ssh_exec_result_t()
        defer { ssh_result_free(&result) }

        let outCb: ssh_stream_cb = { data, len, ctx in
            guard let data, let ctx else { return true }
            let box = Unmanaged<StreamContext>.fromOpaque(ctx).takeUnretainedValue()
            return box.onData(Data(bytes: data, count: Int(len)))
        }
        let progressCb: ssh_progress_cb = { written, total, ctx in
            guard let ctx else { return }
            Unmanaged<StreamContext>.fromOpaque(ctx).takeUnretainedValue().onProgress?(written, total)
        }

        let ret: Int32 = withExtendedLifetime(context) {
            if let stdin, !stdin.isEmpty {
                return stdin.withUnsafeBytes { buf in
                    ssh_exec_stream(s, command, buf.bindMemory(to: UInt8.self).baseAddress,
                                    UInt64(stdin.count), outCb, progressCb, ctx, &result, Int32(idleTimeout))
                }
            }
            return ssh_exec_stream(s, command, nil, 0, outCb, progressCb, ctx, &result, Int32(idleTimeout))
        }

        let stderr = result.stderr_buf != nil ? String(cString: result.stderr_buf) : ""
        switch ret {
        case 0: break
        case -2: throw SSHError.transferFailed("Cancelled")
        default: throw SSHError.transferFailed("SSH stream error \(ret): \(stderr)")
        }
        return SSHResult(stdout: "", stderr: stderr, stdoutData: Data(), exitCode: Int(result.exit_code))
    }

    /// Stream a command's stdout into a local file (e.g. a NAND dump).
    /// `expectedSize` is only used for progress. Fails if the command exits non-zero.
    @discardableResult
    func download(command: String, to fileURL: URL, expectedSize: UInt64 = 0,
                  progress: TransferProgress? = nil, isCancelled: @escaping @Sendable () -> Bool = { false })
    throws -> UInt64 {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        var received: UInt64 = 0
        var writeError: Error?
        let result = try executeStreaming(command, idleTimeout: 120000) { chunk in
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                writeError = error
                return false
            }
            received += UInt64(chunk.count)
            progress?(received, expectedSize)
            return !isCancelled()
        }
        if let writeError { throw writeError }
        guard result.succeeded else {
            throw SSHError.commandFailed(command: command, exitCode: result.exitCode, stderr: result.stderr)
        }
        return received
    }

    /// Stream a command's stdout into memory (for medium-sized binary output
    /// such as the framebuffer, where `execute` would decode text needlessly).
    func downloadData(command: String, progress: TransferProgress? = nil) throws -> Data {
        var data = Data()
        let result = try executeStreaming(command) { chunk in
            data.append(chunk)
            progress?(UInt64(data.count), 0)
            return true
        }
        guard result.succeeded else {
            throw SSHError.commandFailed(command: command, exitCode: result.exitCode, stderr: result.stderr)
        }
        return data
    }

    /// Run a command with `input` on stdin and collect stdout (e.g. `sh` with a script)
    func execute(_ command: String, input: Data, idleTimeout: Int = 60000) throws -> SSHResult {
        var stdout = Data()
        let result = try executeStreaming(command, stdin: input, idleTimeout: idleTimeout) { chunk in
            stdout.append(chunk)
            return true
        }
        return SSHResult(stdout: String(decoding: stdout, as: UTF8.self), stderr: result.stderr,
                         stdoutData: stdout, exitCode: result.exitCode)
    }

    /// Pipe a (possibly large, memory-mapped) file into a command with upload progress
    func upload(fileURL: URL, command: String, progress: TransferProgress? = nil) throws -> SSHResult {
        let data = try Data(contentsOf: fileURL, options: .alwaysMapped)
        var stdout = Data()
        let result = try executeStreaming(command, stdin: data, idleTimeout: 120000,
                                          onUploadProgress: progress) { chunk in
            stdout.append(chunk)
            return true
        }
        return SSHResult(stdout: String(decoding: stdout, as: UTF8.self), stderr: result.stderr,
                         stdoutData: stdout, exitCode: result.exitCode)
    }

    // MARK: - Interactive shell

    /// Open an interactive shell; returns an opaque handle for the other shell calls
    func openShell(columns: Int, rows: Int) throws -> OpaquePointer {
        guard let s = sessionHandle else { throw SSHError.notConnected }
        guard let sh = ssh_shell_open(s, Int32(columns), Int32(rows)) else {
            throw SSHError.connectionFailed("Could not open an interactive shell")
        }
        return sh
    }

    /// Read output for up to `timeout` ms. Returns nil when the shell has exited.
    func readShell(_ shell: OpaquePointer, timeout: Int = 50) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let n = ssh_shell_read(shell, &buffer, UInt32(buffer.count), Int32(timeout))
        if n < 0 { return nil }
        return Data(buffer.prefix(Int(n)))
    }

    func writeShell(_ shell: OpaquePointer, _ data: Data) {
        _ = data.withUnsafeBytes { buf in
            ssh_shell_write(shell, buf.bindMemory(to: UInt8.self).baseAddress, UInt32(data.count))
        }
    }

    func resizeShell(_ shell: OpaquePointer, columns: Int, rows: Int) {
        _ = ssh_shell_resize(shell, Int32(columns), Int32(rows))
    }

    func closeShell(_ shell: OpaquePointer) {
        ssh_shell_close(shell)
    }
}
