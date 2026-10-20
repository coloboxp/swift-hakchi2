import SwiftUI
import AppKit

/// Turns raw PTY output into plain text for the line-mode terminal:
/// drops ANSI escape sequences, applies backspaces, and treats "\r\n" as a newline.
enum TerminalText {
    /// Append `chunk` to `buffer`, keeping at most `limit` characters
    static func append(_ chunk: String, to buffer: inout String, limit: Int = 200_000) {
        var text = chunk.replacingOccurrences(of: "\r\n", with: "\n")
        // CSI (ESC [ ... letter), OSC (ESC ] ... BEL) and two-byte escapes
        text = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\u{1B}[@-_]", with: "", options: .regularExpression)
        for ch in text {
            switch ch {
            case "\u{08}": if !buffer.isEmpty && buffer.last != "\n" { buffer.removeLast() }
            case "\r": // carriage return alone: start the line again
                if let nl = buffer.lastIndex(of: "\n") {
                    buffer.removeSubrange(buffer.index(after: nl)...)
                } else {
                    buffer.removeAll()
                }
            case "\u{07}": break // bell
            default: buffer.append(ch)
            }
        }
        if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
    }
}

/// Interactive shell session behind the terminal window
@MainActor
final class TerminalSession: ObservableObject {
    @Published var output = ""
    @Published var isOpen = false
    @Published var error: String?

    private var shell: SSHService?
    private var handle: OpaquePointer?
    private var pollTask: Task<Void, Never>?

    func open(_ shell: SSHService) {
        guard handle == nil else { return }
        self.shell = shell
        Task {
            do {
                let h = try await shell.openShell(columns: 120, rows: 40)
                handle = h
                isOpen = true
                startPolling(shell, h)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Poll in short slices so other console commands can run in between
    private func startPolling(_ shell: SSHService, _ h: OpaquePointer) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let data = await shell.readShell(h, timeout: 50) else {
                    self?.isOpen = false
                    self?.output += "\n[session ended]\n"
                    return
                }
                if data.isEmpty {
                    try? await Task.sleep(for: .milliseconds(80))
                } else if let self {
                    TerminalText.append(String(decoding: data, as: UTF8.self), to: &self.output)
                }
            }
        }
    }

    func send(_ text: String) {
        guard let shell, let handle else { return }
        Task { await shell.writeShell(handle, Data(text.utf8)) }
    }

    func close() {
        pollTask?.cancel()
        pollTask = nil
        if let shell, let handle {
            Task { await shell.closeShell(handle) }
        }
        handle = nil
        isOpen = false
    }
}

/// Built-in terminal (replaces CE's "Open Telnet client" / PuTTY).
/// Line mode: type a command and press Return; full-screen programs such as vi
/// are not supported.
struct TerminalView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var session = TerminalSession()
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.output.isEmpty ? " " : session.output)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: session.output) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }

            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal)
            }

            HStack {
                TextField("Command", text: $input)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit {
                        session.send(input + "\n")
                        input = ""
                    }
                Button("Ctrl-C") { session.send("\u{03}") }
                Button("Tab") { session.send(input + "\t"); input = "" }
                Button("Clear") { session.output = "" }
            }
            .padding(8)
            .disabled(!session.isOpen)
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear {
            if let shell = appState.deviceManager.sshService {
                session.open(shell)
            } else {
                session.error = "Console not connected."
            }
            inputFocused = true
        }
        .onDisappear { session.close() }
    }
}
