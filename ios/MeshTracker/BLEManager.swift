import Foundation
import CoreBluetooth
import Observation

// Standard Meshtastic BLE GATT service + characteristics.
private let kService = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
private let kToRadio = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")  // write
private let kFromRadio = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002") // read
private let kFromNum = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547e34453")   // notify

struct ConfigRequestToken: Equatable {
    let node: UInt32
    let linkGeneration: Int
    let replyFloor: Int
    let expectedOp: UInt8
}

/// Stream connection. Prefers the Base (sees every tag over LoRa); if no Base appears within a
/// few seconds it connects DIRECTLY to a tag's own BLE — the tag cc's its position stream to the
/// phone queue, so tracking works with no Base alive at all (that one tag only, ~BLE range).
@MainActor
@Observable
final class BLEManager: NSObject, @preconcurrency CBCentralManagerDelegate,
                        @preconcurrency CBPeripheralDelegate {
    var status = "Starting…"
    var nodeName = ""
    var directTag = false            // true = connected straight to a tag, not through Base
    var connectedNodeNum: UInt32 = 0 // who this link talks to (from my_info)
    private(set) var lastConfigReply: ConfigReply?
    private(set) var configReplySequence = 0
    private(set) var lastConfigReplySequence = 0
    private(set) var lastConfigReplyGeneration: Int?
    var trackAcks: [TrackAck] = []    // SEQUENCED 0x85 ACK queue (R4 finding 7: latest-only
                                      // could drop an ACK that landed between two 50 ms polls;
                                      // consumers scan from their own index, nothing is lost)
    var smallAcks: [SmallAck] = []    // SEQUENCED 7-byte SIGNAL/RADIO ACK queue (A4 guaranteed
                                      // delivery) — same append-only-within-a-link discipline
    var linkGeneration = 0            // bumps on every (re)connect — uploads bind to one generation

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var toRadio: CBCharacteristic?
    @ObservationIgnored private var fromRadio: CBCharacteristic?
    @ObservationIgnored private let model: PositionModel
    @ObservationIgnored private var candidates: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var candidateNames: [UUID: String] = [:]
    @ObservationIgnored private var candidateTypes: [UUID: DiscoveryAd.DeviceType] = [:] // A2 typed advert
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var activeAttemptGeneration: Int?
    @ObservationIgnored private var scanFallbackTask: Task<Void, Never>?

    init(model: PositionModel) {
        self.model = model
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func clearProtocolState() {
        directTag = false; connectedNodeNum = 0
        lastConfigReply = nil
        configReplySequence = 0
        lastConfigReplySequence = 0
        lastConfigReplyGeneration = nil
        trackAcks = []
        smallAcks = []
    }

    private func invalidateLink(cancelConnection: Bool) {
        scanFallbackTask?.cancel()
        scanFallbackTask = nil
        central.stopScan()
        if let p = peripheral {
            p.delegate = nil
            if cancelConnection, p.state != .disconnected {
                central.cancelPeripheralConnection(p)
            }
        }
        peripheral = nil
        toRadio = nil
        fromRadio = nil
        activeAttemptGeneration = nil
        linkGeneration &+= 1
        clearProtocolState()
    }

    private func startScan() {
        guard central.state == .poweredOn else {
            invalidateLink(cancelConnection: false)
            return
        }
        invalidateLink(cancelConnection: true)
        candidates = [:]; candidateNames = [:]; candidateTypes = [:]
        scanGeneration &+= 1
        let gen = scanGeneration
        status = "Scanning…"
        central.scanForPeripherals(withServices: [kService])
        // No Base after 6 s -> fall back to a tag's own BLE (tags advertise; the bridge doesn't).
        scanFallbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }
            guard let self, self.scanGeneration == gen else { return }
            self.fallbackToTag(ifStill: gen)
        }
    }

    private func fallbackToTag(ifStill gen: Int) {
        guard gen == scanGeneration, peripheral == nil else { return }
        // Typed tags (A2 advert) outrank every heuristic; then names that look like tags;
        // then any Meshtastic node that isn't a base.
        let pick = candidates.keys.sorted { a, b in
            let at = candidateTypes[a] != nil ? 0 : 1, bt = candidateTypes[b] != nil ? 0 : 1
            let an = (candidateNames[a] ?? "").lowercased(), bn = (candidateNames[b] ?? "").lowercased()
            return (at, an.contains("tag") ? 0 : 1, an) < (bt, bn.contains("tag") ? 0 : 1, bn)
        }.first
        if let id = pick, let p = candidates[id] {
            connect(p, name: candidateNames[id] ?? "tag", direct: true)
        } else {
            status = "No Base or tag found — still scanning…"
        }
    }

    private func isBase(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("base") || n.contains("9cda")
    }

    private func connect(_ p: CBPeripheral, name: String, direct: Bool) {
        scanFallbackTask?.cancel()
        scanFallbackTask = nil
        central.stopScan()
        if let old = peripheral {
            old.delegate = nil
            if old.state != .disconnected {
                central.cancelPeripheralConnection(old)
            }
        }
        clearProtocolState()
        linkGeneration &+= 1 // every connection attempt owns a distinct generation
        activeAttemptGeneration = linkGeneration
        peripheral = p
        p.delegate = self
        nodeName = name
        directTag = direct
        status = direct ? "Connecting to \(name) (direct)…" : "Connecting to \(name)…"
        central.connect(p)
    }

    private func owns(_ c: CBCentralManager, _ p: CBPeripheral) -> Bool {
        c === central && p === peripheral && activeAttemptGeneration == linkGeneration
    }

    private func owns(_ p: CBPeripheral) -> Bool {
        p === peripheral && activeAttemptGeneration == linkGeneration
    }

    // MARK: - CBCentralManagerDelegate

