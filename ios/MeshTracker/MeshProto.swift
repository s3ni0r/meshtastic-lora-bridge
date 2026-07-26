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
    var motionMg: Int = -1  // v4 (19-byte): high-passed |accel| envelope in mg, -1 = unknown
    var radioStatus: Int = -1 // v5 (20-byte): radio-state status byte, -1 = pre-v5 firmware

    var hasLock: Bool { flags & 0x01 != 0 }
    /// v4: the QMA6100P classifier's verdict (provisional land thresholds; see GnssMotion.cpp).
    var moving: Bool { flags & 0x02 != 0 }
    /// Downlink mode echo (tag-downlink firmware): bit2 = ADAPTIVE TX mode, bit3 = slow tier.
    var adaptive: Bool { flags & 0x04 != 0 }
    var slowTier: Bool { flags & 0x08 != 0 }
    /// bit4: this fix is SYNTHETIC (GnssSim indoor simulator) — never mistake it for a real track.
    var simulated: Bool { flags & 0x10 != 0 }
    var source: PacketSource { PacketSource(rawValue: Int((flags >> 5) & 0x7)) ?? .legacy }
    /// v5 status byte (A4 radio states). isDeaf doubles as the GO-DEAF fallback confirmation:
    /// a deaf tag still streams, so this bit proves the transition even if every ACK was lost.
    var isDeaf: Bool { radioStatus >= 0 && radioStatus & 0x01 != 0 }
    var isPermanent: Bool { radioStatus >= 0 && radioStatus & 0x02 != 0 }
    var dutyDegraded: Bool { radioStatus >= 0 && radioStatus & 0x04 != 0 }
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
    if p.count >= 19, p[18] != 255 { // v4: motion energy, wire unit = mg/4
        sp.motionMg = Int(p[18]) * 4
    }
    if p.count >= 20 { // v5: radio-state status byte (bit0 DEAF, bit1 PERMANENT, bit2 degraded)
        sp.radioStatus = Int(p[19])
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
    // v3 — adaptive-mode knobs (tag-downlink firmware)
    var idleSpacingMs: UInt16 = 3000 // slow-tier TX spacing while quasi-stationary
    var adaptFastKmh: UInt8 = 5      // >= this speed -> full rate immediately
    var adaptSlowKmh: UInt8 = 3      // < this speed sustained -> slow tier
    var adaptSustainS: UInt8 = 15
    var isV3 = false                 // the tag's reply carried v3 fields (13-byte settings)
    // v4 — A4 radio states/profiles (docs/RADIO_STATES.md); reply = 18 bytes
    var profileBits: UInt8 = 0       // bit0 PERMANENT (0 = HYBRID), bit1 permanent-DEAF
    var isV4 = false
    var capability: UInt8 = 0        // knob-group bits (read-only, reply byte 16)
    var radioStatus: UInt8 = 0       // radio-status byte (read-only, reply byte 17)
    var dutyFloorMs: UInt16 = 0      // tag-computed legal min spacing (read-only, bytes 18-19;
                                     // 0 = no duty limit). NEVER re-derive from preset guesses.

    /// Wire sized to the tag's capability: 8 bytes for v2 firmware, 13 for v3, 14 for v4 —
    /// an older tag must never receive bytes it would misparse.
    var wire: Data {
        var d = Data([navMode, staticThrDms, minSnr,
                      UInt8(fixIntervalMs & 0xFF), UInt8(fixIntervalMs >> 8),
                      UInt8(txSpacingMs & 0xFF), UInt8(txSpacingMs >> 8),
                      elevMaskDeg])
        if isV3 || isV4 {
            d += Data([UInt8(idleSpacingMs & 0xFF), UInt8(idleSpacingMs >> 8),
                       adaptFastKmh, adaptSlowKmh, adaptSustainS])
        }
        if isV4 {
            d += Data([profileBits])
        }
        return d
    }
    static func fromWire(_ b: [UInt8]) -> TagSettings? {
        guard b.count >= 7 else { return nil }
        var s = TagSettings(navMode: b[0], staticThrDms: b[1], minSnr: b[2],
                            fixIntervalMs: UInt16(b[3]) | (UInt16(b[4]) << 8),
                            txSpacingMs: UInt16(b[5]) | (UInt16(b[6]) << 8),
                            elevMaskDeg: b.count >= 8 ? b[7] : 10)
        if b.count >= 13 { // reply length IS the capability signal (v3+)
            s.idleSpacingMs = UInt16(b[8]) | (UInt16(b[9]) << 8)
            s.adaptFastKmh = b[10]
            s.adaptSlowKmh = b[11]
            s.adaptSustainS = b[12]
            s.isV3 = true
        }
        if b.count >= 16 { // v4: profile + explicit capability byte + radio-status byte
            s.profileBits = b[13]
            s.capability = b[14]
            s.radioStatus = b[15]
            s.isV4 = true
        }
        if b.count >= 18 { // v4 replies also carry the tag's own duty floor (ms, 0 = none)
            s.dutyFloorMs = UInt16(b[16]) | (UInt16(b[17]) << 8)
        }
        return s
    }

    // v4 knob-group capability bits (firmware GnssConfigModule.h). Pre-v4 firmware carried no
    // capability byte and only ever shipped on the GPS tag — assume its full set there.
    static let capGnssBit: UInt8 = 0x01, capModesBit: UInt8 = 0x02, capSimTrackBit: UInt8 = 0x04
    static let capSignalsBit: UInt8 = 0x08, capRadioBit: UInt8 = 0x10, capProfilesBit: UInt8 = 0x20
    private var caps: UInt8 { isV4 ? capability : 0x3F }
    var capGnss: Bool { caps & Self.capGnssBit != 0 }
    var capModes: Bool { caps & Self.capModesBit != 0 }
    var capSimTrack: Bool { caps & Self.capSimTrackBit != 0 }
    var capSignals: Bool { caps & Self.capSignalsBit != 0 }
    var capRadio: Bool { isV4 && capability & Self.capRadioBit != 0 } // RADIO op is v4-only
    var capProfiles: Bool { isV4 && capability & Self.capProfilesBit != 0 }
    // Profile helpers (settings byte 13)
    var isPermanentProfile: Bool { profileBits & 0x01 != 0 }
    var isPermanentDeaf: Bool { profileBits & 0x03 == 0x03 }
}

