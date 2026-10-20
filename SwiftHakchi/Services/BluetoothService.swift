import Foundation
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "Bluetooth")

/// A Bluetooth adapter or device as reported by `bluetoothctl`
/// (port of Hakchi2-CE's `BluetoothControl.BluetoothDeviceData`).
struct BluetoothDevice: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case controller, device }

    let address: String
    var kind: Kind = .device
    var name: String?
    var alias: String?
    var paired = false
    var trusted = false
    var connected = false
    var blocked = false
    var powered = false

    var id: String { address }
    /// "Name (AA:BB:…)" or just the address, like CE's menu items
    var label: String { name.map { "\($0) (\(address))" } ?? address }
}

/// Parses `bluetoothctl` output with CE's regular expressions.
enum BluetoothOutputParser {
    private static let mac = "[A-F0-9]{2}(?::[A-F0-9]{2}){5}"
    private static let change = try! NSRegularExpression(pattern: #"^\[(CHG)\] (Device|Controller) ("# + mac + #") ([^:]+): (.+)$"#)
    private static let newDel = try! NSRegularExpression(pattern: #"^\[(NEW|DEL)\] (Device|Controller) ("# + mac + #") *(.*)$"#)
    private static let device = try! NSRegularExpression(pattern: #"^\s*Device ("# + mac + #") *(.*?)\s*$"#)
    private static let controller = try! NSRegularExpression(pattern: #"^Controller ("# + mac + #") *(.*?)\s*$"#)
    private static let info = try! NSRegularExpression(pattern: #"^\s+([^:]+):\s+(.*?)\s*$"#)
    /// ANSI escapes and readline markers (CE's escapeRegex)
    private static let escapes = try! NSRegularExpression(pattern: "(\u{1B}\\[[0-9;]*[a-zA-Z]|\u{01}|\u{02})")
    /// Interactive prompts like "[bluetooth]# " or "[Wireless Controller]# "
    private static let prompt = try! NSRegularExpression(pattern: #"^(?:\[[^\]\r\n]*\][#>] ?)+"#)

    /// Devices and controllers found in the output, sorted by name
    static func parse(_ output: String) -> [BluetoothDevice] {
        var devices: [String: BluetoothDevice] = [:]
        var order: [String] = []
        var infoDevice: String?

        func get(_ address: String) -> BluetoothDevice {
            if let d = devices[address] { return d }
            order.append(address)
            return BluetoothDevice(address: address)
        }

        for rawLine in output.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            var line = replace(escapes, in: rawLine, with: "")
            line = replace(prompt, in: line, with: "")
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            if let m = match(controller, line) {
                var d = get(m[0]); d.kind = .controller
                d.name = nameOrNil(m[1].replacingOccurrences(of: "[default]", with: ""))
                devices[m[0]] = d
                infoDevice = nil
            } else if let m = match(newDel, line) {
                if m[0] == "DEL" {
                    devices[m[2]] = nil
                    order.removeAll { $0 == m[2] }
                } else {
                    var d = get(m[2]); d.kind = m[1] == "Device" ? .device : .controller
                    if let name = nameOrNil(m[3]) { d.name = name }
                    devices[m[2]] = d
                }
                infoDevice = nil
            } else if let m = match(change, line) {
                var d = get(m[2]); d.kind = m[1] == "Device" ? .device : .controller
                apply(key: m[3].trimmingCharacters(in: .whitespaces), value: m[4], to: &d)
                devices[m[2]] = d
            } else if let m = match(device, line) {
                // "Device AA:… Name" from `devices`, or the first line of an `info` block
                var d = get(m[0])
                if let name = nameOrNil(m[1]), !name.hasPrefix("(") { d.name = d.name ?? name }
                devices[m[0]] = d
                infoDevice = m[0]
            } else if let address = infoDevice, let m = match(info, rawLine) {
                // Indented "Key: value" lines of an `info` block (CE turns them into [CHG])
                var d = get(address)
                apply(key: m[0], value: m[1], to: &d)
                devices[address] = d
            }
        }

        return order.compactMap { devices[$0] }
            .sorted { ($0.name ?? $0.address).localizedCaseInsensitiveCompare($1.name ?? $1.address) == .orderedAscending }
    }

    private static func apply(key: String, value: String, to d: inout BluetoothDevice) {
        let yes = value.trimmingCharacters(in: .whitespaces) == "yes"
        switch key {
        case "Name": d.name = value
        case "Alias": d.alias = value
        case "Paired": d.paired = yes
        case "Trusted": d.trusted = yes
        case "Connected": d.connected = yes
        case "Blocked": d.blocked = yes
        case "Powered": d.powered = yes
        default: break
        }
    }

    private static func nameOrNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private static func match(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
        }
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with t: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
    }
}

/// Drives `bluetoothctl` on the console over SSH (CE talks to it over TCP port 787;
/// this app only has SSH, so each action pipes a short command script into it).
actor BluetoothService {
    private let ssh: SSHService

    init(ssh: SSHService) {
        self.ssh = ssh
    }

    /// CE shows the Bluetooth menu only when `which bluetoothctl` succeeds
    func isAvailable() async -> Bool {
        (try? await ssh.execute("which bluetoothctl"))?.succeeded ?? false
    }

    /// List adapters and devices; with `scanSeconds` > 0, scan for new devices first.
    func refresh(scanSeconds: Int = 0) async throws -> [BluetoothDevice] {
        let scan = scanSeconds > 0 ? "echo 'scan on'; sleep \(scanSeconds); echo 'scan off'; " : ""
        // First pass finds the devices, second pass asks `info` for each (CE: ProcessDevices)
        let script = """
        out=$( ( echo 'list'; \(scan)echo 'devices'; sleep 1; echo 'quit' ) | bluetoothctl 2>&1 )
        echo "$out"
        for a in $(echo "$out" | grep -o 'Device [0-9A-F:]\\{17\\}' | cut -d' ' -f2 | sort -u); do
          ( echo "info $a"; sleep 1; echo 'quit' ) | bluetoothctl 2>&1
        done
        """
        let result = try await ssh.execute(script, timeout: (scanSeconds + 30) * 1000)
        return BluetoothOutputParser.parse(result.stdout)
    }

    /// CE's pair flow: trust, then pair once trusted, then connect once paired
    func pair(_ address: String) async throws {
        try await run(["trust \(address)", "pair \(address)", "connect \(address)"], pause: 4)
    }

    /// CE's unpair: disconnect, untrust, remove
    func unpair(_ address: String) async throws {
        try await run(["disconnect \(address)", "untrust \(address)", "remove \(address)"], pause: 1)
    }

    /// Untrust and remove every device (CE's "Remove all devices")
    func removeAll(_ devices: [BluetoothDevice]) async throws {
        let commands = devices.filter { $0.kind == .device }
            .flatMap { ["untrust \($0.address)", "remove \($0.address)"] }
        guard !commands.isEmpty else { return }
        try await run(commands, pause: 1)
    }

    /// Feed commands to bluetoothctl with a pause after each, so it can finish
    private func run(_ commands: [String], pause: Int) async throws {
        let mac = try! NSRegularExpression(pattern: "^[a-z]+ [A-F0-9]{2}(?::[A-F0-9]{2}){5}$")
        for c in commands where mac.firstMatch(in: c, range: NSRange(location: 0, length: c.utf16.count)) == nil {
            throw BluetoothError.invalidCommand(c)  // never pass unchecked text to the shell
        }
        let body = commands.map { "echo '\($0)'; sleep \(pause);" }.joined(separator: " ")
        let script = "( \(body) echo 'quit' ) | bluetoothctl 2>&1"
        let result = try await ssh.execute(script, timeout: (commands.count * pause + 20) * 1000)
        logger.info("bluetoothctl: \(result.output)")
    }
}

enum BluetoothError: LocalizedError {
    case invalidCommand(String)

    var errorDescription: String? {
        switch self {
        case .invalidCommand(let c): return "Invalid Bluetooth command: \(c)"
        }
    }
}

/// Whether the connected console has bluetoothctl (drives the menu item)
@MainActor
final class BluetoothState: ObservableObject {
    static let shared = BluetoothState()
    @Published var isAvailable = false

    func check(shell: SSHService?) async {
        guard let shell else { isAvailable = false; return }
        isAvailable = await BluetoothService(ssh: shell).isAvailable()
    }
}
