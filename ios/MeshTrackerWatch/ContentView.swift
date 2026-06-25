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

            if bridge.running {
                Button("Stop") {
                    if bridge.testing { bridge.stopTest() } else { bridge.stop() }
                }
                .tint(.red)
            } else {
                Button("Start tracking") { bridge.start() }
                    .tint(.green)
                HStack(spacing: 6) {
                    Button("Test 4Hz") { bridge.startTest(hz: 4) }
                    Button("10Hz") { bridge.startTest(hz: 10) }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 4)
    }
}
