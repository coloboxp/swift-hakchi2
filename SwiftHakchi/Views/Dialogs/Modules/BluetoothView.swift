import SwiftUI

/// Bluetooth controller pairing (port of Hakchi2-CE's Bluetooth menu, shown as a sheet):
/// adapters, paired devices (click to unpair), detected devices (click to pair),
/// trusted-but-not-paired devices (click to remove), and "Remove all devices".
struct BluetoothView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @State private var devices: [BluetoothDevice] = []
    @State private var isBusy = false
    @State private var status: String?
    @State private var error: String?

    private var controllers: [BluetoothDevice] { devices.filter { $0.kind == .controller } }
    private var deviceList: [BluetoothDevice] { devices.filter { $0.kind == .device } }
    private var paired: [BluetoothDevice] { deviceList.filter(\.paired) }
    private var detected: [BluetoothDevice] { deviceList.filter { !$0.paired && !$0.trusted } }
    private var trusted: [BluetoothDevice] { deviceList.filter { !$0.paired && $0.trusted } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bluetooth").font(.title2.bold())
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
            }
            Text("Put the controller in pairing mode, click Scan, then click it under Detected Devices.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                if devices.isEmpty {
                    Text("No devices detected").foregroundStyle(.secondary)
                }
                if !controllers.isEmpty {
                    Section("Bluetooth Adapters") {
                        ForEach(controllers) { Text($0.label) }
                    }
                }
                if !paired.isEmpty {
                    Section("Paired Devices (click to unpair)") {
                        ForEach(paired) { device in
                            Button(device.label + (device.connected ? " — connected" : "")) {
                                act("Unpairing \(device.label)...") { try await $0.unpair(device.address) }
                            }
                        }
                    }
                }
                if !detected.isEmpty {
                    Section("Detected Devices (click to pair)") {
                        ForEach(detected) { device in
                            Button(device.label) {
                                act("Pairing \(device.label)...") { try await $0.pair(device.address) }
                            }
                        }
                    }
                }
                if !trusted.isEmpty {
                    Section("Trusted, Not Paired (click to remove)") {
                        ForEach(trusted) { device in
                            Button(device.label) {
                                act("Removing \(device.label)...") { try await $0.unpair(device.address) }
                            }
                        }
                    }
                }
            }
            .buttonStyle(.link)
            .disabled(isBusy)

            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            else if let status { Text(status).font(.caption).foregroundStyle(.secondary) }

            HStack {
                Button("Scan") { refresh(scan: 10) }
                Button("Remove All Devices") {
                    let list = deviceList
                    act("Removing all devices...") { try await $0.removeAll(list) }
                }
                .disabled(deviceList.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(isBusy)
        }
        .padding()
        .frame(width: 480, height: 460)
        .onAppear { refresh(scan: 0) }
    }

    private func refresh(scan: Int) {
        guard let shell = appState.deviceManager.sshService else { error = "Console not connected."; return }
        isBusy = true
        error = nil
        status = scan > 0 ? "Scanning for \(scan) seconds..." : "Reading devices..."
        Task {
            do {
                devices = try await BluetoothService(ssh: shell).refresh(scanSeconds: scan)
                status = "\(deviceList.count) device(s)"
            } catch {
                self.error = error.localizedDescription
            }
            isBusy = false
        }
    }

    /// Run an action, then reload the device list
    private func act(_ message: String, _ work: @escaping (BluetoothService) async throws -> Void) {
        guard let shell = appState.deviceManager.sshService else { error = "Console not connected."; return }
        isBusy = true
        error = nil
        status = message
        Task {
            do {
                try await work(BluetoothService(ssh: shell))
            } catch {
                self.error = error.localizedDescription
            }
            isBusy = false
            refresh(scan: 0)
        }
    }
}
