import SwiftUI
import UIKit

// MARK: - Analysis state (what the map projects besides the live stream)

let kAnalysisPalette: [Color] = [.orange, .purple, .pink, .indigo, .mint, .brown, .cyan, .yellow]

@Observable
final class AnalysisModel {
    var overlays: [LoadedSession] = []   // static full-res projections (course vs course)
    var open: LoadedSession?             // the session under the scrubber
    var playhead: Double = 0             // seconds since open.meta.startedAt
    var rate: Double = 1
    // Playback is driven by a MODEL-owned timer: view-attached timers proved fragile (the map
    // content missed the mutations), and the model outlives any view identity churn.
    var playing = false {
        didSet {
            if playing { startTimer() } else { stopTimer() }
        }
    }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var colorBase: [UUID: Int] = [:]
    @ObservationIgnored private var nextBase = 0

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let s = self.open else { return }
            let end = max(s.meta.duration, 1)
            self.playhead = min(self.playhead + 0.1 * self.rate, end)
            if self.playhead >= end { self.playing = false }
        }
        RunLoop.main.add(t, forMode: .common) // .common: keeps ticking while the slider is touched
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func color(_ session: LoadedSession, trackIdx: Int) -> Color {
        if colorBase[session.id] == nil {
            colorBase[session.id] = nextBase
            nextBase += session.tracks.count
        }
        return kAnalysisPalette[((colorBase[session.id] ?? 0) + trackIdx) % kAnalysisPalette.count]
    }

    func openSession(_ s: LoadedSession) {
        playing = false
        open = s
        playhead = max(s.meta.duration, 1) // land at the end: the whole course is visible first
    }

    func closeOpen() {
        playing = false
        open = nil
    }

    func isOverlaid(_ id: UUID) -> Bool { overlays.contains { $0.id == id } }

    func toggleOverlay(_ s: LoadedSession) {
        if let i = overlays.firstIndex(where: { $0.id == s.id }) {
            overlays.remove(at: i)
        } else {
            overlays.append(s)
        }
    }
}

// MARK: - Share sheet wrapper (single or batch)

struct ActivityView: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private struct ShareItem: Identifiable {
    let urls: [URL]
    var id: String { urls.map(\.absoluteString).joined() }
}

// MARK: - Library

private enum SessionSort: String, CaseIterable, Identifiable {
    case newest = "Newest first"
    case oldest = "Oldest first"
    case name = "Name"
    case duration = "Duration"
    case distance = "Distance"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .newest: return "arrow.down.circle"
        case .oldest: return "arrow.up.circle"
        case .name: return "textformat"
        case .duration: return "clock"
        case .distance: return "ruler"
        }
    }
}

struct SessionLibraryView: View {
    let library: SessionLibrary
    let analysis: AnalysisModel
    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: ShareItem?
    @State private var renaming: SessionMeta?
    @State private var renameText = ""
    @State private var searchText = ""
    @State private var sort: SessionSort = .newest
    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var confirmBulkDelete = false

    private func totalDistance(_ m: SessionMeta) -> Double {
        m.tags.reduce(0) { $0 + $1.distanceM }
    }

