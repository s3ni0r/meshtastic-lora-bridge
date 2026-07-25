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

    /// Raw portnum-260 frame over this direct link (track uploads etc. — DOWNLINK.md op 0x05).
    func sendRaw(_ payload: Data) { send(payload) }

    func apply(_ s: TagSettings) {
        stage = .applying
        lastStatus = nil
        send(Data([0x01]) + s.wire)
    }
}

// MARK: - Navigation mode catalog (shared by the Tag Setup screen)

struct NavModeInfo: Identifiable {
    let mode: UInt8
    let name: String
    let icon: String
    let detail: String
    let egnos: Bool     // SBAS/EGNOS stays active in this mode
    let supported: Bool // our unit's firmware ACKs it (Swimming is rejected, ACK 4)
    var id: UInt8 { mode }
}

let kNavModes: [NavModeInfo] = [
    .init(mode: 1, name: "Fitness", icon: "figure.walk",
          detail: "Walking / running — weights movement under 5 m/s", egnos: false, supported: true),
    .init(mode: 5, name: "Drone", icon: "airplane",
          detail: "Flight dynamics, vertical acceleration", egnos: true, supported: true),
    .init(mode: 0, name: "Normal", icon: "globe.europe.africa",
          detail: "General purpose", egnos: true, supported: true),
    .init(mode: 9, name: "Bike", icon: "bicycle",
          detail: "Cycling dynamics", egnos: true, supported: true),
    .init(mode: 4, name: "Stationary", icon: "mappin.and.ellipse",
          detail: "Fixed installation, zero dynamics", egnos: true, supported: true),
    .init(mode: 7, name: "Swimming", icon: "figure.pool.swim",
          detail: "Rejected by this unit's firmware (ACK 4)", egnos: false, supported: false),
]
