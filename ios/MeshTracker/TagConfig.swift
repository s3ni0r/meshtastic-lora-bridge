import SwiftUI
import CoreBluetooth
import Observation

// Standard Meshtastic BLE GATT UUIDs (same as BLEManager — this is a second, short-lived link
// directly to the TAG, while the Base connection keeps streaming).
private let kService = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
private let kToRadio = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")
private let kFromRadio = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002")
private let kFromNum = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547e34453")

/// Connects to the GPS tag over its own BLE and speaks the portnum-260 config protocol
/// (GnssConfigModule): handshake -> GET (populate) -> SET (apply + confirm). The tag applies
/// settings live and persists them — no reflash, no reboot.
@Observable
final class TagConfigManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Stage: Equatable { case idle, scanning, connecting, handshaking, ready, applying, failed(String) }
    var stage = Stage.idle
    var discovered: [(id: UUID, name: String)] = []
    var deviceName = ""
    var settings: TagSettings?      // last state read back from the tag
    var lastStatus: UInt8?          // 0 ok / 1 rejected / 2 malformed (from the last SET)

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var toRadio: CBCharacteristic?
    @ObservationIgnored private var fromRadio: CBCharacteristic?
    @ObservationIgnored private var targetNode: UInt32 = 0
    @ObservationIgnored private var handshakeDone = false

    private var rememberKey: String { "tagPeriph.\(targetNode)" }

    func begin(targetNode: UInt32) {
        self.targetNode = targetNode
        stage = .scanning
        discovered = []
        settings = nil
        lastStatus = nil
        handshakeDone = false
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil; toRadio = nil; fromRadio = nil
        stage = .idle
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            if c.state != .unknown { stage = .failed("Bluetooth unavailable") }
            return
        }
        c.scanForPeripherals(withServices: [kService])
        // Auto-reconnect to the peripheral used for this tag before.
        if let saved = UserDefaults.standard.string(forKey: rememberKey), let id = UUID(uuidString: saved),
           let p = c.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "?"
        if !discovered.contains(where: { $0.id == p.identifier }) {
            discovered.append((p.identifier, name))
        }
    }

    func connect(_ id: UUID) {
        guard let c = central, let p = c.retrievePeripherals(withIdentifiers: [id]).first else { return }
        connect(p)
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        deviceName = p.name ?? "tag"
        stage = .connecting
        central?.stopScan()
        central?.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        UserDefaults.standard.set(p.identifier.uuidString, forKey: rememberKey)
        stage = .handshaking
        p.discoverServices([kService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        stage = .failed("connect failed")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if stage != .idle { stage = .failed("disconnected") }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = p.services?.first(where: { $0.uuid == kService }) else { return }
        p.discoverCharacteristics([kToRadio, kFromRadio, kFromNum], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        for ch in svc.characteristics ?? [] {
            switch ch.uuid {
            case kToRadio: toRadio = ch
            case kFromRadio: fromRadio = ch
            case kFromNum: p.setNotifyValue(true, for: ch)
            default: break
            }
        }
        guard let tr = toRadio else { stage = .failed("missing characteristics"); return }
        // Handshake: want_config, then drain FromRadio until an empty read.
        p.writeValue(encodeWantConfig(UInt32.random(in: 1...UInt32.max)), for: tr, type: .withResponse)
        if let fr = fromRadio { p.readValue(for: fr) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == kFromNum {
            if let fr = fromRadio { p.readValue(for: fr) }
            return
        }
        guard ch.uuid == kFromRadio else { return }
        if let v = ch.value, !v.isEmpty {
            if let reply = parseConfigReply(v) {
                settings = reply.settings
                if reply.op == 0x81 { lastStatus = reply.status }
                stage = .ready
            }
            if let fr = fromRadio { p.readValue(for: fr) } // keep draining
        } else if !handshakeDone {
            handshakeDone = true
            sendGet() // config drained — ask the tag for its current GNSS settings
        }
    }

    private func send(_ payload: Data) {
        guard let p = peripheral, let tr = toRadio else { return }
        let frame = encodeToRadioData(to: targetNode, portnum: kGnssConfigPortnum, payload: payload,
                                      packetId: UInt32.random(in: 1...UInt32.max))
        p.writeValue(frame, for: tr, type: .withResponse)
        if let fr = fromRadio { p.readValue(for: fr) }
    }

    func sendGet() { send(Data([0x00])) }

    func apply(_ s: TagSettings) {
        stage = .applying
        lastStatus = nil
        send(Data([0x01]) + s.wire)
    }
}

// MARK: - UI

struct NavModeInfo {
    let mode: UInt8
    let name: String
    let detail: String
    let egnos: Bool // SBAS/EGNOS stays active in this mode
}

let kNavModes: [NavModeInfo] = [
    .init(mode: 0, name: "Normal", detail: "General purpose", egnos: true),
    .init(mode: 1, name: "Fitness", detail: "Walking / running (< 5 m/s weighted)", egnos: false),
    .init(mode: 4, name: "Stationary", detail: "Fixed installation, zero dynamics", egnos: true),
    .init(mode: 5, name: "Drone", detail: "Flight dynamics, vertical acceleration", egnos: true),
    .init(mode: 7, name: "Swimming", detail: "Smooths trajectory at water pace", egnos: false),
    .init(mode: 9, name: "Bike", detail: "Cycling dynamics", egnos: true),
]

struct TagConfigSheet: View {
    let track: SourceTrack
    let ble: BLEManager
    @State private var mgr = TagConfigManager()
    @State private var draft = TagSettings()
    @State private var loadedFromTag = false
    @Environment(\.dismiss) private var dismiss

    /// The stream link already goes straight to THIS tag (no Base alive): reuse it for config —
    /// a second PhoneAPI client on the same node would fight over the FromRadio queue.
    private var direct: Bool { ble.directTag && ble.connectedNodeNum == track.from }
    private var currentSettings: TagSettings? { direct ? ble.lastConfigReply?.settings : mgr.settings }
    private var dirty: Bool { loadedFromTag && draft != (currentSettings ?? draft) }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                if loadedFromTag {
                    settingsSections
                }
            }
            .navigationTitle("GNSS settings · \(track.shortId)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { mgr.stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if direct { ble.sendTagConfig(Data([0x01]) + draft.wire) } else { mgr.apply(draft) }
                    }
                    .disabled(!dirty || mgr.stage == .applying)
                    .bold()
                }
            }
            .onAppear {
                if direct { ble.sendTagConfig(Data([0x00])) } else { mgr.begin(targetNode: track.from) }
            }
            .onDisappear { if !direct { mgr.stop() } }
            .onChange(of: currentSettings) {
                if let s = currentSettings {
                    draft = s
                    loadedFromTag = true
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private var connectionSection: some View {
        Section("Tag connection (BLE)") {
            if direct {
                HStack {
                    Label("\(ble.nodeName) — direct link", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    if let st = ble.lastConfigReply?.status, ble.lastConfigReply?.op == 0x81 {
                        Text(st == 0 ? "applied ✓" : "rejected (\(st))")
                            .foregroundStyle(st == 0 ? .green : .red).font(.caption)
                    }
                }
            } else {
                nonDirectConnectionRows
            }
        }
    }

    @ViewBuilder private var nonDirectConnectionRows: some View {
            switch mgr.stage {
            case .scanning:
                if mgr.discovered.isEmpty {
                    HStack { ProgressView(); Text("Scanning for the tag…").foregroundStyle(.secondary) }
                } else {
                    ForEach(mgr.discovered, id: \.id) { d in
                        Button { mgr.connect(d.id) } label: {
                            Label(d.name, systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                }
            case .connecting, .handshaking:
                HStack { ProgressView(); Text("Connecting to \(mgr.deviceName)…").foregroundStyle(.secondary) }
            case .ready, .applying:
                HStack {
                    Label(mgr.deviceName, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    if mgr.stage == .applying { ProgressView() }
                    else if mgr.lastStatus == 0 { Text("applied ✓").foregroundStyle(.green).font(.caption) }
                    else if let st = mgr.lastStatus, st != 0 {
                        Text("rejected (\(st))").foregroundStyle(.red).font(.caption)
                    }
                }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Retry") { mgr.begin(targetNode: track.from) }
            case .idle:
                Text("—").foregroundStyle(.secondary)
            }
    }

    @ViewBuilder private var settingsSections: some View {
        Section {
            ForEach(kNavModes, id: \.mode) { m in
                Button {
                    draft.navMode = m.mode
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(m.name).foregroundStyle(.primary)
                                if m.egnos {
                                    Text("EGNOS").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.green.opacity(0.15), in: Capsule()).foregroundStyle(.green)
                                }
                            }
                            Text(m.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if draft.navMode == m.mode {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
        } header: {
            Text("Navigation mode ($PAIR080)")
        } footer: {
            Text("Fitness/Swimming trade EGNOS corrections for stronger low-speed filtering.")
        }

        Section("Motion filtering") {
            VStack(alignment: .leading) {
                HStack {
                    Text("Static freeze below")
                    Spacer()
                    Text(draft.staticThrDms == 0 ? "off" : String(format: "%.1f m/s", Double(draft.staticThrDms) / 10))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(get: { Double(draft.staticThrDms) },
                                      set: { draft.staticThrDms = UInt8($0) }), in: 0...20, step: 1)
            }
            VStack(alignment: .leading) {
                HStack {
                    Text("Min satellite SNR")
                    Spacer()
                    Text("\(draft.minSnr) dB").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: Binding(get: { Double(draft.minSnr) },
                                      set: { draft.minSnr = UInt8($0) }), in: 9...37, step: 1)
            }
        }

        Section {
            Picker("GNSS fix rate", selection: $draft.fixIntervalMs) {
                Text("1 Hz").tag(UInt16(1000))
                Text("2 Hz").tag(UInt16(500))
                Text("4 Hz").tag(UInt16(250))
                Text("5 Hz").tag(UInt16(200))
                Text("10 Hz").tag(UInt16(100))
            }
            Picker("LoRa TX spacing", selection: $draft.txSpacingMs) {
                Text("2 Hz — EU868 legal").tag(UInt16(500))
                Text("4 Hz").tag(UInt16(250))
                Text("6.7 Hz").tag(UInt16(150))
                Text("10 Hz").tag(UInt16(100))
            }
        } header: {
            Text("Rates")
        } footer: {
            Text("Sustained TX above 2 Hz exceeds the EU868 duty cycle — bench/US only.")
        }

        Section("Deployment profiles") {
            Button {
                draft.fixIntervalMs = 250; draft.txSpacingMs = 500
            } label: { Label("France · EU868 (4 Hz GNSS, 2 Hz TX)", systemImage: "flag.fill") }
            Button {
                draft.fixIntervalMs = 250; draft.txSpacingMs = 150
            } label: { Label("US bench (4 Hz GNSS, fast TX)", systemImage: "hare.fill") }
        }
    }
}
