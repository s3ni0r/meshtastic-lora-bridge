import Foundation

// Minimal, dependency-free decoding of just the Meshtastic protobuf fields we need:
//   FromRadio.packet (2) -> MeshPacket{ from(1,fixed32), decoded(4), id(6,fixed32),
//                                       rx_snr(8,float), rx_rssi(12,varint) }
//   MeshPacket.decoded -> Data{ portnum(1,varint), payload(2,bytes) }
// Our firmware streams a fixed 12-byte payload on PRIVATE_APP (256):
//   <i lat*1e7 | <i lon*1e7 | <H ms_in_sec | <B seq | <B flags(bit0=GPS lock)

let kPrivateAppPortnum = 256

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

    var hasLock: Bool { flags & 0x01 != 0 }
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
    return true
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
