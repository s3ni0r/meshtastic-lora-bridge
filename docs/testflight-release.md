# Releasing MeshTracker to TestFlight — trains + identifiable builds

Ported from AutoShot's release framework (2026-07-11). One bundle id
(`com.s3ni0r.meshtracker`), one App Store Connect record. Variants ship as
separate **release trains** inside the same TestFlight app; you switch
between them on-device via TestFlight's build picker (one installed at a
time — same sandbox, so app data survives switching).

```sh
# Mainline — from a clean, tagged HEAD (the tag IS the marketing version):
git tag -a v2.1 -m "…"
ios/scripts/release.sh                              # optional: --note "…"

# Experiment — from any clean branch; the note is REQUIRED (it's the
# build's identity in TestFlight):
ios/scripts/release.sh --exp gnss-exp --note "Alternate GNSS profile —
compare fix rate against mainline on the same walk."
```

`ios/scripts/release.sh` refuses a dirty tree, regenerates the xcodeproj
(`xcodegen` — the project file is gitignored; the committed `project.yml`
is the truth), stamps the train's numbers, archives **Release**, injects
the build identity, uploads straight to App Store Connect, and pushes the
note to the build's TestFlight **What to Test**. Processing takes
~5–15 min; **internal** testers get the build immediately (no Beta App
Review; `ITSAppUsesNonExemptEncryption: false` in project.yml skips the
per-build compliance question). External groups need one-time Beta App
Review. There is no test gate in this project (yet) — the Release archive
is the compile check.

## Release trains (stateless — never edit numbers by hand)

| Train | Marketing version | Build number |
| --- | --- | --- |
| **Mainline** | the `v*` tag on HEAD (or `ios/scripts/release.sh 2.1`) → `2.1` | `git rev-list HEAD --count` (monotonic; maps back to its commit) |
| **Experiment** | `MAJOR.MINOR` of the nearest tag + the train number → `2.0.101` | UTC `yymmddHHMM` (monotonic, collision-proof when a train is re-shipped from another branch) |

Both are injected at archive time (`MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` overrides) — the values in `project.yml` are
placeholders and stay untouched, so releases never dirty the tree.

The `.1NN` patch component (≥ 101) marks experiment trains: each experiment
name gets its own train, registered once in **`ios/scripts/trains.env`**
(auto-assigned and auto-committed on first `--exp <name>` use; numbers are
never reused). Mainline stays `x.y` — hotfix patches `x.y.z` with `z < 100`
never collide. TestFlight lists each train separately with its own build
history and What to Test notes.

## Identifiable builds

- **Injection** — after the archive, `release.sh` adds `ASBuildTrain` /
  `ASBuildBranch` / `ASBuildSHA` / `ASBuildDate` / `ASShipNote` to the
  archived app's Info.plist (`plutil`; the export step re-signs, so the
  seal stays valid). Dev/Xcode builds never get the keys. Readable at
  runtime via `Bundle.main.object(forInfoDictionaryKey:)` — surface them
  on an About screen whenever useful (AutoShot's `BuildInfo.swift` +
  `AboutBuildPage.swift` are a ready-made crib).
- **TestFlight "What to Test"** — the `--note` text + a `branch@sha ·
  built …` footer, pushed after upload by `ios/scripts/asc_whats_new.swift`
  (ASC API, ES256 JWT via CryptoKit — no dependencies). It polls until
  processing finishes; on timeout the release still succeeded and the
  script prints the exact re-run command (idempotent). `--check-auth 1`
  validates the key + app record without touching any build.

## One-time setup

1. **App record** — App Store Connect → Apps → “+” → New App: platform iOS,
   bundle ID `com.s3ni0r.meshtracker`, a name, SKU anything. Add yourself
   under TestFlight → Internal Testing group. ← **the only missing step**
2. **API key** — already in place: the team key (team `H6956Z7A2F`) is
   shared with AutoShot; `.release-env` at the repo root (git-ignored)
   carries `ASC_KEY_ID` + `ASC_ISSUER_ID`, and the `.p8` lives at
   `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`.
3. **xcodegen** — `brew install xcodegen` (already installed).

Signing stays **Automatic**; `-allowProvisioningUpdates` plus the API key
lets `xcodebuild` create/refresh the distribution certificate and profile
headlessly (first run takes a little longer).

## Switching builds on-device

TestFlight → MeshTracker → the version list shows each train's latest
build (with its What to Test note); "Previous Builds" reaches anything
older. Install replaces the current one — app data persists (same bundle
id). Builds expire after 90 days; expire superseded experiment builds in
ASC now and then so the picker stays readable.

## Troubleshooting

- **"HEAD carries no v* tag"** — mainline releases are cut from tags only;
  experiments only need a *reachable* tag (for the `MAJOR.MINOR` base).
- **Signing/auth errors** — check the `.p8` path matches `ASC_KEY_ID` and
  the key role is App Manager.
- **"no ASC app record for bundle id"** — do one-time setup step 1.
- **What to Test failed / timed out** — the upload already succeeded;
  re-run the printed `swift ios/scripts/asc_whats_new.swift …` command
  once processing finishes (safe to repeat).
- **Build number collision** — mainline: only if re-releasing the same
  commit count; experiments: effectively impossible (UTC-minute builds).
