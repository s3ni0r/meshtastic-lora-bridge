---
name: release-testflight
description: Ship MeshTracker to TestFlight — mainline or experiment-train releases with identifiable builds and automated "What to Test" notes. Use when asked to release, ship a beta, cut a TestFlight build, publish an experiment variant, or when a release/upload/What-to-Test step fails.
---

# Releasing MeshTracker to TestFlight

Full reference: [docs/testflight-release.md](docs/testflight-release.md).
One command from a **clean tree** (the script refuses anything dirty —
releases are reproducible from git):

```sh
# Mainline: HEAD must carry a v* tag (the tag IS the marketing version)
git tag -a v2.1 -m "…"
ios/scripts/release.sh [--note "custom note"]

# Experiment train from any branch — the note is REQUIRED
ios/scripts/release.sh --exp <name> --note "What this build is / what to test."
```

Pipeline: xcodegen regenerate (the xcodeproj is gitignored; `project.yml`
is the truth) → Release archive → **identity injection** (train, branch,
short sha, UTC date, note → `AS*` Info.plist keys via `plutil`; export
re-signs) → upload to App Store Connect → **What to Test** pushed via the
ASC API (`ios/scripts/asc_whats_new.swift`, polls out the ~5–15 min
processing).

## The train model (never edit numbers by hand)

- **mainline** — version = v-tag, build = commit count.
- **experiment** — version = `MAJOR.MINOR` of nearest tag + train number
  (`2.0.101`), build = UTC `yymmddHHMM`. Train numbers live in
  `ios/scripts/trains.env`, auto-assigned + **auto-committed** on first
  `--exp <name>` (expect that extra commit; push it afterwards).
- All trains share ONE bundle id / ASC record — testers switch builds in
  TestFlight (version list / Previous Builds); app data persists.

## Gotchas the hard way

- **Don't `tee` a log into the repo during a release** — the untracked
  file trips the clean-tree check. Log outside the repo.
- **What to Test fails ≠ release failed**: the upload already succeeded;
  the script prints the exact `swift ios/scripts/asc_whats_new.swift …`
  re-run command (idempotent). `--check-auth 1` validates key + app
  record without touching builds.
- Secrets: `.release-env` (repo root, git-ignored) holds
  `ASC_KEY_ID`/`ASC_ISSUER_ID`; the `.p8` lives in
  `~/.appstoreconnect/private_keys/`. Never commit either.
- One-time ASC app record for `com.s3ni0r.meshtracker` must exist
  (docs §setup) — "no ASC app record" means it doesn't yet.
- New Info.plist keys that builds need (e.g. the compliance key) go in
  `project.yml` `info.properties`, NOT a hand-edited Info.plist (it's
  generated).

## Before releasing

Confirm the release content with the user: train + version + build source
(`branch@sha`), the delta since the last shipped tag
(`git log --oneline <tag>..HEAD`), and the note text — the note ships
verbatim in-app-readable Info.plist keys and TestFlight.
