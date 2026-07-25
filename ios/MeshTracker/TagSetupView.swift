import SwiftUI

/// The GPS tag configuration space — a first-class screen, deliberately separate from the map.
/// Design principles: connection state always visible up top; profiles as one-tap primary
/// actions; every knob explained in plain language next to its value; consequences computed
/// (duty-cycle legality), not implied; a sticky Apply/Revert bar so pending changes are
/// unmistakable; the tag's own echoed values as the source of truth.
/// One simulator program segment (speed × duration); the program persists across launches.
struct SimSeg: Codable, Identifiable, Equatable {
    var id = UUID()
    var speedKmh: Double
    var durS: Double

    static func loadSaved() -> [SimSeg] {
        if let d = UserDefaults.standard.data(forKey: "simProgram"),
           let s = try? JSONDecoder().decode([SimSeg].self, from: d), !s.isEmpty {
            return s
        }
        // Default rehearses one full adaptive cycle: idle -> instant fast -> back to idle.
        return [SimSeg(speedKmh: 1, durS: 30), SimSeg(speedKmh: 12, durS: 20)]
    }

    static func save(_ segs: [SimSeg]) {
        if let d = try? JSONEncoder().encode(segs) {
            UserDefaults.standard.set(d, forKey: "simProgram")
        }
    }
}

struct TagSetupView: View {
    let model: PositionModel
    let ble: BLEManager
    let ui: UIState

