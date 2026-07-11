import SwiftUI
import MapKit
import UIKit

func sourceColor(_ s: PacketSource) -> Color {
    switch s {
    case .bridge: return .blue
    case .gpsTag: return .teal
    case .legacy: return .gray
    }
}

func sourceSymbol(_ s: PacketSource) -> String {
    switch s {
    case .bridge: return "paperplane.fill"
    case .gpsTag: return "location.circle.fill"
    case .legacy: return "questionmark.circle"
    }
}

/// Value snapshot of a track for Map content. Map's content diffing can skip re-evaluating rows
/// whose ForEach element is an unchanged REFERENCE (SourceTrack is a class mutated in place), which
/// froze the markers. Fresh value structs per body pass make every coordinate change visible.
private struct TrackSnapshot: Identifiable {
    let id: UInt32
    let source: PacketSource
    let title: String
    let current: CLLocationCoordinate2D?
    let trail: [CLLocationCoordinate2D]
    let hasLock: Bool
    let heading: Double
    let focused: Bool
}

struct ContentView: View {
    @State private var model: PositionModel
    @State private var ble: BLEManager
    @State private var camera: MapCameraPosition = .automatic
    @State private var follow = true          // keep the focused tag in view (edge-triggered)
    @State private var camDistance: Double = 400
    @State private var camRegion: MKCoordinateRegion?
    @State private var centeredOnce = false
    @State private var panelExpanded = true
    @State private var configTarget: SourceTrack? // GNSS settings sheet (GPS tags only)
    @State private var library = SessionLibrary()
    @State private var analysis = AnalysisModel()
    @State private var showLibrary = false
    @State private var uiTick = Date() // drives the REC elapsed readout
    @State private var phone = PhoneLocation()
    private let playTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    @AppStorage("mapStyleChoice") private var mapStyleChoice = 0 // 0 standard / 1 hybrid / 2 satellite

    init() {
        let m = PositionModel()
        _model = State(initialValue: m)
        _ble = State(initialValue: BLEManager(model: m))
    }

    // MARK: - Camera

    private func centerOnActive() {
        guard let c = model.active?.current else { return }
        camera = .camera(MapCamera(centerCoordinate: c, distance: camDistance))
    }

    /// Follow = the ICON moves and traces its path on a still map; the camera only glides when the
    /// tag nears the edge of the visible region (outside the inner 70%).
    private func recenterIfNeeded() {
        guard let c = model.active?.current else { return }
        if !centeredOnce {
            centeredOnce = true
            camera = .camera(MapCamera(centerCoordinate: c, distance: camDistance))
            return
        }
        guard let r = camRegion else { return }
        let offEdge = abs(c.latitude - r.center.latitude) > r.span.latitudeDelta * 0.35 ||
                      abs(c.longitude - r.center.longitude) > r.span.longitudeDelta * 0.35
        if offEdge {
            withAnimation(.easeInOut(duration: 0.4)) { centerOnActive() }
        }
    }