struct ConfigReply {
    let from: UInt32   // MeshPacket.from — WHICH node these settings belong to (R4 finding 3:
                       // a cached reply from tag A must never be shown or applied as tag B's)
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
/// hopLimit/priority 0 = omit (device defaults). Downlink commands relayed by the Base use
/// hopLimit 1 + priority 100 (HIGH) — the Base firmware's fast lane keys on priority >= HIGH.
func encodeToRadioData(to: UInt32, portnum: Int, payload: Data, packetId: UInt32,
                       hopLimit: Int = 0, priority: Int = 0) -> Data {
    var d = Data()
    d += ptag(1, 0) + pvarint(UInt64(portnum))                 // Data.portnum
    d += ptag(2, 2) + pvarint(UInt64(payload.count)) + payload // Data.payload
    var pkt = Data()
    pkt += ptag(2, 5) + withUnsafeBytes(of: to.littleEndian) { Data($0) }       // MeshPacket.to
    pkt += ptag(6, 5) + withUnsafeBytes(of: packetId.littleEndian) { Data($0) } // MeshPacket.id
    pkt += ptag(4, 2) + pvarint(UInt64(d.count)) + d                            // MeshPacket.decoded
    if hopLimit > 0 { pkt += ptag(9, 0) + pvarint(UInt64(hopLimit)) }           // MeshPacket.hop_limit
    if priority > 0 { pkt += ptag(11, 0) + pvarint(UInt64(priority)) }          // MeshPacket.priority
    var out = Data()
    out += ptag(1, 2) + pvarint(UInt64(pkt.count)) + pkt                        // ToRadio.packet
    return out
}

/// Parse a FromRadio frame as a GNSS config reply (portnum 260, 9-byte payload) — nil otherwise.
/// Keeps MeshPacket.from so callers can bind the settings to the node that sent them.
func parseConfigReply(_ data: Data) -> ConfigReply? {
    var r = ProtoReader(data)
    while let (field, wire) = r.readTag() {
        if field == 2, wire == 2 {
            guard let pkt = r.readBytes() else { return nil }
            var pr = ProtoReader(pkt)
            var from: UInt32 = 0
            var decoded: ArraySlice<UInt8>?
            while let (f, w) = pr.readTag() {
                switch (f, w) {
                case (1, 5): from = pr.readFixed32() ?? 0
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
            guard portnum == kGnssConfigPortnum, let pl = payload, pl.count >= 9 else { return nil }
            let b = Array(pl)
            guard b[0] & 0x80 != 0, b[0] != 0x85, let st = TagSettings.fromWire(Array(b[2...])) else { return nil }
            return ConfigReply(from: from, op: b[0], status: b[1], settings: st)
        }
        r.skip(wire)
    }
    return nil
}

/// Correlated ACK for the TRACK op (0x05): `[0x85, status, sub, offLo, offHi, tid u32 LE]`.
/// The tag echoes exactly WHICH frame of WHICH transfer it answers (the tid travels in EVERY
/// sub-op, R4 finding 7), and the parser keeps the sender's node id — a stale ACK from a
/// previous transfer or a different tag can never be credited.
struct TrackAck: Equatable {
    let from: UInt32 // MeshPacket.from — the replying node (must be the upload's target)
    let status: UInt8
    let sub: UInt8   // 0 BEGIN / 1 CHUNK / 2 COMMIT / 3 ABORT
    let off: UInt16  // BEGIN: record count · CHUNK: offset · else 0
    let tid: UInt32  // per-transfer id chosen by the client, echoed from the REQUEST frame
}

/// Parse a FromRadio frame as a track ACK (portnum 260, 9-byte 0x85 payload) — nil otherwise.
func parseTrackAck(_ data: Data) -> TrackAck? {
    var r = ProtoReader(data)
    while let (field, wire) = r.readTag() {
        if field == 2, wire == 2 {
            guard let pkt = r.readBytes() else { return nil }
            var pr = ProtoReader(pkt)
            var from: UInt32 = 0
            var decoded: ArraySlice<UInt8>?
            while let (f, w) = pr.readTag() {
                switch (f, w) {
                case (1, 5): from = pr.readFixed32() ?? 0
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
            guard portnum == kGnssConfigPortnum, let pl = payload, pl.count == 9 else { return nil }
            let b = Array(pl)
            guard b[0] == 0x85 else { return nil }
            return TrackAck(from: from, status: b[1], sub: b[2],
                            off: UInt16(b[3]) | (UInt16(b[4]) << 8),
                            tid: UInt32(b[5]) | (UInt32(b[6]) << 8) | (UInt32(b[7]) << 16) | (UInt32(b[8]) << 24))
        }
        r.skip(wire)
    }
    return nil
}

/// Correlated 7-byte ACK shared by SIGNAL v5 (0x83) and the RADIO op (0x86):
/// `[ackOp, status, echo, id u32 LE]` — echo is the pattern (SIGNAL) or radio state (RADIO),
/// id is the request's own u32 sid/rid. Satisfiable ONLY by the frame that asked: the sender
/// retransmits the SAME id until this arrives (at-least-once delivery, at-most-once playback —
/// docs/RADIO_STATES.md §4). Distinguished from the legacy 0x83 settings echo by LENGTH (7 vs 18).
struct SmallAck: Equatable {
    let from: UInt32  // replying node — must match the command's target
    let ackOp: UInt8  // 0x83 SIGNAL / 0x86 RADIO
    let status: UInt8 // 0 ok (incl. duplicate re-ACK) / 1 rejected / 2 malformed
    let echo: UInt8   // pattern or radio state, echoed from the request
    let id: UInt32    // sid / rid, echoed from the request
}

/// Parse a FromRadio frame as a 7-byte SIGNAL/RADIO ACK (portnum 260) — nil otherwise.
func parseSmallAck(_ data: Data) -> SmallAck? {
    var r = ProtoReader(data)
    while let (field, wire) = r.readTag() {
        if field == 2, wire == 2 {
            guard let pkt = r.readBytes() else { return nil }
            var pr = ProtoReader(pkt)
            var from: UInt32 = 0
            var decoded: ArraySlice<UInt8>?
            while let (f, w) = pr.readTag() {
                switch (f, w) {
                case (1, 5): from = pr.readFixed32() ?? 0
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
            guard portnum == kGnssConfigPortnum, let pl = payload, pl.count == 7 else { return nil }
            let b = Array(pl)
            guard b[0] == 0x83 || b[0] == 0x86 else { return nil }
            return SmallAck(from: from, ackOp: b[0], status: b[1], echo: b[2],
                            id: UInt32(b[3]) | (UInt32(b[4]) << 8) | (UInt32(b[5]) << 16) | (UInt32(b[6]) << 24))
        }
        r.skip(wire)
    }
    return nil
}

// MARK: - Typed discovery (A2 — docs/DISCOVERY.md is the external contract)

/// The fleet's BLE discovery advertisement: manufacturer data in the scan response,
/// `[company 0xFFFF]['M']['T'][ver][type][nodeNum u32 LE]`. Stock Meshtastic nodes don't
/// carry it — consumers use it to identify device TYPE without name heuristics.
struct DiscoveryAd: Equatable {
    enum DeviceType: UInt8 {
        case bridge = 1 // BLE5/LoRa bridge (relays Dronetag Remote ID)
        case gpsTag = 2 // self-contained GPS tag
        case base = 3   // iPhone-side receiver — the connection target
    }

    let version: UInt8
    let type: DeviceType
    let nodeNum: UInt32

    /// Parse CoreBluetooth's `CBAdvertisementDataManufacturerDataKey` payload.
    static func parse(_ data: Data) -> DiscoveryAd? {
        let b = [UInt8](data)
        guard b.count >= 10, b[0] == 0xFF, b[1] == 0xFF, b[2] == UInt8(ascii: "M"),
              b[3] == UInt8(ascii: "T"), let t = DeviceType(rawValue: b[5]) else { return nil }
        return DiscoveryAd(version: b[4], type: t,
                           nodeNum: UInt32(b[6]) | (UInt32(b[7]) << 8) | (UInt32(b[8]) << 16) | (UInt32(b[9]) << 24))
    }
}

// MARK: - Node names (A3 — NodeInfo.user carries the persisted owner name)

/// Parse a FromRadio frame as NodeInfo (field 4) → (nodeNum, longName, shortName).
/// Nodes broadcast these on boot/rename; the Base relays them like any mesh packet.
func parseNodeInfo(_ data: Data) -> (num: UInt32, longName: String, shortName: String)? {
    var r = ProtoReader(data)
    while let (field, wire) = r.readTag() {
        if field == 4, wire == 2 { // FromRadio.node_info (NodeInfo)
            guard let ni = r.readBytes() else { return nil }
            var n = ProtoReader(ni)
            var num: UInt32 = 0
            var user: ArraySlice<UInt8>?
            while let (nf, nw) = n.readTag() {
                switch (nf, nw) {
                case (1, 0): num = n.readVarint().map { UInt32(truncatingIfNeeded: $0) } ?? 0
                case (2, 2): user = n.readBytes()
                default: n.skip(nw)
                }
            }
            guard num != 0, let u = user else { return nil }
            var ur = ProtoReader(u)
            var longName = "", shortName = ""
            while let (uf, uw) = ur.readTag() {
                switch (uf, uw) {
                case (2, 2): if let b = ur.readBytes() { longName = String(decoding: b, as: UTF8.self) }
                case (3, 2): if let b = ur.readBytes() { shortName = String(decoding: b, as: UTF8.self) }
                default: ur.skip(uw)
                }
            }
            return longName.isEmpty && shortName.isEmpty ? nil : (num, longName, shortName)
        }
        r.skip(wire)
    }
    return nil
}

/// Encode ToRadio{ packet{ to, decoded: Data{ portnum 6 (ADMIN), AdminMessage.set_owner } } }.
/// Rename persists on the device (owner is flash-backed) and re-broadcasts as NodeInfo.
/// LOCAL-LINK ONLY: phone-injected admin (from = 0) skips the session-passkey gate; remote
/// admin over LoRa would need the passkey/PKI dance and is deliberately out of scope.
func encodeAdminSetOwner(to: UInt32, longName: String, shortName: String, packetId: UInt32) -> Data {
    var user = Data()
    if let ln = longName.data(using: .utf8), !ln.isEmpty {
        user += ptag(2, 2) + pvarint(UInt64(ln.count)) + ln // User.long_name
    }
    if let sn = shortName.data(using: .utf8), !sn.isEmpty {
        user += ptag(3, 2) + pvarint(UInt64(sn.count)) + sn // User.short_name
    }
    var admin = Data()
    admin += ptag(2, 2) + pvarint(UInt64(user.count)) + user // AdminMessage.set_owner
    return encodeToRadioData(to: to, portnum: 6, payload: admin, packetId: packetId)
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
