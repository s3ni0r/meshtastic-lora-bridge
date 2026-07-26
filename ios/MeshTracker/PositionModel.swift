import Foundation
import CoreLocation
import Observation

/// One tag's live state — the stream is multi-source (bridge tag + GPS tag can transmit at once),
/// so everything positional is tracked per LoRa `from` node id.
@Observable
final class SourceTrack: Identifiable {
    let from: UInt32
    let seenOrder: Int // arrival order, stable sort key behind favorites
    var id: UInt32 { from }
    var source: PacketSource = .legacy
    var isFavorite = false // pinned to the top of the list (persisted)
    var isVisible = true   // rendered on the map (persisted); the list always shows every tag
    var current: CLLocationCoordinate2D?
    var trail: [CLLocationCoordinate2D] = []
    var hasLock = false
    var lastSnr: Float = 0
    var lastRssi: Int32 = 0
    var packetCount = 0
    var rateHz: Double = 0      // packets/sec (real-time; flush bursts excluded)
    var noveltyHz: Double = 0   // genuinely-new positions/sec = the GPS refresh rate
    var lastHeard: Date?
    // Extended telemetry
    var altitude = 0            // metres
    var speedKmh = 0
    var heading: Double = 0     // degrees
    var hacc = 0                // horizontal accuracy, metres (0 = unknown)
    var battery = -1            // v3 per-packet battery: 0-100 %, 101 = powered, -1 = unknown
    var adaptive = false        // downlink mode echo: ADAPTIVE TX mode active (flags bit2)
    var slowTier = false        // adaptive slow tier engaged (flags bit3)
    var motionMg = -1           // v4 accel energy envelope, mg (-1 = unknown)
    var moving = false          // v4 QMA6100P classifier (flags bit1)
    var simulated = false       // flags bit4: synthetic fixes from the tag's indoor simulator
    var radioStatus = -1        // v5 status byte: bit0 DEAF, bit1 PERMANENT, bit2 duty-degraded
    var radioStatusAt: Date?    // when the last v5 status arrived (confirmation freshness)

    /// v5 radio-state readouts (A4). isDeaf is the GO-DEAF fallback confirmation — a deaf tag
    /// still streams, so the byte proves the transition even when the ACK was lost.
    var isDeaf: Bool { radioStatus >= 0 && radioStatus & 0x01 != 0 }
    var isPermanent: Bool { radioStatus >= 0 && radioStatus & 0x02 != 0 }
    var dutyDegraded: Bool { radioStatus >= 0 && radioStatus & 0x04 != 0 }

    /// Short display id, e.g. "9cda" — enough to tell two physical tags apart.
    var shortId: String { String(String(format: "%08x", from).suffix(4)) }
    var title: String { "\(source.label) ·\(shortId)" }

    @ObservationIgnored private var times: [Date] = []
    @ObservationIgnored private var novelTimes: [Date] = []
    @ObservationIgnored private var lastNovelLat = Double.nan
    @ObservationIgnored private var lastNovelLon = Double.nan
    @ObservationIgnored private var lastArrival: Date?

    init(from: UInt32, seenOrder: Int) {
        self.from = from
        self.seenOrder = seenOrder
    }

    func ingest(_ sp: StreamPacket, at now: Date) {
        // A buffered backlog (e.g. the Base flushing its queue on (re)connect) arrives back-to-back
        // (single-digit ms apart). Anything < 40 ms after this tag's previous packet is a flush
        // artifact: jump to the latest position but don't inflate rates or spam the trail.
        // 40 ms, NOT more: the live stream now runs up to 10 Hz (~100 ms spacing) since the AG3335
        // unlock — a bigger threshold silently discards genuine real-time packets.
        let dt = lastArrival.map { now.timeIntervalSince($0) } ?? 999
        lastArrival = now
        let isFlush = dt < 0.04

        source = sp.source
        hasLock = sp.hasLock
        lastSnr = sp.rxSnr
        lastRssi = sp.rxRssi
        altitude = sp.altitude
        speedKmh = sp.speedKmh
        heading = sp.heading
        hacc = sp.hacc
        if sp.battery >= 0 { battery = sp.battery } // keep the last known level across heartbeats
        adaptive = sp.adaptive
        slowTier = sp.slowTier
        if sp.motionMg >= 0 { motionMg = sp.motionMg }
        moving = sp.moving
        simulated = sp.simulated
        if sp.radioStatus >= 0 {
            radioStatus = sp.radioStatus
            radioStatusAt = now
        }
        packetCount += 1
        lastHeard = now

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
    }
}

/// One node's latest battery snapshot. Two producers feed it: the v3 stream byte (per packet,
/// tags only) and stock portnum-67 device telemetry (every node — the Base's ONLY battery path).
struct NodePower {
    var level: Int      // 0-100 %; 101 = externally powered (firmware magic)
    var voltage: Float  // volts; 0 = not reported (the stream byte carries no voltage)
    var updated: Date
    var isPowered: Bool { level > 100 }
}

