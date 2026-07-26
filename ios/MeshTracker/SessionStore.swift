import Foundation
import CoreLocation
import Observation

// MARK: - Session data model
//
// A session is a raw, unprocessed capture of EVERY PRIVATE_APP packet received while recording —
// this is a measurement instrument for comparing tags under identical conditions, so nothing is
// smoothed, thinned, or interpolated. Layout on disk (crash-safe: every point hits disk on
// arrival; an unterminated session is finalized on next launch):
//
//   Documents/sessions/<uuid>/meta.json      SessionMeta
//   Documents/sessions/<uuid>/<from>.jsonl   one SessionPoint (compact JSON) per line

struct SessionPoint: Codable {
    var t: Double      // epoch seconds (host arrival)
    var la: Double     // lat (0 = no fix / heartbeat)
    var lo: Double     // lon
    var al: Int        // altitude m
    var sp: Int        // speed km/h
    var hd: Double     // heading deg
    var ha: Int        // reported horizontal accuracy m (0 = unknown)
    var sn: Float      // rx SNR dB
    var rs: Int32      // rx RSSI dBm
    var sq: UInt8      // firmware sequence number
    var fl: UInt8      // raw flags byte (bit0 lock, bit1 moving, bits 2-3 mode, bits 5-7 source)
    var bt: Int?       // v3 battery % (101 = powered); absent on pre-v3 recordings/heartbeats
    var me: Int?       // v4 motion energy, mg; absent pre-v4 — THE dataset for surf-threshold tuning
}

struct SessionTagMeta: Codable, Identifiable {
    var from: UInt32
    var source: Int          // PacketSource rawValue
    var title: String
    var points: Int = 0
    var fixes: Int = 0       // points with non-zero coords
    var distanceM: Double = 0
    var maxSpeedKmh: Int = 0
    var avgHaccM: Double = 0
    var id: UInt32 { from }
}

struct SessionMeta: Codable, Identifiable {
    var id: UUID
    var name: String
    var startedAt: Date
    var endedAt: Date?       // nil = still recording (or crashed; recovered on next launch)
    var tags: [SessionTagMeta] = []

    var duration: TimeInterval { (endedAt ?? startedAt).timeIntervalSince(startedAt) }
}

// Fully loaded session for analysis: raw points + precomputed geometry per tag.
struct LoadedTrack: Identifiable {
    let from: UInt32
    let source: PacketSource
    let title: String
    let points: [SessionPoint]              // ALL packets, in arrival order
    let coords: [CLLocationCoordinate2D]    // non-zero fixes only (for the polyline)
    var id: UInt32 { from }

    /// Points with lo <= t <= hi (two binary searches — cheap even while scrubbing at 10 Hz).
    func windowRange(_ lo: Double, _ hi: Double) -> Range<Int> {
        let hiEnd = (lastIndex(atOrBefore: hi) ?? -1) + 1
        var a = 0, b = hiEnd - 1, first = hiEnd
        while a <= b {
            let m = (a + b) / 2
            if points[m].t >= lo { first = m; b = m - 1 } else { a = m + 1 }
        }
        return first..<hiEnd
    }

    /// Index of the last point with t <= absolute time `t` (raw step — no interpolation).
    func lastIndex(atOrBefore t: Double) -> Int? {
        var lo = 0, hi = points.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if points[mid].t <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans >= 0 ? ans : nil
    }
}

struct LoadedSession: Identifiable {
    let meta: SessionMeta
    let tracks: [LoadedTrack]
    var id: UUID { meta.id }
}

// MARK: - Paths

enum SessionPaths {
    static var root: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func dir(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func metaURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("meta.json") }
    static func trackURL(_ id: UUID, from: UInt32) -> URL {
        dir(id).appendingPathComponent(String(format: "%08x.jsonl", from))
    }
}

// MARK: - Recorder

@Observable
final class SessionRecorder {
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var pointCount = 0
    private(set) var tagCount = 0
    private(set) var writeFailures = 0 // disk-full etc. — surfaced in the REC capsule, never silent
    private(set) var lastError: String? // start/setup failures — recording REFUSES to lie
    @ObservationIgnored private var meta: SessionMeta?
    @ObservationIgnored private var handles: [UInt32: FileHandle] = [:]
    @ObservationIgnored private var deadHandles: Set<UInt32> = [] // failed opens: no meta dupes
    @ObservationIgnored private let encoder = JSONEncoder()

    func start() {
        guard !isRecording else { return }
        lastError = nil
        let id = UUID()
        // Setup failures BLOCK the start — an "active" recorder that can't write is a lie
        // (review R2 finding 5).
        do {
            try FileManager.default.createDirectory(at: SessionPaths.dir(id), withIntermediateDirectories: true)
        } catch {
            lastError = "Can't create the session folder (disk full?) — recording NOT started."
            return
        }
        let df = DateFormatter()
        df.dateFormat = "MMM d · HH:mm"
        let m = SessionMeta(id: id, name: df.string(from: Date()), startedAt: Date(), endedAt: nil)
        guard let d = try? JSONEncoder().encode(m), (try? d.write(to: SessionPaths.metaURL(id), options: .atomic)) != nil else {
            lastError = "Can't write session metadata — recording NOT started."
            return
        }
        meta = m
        startedAt = m.startedAt
        pointCount = 0
        tagCount = 0
        writeFailures = 0
        deadHandles = []
        isRecording = true
    }

