import SwiftUI

/// Build identity, straight from Info.plist. Release builds carry the AS* keys injected by
/// ios/scripts/release.sh at archive time (train, branch, sha, date, ship note); dev/Xcode
/// builds don't — the page says so instead of guessing.
enum BuildInfo {
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    }
    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }
    static func injected(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
    static var train: String? { injected("ASBuildTrain") }
    static var branch: String? { injected("ASBuildBranch") }
    static var sha: String? { injected("ASBuildSHA") }
    static var date: String? { injected("ASBuildDate") }
    static var shipNote: String? { injected("ASShipNote") }
    static var isReleaseBuild: Bool { train != nil }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "location.circle.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.white, .teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MeshTracker").font(.title3.bold())
                            Text("v\(BuildInfo.version) (\(BuildInfo.build))")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Build identity") {
                    if BuildInfo.isReleaseBuild {
                        row("Train", BuildInfo.train)
                        row("Branch", BuildInfo.branch)
                        row("Commit", BuildInfo.sha)
                        row("Built", BuildInfo.date)
                    } else {
                        Label("Development build (Xcode) — no release identity injected",
                              systemImage: "hammer")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if let note = BuildInfo.shipNote, !note.isEmpty {
                    Section("What to test (shipped note)") {
                        Text(note).font(.footnote)
                    }
                }

                Section("System") {
                    row("Two tag flavors", "BLE5 bridge · GPS tag (AG3335 @ 4 Hz)")
                    row("Stream", "PRIVATE_APP(256), 17 B, GST-backed ±m")
                    row("Config channel", "portnum 260 over tag BLE")
                }
            }
            .navigationTitle("About this build")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .font(.footnote.monospaced())
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.footnote)
    }
}
