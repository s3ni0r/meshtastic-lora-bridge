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
    var rateHz: Double = 0      // packets/sec (real-time; flush bursts excluded)
    var noveltyHz: Double = 0   // genuinely-new positions/sec = the GPS refresh rate
    var fromNode: UInt32 = 0
    // Extended telemetry from the Dronetag ODID Location message
    var altitude = 0            // metres (geo)
    var speedKmh = 0
    var heading: Double = 0     // degrees
    var hacc = 0                // horizontal accuracy, metres (0 = unknown)

    @ObservationIgnored private var times: [Date] = []
    @ObservationIgnored private var novelTimes: [Date] = []
    @ObservationIgnored private var lastNovelLat = Double.nan
    @ObservationIgnored private var lastNovelLon = Double.nan
    @ObservationIgnored private var lastArrival: Date?
    @ObservationIgnored private var csv: FileHandle?

    init() { openCSV() }

    func ingest(_ sp: StreamPacket) {
        let now = Date()
        // A buffered backlog (e.g. the Base flushing its queue on (re)connect) arrives far faster than
        // the ~3 Hz send rate. Treat anything < 0.15 s after the previous packet as a flush artifact:
        // jump to the latest position but DON'T let it inflate the rate or spam the trail. This keeps
        // the display genuinely real-time at any moment rather than replaying a stale queue.
        let dt = lastArrival.map { now.timeIntervalSince($0) } ?? 999
        lastArrival = now
        let isFlush = dt < 0.15

        hasLock = sp.hasLock
        lastSnr = sp.rxSnr
        lastRssi = sp.rxRssi
        fromNode = sp.from
        altitude = sp.altitude
        speedKmh = sp.speedKmh
        heading = sp.heading
        hacc = sp.hacc
        packetCount += 1

        if !isFlush {
            times.append(now)
            times.removeAll { $0 < now.addingTimeInterval(-10) }
            if let first = times.first, times.count > 1 {
                rateHz = Double(times.count - 1) / now.timeIntervalSince(first)
            }
        }

        // Only treat non-zero coordinates as a real position (heartbeats send 0,0).
        if sp.lat != 0 || sp.lon != 0 {
            let coord = CLLocationCoordinate2D(latitude: sp.lat, longitude: sp.lon)
            current = coord // latest always wins
            if !isFlush {
                if trail.last == nil || trail.last!.latitude != sp.lat || trail.last!.longitude != sp.lon {
                    trail.append(coord)
                    if trail.count > 1000 { trail.removeFirst(trail.count - 1000) }
                }
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
        }

        writeCSV(sp, now)
    }

    // MARK: - CSV logging (Documents/meshtracker_log.csv)

    private func openCSV() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("meshtracker_log.csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "host_time,from,seq,lat,lon,ms_in_sec,flags,rx_snr,rx_rssi,alt_m,speed_kmh,heading,hacc_m\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        csv = try? FileHandle(forWritingTo: url)
        csv?.seekToEndOfFile()
    }

    private func writeCSV(_ sp: StreamPacket, _ now: Date) {
        let line = "\(now.timeIntervalSince1970),\(sp.from),\(sp.seq),\(sp.lat),\(sp.lon),\(sp.msInSec)," +
            "\(sp.flags),\(sp.rxSnr),\(sp.rxRssi),\(sp.altitude),\(sp.speedKmh),\(Int(sp.heading)),\(sp.hacc)\n"
        if let d = line.data(using: .utf8) { csv?.write(d) }
    }
}