    /// Called for EVERY parsed stream packet (heartbeats included) — verbatim capture.
    func ingest(_ sp: StreamPacket, title: String) {
        guard isRecording, var m = meta else { return }
        let pt = SessionPoint(t: Date().timeIntervalSince1970, la: sp.lat, lo: sp.lon, al: sp.altitude,
                              sp: sp.speedKmh, hd: sp.heading, ha: sp.hacc, sn: sp.rxSnr, rs: sp.rxRssi,
                              sq: sp.seq, fl: sp.flags, bt: sp.battery >= 0 ? sp.battery : nil,
                              me: sp.motionMg >= 0 ? sp.motionMg : nil)
        guard var data = try? encoder.encode(pt) else { return }
        data.append(0x0A) // newline
        if handles[sp.from] == nil {
            if deadHandles.contains(sp.from) { // open already failed once: count, don't re-append meta
                writeFailures += 1
                return
            }
            let url = SessionPaths.trackURL(m.id, from: sp.from)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            guard let h = try? FileHandle(forWritingTo: url) else {
                deadHandles.insert(sp.from)
                writeFailures += 1
                return
            }
            handles[sp.from] = h
            m.tags.append(SessionTagMeta(from: sp.from, source: sp.source.rawValue, title: title))
            meta = m
            tagCount = m.tags.count
            if !writeMeta() { // tag list is now on disk too (crash-safe recovery keeps names)
                writeFailures += 1
            }
        }
        if let h = handles[sp.from] {
            do {
                try h.write(contentsOf: data)
                pointCount += 1
            } catch {
                writeFailures += 1 // a full disk must not masquerade as a healthy recording
            }
        }
    }

    /// Stop, compute per-tag stats from the raw files, persist final meta. Returns the session id.
    @discardableResult
    func stop() -> UUID? {
        guard isRecording, var m = meta else { return nil }
        for (_, h) in handles { try? h.close() }
        handles = [:]
        m.endedAt = Date()
        m.tags = m.tags.map { SessionStoreStats.computeStats($0, sessionId: m.id) }
        meta = m
        if !writeMeta() {
            // Finalization not persisted (review R3 finding 8): say so — next launch's
            // recovery pass will rebuild it from the raw point files, nothing is lost.
            lastError = "Session finalization couldn't be saved — it will be recovered on next launch."
        }
        isRecording = false
        let id = m.id
        meta = nil
        startedAt = nil
        return id
    }

    @discardableResult
    private func writeMeta() -> Bool {
        guard let m = meta, let d = try? JSONEncoder().encode(m) else { return false }
        return (try? d.write(to: SessionPaths.metaURL(m.id), options: .atomic)) != nil
    }
}

// MARK: - Stats + loading

enum SessionStoreStats {
    static func loadPoints(sessionId: UUID, from: UInt32) -> [SessionPoint] {
        guard let data = try? Data(contentsOf: SessionPaths.trackURL(sessionId, from: from)) else { return [] }
        let dec = JSONDecoder()
        var out: [SessionPoint] = []
        out.reserveCapacity(4096)
        var start = data.startIndex
        while let nl = data[start...].firstIndex(of: 0x0A) {
            if nl > start, let p = try? dec.decode(SessionPoint.self, from: data[start..<nl]) {
                out.append(p)
            }
            start = data.index(after: nl)
        }
        if start < data.endIndex, let p = try? dec.decode(SessionPoint.self, from: data[start...]) {
            out.append(p) // last line without trailing newline (e.g. after a crash)
        }
        return out
    }

    static func computeStats(_ tag: SessionTagMeta, sessionId: UUID) -> SessionTagMeta {
        var t = tag
        let pts = loadPoints(sessionId: sessionId, from: tag.from)
        t.points = pts.count
        var dist = 0.0, haccSum = 0.0, haccN = 0, fixes = 0, maxSpd = 0
        var prev: CLLocation?
        for p in pts {
            if p.la != 0 || p.lo != 0 {
                fixes += 1
                let loc = CLLocation(latitude: p.la, longitude: p.lo)
                if let pr = prev, pr.coordinate.latitude != p.la || pr.coordinate.longitude != p.lo {
                    dist += loc.distance(from: pr) // raw cumulative — no glitch filtering by design
                }
                prev = loc
            }
            if p.ha > 0 { haccSum += Double(p.ha); haccN += 1 }
            maxSpd = max(maxSpd, p.sp)
        }
        t.fixes = fixes
        t.distanceM = dist
        t.maxSpeedKmh = maxSpd
        t.avgHaccM = haccN > 0 ? haccSum / Double(haccN) : 0
        return t
    }
}

// MARK: - Library

@Observable
final class SessionLibrary {
    var sessions: [SessionMeta] = []

    init() { reload() }

