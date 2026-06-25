import Foundation
import CoreBluetooth
import CoreLocation
import WatchKit
import HealthKit
import Observation

// Meshtastic BLE GATT: connect to Tag (peripheral) and write ToRadio (the watch is the central).
private let kService = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
private let kToRadio = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")

@Observable
final class WatchBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, CLLocationManagerDelegate {
    var status = "Idle"
    var bleConnected = false
    var running = false
    var sent = 0
    var lastFix: CLLocation?

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var tag: CBPeripheral?
    @ObservationIgnored private var toRadio: CBCharacteristic?
    @ObservationIgnored private let loc = CLLocationManager()
    @ObservationIgnored private var seq: UInt8 = 0
    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
        loc.delegate = self
        loc.desiredAccuracy = kCLLocationAccuracyBest
        loc.distanceFilter = kCLDistanceFilterNone
        loc.activityType = .fitness
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
    }

    func start() {
        running = true
        status = "Starting…"
        // A workout session is what keeps GPS + Bluetooth flowing on watchOS (foreground throttles
        // location hard, and BLE dies on wrist-down without it). Request HealthKit, then begin.
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        healthStore.requestAuthorization(toShare: share, read: []) { [weak self] _, _ in
            DispatchQueue.main.async { self?.beginSession() }
        }
    }

    private func beginSession() {
        let cfg = HKWorkoutConfiguration()
        cfg.activityType = .other
        cfg.locationType = .outdoor
        session = try? HKWorkoutSession(healthStore: healthStore, configuration: cfg)
        session?.startActivity(with: Date())
        loc.requestWhenInUseAuthorization()
        loc.startUpdatingLocation()
        if central.state == .poweredOn { scan() }
    }

    func stop() {
        running = false
        loc.stopUpdatingLocation()
        session?.end()
        session = nil
        if let t = tag { central.cancelPeripheralConnection(t) }
        status = "Stopped"
    }

    private func scan() {
        status = "Scanning for Tag…"
        central.scanForPeripherals(withServices: [kService])
    }

    // MARK: - Bluetooth (central → Tag)

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn, running { scan() }
        else if c.state != .poweredOn { status = "Bluetooth off" }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        tag = p
        p.delegate = self
        c.stopScan()
        status = "Connecting to Tag…"
        c.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        bleConnected = true
        status = "Discovering…"
        p.discoverServices([kService])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        bleConnected = false
        toRadio = nil
        if running { scan() } // watchOS has no state restoration — reconnect explicitly
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == kService }) else { return }
        p.discoverCharacteristics([kToRadio], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        toRadio = s.characteristics?.first { $0.uuid == kToRadio }
        status = toRadio != nil ? "Bridging" : "ToRadio characteristic missing"
    }

    // MARK: - Location → encode → write

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        lastFix = l
        guard let p = tag, let ch = toRadio else { return }
        let batt = Int(max(0, WKInterfaceDevice.current().batteryLevel) * 100)
        let payload = MeshEncode.payload(l, seq: seq, sats: 0, batteryPct: batt)
        seq = seq &+ 1
        p.writeValue(MeshEncode.toRadio(payload: payload), for: ch, type: .withResponse)
        sent += 1
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient (no fix yet, e.g. indoors) — Core Location keeps trying.
        if (error as NSError).code == CLError.locationUnknown.rawValue { return }
        status = "Location error: \(error.localizedDescription)"
    }
}
