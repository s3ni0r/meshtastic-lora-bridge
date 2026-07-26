import SwiftUI
import Observation

/// Cross-tab UI state: which tab is showing, and which tag the setup screen should target
/// (set by the gear shortcut on the map's tag list).
@Observable
final class UIState {
    var tab = 0
    var setupTarget: UInt32?
}

/// Two top-level destinations: the tracking/analysis MAP, and the GPS tag CONFIGURATION space.
/// Configuration is a first-class screen, not a sheet buried behind an icon.
struct RootView: View {
    @State private var model: PositionModel
    @State private var ble: BLEManager
    @State private var ui = UIState()

    init() {
        let m = PositionModel()
        _model = State(initialValue: m)
        _ble = State(initialValue: BLEManager(model: m))
#if targetEnvironment(simulator)
        // The simulator has no Bluetooth, so the whole cockpit would render empty. Seed a
        // believable bench so UI work can iterate without hardware: a Base link, a LISTENING
        // GPS tag and a DEAF bridge (exercises the deaf-route warning path). Guarded to the
        // simulator target only — device builds never contain this.
        m.seedSimulatorDemo()
        _ble.wrappedValue.seedSimulatorDemo()
#endif
    }

    var body: some View {
        TabView(selection: Binding(get: { ui.tab }, set: { ui.tab = $0 })) {
            ContentView(model: model, ble: ble, ui: ui)
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(0)
            TagSetupView(model: model, ble: ble, ui: ui)
                .tabItem { Label("Tag Setup", systemImage: "slider.horizontal.3") }
                .tag(1)
        }
    }
}

@main
struct MeshTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
