import Foundation

// Minimal, dependency-free decoding of just the Meshtastic protobuf fields we need:
//   FromRadio.packet (2) -> MeshPacket{ from(1,fixed32), decoded(4), id(6,fixed32),
//                                       rx_snr(8,float), rx_rssi(12,varint) }
//   MeshPacket.decoded -> Data{ portnum(1,varint), payload(2,bytes) }
// Our firmware streams a fixed 12/17-byte payload on PRIVATE_APP (256):
//   <i lat*1e7 | <i lon*1e7 | <H ms_in_sec | <B seq | <B flags | [<h alt | <B spd | <B hdg | <B hacc]
// flags: bit0 = GPS lock, bits 5-7 = source type (which tag flavor sent this).

let kPrivateAppPortnum = 256

/// flags bits 5-7 — which tag flavor produced the fix (on top of `from`, the unique node id).
enum PacketSource: Int {
    case legacy = 0 // pre-fork firmware (no source bits)
    case bridge = 1 // BLE5/LoRa bridge relaying Dronetag Remote ID
    case gpsTag = 2 // self-contained tag streaming its onboard AG3335

    var label: String {
        switch self {
        case .legacy: return "Tag"
        case .bridge: return "Dronetag"
        case .gpsTag: return "GPS tag"
        }
    }
}

struct StreamPacket {
    var from: UInt32 = 0
    var id: UInt32 = 0
    var rxSnr: Float = 0
    var rxRssi: Int32 = 0
    var lat: Double = 0
    var lon: Double = 0
    var msInSec: UInt16 = 0
    var seq: UInt8 = 0
    var flags: UInt8 = 0
    // Extended telemetry (0 if a bare 12-byte position packet)
    var altitude: Int = 0   // metres (geo)
    var speedKmh: Int = 0
    var heading: Double = 0 // degrees
    var hacc: Int = 0       // horizontal accuracy, metres (0 = unknown)
    var battery: Int = -1   // v3 (18-byte payload): 0-100 %, 101 = externally powered, -1 = unknown

    var hasLock: Bool { flags & 0x01 != 0 }
    var source: PacketSource { PacketSource(rawValue: Int((flags >> 5) & 0x7)) ?? .legacy }
}

