import SwiftUI

struct ContentView: View {
    @State private var bridge = WatchBridge()

    var body: some View {
        VStack(spacing: 6) {
            Text(bridge.status)
                .font(.headline)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)

            HStack(spacing: 6) {
                Image(systemName: bridge.bleConnected
                      ? "antenna.radiowaves.left.and.right"
                      : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(bridge.bleConnected ? .green : .secondary)
                Text("sent \(bridge.sent)").font(.caption2).monospacedDigit()
            }

            if let f = bridge.lastFix {
                Text(String(format: "%.5f, %.5f", f.coordinate.latitude, f.coordinate.longitude))
                    .font(.system(.caption2, design: .monospaced))
                Text(String(format: "±%.0fm   %.0f km/h", f.horizontalAccuracy, max(0, f.speed) * 3.6))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Button(bridge.running ? "Stop" : "Start tracking") {
                if bridge.running { bridge.stop() } else { bridge.start() }
            }
            .tint(bridge.running ? .red : .green)
        }
        .padding(.horizontal, 4)
    }
}
