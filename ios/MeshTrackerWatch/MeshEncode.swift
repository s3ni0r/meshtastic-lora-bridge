import Foundation
import CoreLocation

/// Hand-encodes a Meshtastic ToRadio packet carrying our 18-byte PRIVATE_APP(256) position
/// payload. The exact byte layout was validated against the Meshtastic protobuf decoder (M0).
enum MeshEncode {
    static let privateApp = 256

    /// 18-byte payload, identical layout to the firmware + iOS app. flags bit3 = source:watch.
    static func payload(_ loc: CLLocation, seq: UInt8, sats: Int, batteryPct: Int) -> Data {
        var p = Data()
        func i32(_ v: Int32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { p.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { p.append(contentsOf: $0) } }
        func i16(_ v: Int16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { p.append(contentsOf: $0) } }
        i32(Int32(loc.coordinate.latitude * 1e7))
        i32(Int32(loc.coordinate.longitude * 1e7))
        // ms-within-second (watchOS is 32-bit: never build the full epoch-ms, it overflows Int32)
        u16(UInt16(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1000))
        p.append(seq)
        var flags: UInt8 = 0x01 | 0x08          // bit0 lock, bit3 source=watch
        if loc.speed > 0.5 { flags |= 0x02 }    // bit1 moving
        p.append(flags)
        i16(Int16(clamping: Int(loc.altitude)))
        p.append(UInt8(min(255, max(0, Int(max(0, loc.speed) * 3.6)))))   // speed km/h
        let course = loc.course >= 0 ? loc.course : 0
        p.append(UInt8(Int(course * 256 / 360) & 0xFF))                  // heading byte
        p.append(UInt8(min(255, max(0, sats))))                          // sats (watch: 0 = n/a)
        p.append(UInt8(min(101, max(0, batteryPct))))                    // watch battery %
        return p
    }

    static func varint(_ n: Int) -> Data {
        var v = n, d = Data()
        repeat {
            var b = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { b |= 0x80 }
            d.append(b)
        } while v != 0
        return d
    }

    /// ToRadio{ packet: MeshPacket{ to=BROADCAST, channel=0, decoded=Data{portnum=256,payload}, hop_limit=1 } }
    static func toRadio(payload: Data) -> Data {
        var data = Data([0x08])                                  // Data.portnum (field 1, varint)
        data.append(varint(privateApp))
        data.append(0x12)                                        // Data.payload (field 2, bytes)
        data.append(varint(payload.count))
        data.append(payload)

        var mp = Data([0x15, 0xFF, 0xFF, 0xFF, 0xFF])            // MeshPacket.to (field 2, fixed32 = BROADCAST)
        mp.append(contentsOf: [0x18, 0x00])                      // .channel (field 3, varint = 0 / primary)
        mp.append(0x22)                                          // .decoded (field 4, bytes)
        mp.append(varint(data.count))
        mp.append(data)
        mp.append(contentsOf: [0x48, 0x01])                      // .hop_limit (field 9, varint = 1)

        var tr = Data([0x0a])                                    // ToRadio.packet (field 1, bytes)
        tr.append(varint(mp.count))
        tr.append(mp)
        return tr
    }
}