    func reload() {
        var out: [SessionMeta] = []
        let fm = FileManager.default
        for sub in (try? fm.contentsOfDirectory(at: SessionPaths.root, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: sub.lastPathComponent),
                  let data = try? Data(contentsOf: SessionPaths.metaURL(id)),
                  var m = try? JSONDecoder().decode(SessionMeta.self, from: data) else { continue }
            if m.endedAt == nil { // crashed mid-recording: finalize from the raw files
                var lastT = m.startedAt.timeIntervalSince1970
                m.tags = m.tags.map { tag in
                    let t = SessionStoreStats.computeStats(tag, sessionId: m.id)
                    if let last = SessionStoreStats.loadPoints(sessionId: m.id, from: tag.from).last {
                        lastT = max(lastT, last.t)
                    }
                    return t
                }
                m.endedAt = Date(timeIntervalSince1970: lastT)
                m.name += " (recovered)"
                save(m)
            }
            out.append(m)
        }
        sessions = out.sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ m: SessionMeta) {
        if let d = try? JSONEncoder().encode(m) {
            try? d.write(to: SessionPaths.metaURL(m.id), options: .atomic)
        }
        if let i = sessions.firstIndex(where: { $0.id == m.id }) { sessions[i] = m }
    }

    func rename(_ m: SessionMeta, to name: String) {
        var mm = m
        mm.name = name
        save(mm)
    }

    func delete(_ m: SessionMeta) {
        try? FileManager.default.removeItem(at: SessionPaths.dir(m.id))
        sessions.removeAll { $0.id == m.id }
    }

    func load(_ m: SessionMeta) -> LoadedSession {
        let tracks = m.tags.map { tag -> LoadedTrack in
            let pts = SessionStoreStats.loadPoints(sessionId: m.id, from: tag.from)
            let coords = pts.filter { $0.la != 0 || $0.lo != 0 }
                .map { CLLocationCoordinate2D(latitude: $0.la, longitude: $0.lo) }
            return LoadedTrack(from: tag.from, source: PacketSource(rawValue: tag.source) ?? .legacy,
                               title: tag.title, points: pts, coords: coords)
        }
        return LoadedSession(meta: m, tracks: tracks)
    }
}

// MARK: - Export (raw, full resolution)

enum SessionExport {
    private static func isoDF() -> ISO8601DateFormatter {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return df
    }

    static func csv(_ s: LoadedSession) -> URL? {
        var out = "t_iso,t_epoch,from,src,seq,flags,lat,lon,alt_m,speed_kmh,heading_deg,hacc_m,snr_db,rssi_dbm,bat,mot_mg,moving\n"
        let df = isoDF()
        for tr in s.tracks {
            for p in tr.points {
                out += "\(df.string(from: Date(timeIntervalSince1970: p.t))),\(p.t),\(tr.from),"
                out += "\(tr.source.rawValue),\(p.sq),\(p.fl),\(p.la),\(p.lo),\(p.al),\(p.sp),"
                out += "\(Int(p.hd)),\(p.ha),\(p.sn),\(p.rs),\(p.bt.map(String.init) ?? ""),"
                out += "\(p.me.map(String.init) ?? ""),\(p.fl & 0x02 != 0 ? 1 : 0)\n"
            }
        }
        return write(out, name: "\(fileStem(s)).csv")
    }

    static func gpx(_ s: LoadedSession) -> URL? {
        let df = isoDF()
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="MeshTracker" xmlns="http://www.topografix.com/GPX/1/1" xmlns:mt="https://github.com/s3ni0r/meshtastic-lora-bridge/gpx/v1">
        <metadata><name>\(xml(s.meta.name))</name><time>\(df.string(from: s.meta.startedAt))</time></metadata>\n
        """
        for tr in s.tracks {
            out += "<trk><name>\(xml(tr.title))</name><trkseg>\n"
            for p in tr.points where p.la != 0 || p.lo != 0 {
                out += "<trkpt lat=\"\(p.la)\" lon=\"\(p.lo)\"><ele>\(p.al)</ele>"
                out += "<time>\(df.string(from: Date(timeIntervalSince1970: p.t)))</time>"
                out += "<extensions><mt:speed>\(p.sp)</mt:speed><mt:hacc>\(p.ha)</mt:hacc>"
                out += "<mt:snr>\(p.sn)</mt:snr><mt:rssi>\(p.rs)</mt:rssi><mt:seq>\(p.sq)</mt:seq>"
                out += "\(p.bt.map { "<mt:batt>\($0)</mt:batt>" } ?? "")</extensions>"
                out += "</trkpt>\n"
            }
            out += "</trkseg></trk>\n"
        }
        out += "</gpx>\n"
        return write(out, name: "\(fileStem(s)).gpx")
    }

    private static func fileStem(_ s: LoadedSession) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        let safe = s.meta.name.replacingOccurrences(of: "[^A-Za-z0-9-_ ]", with: "",
                                                    options: .regularExpression)
            .replacingOccurrences(of: " ", with: "_")
        return "meshtracker_\(df.string(from: s.meta.startedAt))_\(safe)"
    }

    private static func write(_ content: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch { return nil }
    }

    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