    @State private var mgr = TagConfigManager()
    @State private var draft = TagSettings()
    @State private var baseline: TagSettings? // last state confirmed by the tag
    @State private var target: UInt32?
    @State private var signalSeq = UInt8.random(in: 0...255) // dedupe counter for op 0x03
    @State private var heldMode: UInt8? // 0 = holding CALIBRATION (auto-refresh its TTL); nil = not commanding
    @State private var simSegs: [SimSeg] = SimSeg.loadSaved()
    @State private var simLoop = true
    @State private var simCommanded: UInt8 = 0 // last commanded sim source (for TTL keep-alive)
    private let ttlRefresh = Timer.publish(every: 45, on: .main, in: .common).autoconnect()

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
                    // Mode + signals ride the MAIN link (Base-relayed LoRa downlink, or direct) —
                    // they don't need the settings handshake, only a link and a target.
                    if target != nil && ble.connectedNodeNum != 0 {
                        modeCard
                        simulatorCard
                        signalsCard
                    }
                    if baseline != nil {
                        profilesCard
                        navModeCard
                        filtersCard
                        ratesCard
                        if draft.isV3 {
                            adaptiveCard
                        }
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
            .onChange(of: ui.setupTarget) {
                if ui.setupTarget != nil { engage() } // engage() nils it — don't re-trigger
            }
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
            ble.sendTagConfig(Data([0x00])) // refresh over the live direct link
            // Adopt the cached reply immediately: the fresh GET usually echoes IDENTICAL values,
            // so onChange(of: confirmed) would never fire and the view would wait forever
            // ("Reading settings…" on every re-entry). A genuinely newer reply still updates us.
            if let s = confirmed {
                baseline = s
                draft = s
            }
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
            // Battery: per-packet when the tag streams v3 firmware; telemetry otherwise.
            if let t = target, let pw = model.batteryInfo(t) {
                HStack(spacing: 8) {
                    BatteryBadge(power: pw)
                    if pw.voltage > 0 {
                        Text(String(format: "%.2f V", pw.voltage))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(powerAge(pw.updated)).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
    }

    private func powerAge(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 90 { return "updated just now" }
        if s < 3600 { return "updated \(s / 60) min ago" }
        return "updated \(s / 3600) h ago"
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

    // MARK: - TX mode (downlink op 0x02 — calibration vs adaptive, confirmed via stream flags)

    private var targetTrack: SourceTrack? {
        model.tracks.first { $0.from == target }
    }

    private func sendMode(_ m: UInt8) {
        guard let t = target else { return }
        heldMode = m == 0 ? 0 : nil
        // CALIBRATION carries a 120 s dead-man TTL; this screen refreshes it every 45 s while
        // held, so leaving the screen (or the app dying) always lands the tag back in ADAPTIVE.
        ble.sendGnssCommand(to: t, payload: m == 0 ? Data([0x02, 0, 120, 0]) : Data([0x02, 1]))
    }

    private var modeCard: some View {
        card {
            sectionHeader("TX mode", "dot.radiowaves.up.forward")
            // Live state — the tag stamps its mode into every stream packet (flags bits 2-3).
            if let t = targetTrack, let heard = t.lastHeard, Date().timeIntervalSince(heard) < 30 {
                HStack(spacing: 6) {
                    Circle().fill(t.adaptive ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(t.adaptive
                         ? "Tag reports: ADAPTIVE — \(t.slowTier ? "idle tier (slow while still)" : "fast tier (full rate)")"
                         : "Tag reports: CALIBRATION — fixed full rate")
                        .font(.caption.bold())
                    Spacer()
                }
            } else {
                Text("No live stream from this tag yet — mode unknown until a packet arrives.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                modeButton("Calibration", "bolt.fill", .orange, active: targetTrack?.adaptive == false,
                           subtitle: "max fixed rate") { sendMode(0) }
                modeButton("Adaptive", "figure.walk.motion", .green, active: targetTrack?.adaptive == true,
                           subtitle: "speed-gated rate") { sendMode(1) }
            }
            Text("Calibration auto-reverts on the tag (dead-man TTL): this screen refreshes it every 45 s while open. Adaptive is the boot default and the EU-legal sustained mode.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .onReceive(ttlRefresh) { _ in
            if heldMode == 0 { sendMode(0) }
            // Sim keep-alive: extend the dead-man WITHOUT restarting playback (sub-op 0xFF).
            if simCommanded != 0, simActive, let t = target {
                ble.sendGnssCommand(to: t, payload: Data([0x04, 0xFF, 0, 0x58, 0x02]))
            }
        }
        .onDisappear { heldMode = nil } // stop refreshing: the tag's TTLs take over
    }

    private func modeButton(_ label: String, _ icon: String, _ tint: Color, active: Bool,
                            subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 16))
                Text(label).font(.footnote.bold())
                Text(subtitle).font(.caption2)
                    .foregroundStyle(active ? .white.opacity(0.85) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(active ? tint : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(active ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Adaptive tuning (v3 firmware only — the reply length announces capability)

    private var adaptiveCard: some View {
        card {
            sectionHeader("Adaptive mode tuning", "gauge.with.needle")
            knobSlider(title: "When stationary, send every",
                       value: Binding(get: { Double(draft.idleSpacingMs) },
                                      set: { draft.idleSpacingMs = UInt16($0) }),
                       range: 1000...10000,
                       display: String(format: "%.1f s", Double(draft.idleSpacingMs) / 1000),
                       caption: "Idle-tier spacing — the whole airtime/battery saving lives here.",
                       step: 500)
            Divider()
            knobSlider(title: "Full rate above",
                       value: Binding(get: { Double(draft.adaptFastKmh) },
                                      set: { draft.adaptFastKmh = UInt8($0)
                                             if draft.adaptSlowKmh >= draft.adaptFastKmh {
                                                 draft.adaptSlowKmh = draft.adaptFastKmh - 1
                                             } }),
                       range: 2...15,
                       display: "\(draft.adaptFastKmh) km/h",
                       caption: "Upshift is instant — first fast packet on the next fix.")
            Divider()
            knobSlider(title: "Slow down below",
                       value: Binding(get: { Double(draft.adaptSlowKmh) },
                                      set: { draft.adaptSlowKmh = UInt8(min($0, Double(draft.adaptFastKmh) - 1)) }),
                       range: 1...14,
                       display: "\(draft.adaptSlowKmh) km/h",
                       caption: "Must stay under the upshift speed (hysteresis gap between them).")
            Divider()
            knobSlider(title: "…after being slow for",
                       value: Binding(get: { Double(draft.adaptSustainS) },
                                      set: { draft.adaptSustainS = UInt8($0) }),
                       range: 3...60,
                       display: "\(draft.adaptSustainS) s",
                       caption: "Downshift is skeptical — a wave lull shouldn't drop the rate too eagerly.")
        }
    }

    // MARK: - Indoor simulator (op 0x04 — synthetic fixes generated ON the tag)

    private var simActive: Bool { targetTrack?.simulated == true }

    private func sendSim(_ source: UInt8) {
        guard let t = target else { return }
        simCommanded = source
        var p = Data([0x04, source, simLoop ? 1 : 0, 0x58, 0x02]) // TTL 600 s (0x0258)
        if source == 1 {
            p += Data([UInt8(simSegs.count)])
            for s in simSegs {
                p += Data([UInt8(s.speedKmh), UInt8(s.durS)])
            }
        }
        ble.sendGnssCommand(to: t, payload: p)
        SimSeg.save(simSegs)
    }

    private var simulatorCard: some View {
        card {
            sectionHeader("Indoor simulator", "wave.3.forward.circle")
            HStack(spacing: 6) {
                Circle().fill(simActive ? Color.orange : Color(.systemGray4)).frame(width: 8, height: 8)
                Text(simActive
                     ? "SIMULATING — synthetic fixes, marked in every packet"
                     : "Off — real GPS. Fakes movement indoors to exercise the modes.")
                    .font(.caption.bold())
                Spacer()
            }
            // Segment program editor (≤8 rows; one command packet)
            ForEach($simSegs) { $seg in
                HStack(spacing: 8) {
                    Text("\(Int(seg.speedKmh)) km/h")
                        .font(.caption.monospacedDigit()).frame(width: 58, alignment: .leading)
                    Slider(value: $seg.speedKmh, in: 0...25, step: 1)
                    Text("\(Int(seg.durS)) s")
                        .font(.caption.monospacedDigit()).frame(width: 34, alignment: .leading)
                    Slider(value: $seg.durS, in: 5...180, step: 5)
                    Button {
                        simSegs.removeAll { $0.id == seg.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(simSegs.count <= 1)
                }
            }
            HStack {
                Button {
                    if simSegs.count < 8 { simSegs.append(SimSeg(speedKmh: 5, durS: 30)) }
                } label: {
                    Label("Add segment", systemImage: "plus.circle").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(simSegs.count >= 8)
                Spacer()
                Toggle(isOn: $simLoop) { Text("Loop").font(.caption) }
                    .toggleStyle(.switch).controlSize(.mini).fixedSize()
            }
            HStack(spacing: 8) {
                Button { sendSim(1) } label: { simButtonLabel("Run program", "play.circle.fill", .orange) }
                    .buttonStyle(.plain)
                Button { sendSim(2) } label: { simButtonLabel("Shake mode", "hand.wave.fill", .teal) }
                    .buttonStyle(.plain)
                Button { sendSim(0) } label: { simButtonLabel("Stop", "stop.circle.fill", .gray) }
                    .buttonStyle(.plain)
            }
            Text("Runs ON the tag through the real firmware path — the map, tiers and modes react exactly as outdoors. Auto-stops via dead-man TTL; a reboot always returns to real GPS. Shake mode drives speed from the accelerometer.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func simButtonLabel(_ label: String, _ icon: String, _ tint: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(tint)
            Text(label).font(.caption2.bold())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Operator signals (calibration language v2 — beeper-first, tag-side)

    private func sendSignal(_ id: UInt8) {
        guard let t = target else { return }
        signalSeq &+= 1
        ble.sendGnssCommand(to: t, payload: Data([0x03, id, signalSeq]))
    }

    private var signalsCard: some View {
        card {
            sectionHeader("Operator signals (test)", "bell.and.waves.left.and.right")
            Text(ble.directTag
                 ? "Plays on the tag you're directly linked to."
                 : "Sent through the Base over LoRa — expect a fraction of a second.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach([1, 2, 3], id: \.self) { n in
                    Button { sendSignal(UInt8(n)) } label: {
                        VStack(spacing: 2) {
                            Text("\(n)×").font(.callout.bold())
                            Text(n == 1 ? "beep" : "beeps").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                signalButton("Record start", "record.circle.fill", .green, id: 10)
                signalButton("Problem", "exclamationmark.triangle.fill", .red, id: 11)
                signalButton("Stop", "stop.circle.fill", .gray, id: 0)
            }
            Text("Counted beeps = convergence progress. Record start = one long high beep, then the LED heartbeats every 3 s. Problem = low beep every 2 s until Stop (auto-stops after 2 min).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func signalButton(_ label: String, _ icon: String, _ tint: Color, id: UInt8) -> some View {
        Button { sendSignal(id) } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(tint)
                Text(label).font(.caption2.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
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
                            display: String, caption: String, step: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.footnote)
                Spacer()
                Text(display).font(.footnote.bold().monospacedDigit()).foregroundStyle(.teal)
            }
            Slider(value: value, in: range, step: step)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Rates + computed consequences

    private var dutyPercent: Double {
        // ShortFast airtime for our 41 B v3 packet ≈ 48 ms (docs/CAPACITY.md) — the EU-relevant
        // case. 2 Hz = 9.6%: still legal, but there is no headroom below 500 ms spacing.
        48.0 / Double(draft.txSpacingMs) * 100
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
