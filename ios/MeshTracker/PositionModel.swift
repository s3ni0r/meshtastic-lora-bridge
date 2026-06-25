import Foundation
import CoreLocation
import Observation

@Observable
final class PositionModel {
    var current: CLLocationCoordinate2D?
    var trail: [CLLocationCoordinate2D] = []
    var hasLock = false
    var lastSnr: Float = 0
    var lastRssi: Int32 = 0
    var packetCount = 0
    var rateHz: Double = 0      // packets/sec (stream rate)
    var noveltyHz: Double = 0   // genuinely-new positions/sec = the true GPS refresh rate
    var fromNode: UInt32 = 0

    @ObservationIgnored private var times: [Date] = []
    @ObservationIgnored private var novelTimes: [Date] = []
    @ObservationIgnored private var lastNovelLat = Double.nan
    @ObservationIgnored private var lastNovelLon = Double.nan
    @ObservationIgnored private var csv: FileHandle?

    init() { openCSV() }

    func ingest(_ sp: StreamPacket) {
        hasLock = sp.hasLock
        lastSnr = sp.rxSnr
        lastRssi = sp.rxRssi
        fromNode = sp.from
        packetCount += 1

        let now = Date()
        times.append(now)
        times.removeAll { $0 < now.addingTimeInterval(-10) }
        if let first = times.first, times.count > 1 {
            rateHz = Double(times.count - 1) / now.timeIntervalSince(first)
        }

        // Only treat non-zero coordinates as a real position (heartbeats send 0,0).
        if sp.lat != 0 || sp.lon != 0 {
            let coord = CLLocationCoordinate2D(latitude: sp.lat, longitude: sp.lon)
            current = coord
            if trail.last == nil || trail.last!.latitude != sp.lat || trail.last!.longitude != sp.lon {
                trail.append(coord)
                if trail.count > 1000 { trail.removeFirst(trail.count - 1000) }
            }
            // Novelty rate: count only genuinely-new positions. Real GPS jitters on every fix, so
            // this measures the true GPS refresh rate (vs the constant ~2.8 Hz packet rate).
            if sp.lat != lastNovelLat || sp.lon != lastNovelLon {
                lastNovelLat = sp.lat
                lastNovelLon = sp.lon
                novelTimes.append(now)
            }
            novelTimes.removeAll { $0 < now.addingTimeInterval(-10) }
            if let first = novelTimes.first, novelTimes.count > 1 {
                noveltyHz = Double(novelTimes.count - 1) / now.timeIntervalSince(first)
            }
        }

        writeCSV(sp, now)
    }

    // MARK: - CSV logging (Documents/meshtracker_log.csv)

    private func openCSV() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("meshtracker_log.csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "host_time,from,seq,lat,lon,ms_in_sec,flags,rx_snr,rx_rssi\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        csv = try? FileHandle(forWritingTo: url)
        csv?.seekToEndOfFile()
    }

    private func writeCSV(_ sp: StreamPacket, _ now: Date) {
        let line = "\(now.timeIntervalSince1970),\(sp.from),\(sp.seq),\(sp.lat),\(sp.lon),\(sp.msInSec),\(sp.flags),\(sp.rxSnr),\(sp.rxRssi)\n"
        if let d = line.data(using: .utf8) { csv?.write(d) }
    }
}
