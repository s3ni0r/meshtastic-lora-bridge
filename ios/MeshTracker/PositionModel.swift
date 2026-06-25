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
    var rateHz: Double = 0
    var fromNode: UInt32 = 0

    @ObservationIgnored private var times: [Date] = []
    @ObservationIgnored private var csv: FileHandle?

    init() { openCSV() }

    func ingest(_ sp: StreamPacket) {
        let coord = CLLocationCoordinate2D(latitude: sp.lat, longitude: sp.lon)
        current = coord
        hasLock = (sp.flags & 1) != 0
        lastSnr = sp.rxSnr
        lastRssi = sp.rxRssi
        fromNode = sp.from
        packetCount += 1

        if let last = trail.last {
            if last.latitude != sp.lat || last.longitude != sp.lon { trail.append(coord) }
        } else {
            trail.append(coord)
        }
        if trail.count > 1000 { trail.removeFirst(trail.count - 1000) }

        let now = Date()
        times.append(now)
        let cutoff = now.addingTimeInterval(-10)
        times.removeAll { $0 < cutoff }
        if let first = times.first, times.count > 1 {
            rateHz = Double(times.count - 1) / now.timeIntervalSince(first)
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
