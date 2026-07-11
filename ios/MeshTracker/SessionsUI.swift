import SwiftUI
import UIKit

// MARK: - Analysis state (what the map projects besides the live stream)

let kAnalysisPalette: [Color] = [.orange, .purple, .pink, .indigo, .mint, .brown, .cyan, .yellow]

@Observable
final class AnalysisModel {
    var overlays: [LoadedSession] = []   // static full-res projections (course vs course)
    var open: LoadedSession?             // the session under the scrubber
    var playhead: Double = 0             // seconds since open.meta.startedAt
    var playing = false
    var rate: Double = 1
    @ObservationIgnored private var colorBase: [UUID: Int] = [:]
    @ObservationIgnored private var nextBase = 0

    func color(_ session: LoadedSession, trackIdx: Int) -> Color {
        if colorBase[session.id] == nil {
            colorBase[session.id] = nextBase
            nextBase += session.tracks.count
        }
        return kAnalysisPalette[((colorBase[session.id] ?? 0) + trackIdx) % kAnalysisPalette.count]
    }

    func openSession(_ s: LoadedSession) {
        open = s
        playhead = max(s.meta.duration, 1) // land at the end: the whole course is visible first
        playing = false
    }

    func closeOpen() {
        open = nil
        playing = false
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

// MARK: - Share sheet wrapper

struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Library

struct SessionLibraryView: View {
    let library: SessionLibrary
    let analysis: AnalysisModel
    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: ShareItem?
    @State private var renaming: SessionMeta?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Group {
                if library.sessions.isEmpty {
                    ContentUnavailableView("No recordings yet",
                                           systemImage: "record.circle",
                                           description: Text("Start a recording from the map panel; every received packet is captured verbatim."))
                } else {
                    List {
                        ForEach(library.sessions) { m in
                            row(m)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $shareItem) { item in ActivityView(url: item.url) }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.subheadline.bold())
                    Text(m.startedAt.formatted(date: .abbreviated, time: .shortened) +
                         " · " + fmtDuration(m.duration))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
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
                        if let s = SessionExport.gpx(library.load(m)) { shareItem = ShareItem(url: s) }
                    } label: { Label("Export GPX", systemImage: "square.and.arrow.up") }
                    Button {
                        if let s = SessionExport.csv(library.load(m)) { shareItem = ShareItem(url: s) }
                    } label: { Label("Export CSV", systemImage: "tablecells") }
                    Button { renaming = m; renameText = m.name } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) { library.delete(m) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
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
        .contentShape(Rectangle())
        .onTapGesture {
            analysis.openSession(library.load(m))
            dismiss()
        }
    }
}
