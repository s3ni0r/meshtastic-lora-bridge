import SwiftUI

/// The GPS tag configuration space — a first-class screen, deliberately separate from the map.
/// Design principles: connection state always visible up top; profiles as one-tap primary
/// actions; every knob explained in plain language next to its value; consequences computed
/// (duty-cycle legality), not implied; a sticky Apply/Revert bar so pending changes are
/// unmistakable; the tag's own echoed values as the source of truth.
struct TagSetupView: View {
    let model: PositionModel
    let ble: BLEManager
    let ui: UIState

    @State private var mgr = TagConfigManager()
    @State private var draft = TagSettings()
    @State private var baseline: TagSettings? // last state confirmed by the tag
    @State private var target: UInt32?

    // MARK: - Connection routing (single PhoneAPI client per node — see BLEManager)

    private var direct: Bool {
        ble.directTag && target != nil && ble.connectedNodeNum == target
    }
    private var confirmed: TagSettings? { direct ? ble.lastConfigReply?.settings : mgr.settings }
    private var lastStatus: UInt8? {
        direct ? (ble.lastConfigReply?.op == 0x81 ? ble.lastConfigReply?.status : nil) : mgr.lastStatus
    }
    private var connected: Bool {
        direct || mgr.stage == .ready || mgr.stage == .applying
    }
    private var dirty: Bool { baseline != nil && draft != baseline }