    /// Frame every visible tag (and the phone) in one view.
    private func fitAll() {
        var coords = model.tracks.filter { $0.isVisible }.compactMap { $0.current }
        if let me = phone.coordinate { coords.append(me) }
        for sess in analysis.overlays { for tr in sess.tracks { coords += tr.coords } }
        if let open = analysis.open { for tr in open.tracks { coords += tr.coords } }
        guard !coords.isEmpty else { return }
        var minLat = coords[0].latitude, maxLat = minLat
        var minLon = coords[0].longitude, maxLon = minLon
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.5, 0.003),
                                    longitudeDelta: max((maxLon - minLon) * 1.5, 0.003))
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        follow = false
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    private var mapStyle: MapStyle {
        switch mapStyleChoice {
        case 1: return .hybrid(elevation: .flat)
        case 2: return .imagery(elevation: .flat)
        default: return .standard(elevation: .flat, pointsOfInterest: .excludingAll)
        }
    }

    private func distanceString(_ m: Double) -> String {
        m < 1000 ? "\(Int(m)) m" : String(format: "%.2f km", m / 1000)
    }

    // MARK: - Body

    var body: some View {
        // Dependency on the packet counter: guarantees body re-evaluates for every packet.
        let _ = model.revision
        let snaps = model.tracks.filter { $0.isVisible }.map { t in
            TrackSnapshot(id: t.from, source: t.source, title: t.title, current: t.current,
                          trail: t.trail, hasLock: t.hasLock, heading: t.heading,
                          focused: model.active?.from == t.from)
        }
        return ZStack(alignment: .top) {
            Map(position: $camera, bounds: MapCameraBounds(minimumDistance: 15, maximumDistance: 2_000_000)) {
                UserAnnotation()
                // Recorded projections render UNDER the live stream: static overlays first, then
                // the session under the scrubber with its playhead markers + fix scatter.
                ForEach(analysis.overlays) { sess in
                    sessionContent(sess, isOpen: false)
                }
                if let openSess = analysis.open {
                    sessionContent(openSess, isOpen: true)
                    playheadContent(openSess)
                }
                ForEach(snaps) { track in
                    if track.trail.count > 1 {
                        MapPolyline(coordinates: track.trail)
                            .stroke(sourceColor(track.source).opacity(track.focused ? 0.95 : 0.5),
                                    style: StrokeStyle(lineWidth: track.focused ? 4 : 2.5,
                                                       lineCap: .round, lineJoin: .round))
                    }
                    if let c = track.current {
                        Annotation(track.title, coordinate: c, anchor: .center) {
                            // Every tag gets a live heading arrow; the focused one is just bigger.
                            ZStack {
                                Circle()
                                    .fill(track.hasLock ? sourceColor(track.source) : .orange)
                                    .frame(width: track.focused ? 26 : 20, height: track.focused ? 26 : 20)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: track.focused ? 3 : 2))
                                    .shadow(color: .black.opacity(0.35), radius: track.focused ? 5 : 2)
                                Image(systemName: "location.north.fill")
                                    .font(.system(size: track.focused ? 10 : 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .rotationEffect(.degrees(track.heading))
                            }
                        }
                    }
                }
            }
            .mapStyle(mapStyle)
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .ignoresSafeArea()
            .onMapCameraChange(frequency: .continuous) { ctx in
                camDistance = ctx.camera.distance
                camRegion = ctx.region
            }
            .onChange(of: model.active?.current?.latitude) {
                if follow { recenterIfNeeded() }
            }
            .onChange(of: model.selectedFrom) {
                withAnimation(.easeInOut(duration: 0.4)) { centerOnActive() }
            }

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    statusCapsule
                    Spacer()
                    mapControlsColumn
                }
                .padding(.horizontal, 12)
                Spacer()
                if !analysis.overlays.isEmpty {
                    overlayLegend
                }
                if analysis.open != nil {
                    analysisPanel
                } else {
                    bottomPanel
                }
            }
        }
        .sheet(item: $configTarget) { t in
            TagConfigSheet(track: t, ble: ble)
        }
        .sheet(isPresented: $showLibrary) {
            SessionLibraryView(library: library, analysis: analysis)
        }
    }

    // MARK: - Top status

    private var connected: Bool { ble.status.hasPrefix("Connected") }

    private var recElapsed: String {
        guard let t0 = model.recorder.startedAt else { return "0:00" }
        let s = Int(uiTick.timeIntervalSince(t0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var statusCapsule: some View {
        HStack(spacing: 8) {
            Circle().fill(connected ? .green : .orange).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 0) {
                Text("MeshTracker").font(.footnote.bold())
                Text(ble.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.recorder.isRecording {
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text(recElapsed).font(.caption.bold().monospacedDigit())
                    Text("\(model.recorder.pointCount)p").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    // MARK: - Map controls (right column)

    private var mapControlsColumn: some View {
        VStack(spacing: 10) {
            Menu {
                Picker("Map style", selection: $mapStyleChoice) {
                    Label("Standard", systemImage: "map").tag(0)
                    Label("Hybrid", systemImage: "map.fill").tag(1)
                    Label("Satellite", systemImage: "globe.europe.africa.fill").tag(2)
                }
            } label: {
                controlIcon("square.3.layers.3d")
            }
            Button {
                follow.toggle()
                if follow { withAnimation(.easeInOut(duration: 0.4)) { centerOnActive() } }
            } label: {
                controlIcon(follow ? "location.fill" : "location")
                    .foregroundStyle(follow ? Color.accentColor : Color.primary)
            }
            Button { fitAll() } label: {
                controlIcon("arrow.up.left.and.arrow.down.right")
            }
            Button { showLibrary = true } label: {
                controlIcon("tray.full")
            }
        }
    }

    private func controlIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 40, height: 40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    // MARK: - Bottom panel

    private var recordButton: some View {
        Button {
            if model.recorder.isRecording {
                model.recorder.stop()
                library.reload()
            } else {
                model.recorder.start()
            }
        } label: {
            Image(systemName: model.recorder.isRecording ? "stop.circle.fill" : "record.circle")
                .font(.system(size: 30))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, isActive: model.recorder.isRecording)
        }
        .buttonStyle(.plain)
    }

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Capsule().fill(.tertiary).frame(width: 38, height: 5).padding(.top, 8)
                HStack(spacing: 10) {
                    recordButton
                    focusSummaryRow
                }
                .padding(.horizontal, 14).padding(.bottom, panelExpanded ? 4 : 12)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.spring(duration: 0.35)) { panelExpanded.toggle() } }

            if panelExpanded {
                VStack(spacing: 10) {
                    Divider()
                    tagList
                    if model.active != nil {
                        metricsGrid
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var focusSummaryRow: some View {
        HStack(spacing: 10) {
            if let a = model.active {
                Image(systemName: sourceSymbol(a.source))
                    .foregroundStyle(sourceColor(a.source))
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(a.title).font(.subheadline.bold())
                        if a.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                        if model.selectedFrom == a.from { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Text(a.hasLock ? "GPS lock" : (a.current != nil ? "GPS stale" : "searching…"))
                        .font(.caption2)
                        .foregroundStyle(a.hasLock ? .green : .orange)
                }
                Spacer()
                if let d = phone.distance(to: a.current) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(distanceString(d)).font(.subheadline.bold().monospacedDigit())
                        Text("away").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.1f Hz", a.noveltyHz)).font(.subheadline.bold().monospacedDigit())
                    Text("refresh").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Text(model.packetCount > 0 ? "Waiting for a position…" : "Waiting for tags…")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            Image(systemName: panelExpanded ? "chevron.down" : "chevron.up")
                .font(.caption.bold()).foregroundStyle(.tertiary)
        }
    }

    private var tagList: some View {
        VStack(spacing: 2) {
            ForEach(model.tracks) { track in
                tagRow(track)
            }
        }
    }

    private func tagRow(_ track: SourceTrack) -> some View {
        let pinned = model.selectedFrom == track.from
        let isActive = model.active?.from == track.from
        let quiet = (track.lastHeard.map { Date().timeIntervalSince($0) > 10 }) ?? true
        return HStack(spacing: 10) {
            Button {
                // Tap = focus this tag (auto-reveals it); tap the pinned row again = follow-latest.
                if pinned {
                    model.selectedFrom = nil
                } else {
                    model.selectedFrom = track.from
                    if !track.isVisible { model.toggleVisible(track) }
                }
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(sourceColor(track.source).opacity(quiet ? 0.25 : 1))
                            .frame(width: 12, height: 12)
                        if quiet { Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 12, height: 12) }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(track.title).font(.footnote.weight(isActive ? .bold : .regular))
                        Text(quiet ? "quiet"
                             : track.hacc > 0
                             ? String(format: "%.1f Hz · ±%d m · %d pkts", track.noveltyHz, track.hacc, track.packetCount)
                             : String(format: "%.1f Hz · ±— · %d pkts", track.noveltyHz, track.packetCount))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { model.toggleFavorite(track) } label: {
                Image(systemName: track.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(track.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            Button { model.toggleVisible(track) } label: {
                Image(systemName: track.isVisible ? "eye.fill" : "eye.slash")
                    .foregroundStyle(track.isVisible ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            if track.source == .gpsTag {
                Button { configTarget = track } label: {
                    Image(systemName: "gearshape.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(isActive ? AnyShapeStyle(sourceColor(track.source).opacity(0.12)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private var metricsGrid: some View {
        let a = model.active!
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return VStack(spacing: 8) {
            if let c = a.current {
                Text(String(format: "%.6f, %.6f", c.latitude, c.longitude))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LazyVGrid(columns: cols, spacing: 8) {
                metricTile("speedometer", String(format: "%d", a.speedKmh), "km/h")
                metricTile("safari", String(format: "%d°", Int(a.heading)), "heading")
                metricTile("mountain.2.fill", "\(a.altitude)", "alt m")
                metricTile("scope", a.hacc > 0 ? "±\(a.hacc)" : "±—", "acc m")
                metricTile("antenna.radiowaves.left.and.right", String(format: "%.0f", a.lastSnr), "SNR dB")
                metricTile("dot.radiowaves.right", "\(a.lastRssi)", "RSSI")
            }
            HStack {
                Text(String(format: "stream %.1f Hz", a.rateHz))
                Spacer()
                Text("pkts \(a.packetCount)")
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func metricTile(_ icon: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.bold().monospacedDigit())
            Text(unit).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Recorded-session projection (RAW: every fix as received, no smoothing/decimation)

    @MapContentBuilder
    private func sessionContent(_ sess: LoadedSession, isOpen: Bool) -> some MapContent {
        ForEach(Array(sess.tracks.enumerated()), id: \.element.id) { idx, tr in
            let color = analysis.color(sess, trackIdx: idx)
            if tr.coords.count > 1 {
                MapPolyline(coordinates: tr.coords)
                    .stroke(color.opacity(isOpen ? 0.9 : 0.55),
                            style: StrokeStyle(lineWidth: isOpen ? 3.5 : 2.5, lineCap: .round, lineJoin: .round))
            }
            if let first = tr.coords.first {
                Annotation("", coordinate: first, anchor: .center) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(.white, color)
                }
            }
            if let last = tr.coords.last {
                Annotation("", coordinate: last, anchor: .center) {
                    Image(systemName: "flag.checkered.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(.white, color)
                }
            }
        }
    }

    /// The moment under the scrubber: last real fix <= t per tag (step, never interpolated),
    /// the tag's REPORTED accuracy as a circle, and the raw fix scatter for +-15 s around t.
    @MapContentBuilder
    private func playheadContent(_ sess: LoadedSession) -> some MapContent {
        let absT = sess.meta.startedAt.timeIntervalSince1970 + analysis.playhead
        ForEach(Array(sess.tracks.enumerated()), id: \.element.id) { idx, tr in
            let color = analysis.color(sess, trackIdx: idx)
            let win = tr.windowRange(absT - 15, absT + 15)
            ForEach(win, id: \.self) { i in
                let p = tr.points[i]
                if p.la != 0 || p.lo != 0 {
                    Annotation("", coordinate: .init(latitude: p.la, longitude: p.lo), anchor: .center) {
                        Circle().fill(color.opacity(0.6)).frame(width: 5, height: 5)
                    }
                }
            }
            if let i = tr.lastIndex(atOrBefore: absT) {
                let p = tr.points[i]
                if p.la != 0 || p.lo != 0 {
                    if p.ha > 0 {
                        MapCircle(center: .init(latitude: p.la, longitude: p.lo), radius: Double(p.ha))
                            .foregroundStyle(color.opacity(0.10))
                            .stroke(color.opacity(0.5), lineWidth: 1)
                    }
                    Annotation(tr.title, coordinate: .init(latitude: p.la, longitude: p.lo), anchor: .center) {
                        Circle().fill(color).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                            .shadow(color: .black.opacity(0.4), radius: 3)
                    }
                }
            }
        }
    }

    private var overlayLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(analysis.overlays) { sess in
                    HStack(spacing: 6) {
                        HStack(spacing: 3) {
                            ForEach(Array(sess.tracks.enumerated()), id: \.element.id) { idx, _ in
                                Capsule().fill(analysis.color(sess, trackIdx: idx))
                                    .frame(width: 12, height: 4)
                            }
                        }
                        Text(sess.meta.name).font(.caption2.bold()).lineLimit(1)
                        Button { analysis.toggleOverlay(sess) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Analysis panel (scrubber)

    private func fmtClock(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.S"
        return df.string(from: d)
    }

    private func fmtDur(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private var analysisPanel: some View {
        let sess = analysis.open!
        let duration = max(sess.meta.duration, 1)
        let absT = sess.meta.startedAt.timeIntervalSince1970 + analysis.playhead
        return VStack(spacing: 8) {
            HStack {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(sess.meta.name).font(.subheadline.bold())
                    Text("\(sess.meta.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(fmtDur(duration))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    analysis.closeOpen()
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(sess.tracks.enumerated()), id: \.element.id) { idx, tr in
                        readoutCard(tr, color: analysis.color(sess, trackIdx: idx), absT: absT)
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    if analysis.playhead >= duration { analysis.playhead = 0 }
                    analysis.playing.toggle()
                } label: {
                    Image(systemName: analysis.playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                }
                .buttonStyle(.plain)
                Slider(value: Binding(get: { analysis.playhead },
                                      set: { analysis.playhead = $0; analysis.playing = false }),
                       in: 0...duration)
                Button {
                    analysis.rate = analysis.rate >= 10 ? 1 : (analysis.rate >= 4 ? 10 : 4)
                } label: {
                    Text("\(Int(analysis.rate))×").font(.callout.bold().monospacedDigit())
                        .frame(width: 38, height: 30)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            HStack {
                Text(fmtClock(Date(timeIntervalSince1970: absT))).font(.caption.monospacedDigit()).bold()
                Spacer()
                Text("\(fmtDur(analysis.playhead)) / \(fmtDur(duration))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// Raw readout for one tag at the playhead: the exact packet contents, plus its age vs t.
    private func readoutCard(_ tr: LoadedTrack, color: Color, absT: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(tr.title).font(.caption.bold())
            }
            if let i = tr.lastIndex(atOrBefore: absT), tr.points[i].la != 0 || tr.points[i].lo != 0 {
                let p = tr.points[i]
                Text(String(format: "%.6f, %.6f", p.la, p.lo)).font(.caption2.monospaced())
                HStack(spacing: 8) {
                    Text("±\(p.ha)m")
                    Text("\(p.sp) km/h")
                    Text(String(format: "%.1fs old", absT - p.t)).foregroundStyle(.secondary)
                }
                .font(.caption2.monospacedDigit())
                HStack(spacing: 8) {
                    Text(String(format: "SNR %.0f", p.sn))
                    Text("RSSI \(p.rs)")
                    Text("seq \(p.sq)")
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("no fix yet").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
