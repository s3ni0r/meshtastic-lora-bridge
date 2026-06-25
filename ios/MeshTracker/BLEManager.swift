import Foundation
import CoreBluetooth
import Observation

// Standard Meshtastic BLE GATT service + characteristics.
private let kService = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
private let kToRadio = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")  // write
private let kFromRadio = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002") // read
private let kFromNum = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547e34453")   // notify

@Observable
final class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var status = "Starting…"
    var nodeName = ""

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var toRadio: CBCharacteristic?
    @ObservationIgnored private var fromRadio: CBCharacteristic?
    @ObservationIgnored private let model: PositionModel

    init(model: PositionModel) {
        self.model = model
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            status = "Scanning…"
            c.scanForPeripherals(withServices: [kService])
        case .poweredOff: status = "Bluetooth is off"
        case .unauthorized: status = "Bluetooth not authorized"
        default: status = "Bluetooth unavailable"
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        // Connect ONLY to Base (the receiver) — never Tag. Match its name or node-id suffix (!b0bb9cda).
        let n = name.lowercased()
        guard n.contains("base") || n.contains("9cda") else {
            status = "Looking for Base… (ignoring \(name.isEmpty ? "unnamed node" : name))"
            return
        }
        peripheral = p
        p.delegate = self
        nodeName = name
        status = "Connecting to \(name)…"
        c.stopScan()
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "Discovering services…"
        p.discoverServices([kService])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        status = "Connect failed — rescanning…"
        c.scanForPeripherals(withServices: [kService])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        status = "Disconnected — rescanning…"
        toRadio = nil; fromRadio = nil
        c.scanForPeripherals(withServices: [kService])
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
        status = "Connected to \(nodeName)"
        // Kick off the config session, then start draining FromRadio.
        if let tr = toRadio {
            p.writeValue(encodeWantConfig(UInt32.random(in: 1...UInt32.max)), for: tr, type: .withResponse)
        }
        if let fr = fromRadio { p.readValue(for: fr) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if ch.uuid == kFromNum {
            if let fr = fromRadio { p.readValue(for: fr) } // new data queued — start draining
            return
        }
        if ch.uuid == kFromRadio {
            guard let v = ch.value, !v.isEmpty else { return } // empty read == queue drained
            if let sp = parseFromRadio(v) { model.ingest(sp) }
            if let fr = fromRadio { p.readValue(for: fr) }    // keep draining
        }
    }
}