#if targetEnvironment(simulator)
    /// Simulator-only bench double: presents a plausible connected Base link so Tag Setup's
    /// full cockpit renders for UI work. Never compiled into device builds.
    @ObservationIgnored private var simulatorDemo = false
    func seedSimulatorDemo() {
        simulatorDemo = true
        connectedNodeNum = 0xB0BB_9CDA // the bench Base's node id — familiar in screenshots
        nodeName = "BASE-1"
        directTag = false
        status = "Simulator demo — synthetic Base link"
    }
#endif

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c === central else { return }
#if targetEnvironment(simulator)
        if simulatorDemo { return } // the (absent) sim Bluetooth must not wipe the demo bench
#endif
        switch c.state {
        case .poweredOn: startScan()
        case .poweredOff:
            invalidateLink(cancelConnection: false)
            status = "Bluetooth is off"
        case .unauthorized:
            invalidateLink(cancelConnection: false)
            status = "Bluetooth not authorized"
        default:
            invalidateLink(cancelConnection: false)
            status = "Bluetooth unavailable"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard c === central, peripheral == nil else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        // A2 typed discovery: the fleet's manufacturer-data advert states the device TYPE —
        // the authoritative signal. Name heuristics remain only as the pre-A2-firmware fallback.
        let ad = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
            .flatMap(DiscoveryAd.parse)
        if ad?.type == .base || (ad == nil && isBase(name)) {
            connect(p, name: name, direct: false) // Base always wins
            return
        }
        candidates[p.identifier] = p
        candidateNames[p.identifier] = name
        candidateTypes[p.identifier] = ad?.type
        status = "Looking for Base… (\(candidates.count) node\(candidates.count == 1 ? "" : "s") nearby)"
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        guard owns(c, p) else { return }
        status = "Discovering services…"
        p.discoverServices([kService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard owns(c, p) else { return }
        status = "Connect failed — rescanning…"
        startScan()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard owns(c, p) else { return }
        status = "Disconnected — rescanning…"
        startScan()
    }

    // MARK: - CBPeripheralDelegate

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
        status = directTag ? "Direct: \(nodeName) — no Base" : "Connected to \(nodeName)"
        if let tr = toRadio {
            p.writeValue(encodeWantConfig(UInt32.random(in: 1...UInt32.max)), for: tr, type: .withResponse)
        }
        if let fr = fromRadio { p.readValue(for: fr) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard owns(p) else { return }
        if ch.uuid == kFromNum {
            if let fr = fromRadio { p.readValue(for: fr) }
            return
        }
        if ch.uuid == kFromRadio {
            guard let v = ch.value, !v.isEmpty else { return } // empty read == queue drained
            if connectedNodeNum == 0, let me = parseMyNodeNum(v) {
                connectedNodeNum = me
                if directTag { // show WHO we actually latched onto, not just an advertised name
                    status = "Direct: \(nodeName) · !\(String(format: "%08x", me)) — no Base"
                }
            }
            if let sp = parseFromRadio(v) { model.ingest(sp) }
            if directTag, connectedNodeNum != 0, let cr = parseConfigReply(v),
               cr.from == connectedNodeNum {
                configReplySequence &+= 1
                lastConfigReply = cr
                lastConfigReplySequence = configReplySequence
                lastConfigReplyGeneration = linkGeneration
            }
            if let ta = parseTrackAck(v) {
                // Append-only within a link (cleared on every reconnect): consumers hold plain
                // indices into this array, so it must never be compacted mid-link. ~42 ACKs per
                // full upload — bounded in practice by the link session itself.
                trackAcks.append(ta)
            }
            if let sa = parseSmallAck(v) {
                smallAcks.append(sa) // sequenced like trackAcks; retry loops scan by index
            }
            if var pw = parseTelemetry(v) {                  // battery: Base every 15 s, tags via LoRa
                if pw.from == 0 { pw.from = connectedNodeNum }
                if pw.from != 0 { model.ingestPower(pw) }
            }
            if let ni = parseNodeInfo(v) {                   // A3: persisted owner names -> labels
                model.setName(ni.num, long: ni.longName, short: ni.shortName)
            }
            if let fr = fromRadio { p.readValue(for: fr) }    // keep draining
        }
    }

    // MARK: - Config transport over a direct tag link (avoids a second PhoneAPI client)

    /// Sends a settings GET/SET and returns the exact link + reply-sequence floor that its
    /// response must exceed. A cached or pre-request reply can therefore never satisfy it.
    @discardableResult
    func sendTagConfigRequest(_ payload: Data) -> ConfigRequestToken? {
        guard let op = payload.first, op <= 0x01, directTag,
              let p = peripheral, let tr = toRadio, connectedNodeNum != 0,
              activeAttemptGeneration == linkGeneration else { return nil }
        let token = ConfigRequestToken(node: connectedNodeNum, linkGeneration: linkGeneration,
                                       replyFloor: configReplySequence, expectedOp: 0x80 | op)
        let frame = encodeToRadioData(to: connectedNodeNum, portnum: kGnssConfigPortnum,
                                      payload: payload, packetId: UInt32.random(in: 1...UInt32.max))
        p.writeValue(frame, for: tr, type: .withResponse)
        if let fr = fromRadio { p.readValue(for: fr) }
        return token
    }

    func sendTagConfig(_ payload: Data) {
        guard directTag, let p = peripheral, let tr = toRadio, connectedNodeNum != 0,
              activeAttemptGeneration == linkGeneration else { return }
        let frame = encodeToRadioData(to: connectedNodeNum, portnum: kGnssConfigPortnum,
                                      payload: payload, packetId: UInt32.random(in: 1...UInt32.max))
        p.writeValue(frame, for: tr, type: .withResponse)
        if let fr = fromRadio { p.readValue(for: fr) }
    }

    /// Rename the CONNECTED node (persists on-device; NodeInfo re-broadcasts follow).
    /// LOCAL link only — phone-injected admin skips the session-passkey gate (see MeshProto).
    func renameConnectedNode(longName: String, shortName: String) {
        guard let p = peripheral, let tr = toRadio, connectedNodeNum != 0,
              activeAttemptGeneration == linkGeneration else { return }
        let frame = encodeAdminSetOwner(to: connectedNodeNum, longName: longName, shortName: shortName,
                                        packetId: UInt32.random(in: 1...UInt32.max))
        p.writeValue(frame, for: tr, type: .withResponse)
        if let fr = fromRadio { p.readValue(for: fr) }
        model.setName(connectedNodeNum, long: longName, short: shortName) // optimistic; NodeInfo confirms
    }

    /// GNSS command to any tag over WHATEVER link is up: through the Base it rides the LoRa
    /// downlink (priority HIGH + hop 1 — the Base firmware's fast lane); on a direct tag link
    /// it's local delivery. Fire-and-forget: confirmation is the tag's stream/flags echo.
    func sendGnssCommand(to node: UInt32, payload: Data) {
        guard let p = peripheral, let tr = toRadio, connectedNodeNum != 0,
              activeAttemptGeneration == linkGeneration else { return }
        let frame = encodeToRadioData(to: node, portnum: kGnssConfigPortnum, payload: payload,
                                      packetId: UInt32.random(in: 1...UInt32.max),
                                      hopLimit: 1, priority: 100)
        p.writeValue(frame, for: tr, type: .withResponse)
        if let fr = fromRadio { p.readValue(for: fr) }
    }
}
