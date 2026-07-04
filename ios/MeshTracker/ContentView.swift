import SwiftUI
import MapKit

private func sourceColor(_ s: PacketSource) -> Color {
    switch s {
    case .bridge: return .blue
    case .gpsTag: return .teal
    case .legacy: return .gray
    }
}

private func sourceSymbol(_ s: PacketSource) -> String {
    switch s {
    case .bridge: return "paperplane.fill"
    case .gpsTag: return "location.circle.fill"
    case .legacy: return "questionmark.circle"
    }
}

struct ContentView: View {
    @State private var model: PositionModel
    @State private var ble: BLEManager
    @State private var camera: MapCameraPosition = .automatic
    @State private var follow = true          // camera tracks the selected tag in realtime
    @State private var camDistance: Double = 600 // user zoom, preserved while following
    @State private var phone = PhoneLocation()

    init() {
        let m = PositionModel()
        _model = State(initialValue: m)
        _ble = State(initialValue: BLEManager(model: m))
    }

    private func distanceString(_ m: Double) -> String {
        m < 1000 ? "\(Int(m)) m" : String(format: "%.2f km", m / 1000)
    }

    private func lockText(_ t: SourceTrack?) -> String {
        guard let t else { return model.packetCount > 0 ? "searching…" : "no signal" }
        if t.hasLock { return "GPS lock" }
        if t.current != nil { return "GPS stale" }
        return "searching…"
    }

    private func centerOnActive() {
        guard let c = model.active?.current else { return }
        camera = .camera(MapCamera(centerCoordinate: c, distance: camDistance))
    }

    var body: some View {
        // Register a dependency on the packet counter: SourceTrack is a reference type, so this
        // is what guarantees the map content re-evaluates for every packet of a 10 Hz stream.
        let _ = model.revision
        return ZStack(alignment: .top) {
            Map(position: $camera) {
                // Every tag heard gets its own colored trail + marker — that's how the bridge tag,
                // the GPS tag and anything else stay visually distinct on one map.
                ForEach(model.tracks) { track in
                    if track.trail.count > 1 {
                        MapPolyline(coordinates: track.trail)
                            .stroke(sourceColor(track.source), lineWidth: 3)
                    }
                    if let c = track.current {
                        Marker(track.title, systemImage: sourceSymbol(track.source), coordinate: c)
                            .tint(track.hasLock ? sourceColor(track.source) : .orange)
                    }
                }
            }
            .ignoresSafeArea()
            .onMapCameraChange(frequency: .continuous) { ctx in
                camDistance = ctx.camera.distance // remember the user's zoom level
            }
            .onChange(of: model.active?.current?.latitude) {
                // Realtime tracking: short linear glide between 10 Hz fixes reads as continuous motion.
                if follow { withAnimation(.linear(duration: 0.1)) { centerOnActive() } }
            }
            .onChange(of: model.selectedFrom) {
                if follow { centerOnActive() } // chip tap -> jump to that tag
            }

            statsPanel
        }
    }

    private var subtitle: String {
        switch model.active?.source {
        case .bridge: return "Dronetag · Remote ID → LoRa"
        case .gpsTag: return "T1000-E · internal GPS → LoRa"
        default: return "waiting for a tag…"
        }
    }

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(ble.status).font(.headline)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    follow.toggle()
                    if follow { centerOnActive() }
                } label: { Image(systemName: follow ? "location.fill" : "location") }
                .tint(follow ? .blue : .secondary)
                .disabled(model.active?.current == nil && !follow)
            }

            if !model.tracks.isEmpty {
                sourceChips
            }

            let a = model.active

            HStack(alignment: .firstTextBaseline) {
                Label(lockText(a), systemImage: (a?.hasLock ?? false) ? "location.fill" : "location.slash")
                    .foregroundStyle((a?.hasLock ?? false) ? .green : .orange)
                    .font(.subheadline)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.1f Hz", a?.noveltyHz ?? 0)).font(.title3).bold().monospacedDigit()
                    Text("GPS refresh").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let c = a?.current {
                Text(String(format: "%.6f, %.6f", c.latitude, c.longitude))
                    .font(.caption.monospaced())
            }

            if let d = phone.distance(to: a?.current) {
                Label(distanceString(d) + " from you", systemImage: "ruler")
                    .font(.subheadline).bold()
            }

            HStack(spacing: 14) {
                Label("\(a?.speedKmh ?? 0) km/h", systemImage: "speedometer")
                HStack(spacing: 2) {
                    Image(systemName: "location.north.fill").rotationEffect(.degrees(a?.heading ?? 0))
                    Text("\(Int(a?.heading ?? 0))°")
                }
                Label("\(a?.altitude ?? 0) m", systemImage: "mountain.2.fill")
                Spacer()
                Text((a?.hacc ?? 0) > 0 ? "±\(a!.hacc) m" : "±— m")
            }
            .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("pkts \(a?.packetCount ?? 0)")
                Spacer()
                Text(String(format: "stream %.1f Hz", a?.rateHz ?? 0))
                Spacer()
                Text(String(format: "SNR %.0f  RSSI %d", a?.lastSnr ?? 0, a?.lastRssi ?? 0))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding()
    }

    /// One chip per tag heard. Tap to pin the panel (and auto-centering) to that tag; tap again to
    /// go back to follow-latest. The dot dims when a tag goes quiet for >10 s.
    private var sourceChips: some View {
        HStack(spacing: 8) {
            ForEach(model.tracks) { track in
                let pinned = model.selectedFrom == track.from
                let isActive = model.active?.from == track.from
                let quiet = (track.lastHeard.map { Date().timeIntervalSince($0) > 10 }) ?? true
                Button {
                    model.selectedFrom = pinned ? nil : track.from
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(sourceColor(track.source))
                            .frame(width: 8, height: 8)
                            .opacity(quiet ? 0.3 : 1)
                        Text(track.title).font(.caption2).bold()
                        Text(String(format: "%.1f Hz", track.noveltyHz))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        if pinned { Image(systemName: "pin.fill").font(.system(size: 8)) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(isActive ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.clear),
                                in: Capsule())
                    .overlay(Capsule().strokeBorder(sourceColor(track.source).opacity(isActive ? 0.8 : 0.3)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