private struct ProtoReader {
    let data: [UInt8]
    var idx = 0
    init(_ d: Data) { data = [UInt8](d) }
    init(_ d: ArraySlice<UInt8>) { data = Array(d) }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while idx < data.count {
            let b = data[idx]; idx += 1
            result |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    mutating func readFixed32() -> UInt32? {
        guard idx + 4 <= data.count else { return nil }
        let v = UInt32(data[idx]) | (UInt32(data[idx + 1]) << 8)
              | (UInt32(data[idx + 2]) << 16) | (UInt32(data[idx + 3]) << 24)
        idx += 4
        return v
    }

    mutating func readBytes() -> ArraySlice<UInt8>? {
        guard let len = readVarint() else { return nil }
        let n = Int(len)
        guard idx + n <= data.count else { return nil }
        defer { idx += n }
        return data[idx ..< idx + n]
    }

    mutating func readTag() -> (field: Int, wire: Int)? {
        guard let t = readVarint() else { return nil }
        return (Int(t >> 3), Int(t & 0x7))
    }

    mutating func skip(_ wire: Int) {
        switch wire {
        case 0: _ = readVarint()
        case 1: idx += 8
        case 2: if let len = readVarint() { idx += Int(len) }
        case 5: idx += 4
        default: break
        }
    }
}

/// Parse a FromRadio frame; returns a StreamPacket only if it carried a PRIVATE_APP position.
func parseFromRadio(_ data: Data) -> StreamPacket? {
    var r = ProtoReader(data)
    while let (field, wire) = r.readTag() {
        if field == 2, wire == 2 {            // FromRadio.packet (MeshPacket)
            if let pkt = r.readBytes() { return parseMeshPacket(pkt) }
            return nil
        }
        r.skip(wire)
    }
    return nil
}

private func parseMeshPacket(_ bytes: ArraySlice<UInt8>) -> StreamPacket? {
    var r = ProtoReader(bytes)
    var sp = StreamPacket()
    var decoded: ArraySlice<UInt8>?
    while let (field, wire) = r.readTag() {
        switch (field, wire) {
        case (1, 5): sp.from = r.readFixed32() ?? 0
        case (6, 5): sp.id = r.readFixed32() ?? 0
        case (8, 5): if let b = r.readFixed32() { sp.rxSnr = Float(bitPattern: b) }
        case (12, 0): if let v = r.readVarint() { sp.rxRssi = Int32(bitPattern: UInt32(truncatingIfNeeded: v)) }
        case (4, 2): decoded = r.readBytes()
        default: r.skip(wire)
        }
    }
    guard let d = decoded, parseData(d, into: &sp) else { return nil }
    return sp
}

private func parseData(_ bytes: ArraySlice<UInt8>, into sp: inout StreamPacket) -> Bool {
    var r = ProtoReader(bytes)
    var portnum = 0
    var payload: ArraySlice<UInt8>?
    while let (field, wire) = r.readTag() {
        switch (field, wire) {
        case (1, 0): portnum = Int(r.readVarint() ?? 0)
        case (2, 2): payload = r.readBytes()
        default: r.skip(wire)
        }
    }
    guard portnum == kPrivateAppPortnum, let pl = payload, pl.count >= 12 else { return false }
    let p = Array(pl)
    func i32(_ o: Int) -> Int32 {
        Int32(bitPattern: UInt32(p[o]) | (UInt32(p[o + 1]) << 8) | (UInt32(p[o + 2]) << 16) | (UInt32(p[o + 3]) << 24))
    }
    sp.lat = Double(i32(0)) / 1e7
    sp.lon = Double(i32(4)) / 1e7
    sp.msInSec = UInt16(p[8]) | (UInt16(p[9]) << 8)
    sp.seq = p[10]
    sp.flags = p[11]
    if p.count >= 17 { // extended telemetry: alt(i16) speed(u8) heading(u8) hacc(u8)
        sp.altitude = Int(Int16(bitPattern: UInt16(p[12]) | (UInt16(p[13]) << 8)))
        sp.speedKmh = Int(p[14])
        sp.heading = Double(p[15]) * 360.0 / 256.0
        sp.hacc = Int(p[16])
    }
    if p.count >= 18, p[17] != 255 { // v3: live battery (101 = externally powered)
        sp.battery = Int(p[17])
    }
    return true
}

// MARK: - Device telemetry (portnum 67 — battery/voltage for every T1000-E role)

let kTelemetryPortnum = 67

/// Battery snapshot decoded from a stock Meshtastic DeviceMetrics telemetry packet. Every role
/// emits these unmodified-firmware-style: the BLE-connected node (Base, or a tag when direct)
/// pushes its own every 60 s, and tags broadcast theirs over LoRa on the telemetry module's mesh
/// interval (default 30 min) — the Base relays those to the phone like any mesh packet.
struct PowerReading {
    var from: UInt32 = 0
    var level: Int = -1     // 0-100; the firmware sends 101 when externally powered (USB)
    var voltage: Float = 0  // volts; 0 = not reported
}

/// Parse a FromRadio frame as device telemetry — nil unless it carries DeviceMetrics with a
/// battery level (the LocalStats / environment telemetry variants are ignored).
func parseTelemetry(_ data: Data) -> PowerReading? {
    var r = ProtoReader(data)
    while let (field, wire) = r.readTag() {
        if field == 2, wire == 2 {                    // FromRadio.packet (MeshPacket)
            guard let pkt = r.readBytes() else { return nil }
            var pr = ProtoReader(pkt)
            var out = PowerReading()
            var decoded: ArraySlice<UInt8>?
            while let (f, w) = pr.readTag() {
                switch (f, w) {
                case (1, 5): out.from = pr.readFixed32() ?? 0
                case (4, 2): decoded = pr.readBytes()
                default: pr.skip(w)
                }
            }
            guard let dec = decoded else { return nil }
            var dr = ProtoReader(dec)
            var portnum = 0
            var payload: ArraySlice<UInt8>?
            while let (df, dw) = dr.readTag() {
                switch (df, dw) {
                case (1, 0): portnum = Int(dr.readVarint() ?? 0)
                case (2, 2): payload = dr.readBytes()
                default: dr.skip(dw)
                }
            }
            guard portnum == kTelemetryPortnum, let pl = payload else { return nil }
            var tr = ProtoReader(pl)
            var metrics: ArraySlice<UInt8>?
            while let (tf, tw) = tr.readTag() {
                if tf == 2, tw == 2 { metrics = tr.readBytes() } // Telemetry.device_metrics
                else { tr.skip(tw) }
            }
            guard let dm = metrics else { return nil }
            var mr = ProtoReader(dm)
            while let (mf, mw) = mr.readTag() {
                switch (mf, mw) {
                case (1, 0): out.level = Int(mr.readVarint() ?? 0) // DeviceMetrics.battery_level
                case (2, 5): if let b = mr.readFixed32() { out.voltage = Float(bitPattern: b) }
                default: mr.skip(mw)
                }
            }
            return out.level >= 0 ? out : nil
        }
        r.skip(wire)
    }
    return nil
}

// MARK: - GNSS tag configuration channel (portnum 260 — see firmware GnssConfigModule)

let kGnssConfigPortnum = 260

struct TagSettings: Equatable {
    var navMode: UInt8 = 1        // $PAIR080: 0 normal / 1 fitness / 4 stationary / 5 drone / 7 swim / 9 bike
    var staticThrDms: UInt8 = 3   // $PAIR070: 0-20 dm/s
    var minSnr: UInt8 = 14        // $PAIR058: 9-37 dB
    var fixIntervalMs: UInt16 = 250
    var txSpacingMs: UInt16 = 150
    var elevMaskDeg: UInt8 = 10   // $PAIR072: 0-45 deg — satellites below are excluded

