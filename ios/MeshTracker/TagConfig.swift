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
@MainActor
@Observable
final class TagConfigManager: NSObject, @preconcurrency CBCentralManagerDelegate,
                               @preconcurrency CBPeripheralDelegate {
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
    var smallAcks: [SmallAck] = []  // SEQUENCED 7-byte SIGNAL/RADIO ACK queue — the direct
                                    // config link is the close-range command path (A4)
    var linkGeneration = 0          // bumps on every (re)connect/stop — uploads bind to one generation
    var onNodeInfo: ((UInt32, String, String) -> Void)? // A3: names heard on this link
    var linkNodeNum: UInt32 = 0     // my_node_num of the CONNECTED peripheral (identity proof)

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var toRadio: CBCharacteristic?
    @ObservationIgnored private var fromRadio: CBCharacteristic?
    @ObservationIgnored private var targetNode: UInt32 = 0
    @ObservationIgnored private var handshakeDone = false
    @ObservationIgnored private var activeAttemptGeneration: Int?
    @ObservationIgnored private var connectionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var configReplySequence = 0
    @ObservationIgnored private var configRequestFloor: Int?
    @ObservationIgnored private var configRequestGeneration: Int?
    @ObservationIgnored private var configRequestExpectedOp: UInt8?

    private var rememberKey: String { "tagPeriph.\(targetNode)" }

    func begin(targetNode: UInt32) {
        invalidateSession()
        self.targetNode = targetNode
        stage = .scanning
        discovered = []
        settings = nil
        lastStatus = nil
        replyCount = 0
        lastReplyOp = 0
        lastReplyStatus = 0
        trackAcks = []
        smallAcks = []
        handshakeDone = false
        linkNodeNum = 0
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        invalidateSession()
        stage = .idle
    }

    private func invalidateSession() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        central?.stopScan()
        if let p = peripheral {
            p.delegate = nil
            if p.state != .disconnected {
                central?.cancelPeripheralConnection(p)
            }
        }
        central?.delegate = nil
        central = nil
        peripheral = nil
        toRadio = nil
        fromRadio = nil
        activeAttemptGeneration = nil
        configReplySequence = 0
        configRequestFloor = nil
        configRequestGeneration = nil
        configRequestExpectedOp = nil
        linkNodeNum = 0
        linkGeneration &+= 1
    }

    private func owns(_ c: CBCentralManager, _ p: CBPeripheral) -> Bool {
        c === central && p === peripheral && activeAttemptGeneration == linkGeneration
    }

    private func owns(_ p: CBPeripheral) -> Bool {
        p === peripheral && activeAttemptGeneration == linkGeneration
    }

    private func armConnectionTimeout(for id: UUID, generation: Int, after delay: Duration) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, self.linkGeneration == generation,
                  self.activeAttemptGeneration == generation,
                  self.peripheral?.identifier == id, self.linkNodeNum == 0 else { return }
            self.recoverFromUnverifiedConnection()
        }
    }

    /// A remembered peripheral that is gone can otherwise leave Core Bluetooth connecting
    /// indefinitely. Forget it, invalidate this attempt, and resume discovery on the same central.
    private func recoverFromUnverifiedConnection() {
        UserDefaults.standard.removeObject(forKey: rememberKey)
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        if let p = peripheral {
            p.delegate = nil
            if p.state != .disconnected {
                central?.cancelPeripheralConnection(p)
            }
        }
        peripheral = nil
        toRadio = nil
        fromRadio = nil
        activeAttemptGeneration = nil
        configReplySequence = 0
        configRequestFloor = nil
        configRequestGeneration = nil
        configRequestExpectedOp = nil
        linkNodeNum = 0
        handshakeDone = false
        trackAcks = []
        smallAcks = []
        linkGeneration &+= 1
        guard let c = central, c.state == .poweredOn else {
            stage = .failed("Bluetooth unavailable")
            return
        }
        stage = .scanning
        c.scanForPeripherals(withServices: [kService])
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c === central else { return } // stale central from a previous begin() — ignore
        guard c.state == .poweredOn else {
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            if let p = peripheral { p.delegate = nil }
            peripheral = nil
            toRadio = nil
            fromRadio = nil
            activeAttemptGeneration = nil
            configReplySequence = 0
            configRequestFloor = nil
            configRequestGeneration = nil
            configRequestExpectedOp = nil
            handshakeDone = false
            linkNodeNum = 0
            trackAcks = []
            smallAcks = []
            settings = nil
            lastStatus = nil
            linkGeneration &+= 1
            if c.state != .unknown { stage = .failed("Bluetooth unavailable") }
            return
        }
        stage = .scanning
        c.scanForPeripherals(withServices: [kService])
        // Auto-reconnect to the peripheral used for this tag before. The mapping is written
        // only after a verified identity match and DELETED on mismatch (R4 finding 4), so a
        // stale mapping cannot trap us in a connect-fail-retry loop with the wrong device.
        if let saved = UserDefaults.standard.string(forKey: rememberKey), let id = UUID(uuidString: saved),
           let p = c.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p, remembered: true)
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard c === central, peripheral == nil else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? "?"
        if !discovered.contains(where: { $0.id == p.identifier }) {
            discovered.append((p.identifier, name))
        }
    }

    func connect(_ id: UUID) {
        guard let c = central, let p = c.retrievePeripherals(withIdentifiers: [id]).first else { return }
        connect(p, remembered: false)
    }

    private func connect(_ p: CBPeripheral, remembered: Bool) {
        connectionTimeoutTask?.cancel()
        if let old = peripheral {
            old.delegate = nil
            if old.state != .disconnected {
                central?.cancelPeripheralConnection(old)
            }
        }
        central?.stopScan()
        toRadio = nil
        fromRadio = nil
        linkNodeNum = 0
        handshakeDone = false
        configReplySequence = 0
        configRequestFloor = nil
        configRequestGeneration = nil
        configRequestExpectedOp = nil
        trackAcks = []
        smallAcks = []
        linkGeneration &+= 1
        activeAttemptGeneration = linkGeneration
        peripheral = p
        p.delegate = self
        deviceName = p.name ?? "tag"
        stage = .connecting
        central?.connect(p)
        // Remembered UUIDs are the trap this timeout primarily prevents. Applying it to manual
        // choices too gives every unverified attempt the same finite, recoverable lifecycle.
        armConnectionTimeout(for: p.identifier, generation: linkGeneration,
                             after: .seconds(remembered ? 12 : 20))
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard owns(c, p) else { return }
        // NOTE: deliberately NOT remembered yet — only the peripheral's own my_info proves
        // this is the target node (see didUpdateValueFor).
        stage = .handshaking
        p.discoverServices([kService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard owns(c, p) else { return }
        recoverFromUnverifiedConnection()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard owns(c, p) else { return }
        if linkNodeNum == 0 {
            recoverFromUnverifiedConnection()
            return
        }
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        p.delegate = nil
        peripheral = nil
        toRadio = nil
        fromRadio = nil
        activeAttemptGeneration = nil
        linkNodeNum = 0
        linkGeneration &+= 1 // any in-flight upload bound to the old link aborts
        if stage != .idle { stage = .failed("disconnected") }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard owns(p) else { return }
        guard let svc = p.services?.first(where: { $0.uuid == kService }) else { return }
        p.discoverCharacteristics([kToRadio, kFromRadio, kFromNum], for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        guard owns(p) else { return }
        for ch in svc.characteristics ?? [] {
            switch ch.uuid {
            case kToRadio: toRadio = ch
            case kFromRadio: fromRadio = ch
            case kFromNum: p.setNotifyValue(true, for: ch)
            default: break
            }
        }
        guard let tr = toRadio else {
            recoverFromUnverifiedConnection()
            return
        }
        // Handshake: want_config, then drain FromRadio until an empty read.
        p.writeValue(encodeWantConfig(UInt32.random(in: 1...UInt32.max)), for: tr, type: .withResponse)
        if let fr = fromRadio { p.readValue(for: fr) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard owns(p) else { return } // stale connection's callbacks never touch state
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
                    recoverFromUnverifiedConnection()
                    return
                }
                // Verified: THIS peripheral is the target node — now it's worth remembering.
                connectionTimeoutTask?.cancel()
                connectionTimeoutTask = nil
                UserDefaults.standard.set(p.identifier.uuidString, forKey: rememberKey)
            }
            if linkNodeNum == targetNode, let reply = parseConfigReply(v), reply.from == targetNode {
                configReplySequence &+= 1
                if configRequestGeneration == linkGeneration, let floor = configRequestFloor,
                   configReplySequence > floor, reply.op == configRequestExpectedOp {
                    settings = reply.settings
                    if reply.op == 0x81 { lastStatus = reply.status }
                    lastReplyOp = reply.op
                    lastReplyStatus = reply.status
                    replyCount &+= 1
                    stage = .ready
                }
            }
            if let ta = parseTrackAck(v) {
                trackAcks.append(ta) // sequenced queue — consumers scan by index (R4 f7)
            }
            if let sa = parseSmallAck(v) {
                smallAcks.append(sa) // same discipline for SIGNAL/RADIO ACKs
            }
            if let ni = parseNodeInfo(v) { // A3: names flow on this link too
                onNodeInfo?(ni.num, ni.longName, ni.shortName)
            }
            if let fr = fromRadio { p.readValue(for: fr) } // keep draining
        } else if !handshakeDone {
            handshakeDone = true
            guard linkNodeNum == targetNode else { // drained without identity = wrong/broken node
                recoverFromUnverifiedConnection()
                return
            }
            sendGet() // identity verified + config drained — ask for the GNSS settings
        }
    }

    private func send(_ payload: Data) {
        guard let p = peripheral, let tr = toRadio,
              activeAttemptGeneration == linkGeneration else { return }
        let frame = encodeToRadioData(to: targetNode, portnum: kGnssConfigPortnum, payload: payload,
                                      packetId: UInt32.random(in: 1...UInt32.max))
        p.writeValue(frame, for: tr, type: .withResponse)
        if let fr = fromRadio { p.readValue(for: fr) }
    }

    private func sendConfigRequest(_ payload: Data) {
        guard let op = payload.first, op <= 0x01 else { return }
        configRequestFloor = configReplySequence
        configRequestGeneration = linkGeneration
        configRequestExpectedOp = 0x80 | op
        send(payload)
    }

    func sendGet() { sendConfigRequest(Data([0x00])) }

    /// Raw portnum-260 frame over this direct link (track uploads etc. — DOWNLINK.md op 0x05).
    func sendRaw(_ payload: Data) { send(payload) }

    /// Rename THIS link's tag (persists on-device). Local-link admin only — see MeshProto.
    func renameNode(longName: String, shortName: String) {
        guard let p = peripheral, let tr = toRadio, linkNodeNum == targetNode,
              activeAttemptGeneration == linkGeneration else { return }
        let frame = encodeAdminSetOwner(to: targetNode, longName: longName, shortName: shortName,
                                        packetId: UInt32.random(in: 1...UInt32.max))
        p.writeValue(frame, for: tr, type: .withResponse)
        if let fr = fromRadio { p.readValue(for: fr) }
        onNodeInfo?(targetNode, longName, shortName) // optimistic; the NodeInfo broadcast confirms
    }

    func apply(_ s: TagSettings) {
        stage = .applying
        lastStatus = nil
        sendConfigRequest(Data([0x01]) + s.wire)
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
