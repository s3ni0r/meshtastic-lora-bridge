import Foundation

// Track-slot pipeline for the tag's GPX replay (GnssSim TRACK source, DOWNLINK.md op 0x05):
// GPX / recorded session  ->  [TrackRecord]  ->  10-byte wire records  ->  BEGIN/CHUNK/COMMIT.
// The tag never sees XML — parsing, speed derivation and decimation all happen here.

/// One slot record (wire: lat i32 LE, lon i32 LE, speed u8 km/h, dt u8 in 0.1 s from previous).
struct TrackRecord {
    var lat: Int32
    var lon: Int32
    var speedKmh: UInt8
    var dtDs: UInt8
}

enum TrackBuilder {
    /// Tag-side slot cap. The tag keeps TWO A/B slots (R4 f2) on its 28 KiB shared LittleFS:
    /// each committed v3 slot is 16-byte header + 800×10-byte records + 16-byte footer.
    /// The exact bundled-LittleFS host gate promotes both slots with an 8 KiB prefs filler
    /// present (209/224 blocks used); this physical-block result replaces logical subtraction.
    static let maxRecords = 800

    // MARK: GPX -> records

    /// Parse GPX <trkpt lat lon> (+ optional <time>) into records. Speeds derive from
    /// point-to-point motion; missing timestamps assume 1 s per point.
    static func fromGPX(_ data: Data) -> [TrackRecord]? {
        let parser = GPXParser()
        guard let pts = parser.parse(data), pts.count >= 2 else { return nil }
        var recs: [TrackRecord] = []
        recs.reserveCapacity(pts.count)
        for i in 0..<pts.count {
            let p = pts[i]
            var dtS = 1.0
            var spd = 0.0
            if i > 0 {
                let q = pts[i - 1]
                if let t0 = q.time, let t1 = p.time {
                    dtS = max(0.1, min(25.5, t1.timeIntervalSince(t0)))
                }
                let dM = haversineM(q.la, q.lo, p.la, p.lo)
                spd = dM / dtS * 3.6
            }
            recs.append(TrackRecord(lat: Int32(p.la * 1e7), lon: Int32(p.lo * 1e7),
                                    speedKmh: UInt8(max(0, min(255, spd))),
                                    dtDs: UInt8(max(1, min(255, dtS * 10)))))
        }
        return decimate(recs)
    }

    /// From a recorded session's raw points (t epoch s, lat, lon, speed km/h) — fixes only.
    static func fromSessionPoints(_ pts: [SessionPoint]) -> [TrackRecord]? {
        let fixes = pts.filter { $0.la != 0 || $0.lo != 0 }
        guard fixes.count >= 2 else { return nil }
        var recs: [TrackRecord] = []
        recs.reserveCapacity(fixes.count)
        for i in 0..<fixes.count {
            let p = fixes[i]
            let dtS = i > 0 ? max(0.1, min(25.5, p.t - fixes[i - 1].t)) : 1.0
            recs.append(TrackRecord(lat: Int32(p.la * 1e7), lon: Int32(p.lo * 1e7),
                                    speedKmh: UInt8(max(0, min(255, p.sp))),
                                    dtDs: UInt8(max(1, min(255, dtS * 10)))))
        }
        return decimate(recs)
    }

    /// Halve until the slot cap fits, merging the dropped point's dt into the survivor.
    static func decimate(_ input: [TrackRecord]) -> [TrackRecord] {
        var recs = input
        while recs.count > maxRecords {
            var out: [TrackRecord] = []
            out.reserveCapacity(recs.count / 2 + 1)
            var i = 0
            while i < recs.count {
                var r = recs[i]
                if i + 1 < recs.count, out.count + (recs.count - i) / 2 >= 2 {
                    let merged = Int(r.dtDs) + Int(recs[i + 1].dtDs)
                    r = recs[i + 1]
                    r.dtDs = UInt8(min(255, merged))
                    i += 2
                } else {
                    i += 1
                }
                out.append(r)
            }
            recs = out
        }
        return recs
    }

    // MARK: wire + checksum

    static func wireData(_ recs: [TrackRecord]) -> Data {
        var d = Data(capacity: recs.count * 10)
        for r in recs {
            d += withUnsafeBytes(of: r.lat.littleEndian) { Data($0) }
            d += withUnsafeBytes(of: r.lon.littleEndian) { Data($0) }
            d.append(r.speedKmh)
            d.append(r.dtDs)
        }
        return d
    }

    /// zlib-compatible CRC32 (matches the firmware's bitwise 0xEDB88320 implementation).
    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = ~0
        for byte in data {
            c ^= UInt32(byte)
            for _ in 0..<8 {
                c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1)))
            }
        }
        return ~c
    }

    static func durationS(_ recs: [TrackRecord]) -> Double {
        recs.dropFirst().reduce(0.0) { $0 + Double($1.dtDs) / 10.0 }
    }

    private static func haversineM(_ la1: Double, _ lo1: Double, _ la2: Double, _ lo2: Double) -> Double {
        let r = 6_371_000.0
        let dLa = (la2 - la1) * .pi / 180, dLo = (lo2 - lo1) * .pi / 180
        let a = sin(dLa / 2) * sin(dLa / 2) +
            cos(la1 * .pi / 180) * cos(la2 * .pi / 180) * sin(dLo / 2) * sin(dLo / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

// MARK: - Minimal GPX parser (trkpt lat/lon + time; rtept accepted too)

private final class GPXParser: NSObject, XMLParserDelegate {
    struct Pt { let la: Double, lo: Double, time: Date? }
    private var pts: [Pt] = []
    private var curLa: Double?, curLo: Double?
    private var inTime = false, timeText = ""
    private let iso = ISO8601DateFormatter()
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func parse(_ data: Data) -> [Pt]? {
        let p = XMLParser(data: data)
        p.delegate = self
        return p.parse() || !pts.isEmpty ? pts : nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let tag = name.lowercased()
        if tag == "trkpt" || tag == "rtept" {
            curLa = Double(attributes["lat"] ?? "")
            curLo = Double(attributes["lon"] ?? "")
            timeText = ""
        } else if tag == "time", curLa != nil {
            inTime = true
            timeText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTime { timeText += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let tag = name.lowercased()
        if tag == "time" {
            inTime = false
        } else if tag == "trkpt" || tag == "rtept" {
            if let la = curLa, let lo = curLo {
                let trimmed = timeText.trimmingCharacters(in: .whitespacesAndNewlines)
                let t = isoFrac.date(from: trimmed) ?? iso.date(from: trimmed)
                pts.append(Pt(la: la, lo: lo, time: t))
            }
            curLa = nil
            curLo = nil
        }
    }
}
