import SwiftUI
import UIKit // UINotificationFeedbackGenerator — the LOUD delivery-failure haptic
import UniformTypeIdentifiers

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
    @State private var signalSeq = UInt8.random(in: 0...255) // legacy op 0x03 dedupe (pre-v4 tags)
    // A4 guaranteed delivery: one in-flight signal + one in-flight radio command, each with a
    // visible outcome — the one forbidden result is a silently lost command (RADIO_STATES §4).
    @State private var signalDelivery = DeliveryState.idle
    @State private var signalTask: Task<Void, Never>?
    @State private var radioDelivery = DeliveryState.idle
    @State private var radioTask: Task<Void, Never>?
    @State private var heldMode: UInt8? // 0 = holding CALIBRATION (auto-refresh its TTL); nil = not commanding
    @State private var simSegs: [SimSeg] = SimSeg.loadSaved()
    @State private var simLoop = true
    @State private var simCommanded: UInt8 = 0 // last commanded sim source (for TTL keep-alive)
    // Track replay (phase 2)
    @State private var sessionLib = SessionLibrary()
    @State private var showGpxImporter = false
    @State private var uploadProgress: Double?
    @State private var trackReady = false
    @State private var trackInfo = ""
    @State private var uploadNote: String?
    @State private var uploadTask: Task<Void, Never>? // owned: cancellable on leave/rebind (R3 f2)
    @State private var uploadGeneration = 0
    @State private var directConfigRequest: ConfigRequestToken?
    private let ttlRefresh = Timer.publish(every: 45, on: .main, in: .common).autoconnect()

    // MARK: - Connection routing (single PhoneAPI client per node — see BLEManager)

    private var direct: Bool {
        ble.directTag && target != nil && ble.connectedNodeNum == target
    }
    /// Settings are only ever adopted when the REPLY's sender is the current target (R4 f3):
    /// a cached reply from tag A (or one relayed from another node) is never shown, edited or
    /// applied as tag B's. The reply must also follow this screen's GET on the same link.
    private var boundReply: ConfigReply? {
        guard direct, let request = directConfigRequest, request.node == target,
              request.linkGeneration == ble.linkGeneration,
              ble.lastConfigReplyGeneration == request.linkGeneration,
              ble.lastConfigReplySequence > request.replyFloor,
              let r = ble.lastConfigReply, r.from == request.node,
              r.op == request.expectedOp else { return nil }
        return r
    }
    private var confirmed: TagSettings? { direct ? boundReply?.settings : mgr.settings }
    private var lastStatus: UInt8? {
        direct ? (boundReply?.op == 0x81 ? boundReply?.status : nil) : mgr.lastStatus
    }
    private var connected: Bool {
        direct || mgr.stage == .ready || mgr.stage == .applying
    }
    private var dirty: Bool { baseline != nil && draft != baseline }

    /// Both tag flavors are Tag Setup targets since A1 (the bridge speaks portnum 260 and
    /// advertises BLE now). Which cards render is driven by the capability byte below.
    private var knownTags: [SourceTrack] {
        model.tracks.filter { $0.source == .gpsTag || $0.source == .bridge }
    }

    // MARK: - Capability gating (v4 capability byte; sane per-flavor defaults before it's read)

    private var knownCaps: TagSettings? { baseline ?? confirmed }
    private var isBridge: Bool { targetTrack?.source == .bridge }
    /// The tag speaks the v4 wire (sid signals, RADIO op, v5 stream status) — proven by either
    /// an 18-byte settings reply or a 20-byte stream packet.
    private var v4Wire: Bool { (knownCaps?.isV4 ?? false) || (targetTrack?.radioStatus ?? -1) >= 0 }
    private var showGnssKnobs: Bool { knownCaps?.isV4 == true ? knownCaps!.capGnss : !isBridge }
    private var showModes: Bool { knownCaps?.isV4 == true ? knownCaps!.capModes : !isBridge }
    private var showSimTrack: Bool { knownCaps?.isV4 == true ? knownCaps!.capSimTrack : !isBridge }
    private var showSignals: Bool { knownCaps?.isV4 == true ? knownCaps!.capSignals : true }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    deviceCard
                    // Mode + signals ride the MAIN link (Base-relayed LoRa downlink, or direct) —
                    // they don't need the settings handshake, only a link and a target.
                    if target != nil && ble.connectedNodeNum != 0 {
                        if v4Wire { radioCard }
                        if showModes { modeCard }
                        if showSimTrack { simulatorCard }
                        if showSignals { signalsCard }
                    }
                    if baseline != nil {
                        if draft.isV4 && draft.capProfiles { persistenceCard }
                        if showGnssKnobs {
                            profilesCard
                            navModeCard
                            filtersCard
                            ratesCard
                        }
                        if draft.isV3 && showModes {
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
            .onDisappear {
                cancelUpload(clearUI: true)
                signalTask?.cancel()
                radioTask?.cancel()
                directConfigRequest = nil
                mgr.stop()
            }
            .onChange(of: ui.setupTarget) {
                if ui.setupTarget != nil { engage() } // engage() nils it — don't re-trigger
            }
            .onChange(of: confirmed) {
                if let s = confirmed {
                    baseline = s
                    draft = s
                }
            }
            .onChange(of: target) {
                // trackReady describes ONE tag's slot — a new target starts from unknown, and
                // any in-flight upload to the old tag is cancelled, not orphaned (R3 f2).
                cancelUpload(clearUI: true)
                signalTask?.cancel()
                radioTask?.cancel()
                signalDelivery = .idle
                radioDelivery = .idle
            }
            .onChange(of: ble.linkGeneration) {
                if directConfigRequest != nil { baseline = nil }
                directConfigRequest = nil
            }
            .onChange(of: ble.connectedNodeNum) {
                if ble.directTag, let t = target, ble.connectedNodeNum == t {
                    requestDirectSettings()
                }
            }
        }
    }

    private func engage() {
        let newTarget = ui.setupTarget ?? target ?? knownTags.first?.from
        target = newTarget
        ui.setupTarget = nil
        baseline = nil
        guard let t = newTarget else { return }
        if ble.directTag && ble.connectedNodeNum == t {
            requestDirectSettings()
        } else {
            directConfigRequest = nil
            mgr.begin(targetNode: t)
        }
    }

    private func requestDirectSettings() {
        guard ble.directTag, let t = target, ble.connectedNodeNum == t else {
            directConfigRequest = nil
            return
        }
        if mgr.stage != .idle { mgr.stop() }
        // The token captures the reply floor before the GET is written. Even an identical
        // response transitions confirmed nil -> settings, so no cached-reply shortcut is needed.
        directConfigRequest = ble.sendTagConfigRequest(Data([0x00]))
    }

    private func apply() {
        if direct {
            directConfigRequest = ble.sendTagConfigRequest(Data([0x01]) + draft.wire)
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
            if knownTags.count > 1 {
                HStack(spacing: 8) {
                    ForEach(knownTags) { t in
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
                        .disabled(uploadProgress != nil) // never switch targets mid-upload
                    }
                }
            }
            HStack(spacing: 10) {
                Circle()
                    .fill(connected ? .green : (mgr.stage == .scanning || mgr.stage == .connecting ? .orange : .red))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    if let t = target {
                        Text(knownTags.first(where: { $0.from == t })?.title ?? "Tag ·\(String(format: "%08x", t).suffix(4))")
                            .font(.subheadline.bold())
                    } else {
                        Text("No tag seen yet").font(.subheadline.bold())
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
            Divider()
            HStack {
                Label("Track replay", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                if trackReady {
                    Text(trackInfo).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let p = uploadProgress {
                ProgressView(value: p)
                Text("Uploading track to the tag…").font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Button { showGpxImporter = true } label: {
                        simButtonLabel("Import GPX", "square.and.arrow.down", .indigo)
                    }
                    .buttonStyle(.plain)
                    Menu {
                        ForEach(sessionLib.sessions) { m in
                            Button(m.name) { importSession(m) }
                        }
                    } label: {
                        simButtonLabel("From session", "tray.full", .indigo)
                    }
                    Button { sendSimTrack() } label: {
                        simButtonLabel("Play track", "play.circle.fill", .green)
                    }
                    .buttonStyle(.plain)
                    .disabled(!trackReady)
                }
                if let n = uploadNote {
                    Text(n).font(.caption2).foregroundStyle(.orange)
                }
                Text("Record once outdoors, replay forever indoors — the tag interpolates the uploaded course at its fix rate. Upload needs a DIRECT BLE link to the tag; playback then works from anywhere (Stop above ends it).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: $showGpxImporter,
                      allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let recs = TrackBuilder.fromGPX(data) else {
                uploadNote = "Couldn't parse that GPX (needs trkpt/rtept points)."
                return
            }
            uploadTrack(recs)
        }
    }

    /// Direct-only transport for bulk track upload (LoRa would take minutes and eat the duty
    /// budget). The little play/stop commands still go over any link.
    private struct UploadLink {
        let node: UInt32               // the tag this upload is bound to — ACK sender must match
        let send: (Data) -> Void
        let ackQueue: () -> [TrackAck] // SEQUENCED per-link queue (R4 f7) — scanned by index,
                                       // so an ACK landing between polls can never be lost
        let generationOK: () -> Bool   // false the moment the underlying connection rebinds
    }

    private func trackUploadLink() -> UploadLink? {
        if ble.directTag, let t = target, ble.connectedNodeNum == t {
            let gen = ble.linkGeneration
            return UploadLink(node: t,
                              send: { ble.sendTagConfig($0) },
                              ackQueue: { ble.trackAcks },
                              generationOK: { ble.linkGeneration == gen && ble.connectedNodeNum == t })
        }
        if let t = target, mgr.stage == .ready || mgr.stage == .applying, mgr.linkNodeNum == t {
            let gen = mgr.linkGeneration
            return UploadLink(node: t,
                              send: { mgr.sendRaw($0) },
                              ackQueue: { mgr.trackAcks },
                              generationOK: { mgr.linkGeneration == gen && mgr.linkNodeNum == t })
        }
        return nil
    }

    /// One frame, one CORRELATED ACK: only an exact (sender-node, tid, sub, offset) match
    /// counts — a delayed ACK from an earlier frame, a previous transfer, or another tag can
    /// never credit this one (reviews R2 f1 + R3 f3 + R4 f7: the u32 tid travels in EVERY
    /// frame and every queue entry is inspected exactly once, none skipped). Cancellation and
    /// connection rebinds abort immediately (R3 f2). NAK/timeout → one retry (the firmware is
    /// idempotent per-frame, and a COMMIT retry after a REAL failure keeps NAKing — R4 f1).
    private func sendAcked(_ link: UploadLink, _ frame: Data, sub: UInt8, off: UInt16,
                           tid: UInt32) async throws -> Bool {
        for _ in 0..<2 {
            try Task.checkCancellation()
            guard link.generationOK() else { return false }
            var seen = link.ackQueue().count // only ACKs appended AFTER this send can count
            link.send(frame)
            let deadline = Date().addingTimeInterval(2.0)
            var verdict: Bool?
            while Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
                try Task.checkCancellation()
                guard link.generationOK() else { return false }
                let q = link.ackQueue()
                while verdict == nil && seen < q.count {
                    let a = q[seen]
                    seen += 1
                    if a.from == link.node, a.tid == tid, a.sub == sub, a.off == off {
                        verdict = (a.status == 0)
                    }
                    // entries for OTHER frames/transfers/tags are skipped, never re-read
                }
                if verdict != nil { break }
            }
            if verdict == true { return true }
        }
        return false
    }

    private func importSession(_ m: SessionMeta) {
        let loaded = sessionLib.load(m)
        guard let tr = loaded.tracks.max(by: { $0.points.count < $1.points.count }),
              let recs = TrackBuilder.fromSessionPoints(tr.points) else {
            uploadNote = "That session has no usable fixes."
            return
        }
        uploadTrack(recs)
    }

    private func cancelUpload(clearUI: Bool) {
        uploadGeneration &+= 1
        uploadTask?.cancel()
        uploadTask = nil
        if clearUI {
            uploadProgress = nil
            trackReady = false
            trackInfo = ""
            uploadNote = nil
        }
    }

    private func uploadTrack(_ recs: [TrackRecord]) {
        guard let link = trackUploadLink() else {
            uploadNote = "Track upload needs a direct BLE link to the tag (not via the Base)."
            return
        }
        uploadTask?.cancel()
        uploadGeneration &+= 1
        let operationGeneration = uploadGeneration
        uploadNote = nil
        trackReady = false
        uploadProgress = 0
        let wire = TrackBuilder.wireData(recs)
        let crc = TrackBuilder.crc32(wire)
        let boundTarget = target // upload is BOUND to this tag; a mid-flight switch aborts
        let tid = UInt32.random(in: 1...UInt32.max) // per-transfer id, carried in EVERY frame (R4 f7)
        let tidData = withUnsafeBytes(of: tid.littleEndian) { Data($0) }
        uploadTask = Task { @MainActor in
            let fail: (String) -> Void = { msg in
                guard self.uploadGeneration == operationGeneration, !Task.isCancelled else { return }
                self.uploadProgress = nil
                self.trackReady = false
                self.uploadNote = msg
            }
            defer {
                if self.uploadGeneration == operationGeneration {
                    self.uploadTask = nil
                }
            }
            do {
                var begin = Data([0x05, 0x00]) + tidData
                begin += withUnsafeBytes(of: UInt16(recs.count).littleEndian) { Data($0) }
                begin += withUnsafeBytes(of: crc.littleEndian) { Data($0) }
                guard try await sendAcked(link, begin, sub: 0, off: UInt16(recs.count), tid: tid) else {
                    fail("Tag rejected the upload start (stop any running track replay first).")
                    return
                }
                let per = 20
                var off = 0
                while off < recs.count {
                    try Task.checkCancellation()
                    guard uploadGeneration == operationGeneration, target == boundTarget else { return }
                    let n = min(per, recs.count - off)
                    var p = Data([0x05, 0x01]) + tidData
                    p += withUnsafeBytes(of: UInt16(off).littleEndian) { Data($0) }
                    p.append(UInt8(n))
                    p += wire.subdata(in: off * 10 ..< (off + n) * 10)
                    guard try await sendAcked(link, p, sub: 1, off: UInt16(off), tid: tid) else {
                        fail("Upload failed at point \(off)/\(recs.count) — check the link and retry.")
                        return
                    }
                    try Task.checkCancellation()
                    guard uploadGeneration == operationGeneration, target == boundTarget else { return }
                    off += n
                    uploadProgress = Double(off) / Double(recs.count)
                }
                try Task.checkCancellation()
                guard uploadGeneration == operationGeneration, target == boundTarget else { return }
                // COMMIT: the tag verifies the STAGED slot in place and promotes it by appending
                // a proven generation footer — the previous track is never touched. Success is
                // ONLY a status-0 ACK carrying OUR tid. Retry proof uses the active on-disk tid,
                // and BEGIN rejects active-tid reuse, so an older track can never earn "verified"
                // for this transfer (R4 f1).
                guard try await sendAcked(link, Data([0x05, 0x02]) + tidData,
                                          sub: 2, off: 0, tid: tid) else {
                    fail("Tag CRC/commit failed — track NOT stored. Retry the upload.")
                    return
                }
                try Task.checkCancellation()
                guard uploadGeneration == operationGeneration, target == boundTarget else { return }
                uploadProgress = nil
                trackReady = true
                trackInfo = "\(recs.count) pts · \(Int(TrackBuilder.durationS(recs))) s · verified"
            } catch is CancellationError {
                return
            } catch {
                fail("Upload interrupted — check the link and retry.")
            }
        }
    }

    private func sendSimTrack() {
        guard let t = target else { return }
        simCommanded = 3
        ble.sendGnssCommand(to: t, payload: Data([0x04, 3, simLoop ? 1 : 0, 0x58, 0x02]))
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

    // MARK: - A4 guaranteed delivery (retry-until-correlated-ACK; RADIO_STATES §4)

    enum DeliveryState: Equatable {
        case idle
        case sending(String)
        case confirmed(String)
        case failed(String) // shown LOUD — a silently lost command is the forbidden outcome
    }

    private enum DeliverOutcome { case confirmed, refused, timedOut }

    /// At-least-once delivery: retransmit the SAME frame (same u32 cid) until a correlated ACK
    /// {ackOp, echo, cid} arrives from the target node — the tag dedupes on the cid, so
    /// re-sends never replay. A NAK stops the retries immediately (the tag actively refused).
    /// `streamConfirm` is GO-DEAF's second layer: even if every ACK is lost, a fresh stream
    /// packet whose v5 status matches the commanded state proves the transition.
    private func deliverAcked(frame: Data, ackOp: UInt8, echo: UInt8, cid: UInt32, to node: UInt32,
                              streamConfirm: (() -> Bool)?) async -> DeliverOutcome {
        let gen = ble.linkGeneration
        var seen = ble.smallAcks.count // only ACKs appended after our first send may count
        for _ in 0..<6 {
            if Task.isCancelled || ble.linkGeneration != gen { return .timedOut }
            ble.sendGnssCommand(to: node, payload: frame)
            let deadline = Date().addingTimeInterval(0.35)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled || ble.linkGeneration != gen { return .timedOut }
                let q = ble.smallAcks
                while seen < q.count {
                    let a = q[seen]
                    seen += 1
                    if a.from == node, a.ackOp == ackOp, a.echo == echo, a.id == cid {
                        return a.status == 0 ? .confirmed : .refused
                    }
                }
                if let confirmedByStream = streamConfirm, confirmedByStream() { return .confirmed }
            }
        }
        if let confirmedByStream = streamConfirm {
            // Retry budget exhausted with no ACK — give the stream fallback one packet interval.
            let deadline = Date().addingTimeInterval(6.0)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled || ble.linkGeneration != gen { return .timedOut }
                if confirmedByStream() { return .confirmed }
            }
        }
        return .timedOut
    }

    private func failureHaptic() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    @ViewBuilder private func deliveryBanner(_ state: DeliveryState) -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .sending(let what):
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Delivering \(what)…").font(.caption.bold())
            }
        case .confirmed(let what):
            Label("Tag confirmed: \(what)", systemImage: "checkmark.circle.fill")
                .font(.caption.bold()).foregroundStyle(.green)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.octagon.fill")
                .font(.footnote.bold()).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Radio state (op 0x06 — LISTENING/DEAF with two-layer confirmation)

    private func sendRadio(deaf: Bool) {
        guard let t = target else { return }
        radioTask?.cancel()
        let state: UInt8 = deaf ? 1 : 0
        let rid = UInt32.random(in: 1...UInt32.max)
        var frame = Data([0x06, state])
        frame += withUnsafeBytes(of: rid.littleEndian) { Data($0) }
        let sentAt = Date()
        let label = deaf ? "radio muted (session mode)" : "listening restored"
        radioDelivery = .sending(deaf ? "go-deaf" : "restore-listening")
        radioTask = Task { @MainActor in
            let outcome = await deliverAcked(frame: frame, ackOp: 0x86, echo: state, cid: rid, to: t,
                                             streamConfirm: { [weak model] in
                guard let tr = model?.tracks.first(where: { $0.from == t }),
                      let at = tr.radioStatusAt, at > sentAt else { return false }
                return tr.isDeaf == deaf
            })
            guard !Task.isCancelled else { return }
            switch outcome {
            case .confirmed: radioDelivery = .confirmed(label)
            case .refused:
                radioDelivery = .failed("Tag REFUSED the radio command — state unchanged.")
                failureHaptic()
            case .timedOut:
                radioDelivery = .failed(deaf
                    ? "TAG DID NOT CONFIRM going deaf — treat the session as NOT started."
                    : "TAG DID NOT CONFIRM listening. If it is deaf, LoRa can't reach it: connect the app directly to the tag over Bluetooth, or reboot it.")
                failureHaptic()
            }
        }
    }

    private var radioLive: (deaf: Bool, permanent: Bool, degraded: Bool, fresh: Bool)? {
        guard let tr = targetTrack, tr.radioStatus >= 0 else { return nil }
        let fresh = tr.radioStatusAt.map { Date().timeIntervalSince($0) < 30 } ?? false
        return (tr.isDeaf, tr.isPermanent, tr.dutyDegraded, fresh)
    }

    private var radioCard: some View {
        card {
            sectionHeader("Radio state", "antenna.radiowaves.left.and.right.slash")
            if let live = radioLive {
                HStack(spacing: 6) {
                    Circle().fill(live.deaf ? Color.orange : Color.green).frame(width: 8, height: 8)
                    Text(live.deaf
                         ? "Tag reports: DEAF — transmit-only, LoRa commands can't reach it"
                         : "Tag reports: LISTENING — commands work at LoRa range")
                        .font(.caption.bold())
                    if !live.fresh { Text("(stale)").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                }
                HStack(spacing: 4) {
                    if live.permanent { badge("PERMANENT profile", color: .indigo, active: false) }
                    if live.degraded { badge("duty-clamped", color: .orange, active: false) }
                }
            } else {
                Text("No v5 stream status from this tag yet.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                modeButton("Go deaf", "speaker.slash.fill", .orange,
                           active: radioLive?.deaf == true,
                           subtitle: "session: TX-only") { sendRadio(deaf: true) }
                modeButton("Listen", "ear.badge.waveform", .green,
                           active: radioLive?.deaf == false,
                           subtitle: "commands at range") { sendRadio(deaf: false) }
            }
            deliveryBanner(radioDelivery)
            Text("Deaf = the session state: radio sleeps between sends (best battery, immune to LoRa noise). The tag confirms BEFORE muting, and the stream's status byte is the second proof. Recovery ladder: LoRa while listening → Bluetooth next to the tag in any state → reboot (deafness never survives a reboot in the Hybrid profile).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Persistence profile (settings v4 byte 13 — HYBRID vs PERMANENT, app consent)

    private var persistenceCard: some View {
        card {
            sectionHeader("Persistence profile", "externaldrive.badge.checkmark")
            Picker("", selection: $draft.profileBits) {
                Text("Hybrid").tag(UInt8(0x00))
                Text("Permanent · Listen").tag(UInt8(0x01))
                Text("Permanent · Deaf").tag(UInt8(0x03))
            }
            .pickerStyle(.segmented)
            Group {
                switch draft.profileBits {
                case 0x00:
                    Text("Hybrid (default): every power-on lands in LISTENING + adaptive — always reachable at range. Going deaf is session-only and never survives a reboot.")
                case 0x01:
                    Text("Permanent · Listening: fixed transmit spacing (no adaptive tiers, no calibration choreography), radio always listening. PERSISTS ACROSS REBOOTS until you change it here.")
                default:
                    Text("Permanent · Deaf: a pure beacon at fixed spacing, EVERY boot, FOREVER. ⚠️ Reachable ONLY with the phone next to it (Bluetooth) or a USB cable — LoRa commands will never work. Radio-state buttons rewrite this stored profile.")
                }
            }
            .font(.caption)
            .foregroundStyle(draft.profileBits == 0x03 ? .orange : .secondary)
            Text("Applied with the settings below — the tag re-checks radio-law limits at every boot and clamps + flags itself \"duty-clamped\" rather than ever transmitting illegally.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Operator signals (calibration language v2 — beeper-first, tag-side)

    private func signalName(_ id: UInt8) -> String {
        switch id {
        case 1...8: return "\(id)× beep"
        case 10: return "record-start"
        case 11: return "problem"
        default: return "stop"
        }
    }

    private func sendSignal(_ id: UInt8) {
        guard let t = target else { return }
        guard v4Wire else {
            // Pre-v4 firmware: the old fire-and-forget wire (u8 seq, no ACK to await).
            signalSeq &+= 1
            ble.sendGnssCommand(to: t, payload: Data([0x03, id, signalSeq]))
            return
        }
        signalTask?.cancel()
        let sid = UInt32.random(in: 1...UInt32.max)
        var frame = Data([0x03, id])
        frame += withUnsafeBytes(of: sid.littleEndian) { Data($0) }
        signalDelivery = .sending(signalName(id))
        signalTask = Task { @MainActor in
            let outcome = await deliverAcked(frame: frame, ackOp: 0x83, echo: id, cid: sid, to: t,
                                             streamConfirm: nil)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .confirmed: signalDelivery = .confirmed("\(signalName(id)) played")
            case .refused:
                signalDelivery = .failed("Tag REFUSED the \(signalName(id)) signal.")
                failureHaptic()
            case .timedOut:
                signalDelivery = .failed("TAG DID NOT CONFIRM the \(signalName(id)) signal — assume it did NOT play.")
                failureHaptic()
            }
        }
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
            deliveryBanner(signalDelivery)
            Text(v4Wire
                 ? "Every signal is delivered-or-loud: the app re-sends the same request until the tag confirms it (duplicates never double-beep), and tells you unmistakably if it could not."
                 : "Counted beeps = convergence progress. Record start = one long high beep, then the LED heartbeats every 3 s. Problem = low beep every 2 s until Stop (auto-stops after 2 min).")
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
        // Pre-v4 fallback only: assumes ShortFast airtime ≈48 ms (docs/CAPACITY.md). v4 tags
        // report their OWN duty floor (region law × measured airtime at the ACTIVE preset) —
        // trust that, never a preset guess (the bench fleet turned out to run LongFast).
        48.0 / Double(draft.txSpacingMs) * 100
    }

    /// v4: the tag's own legality verdict for the drafted spacing. nil = pre-v4 firmware.
    private var dutyVerdict: (legal: Bool, text: String)? {
        guard draft.isV4 else { return nil }
        let floor = draft.dutyFloorMs
        if floor == 0 {
            return (true, "No duty-cycle limit in this region — any spacing is legal (bench).")
        }
        if draft.txSpacingMs >= floor {
            return (true, "Legal here: the tag requires ≥ \(floor) ms between sends (its own region-law number).")
        }
        return (false, "Below this region's legal floor of \(floor) ms — the tag will refuse it, or clamp and flag itself \"duty-clamped\".")
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
                let legal = dutyVerdict?.legal ?? (dutyPercent <= 10)
                Image(systemName: legal ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(legal ? .green : .orange)
                Text(dutyVerdict?.text ?? (dutyPercent <= 10
                     ? String(format: "≈%.0f%% duty cycle — EU868-legal sustained", dutyPercent)
                     : String(format: "≈%.0f%% duty cycle — bench / US only (EU limit is 10%%)", dutyPercent)))
                    .font(.caption)
                Spacer()
            }
            .padding(8)
            .background(((dutyVerdict?.legal ?? (dutyPercent <= 10)) ? Color.green : Color.orange).opacity(0.1),
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
