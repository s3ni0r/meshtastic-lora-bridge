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
    var replyCount = 0              // bumps per reply — ACK tracking for bulk uploads
    var lastReplyOp: UInt8 = 0
    var lastReplyStatus: UInt8 = 0
    var trackAcks: [TrackAck] = []  // SEQUENCED 0x85 ACK queue (R4 f7) — cleared per link,
                                    // append-only within one, consumers scan by index
    var linkGeneration = 0          // bumps on every (re)connect/stop — uploads bind to one generation
    var linkNodeNum: UInt32 = 0     // my_node_num of the CONNECTED peripheral (identity proof)

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var toRadio: CBCharacteristic?
    @ObservationIgnored private var fromRadio: CBCharacteristic?
    @ObservationIgnored private var targetNode: UInt32 = 0
    @ObservationIgnored private var handshakeDone = false

    private var rememberKey: String { "tagPeriph.\(targetNode)" }

    func begin(targetNode: UInt32) {
        // Fence the previous session completely before replacing the central: detach our
        // delegate so callbacks from the old connection can never mutate the new session's
        // state (R4 finding 4 — begin() used to swap centrals with the old one still live).
        if let p = peripheral { p.delegate = nil; central?.cancelPeripheralConnection(p) }
        central?.delegate = nil
        central?.stopScan()
        peripheral = nil; toRadio = nil; fromRadio = nil
        self.targetNode = targetNode
        stage = .scanning
        discovered = []
        settings = nil
        lastStatus = nil
        trackAcks = []
        handshakeDone = false
        linkNodeNum = 0
        linkGeneration += 1
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil; toRadio = nil; fromRadio = nil
        linkNodeNum = 0
        linkGeneration += 1
        stage = .idle
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c === central else { return } // stale central from a previous begin() — ignore
        guard c.state == .poweredOn else {
            if c.state != .unknown { stage = .failed("Bluetooth unavailable") }
            return
        }
        c.scanForPeripherals(withServices: [kService])
        // Auto-reconnect to the peripheral used for this tag before. The mapping is written
        // only after a verified identity match and DELETED on mismatch (R4 finding 4), so a
        // stale mapping cannot trap us in a connect-fail-retry loop with the wrong device.
        if let saved = UserDefaults.standard.string(forKey: rememberKey), let id = UUID(uuidString: saved),
           let p = c.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard c === central else { return }
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
        guard c === central, p === peripheral else { return }
        // NOTE: deliberately NOT remembered yet — only the peripheral's own my_info proves
        // this is the target node (see didUpdateValueFor).
        stage = .handshaking
        p.discoverServices([kService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard c === central, p === peripheral else { return }
        stage = .failed("connect failed")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard c === central, p === peripheral else { return }
        linkNodeNum = 0
        linkGeneration += 1 // any in-flight upload bound to the old link aborts
        if stage != .idle { stage = .failed("disconnected") }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral else { return }
        guard let svc = p.services?.first(where: { $0.uuid == kService }) else { return }
        p.discoverCharacteristics([kToRadio, kFromRadio, kFromNum], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        guard p === peripheral else { return }
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
        guard p === peripheral else { return } // stale connection's callbacks never touch state
        if ch.uuid == kFromNum {
            if let fr = fromRadio { p.readValue(for: fr) }
            return
        }
        guard ch.uuid == kFromRadio else { return }
        if let v = ch.value, !v.isEmpty {
            // Identity gate (review R3 finding 1): a portnum-260 reply only proves the packet
            // REACHED targetNode — possibly relayed via LoRa through whatever node we're
            // actually connected to. The peripheral's own my_info is the identity proof, and
            // NOTHING proceeds (no GET, no ready, no persistence) until it matches.
            if linkNodeNum == 0, let me = parseMyNodeNum(v) {
                linkNodeNum = me
                if me != targetNode {
                    // Drop the saved mapping BEFORE disconnecting: a mapping that points at
                    // the wrong device would otherwise auto-reconnect on every retry, trapping
                    // configuration permanently (R4 finding 4 — likely for mappings saved by
                    // the pre-R3 identity bug). Next attempt scans fresh instead.
                    UserDefaults.standard.removeObject(forKey: rememberKey)
                    stage = .failed(String(format: "wrong node !%08x — expected !%08x (forgot the saved device; retry will rescan)", me, targetNode))
                    if let pp = peripheral { central?.cancelPeripheralConnection(pp) }
                    return
                }
                // Verified: THIS peripheral is the target node — now it's worth remembering.
                UserDefaults.standard.set(p.identifier.uuidString, forKey: rememberKey)
            }
            if linkNodeNum == targetNode, let reply = parseConfigReply(v), reply.from == targetNode || reply.from == 0 {
                settings = reply.settings
                if reply.op == 0x81 { lastStatus = reply.status }
                lastReplyOp = reply.op
                lastReplyStatus = reply.status
                replyCount += 1
                stage = .ready
            }
            if let ta = parseTrackAck(v) {
                trackAcks.append(ta) // sequenced queue — consumers scan by index (R4 f7)
            }
            if let fr = fromRadio { p.readValue(for: fr) } // keep draining
        } else if !handshakeDone {
            handshakeDone = true
            guard linkNodeNum == targetNode else { // drained without identity = wrong/broken node
                UserDefaults.standard.removeObject(forKey: rememberKey) // same trap-breaker as above
                stage = .failed("peripheral identity unverified — not the target tag")
                if let pp = peripheral { central?.cancelPeripheralConnection(pp) }
                return
            }
            sendGet() // identity verified + config drained — ask for the GNSS settings
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
