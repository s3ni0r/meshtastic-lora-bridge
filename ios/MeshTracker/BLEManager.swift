import Foundation
import CoreBluetooth
import Observation

// Standard Meshtastic BLE GATT service + characteristics.
private let kService = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
private let kToRadio = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")  // write
private let kFromRadio = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002") // read
private let kFromNum = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547e34453")   // notify

/// Stream connection. Prefers the Base (sees every tag over LoRa); if no Base appears within a
/// few seconds it connects DIRECTLY to a tag's own BLE — the tag cc's its position stream to the
/// phone queue, so tracking works with no Base alive at all (that one tag only, ~BLE range).
@Observable
final class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var status = "Starting…"
    var nodeName = ""
    var directTag = false            // true = connected straight to a tag, not through Base
    var connectedNodeNum: UInt32 = 0 // who this link talks to (from my_info)
    var lastConfigReply: ConfigReply? // portnum-260 replies when the tag link doubles as config

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var toRadio: CBCharacteristic?
    @ObservationIgnored private var fromRadio: CBCharacteristic?
    @ObservationIgnored private let model: PositionModel
    @ObservationIgnored private var candidates: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var candidateNames: [UUID: String] = [:]
    @ObservationIgnored private var scanGeneration = 0

    init(model: PositionModel) {
        self.model = model
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func startScan() {
        guard central.state == .poweredOn else { return }
        peripheral = nil; toRadio = nil; fromRadio = nil
        directTag = false; connectedNodeNum = 0
        candidates = [:]; candidateNames = [:]
        scanGeneration += 1
        let gen = scanGeneration
        status = "Scanning…"
        central.scanForPeripherals(withServices: [kService])
        // No Base after 6 s -> fall back to a tag's own BLE (tags advertise; the bridge doesn't).
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.fallbackToTag(ifStill: gen)
        }
    }

    private func fallbackToTag(ifStill gen: Int) {
        guard gen == scanGeneration, peripheral == nil else { return }
        // Prefer names that look like our tags; otherwise any Meshtastic node that isn't a base.
        let pick = candidates.keys.sorted { a, b in
            let an = (candidateNames[a] ?? "").lowercased(), bn = (candidateNames[b] ?? "").lowercased()
            return (an.contains("tag") ? 0 : 1, an) < (bn.contains("tag") ? 0 : 1, bn)
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
        peripheral = p
        p.delegate = self
        nodeName = name
        directTag = direct
        status = direct ? "Connecting to \(name) (direct)…" : "Connecting to \(name)…"
        central.stopScan()
        central.connect(p)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: startScan()
        case .poweredOff: status = "Bluetooth is off"
        case .unauthorized: status = "Bluetooth not authorized"
        default: status = "Bluetooth unavailable"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        if isBase(name) {
            connect(p, name: name, direct: false) // Base always wins
            return
        }
        candidates[p.identifier] = p
        candidateNames[p.identifier] = name
        status = "Looking for Base… (\(candidates.count) node\(candidates.count == 1 ? "" : "s") nearby)"
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Discovering services…"
        p.discoverServices([kService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        status = "Connect failed — rescanning…"
        startScan()
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        status = "Disconnected — rescanning…"
        startScan()
    }

    // MARK: - CBPeripheralDelegate

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
        status = directTag ? "Direct: \(nodeName) — no Base" : "Connected to \(nodeName)"
        if let tr = toRadio {
            p.writeValue(encodeWantConfig(UInt32.random(in: 1...UInt32.max)), for: tr, type: .withResponse)
        }
        if let fr = fromRadio { p.readValue(for: fr) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == kFromNum {
            if let fr = fromRadio { p.readValue(for: fr) }
            return
        }
        if ch.uuid == kFromRadio {
            guard let v = ch.value, !v.isEmpty else { return } // empty read == queue drained
            if connectedNodeNum == 0, let me = parseMyNodeNum(v) { connectedNodeNum = me }
            if let sp = parseFromRadio(v) { model.ingest(sp) }
            if let cr = parseConfigReply(v) { lastConfigReply = cr }
            if var pw = parseTelemetry(v) {                  // battery: Base every 15 s, tags via LoRa
                if pw.from == 0 { pw.from = connectedNodeNum }
                if pw.from != 0 { model.ingestPower(pw) }
            }
            if let fr = fromRadio { p.readValue(for: fr) }    // keep draining
        }
    }

    // MARK: - Config transport over a direct tag link (avoids a second PhoneAPI client)

    func sendTagConfig(_ payload: Data) {
        guard directTag, let p = peripheral, let tr = toRadio, connectedNodeNum != 0 else { return }
        let frame = encodeToRadioData(to: connectedNodeNum, portnum: kGnssConfigPortnum,
                                      payload: payload, packetId: UInt32.random(in: 1...UInt32.max))
        p.writeValue(frame, for: tr, type: .withResponse)
        if let fr = fromRadio { p.readValue(for: fr) }
    }
}