    var wire: Data {
        Data([navMode, staticThrDms, minSnr,
              UInt8(fixIntervalMs & 0xFF), UInt8(fixIntervalMs >> 8),
              UInt8(txSpacingMs & 0xFF), UInt8(txSpacingMs >> 8),
              elevMaskDeg])
    }
    static func fromWire(_ b: [UInt8]) -> TagSettings? {
        guard b.count >= 7 else { return nil }
        return TagSettings(navMode: b[0], staticThrDms: b[1], minSnr: b[2],
                           fixIntervalMs: UInt16(b[3]) | (UInt16(b[4]) << 8),
                           txSpacingMs: UInt16(b[5]) | (UInt16(b[6]) << 8),
                           elevMaskDeg: b.count >= 8 ? b[7] : 10)
    }
}

struct ConfigReply {
    let op: UInt8      // 0x80 = GET reply, 0x81 = SET reply
    let status: UInt8  // 0 ok / 1 rejected / 2 malformed
    let settings: TagSettings
}

private func pvarint(_ v: UInt64) -> Data {
    var out = Data(); var x = v
    repeat { var b = UInt8(x & 0x7f); x >>= 7; if x != 0 { b |= 0x80 }; out.append(b) } while x != 0
    return out
}
private func ptag(_ field: Int, _ wire: Int) -> Data { pvarint(UInt64((field << 3) | wire)) }

/// Encode ToRadio{ packet: MeshPacket{ to, id, decoded: Data{ portnum, payload } } }.
func encodeToRadioData(to: UInt32, portnum: Int, payload: Data, packetId: UInt32) -> Data {
    var d = Data()
    d += ptag(1, 0) + pvarint(UInt64(portnum))                 // Data.portnum
    d += ptag(2, 2) + pvarint(UInt64(payload.count)) + payload // Data.payload
    var pkt = Data()
    pkt += ptag(2, 5) + withUnsafeBytes(of: to.littleEndian) { Data($0) }       // MeshPacket.to
    pkt += ptag(6, 5) + withUnsafeBytes(of: packetId.littleEndian) { Data($0) } // MeshPacket.id
    pkt += ptag(4, 2) + pvarint(UInt64(d.count)) + d                            // MeshPacket.decoded
    var out = Data()
    out += ptag(1, 2) + pvarint(UInt64(pkt.count)) + pkt                        // ToRadio.packet
    return out
}

/// Parse a FromRadio frame as a GNSS config reply (portnum 260, 9-byte payload) — nil otherwise.
func parseConfigReply(_ data: Data) -> ConfigReply? {
    var r = ProtoReader(data)
    while let (field, wire) = r.readTag() {
        if field == 2, wire == 2 {
            guard let pkt = r.readBytes() else { return nil }
            var pr = ProtoReader(pkt)
            while let (f, w) = pr.readTag() {
                if f == 4, w == 2 {
                    guard let dec = pr.readBytes() else { return nil }
                    var dr = ProtoReader(dec)
                    var portnum = 0
                    var payload: ArraySlice<UInt8>?
                    while let (df, dw) = dr.readTag() {
                        switch (df, dw) {
                        case (1, 0): portnum = Int(dr.readVarint() ?? 0)
                        case (2, 2): payload = dr.readBytes()
                        default: dr.skip(dw)
                        }
                    }
                    guard portnum == kGnssConfigPortnum, let pl = payload, pl.count >= 9 else { return nil }
                    let b = Array(pl)
                    guard b[0] & 0x80 != 0, let st = TagSettings.fromWire(Array(b[2...])) else { return nil }
                    return ConfigReply(op: b[0], status: b[1], settings: st)
                }
                pr.skip(w)
            }
            return nil
        }
        r.skip(wire)
    }
    return nil
}

/// Parse FromRadio.my_info.my_node_num — tells us WHICH node this BLE link talks to.
func parseMyNodeNum(_ data: Data) -> UInt32? {
    var r = ProtoReader(data)
    while let (field, wire) = r.readTag() {
        if field == 3, wire == 2 { // FromRadio.my_info (MyNodeInfo)
            guard let mi = r.readBytes() else { return nil }
            var m = ProtoReader(mi)
            while let (mf, mw) = m.readTag() {
                if mf == 1, mw == 0 { // MyNodeInfo.my_node_num
                    return m.readVarint().map { UInt32(truncatingIfNeeded: $0) }
                }
                m.skip(mw)
            }
            return nil
        }
        r.skip(wire)
    }
    return nil
}

/// Encode ToRadio{ want_config_id = id } (field 3, varint) to kick off the BLE config session.
func encodeWantConfig(_ id: UInt32) -> Data {
    var out: [UInt8] = [UInt8((3 << 3) | 0)]
    var v = UInt64(id)
    repeat {
        var b = UInt8(v & 0x7f)
        v >>= 7
        if v != 0 { b |= 0x80 }
        out.append(b)
    } while v != 0
    return Data(out)
}
