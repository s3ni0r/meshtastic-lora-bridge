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
            HStack(spacing: 12) {
                Label(model.hasLock ? "GPS lock" : "no lock",
                      systemImage: model.hasLock ? "location.fill" : "location.slash")
                    .foregroundStyle(model.hasLock ? .green : .orange)
                Spacer()
                Text(String(format: "%.1f Hz", model.rateHz)).monospacedDigit()
            }
            .font(.subheadline)
            if let c = model.current {
                Text(String(format: "%.6f, %.6f", c.latitude, c.longitude))
                    .font(.caption.monospaced())
            }
            HStack(spacing: 14) {
                Label("\(model.speedKmh) km/h", systemImage: "speedometer")
                Image(systemName: "location.north.fill")
                    .imageScale(.small)
                    .rotationEffect(.degrees(model.heading))
                Text("\(model.altitude) m")
                Spacer()
                Label("\(model.sats)", systemImage: "antenna.radiowaves.left.and.right")
                Label(model.battery > 100 ? "—%" : "\(model.battery)%",
                      systemImage: model.charging ? "bolt.fill" : "battery.50")
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("pkts \(model.packetCount)")
                Spacer()
                Text(String(format: "SNR %.1f   RSSI %d", model.lastSnr, model.lastRssi))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding()
    }
}