@Observable
final class PositionModel {
    /// All tags heard this session, in first-seen order.
    var tracks: [SourceTrack] = []
    /// Latest portnum-67 telemetry per node id (Base + any tag whose telemetry reaches us).
    var power: [UInt32: NodePower] = [:]
    /// User-pinned tag (tap a chip); nil = follow whichever tag spoke last.
    var selectedFrom: UInt32?
    var packetCount = 0
    /// Bumped on every packet. The view reads this so a 10 Hz stream re-renders the map content
    /// even when only reference-type SourceTrack properties mutate.
    var revision = 0
    /// Session recorder — while armed, EVERY parsed packet is written to disk verbatim
    /// (measurement-grade capture; see SessionStore.swift).
    let recorder = SessionRecorder()

    /// The tag the header/metrics/camera follow: the pinned one, else a STABLE default — the
    /// first visible entry of the sorted list (favorites sort first). Never "most recently
    /// heard": with two live tags that flips focus on every packet and yanks the map around.
    var active: SourceTrack? {
        if let sel = selectedFrom, let t = tracks.first(where: { $0.from == sel }) { return t }
        return tracks.first(where: { $0.isVisible }) ?? tracks.first
    }

    @ObservationIgnored private var csv: FileHandle?
    @ObservationIgnored private var favorites: Set<UInt32> = []
    @ObservationIgnored private var hidden: Set<UInt32> = []

    init() {
        let d = UserDefaults.standard
        favorites = Set((d.array(forKey: "favoriteTags") as? [String] ?? []).compactMap { UInt32($0) })
        hidden = Set((d.array(forKey: "hiddenTags") as? [String] ?? []).compactMap { UInt32($0) })
        openCSV()
    }

    func ingest(_ sp: StreamPacket) {
        let now = Date()
        let track: SourceTrack
        if let t = tracks.first(where: { $0.from == sp.from }) {
            track = t
        } else {
            track = SourceTrack(from: sp.from, seenOrder: tracks.count)
            track.isFavorite = favorites.contains(sp.from)
            track.isVisible = !hidden.contains(sp.from)
            tracks.append(track)
            resort()
        }
        track.ingest(sp, at: now)
        recorder.ingest(sp, title: track.title)
        packetCount += 1
        revision &+= 1
        writeCSV(sp, now)
    }

    /// Device telemetry (portnum 67) — battery/voltage for nodes that don't stream positions
    /// (the Base) or run pre-v3 firmware.
    func ingestPower(_ r: PowerReading) {
        power[r.from] = NodePower(level: r.level, voltage: r.voltage, updated: Date())
        revision &+= 1
    }

    /// Best battery estimate for a node: the per-packet stream byte when the node streams
    /// (live at up to 6.7 Hz), else its last telemetry. Voltage only ever comes from telemetry.
    func batteryInfo(_ from: UInt32) -> NodePower? {
        if let t = tracks.first(where: { $0.from == from }), t.battery >= 0, let heard = t.lastHeard {
            return NodePower(level: t.battery, voltage: power[from]?.voltage ?? 0, updated: heard)
        }
        return power[from]
    }

    // MARK: - Favorites / visibility (persisted across launches)

    func toggleFavorite(_ t: SourceTrack) {
        t.isFavorite.toggle()
        if t.isFavorite { favorites.insert(t.from) } else { favorites.remove(t.from) }
        UserDefaults.standard.set(favorites.map(String.init), forKey: "favoriteTags")
        resort()
        revision &+= 1
    }

    func toggleVisible(_ t: SourceTrack) {
        t.isVisible.toggle()
        if t.isVisible { hidden.remove(t.from) } else { hidden.insert(t.from) }
        UserDefaults.standard.set(hidden.map(String.init), forKey: "hiddenTags")
        revision &+= 1
    }

    private func resort() {
        tracks.sort {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.seenOrder < $1.seenOrder
        }
    }

    // MARK: - CSV logging (Documents/meshtracker_log4.csv — v4 schema adds `mot_mg`,`moving`)

    private func openCSV() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("meshtracker_log4.csv")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "host_time,from,src,seq,lat,lon,ms_in_sec,flags,rx_snr,rx_rssi,alt_m,speed_kmh,heading,hacc_m,bat,mot_mg,moving\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
        csv = try? FileHandle(forWritingTo: url)
        csv?.seekToEndOfFile()
    }

    private func writeCSV(_ sp: StreamPacket, _ now: Date) {
        let bat = sp.battery >= 0 ? String(sp.battery) : ""
        let mot = sp.motionMg >= 0 ? String(sp.motionMg) : ""
        var line = "\(now.timeIntervalSince1970),\(sp.from),\(sp.source.rawValue),\(sp.seq),\(sp.lat),\(sp.lon),"
        line += "\(sp.msInSec),\(sp.flags),\(sp.rxSnr),\(sp.rxRssi),\(sp.altitude),\(sp.speedKmh),"
        line += "\(Int(sp.heading)),\(sp.hacc),\(bat),\(mot),\(sp.moving ? 1 : 0)\n"
        if let d = line.data(using: .utf8) { csv?.write(d) }
    }
}