    private var knownGpsTags: [SourceTrack] {
        model.tracks.filter { $0.source == .gpsTag }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    deviceCard
                    if baseline != nil {
                        profilesCard
                        navModeCard
                        filtersCard
                        ratesCard
                        onTagFooter
                    } else if connected {
                        ProgressView("Reading settings from the tag…")
                            .padding(.vertical, 30)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, dirty ? 90 : 20)
            }
            .navigationTitle("Tag Setup")
            .navigationBarTitleDisplayMode(.large)
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { if dirty { applyBar } }
            .onAppear { engage() }
            .onDisappear { if !direct { mgr.stop() } }
            .onChange(of: ui.setupTarget) { engage() }
            .onChange(of: confirmed) {
                if let s = confirmed {
                    baseline = s
                    draft = s
                }
            }
        }
    }

    private func engage() {
        let newTarget = ui.setupTarget ?? target ?? knownGpsTags.first?.from
        target = newTarget
        ui.setupTarget = nil
        baseline = nil
        guard let t = newTarget else { return }
        if ble.directTag && ble.connectedNodeNum == t {
            ble.sendTagConfig(Data([0x00])) // reuse the live direct link
        } else {
            mgr.begin(targetNode: t)
        }
    }

    private func apply() {
        if direct {
            ble.sendTagConfig(Data([0x01]) + draft.wire)
        } else {
            mgr.apply(draft)
        }
    }

    // MARK: - Device / connection card

    private var deviceCard: some View {
        card {
            HStack {
                Label("Device", systemImage: "sensor.tag.radiowaves.forward")
                    .font(.footnote.bold()).foregroundStyle(.secondary)
                Spacer()
            }
            if knownGpsTags.count > 1 {
                HStack(spacing: 8) {
                    ForEach(knownGpsTags) { t in
                        Button {
                            ui.setupTarget = t.from
                        } label: {
                            Text(t.shortId)
                                .font(.caption.bold())
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(target == t.from ? Color.teal.opacity(0.2) : Color(.tertiarySystemFill),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack(spacing: 10) {
                Circle()
                    .fill(connected ? .green : (mgr.stage == .scanning || mgr.stage == .connecting ? .orange : .red))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    if let t = target {
                        Text(knownGpsTags.first(where: { $0.from == t })?.title ?? "GPS tag ·\(String(format: "%08x", t).suffix(4))")
                            .font(.subheadline.bold())
                    } else {
                        Text("No GPS tag seen yet").font(.subheadline.bold())
                    }
                    Text(connectionSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                connectionAccessory
            }
        }
    }

    private var connectionSubtitle: String {
        if direct { return "Direct BLE link (shared with the live stream)" }
        switch mgr.stage {
        case .ready, .applying: return "Config link via \(mgr.deviceName)"
        case .scanning: return "Scanning for the tag over Bluetooth…"
        case .connecting, .handshaking: return "Connecting to \(mgr.deviceName)…"
        case .failed(let why): return "Connection failed — \(why)"
        case .idle: return target == nil ? "Bring a GPS tag in range, or open the Map first"
                                         : "Not connected"
        }
    }

    @ViewBuilder private var connectionAccessory: some View {
        if case .scanning = mgr.stage, !mgr.discovered.isEmpty {
            Menu {
                ForEach(mgr.discovered, id: \.id) { d in
                    Button(d.name) { mgr.connect(d.id) }
                }
            } label: {
                Text("Choose").font(.caption.bold())
            }
        } else if case .failed = mgr.stage {
            Button("Retry") { engage() }.font(.caption.bold())
        } else if mgr.stage == .connecting || mgr.stage == .handshaking {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: - Deployment profiles (one-tap primary actions)

    private struct Profile {
        let name: String
        let subtitle: String
        let icon: String
        let fixMs: UInt16
        let spacingMs: UInt16
    }

    private let profiles: [Profile] = [
        .init(name: "France · EU868", subtitle: "4 Hz GPS · 2 Hz radio — legal sustained",
              icon: "checkmark.shield.fill", fixMs: 250, spacingMs: 500),
        .init(name: "Bench / US", subtitle: "4 Hz GPS · fast radio — max fidelity",
              icon: "hare.fill", fixMs: 250, spacingMs: 150),
    ]

    private var profilesCard: some View {
        card {
            sectionHeader("Deployment profile", "square.grid.2x2")
            HStack(spacing: 10) {
                ForEach(profiles, id: \.name) { p in
                    let active = draft.fixIntervalMs == p.fixMs && draft.txSpacingMs == p.spacingMs
                    Button {
                        draft.fixIntervalMs = p.fixMs
                        draft.txSpacingMs = p.spacingMs
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Image(systemName: p.icon)
                                .font(.system(size: 18))
                                .foregroundStyle(active ? .white : .teal)
                            Text(p.name).font(.footnote.bold())
                            Text(p.subtitle).font(.caption2)
                                .foregroundStyle(active ? .white.opacity(0.85) : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(active ? Color.teal : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(active ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Navigation mode (card grid)

    private var navModeCard: some View {
        card {
            sectionHeader("Navigation mode", "location.north.line")
            Text("Tunes the GPS chip's motion model to the activity.")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(kNavModes) { m in
                    let active = draft.navMode == m.mode
                    Button {
                        if m.supported { draft.navMode = m.mode }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Image(systemName: m.icon).font(.system(size: 15))
                                Text(m.name).font(.footnote.bold())
                                Spacer()
                                if active { Image(systemName: "checkmark.circle.fill").font(.system(size: 14)) }
                            }
                            Text(m.detail).font(.caption2)
                                .foregroundStyle(active ? .white.opacity(0.85) : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 4) {
                                badge(m.egnos ? "EGNOS ✓" : "no EGNOS",
                                      color: m.egnos ? .green : .orange, active: active)
                                if !m.supported {
                                    badge("unsupported", color: .red, active: active)
                                }
                            }
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                        .background(active ? Color.indigo : Color(.tertiarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(active ? .white : .primary)
                        .opacity(m.supported ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .disabled(!m.supported)
                }
            }
        }
    }

    private func badge(_ text: String, color: Color, active: Bool) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((active ? Color.white.opacity(0.25) : color.opacity(0.15)), in: Capsule())
            .foregroundStyle(active ? .white : color)
    }

    // MARK: - Precision filters

    private var filtersCard: some View {
        card {
            sectionHeader("Precision filters", "scope")
            knobSlider(title: "Freeze position when slower than",
                       value: Binding(get: { Double(draft.staticThrDms) },
                                      set: { draft.staticThrDms = UInt8($0) }),
                       range: 0...20,
                       display: draft.staticThrDms == 0 ? "off" : String(format: "%.1f m/s", Double(draft.staticThrDms) / 10),
                       caption: "Kills GPS wander while parked; the chip locks the position below this speed.")
            Divider()
            knobSlider(title: "Ignore satellites weaker than",
                       value: Binding(get: { Double(draft.minSnr) },
                                      set: { draft.minSnr = UInt8($0) }),
                       range: 9...37,
                       display: "\(draft.minSnr) dB",
                       caption: "Higher = fewer multipath ghosts, slightly slower first fix.")
            Divider()
            knobSlider(title: "Ignore satellites lower than",
                       value: Binding(get: { Double(draft.elevMaskDeg) },
                                      set: { draft.elevMaskDeg = UInt8($0) }),
                       range: 0...30,
                       display: "\(draft.elevMaskDeg)° above horizon",
                       caption: "Low-horizon satellites cause most urban drift.")
        }
    }

    private func knobSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>,
                            display: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.footnote)
                Spacer()
                Text(display).font(.footnote.bold().monospacedDigit()).foregroundStyle(.teal)
            }
            Slider(value: value, in: range, step: 1)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Rates + computed consequences

    private var dutyPercent: Double {
        // ShortFast airtime for our 40 B packet ≈ 45 ms (docs/CAPACITY.md) — the EU-relevant case.
        45.0 / Double(draft.txSpacingMs) * 100
    }

    private var ratesCard: some View {
        card {
            sectionHeader("Rates", "speedometer")
            HStack {
                Text("GPS fixes").font(.footnote)
                Spacer()
                Picker("", selection: $draft.fixIntervalMs) {
                    Text("1 Hz").tag(UInt16(1000))
                    Text("2 Hz").tag(UInt16(500))
                    Text("4 Hz").tag(UInt16(250))
                    Text("5 Hz").tag(UInt16(200))
                    Text("10 Hz").tag(UInt16(100))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            HStack {
                Text("Radio sends").font(.footnote)
                Spacer()
                Picker("", selection: $draft.txSpacingMs) {
                    Text("2 Hz").tag(UInt16(500))
                    Text("4 Hz").tag(UInt16(250))
                    Text("6.7 Hz").tag(UInt16(150))
                    Text("10 Hz").tag(UInt16(100))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }
            HStack(spacing: 6) {
                Image(systemName: dutyPercent <= 10 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(dutyPercent <= 10 ? .green : .orange)
                Text(dutyPercent <= 10
                     ? String(format: "≈%.0f%% duty cycle — EU868-legal sustained", dutyPercent)
                     : String(format: "≈%.0f%% duty cycle — bench / US only (EU limit is 10%%)", dutyPercent))
                    .font(.caption)
                Spacer()
            }
            .padding(8)
            .background((dutyPercent <= 10 ? Color.green : Color.orange).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8))
            Text("Fix rate is what the GPS measures; radio rate is what goes over LoRa. A 4 Hz fix with 2 Hz radio still sends positions at most 250 ms old.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - On-tag footer + apply bar

    private var onTagFooter: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.icloud")
            if let b = baseline {
                Text("On tag now: \(kNavModes.first(where: { $0.mode == b.navMode })?.name ?? "mode \(b.navMode)") · freeze \(b.staticThrDms == 0 ? "off" : String(format: "%.1f m/s", Double(b.staticThrDms) / 10)) · SNR \(b.minSnr) dB · elev \(b.elevMaskDeg)° · \(1000 / max(b.fixIntervalMs, 1)) Hz fix · \(String(format: "%.1f", 1000.0 / Double(max(b.txSpacingMs, 1)))) Hz radio")
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var applyBar: some View {
        HStack(spacing: 12) {
            Button {
                if let b = baseline { draft = b }
            } label: {
                Text("Revert").font(.subheadline.bold())
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Color(.tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)
            Button {
                apply()
            } label: {
                HStack(spacing: 6) {
                    if mgr.stage == .applying { ProgressView().controlSize(.small).tint(.white) }
                    Text("Apply to tag").font(.subheadline.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.teal, in: Capsule())
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!connected)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            if let st = lastStatus, st != 0 {
                Text("Tag rejected the settings (status \(st))")
                    .font(.caption2.bold()).foregroundStyle(.red)
                    .offset(y: -18)
            }
        }
    }

    // MARK: - Card scaffolding

    private func sectionHeader(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.footnote.bold())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