    private var shown: [SessionMeta] {
        var list = library.sessions
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch sort {
        case .newest: list.sort { $0.startedAt > $1.startedAt }
        case .oldest: list.sort { $0.startedAt < $1.startedAt }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .duration: list.sort { $0.duration > $1.duration }
        case .distance: list.sort { totalDistance($0) > totalDistance($1) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.sessions.isEmpty {
                    ContentUnavailableView("No recordings yet",
                                           systemImage: "record.circle",
                                           description: Text("Start a recording from the map panel; every received packet is captured verbatim."))
                } else {
                    List(selection: $selection) {
                        ForEach(shown) { m in
                            row(m).tag(m.id)
                        }
                    }
                    .environment(\.editMode, .constant(selecting ? .active : .inactive))
                    .searchable(text: $searchText, prompt: "Search sessions")
                }
            }
            .navigationTitle(selecting ? "\(selection.count) selected" : "Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selecting {
                        Button("Cancel") { selecting = false; selection = [] }
                    } else {
                        Menu {
                            Picker("Sort", selection: $sort) {
                                ForEach(SessionSort.allCases) { s in
                                    Label(s.rawValue, systemImage: s.icon).tag(s)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if selecting {
                        Button("Done") { selecting = false; selection = [] }.bold()
                    } else {
                        Button("Done") { dismiss() }.bold()
                    }
                }
                ToolbarItem(placement: .principal) {
                    if !selecting, !library.sessions.isEmpty {
                        Button("Select") { selecting = true }
                            .font(.subheadline)
                    }
                }
                // Bulk actions on the current selection
                ToolbarItemGroup(placement: .bottomBar) {
                    if selecting {
                        Button {
                            bulkExport { SessionExport.gpx($0) }
                        } label: { Label("GPX", systemImage: "square.and.arrow.up") }
                            .disabled(selection.isEmpty)
                        Button {
                            bulkExport { SessionExport.csv($0) }
                        } label: { Label("CSV", systemImage: "tablecells") }
                            .disabled(selection.isEmpty)
                        Spacer()
                        Button(role: .destructive) {
                            confirmBulkDelete = true
                        } label: { Label("Delete", systemImage: "trash") }
                            .disabled(selection.isEmpty)
                    }
                }
            }
            .confirmationDialog("Delete \(selection.count) session(s)? The raw recordings are removed permanently.",
                                isPresented: $confirmBulkDelete, titleVisibility: .visible) {
                Button("Delete \(selection.count) session(s)", role: .destructive) {
                    for id in selection {
                        if let m = library.sessions.first(where: { $0.id == id }) {
                            analysis.overlays.removeAll { $0.id == id }
                            if analysis.open?.id == id { analysis.closeOpen() }
                            library.delete(m)
                        }
                    }
                    selection = []
                    selecting = false
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $shareItem) { item in ActivityView(urls: item.urls) }
            .alert("Rename session", isPresented: Binding(get: { renaming != nil },
                                                          set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let m = renaming { library.rename(m, to: renameText) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private func bulkExport(_ make: (LoadedSession) -> URL?) {
        let urls = selection.compactMap { id -> URL? in
            guard let m = library.sessions.first(where: { $0.id == id }) else { return nil }
            return make(library.load(m))
        }
        if !urls.isEmpty { shareItem = ShareItem(urls: urls) }
    }

    private func fmtDuration(_ d: TimeInterval) -> String {
        let s = Int(d)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func fmtDist(_ m: Double) -> String {
        m < 1000 ? String(format: "%.0f m", m) : String(format: "%.2f km", m / 1000)
    }

    @ViewBuilder private func row(_ m: SessionMeta) -> some View {
        let overlaid = analysis.isOverlaid(m.id)
        let content = VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.subheadline.bold())
                    Text(m.startedAt.formatted(date: .abbreviated, time: .shortened) +
                         " · " + fmtDuration(m.duration))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if !selecting {
                    // Overlay toggle: project this session statically on the map (multi-select).
                    Button {
                        analysis.toggleOverlay(library.load(m))
                    } label: {
                        Image(systemName: overlaid ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                            .foregroundStyle(overlaid ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)
                    Menu {
                        Button { analysis.openSession(library.load(m)); dismiss() } label: {
                            Label("Explore (scrubber)", systemImage: "slider.horizontal.below.rectangle")
                        }
                        Button {
                            if let s = SessionExport.gpx(library.load(m)) { shareItem = ShareItem(urls: [s]) }
                        } label: { Label("Export GPX", systemImage: "square.and.arrow.up") }
                        Button {
                            if let s = SessionExport.csv(library.load(m)) { shareItem = ShareItem(urls: [s]) }
                        } label: { Label("Export CSV", systemImage: "tablecells") }
                        Button { renaming = m; renameText = m.name } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            analysis.overlays.removeAll { $0.id == m.id }
                            if analysis.open?.id == m.id { analysis.closeOpen() }
                            library.delete(m)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            // Per-tag stat chips — the instrument summary: points/fixes, distance, mean ±acc.
            ForEach(Array(m.tags.enumerated()), id: \.element.id) { idx, tag in
                HStack(spacing: 6) {
                    Circle().fill(kAnalysisPalette[idx % kAnalysisPalette.count])
                        .frame(width: 8, height: 8)
                    Text(tag.title).font(.caption)
                    Text("\(tag.fixes)/\(tag.points) pts · \(fmtDist(tag.distanceM)) · ±\(String(format: "%.1f", tag.avgHaccM)) m · max \(tag.maxSpeedKmh) km/h")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        if selecting {
            content // List's edit-mode selection handles the taps
        } else {
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    analysis.openSession(library.load(m))
                    dismiss()
                }
        }
    }
}
