import SwiftUI
import MapKit

struct ContentView: View {
    @State private var model: PositionModel
    @State private var ble: BLEManager
    @State private var camera: MapCameraPosition = .automatic
    @State private var centered = false

    init() {
        let m = PositionModel()
        _model = State(initialValue: m)
        _ble = State(initialValue: BLEManager(model: m))
    }

    private var lockText: String {
        if model.hasLock { return "GPS lock" }
        if model.current != nil { return "GPS stale" }
        if model.packetCount > 0 { return "searching…" }
        return "no signal"
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $camera) {
                if model.trail.count > 1 {
                    MapPolyline(coordinates: model.trail).stroke(.blue, lineWidth: 3)
                }
                if let c = model.current {
                    Marker("Tag", systemImage: "location.fill", coordinate: c)
                        .tint(model.hasLock ? .green : .orange)
                }
            }
            .ignoresSafeArea()
            .onChange(of: model.current?.latitude) {
                guard let c = model.current, !centered else { return }
                camera = .region(MKCoordinateRegion(center: c,
                                                     latitudinalMeters: 300, longitudinalMeters: 300))
                centered = true
            }

            statsPanel
        }
    }

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ble.status).font(.headline)
                Spacer()
                Button {
                    if let c = model.current {
                        camera = .region(MKCoordinateRegion(center: c,
                                                            latitudinalMeters: 300, longitudinalMeters: 300))
                    }
                } label: { Image(systemName: "scope") }
                .disabled(model.current == nil)
            }

            HStack(alignment: .firstTextBaseline) {
                Label(lockText, systemImage: model.hasLock ? "location.fill" : "location.slash")
                    .foregroundStyle(model.hasLock ? .green : .orange)
                    .font(.subheadline)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.1f Hz", model.noveltyHz)).font(.title3).bold().monospacedDigit()
                    Text("GPS refresh").font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let c = model.current {
                Text(String(format: "%.6f, %.6f", c.latitude, c.longitude))
                    .font(.caption.monospaced())
            }

            HStack {
                Text("pkts \(model.packetCount)")
                Spacer()
                Text(String(format: "stream %.1f Hz", model.rateHz))
                Spacer()
                Text(String(format: "SNR %.0f  RSSI %d", model.lastSnr, model.lastRssi))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding()
    }
}
