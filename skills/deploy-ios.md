# Deploying MeshTracker

> **Use when:** Build MeshTracker and install it on the connected iPhone (the standing rule for EVERY iOS change), plus the TestFlight release path. Use for "deploy the app", "test on my phone", or after any Swift change.
>
> Agent-neutral procedure (standing rule C1: anything written for agents lives
> vendor-neutrally; `skills/deploy-ios.md` is only the Claude Code shim).


**Standing rule:** every iOS change ends with build → install on the physical iPhone. A
compile check alone is never "done".

## Device build + install (the default loop)

Connected iPhone 17 Pro device id: `3E5C778B-8B00-5E9A-9D74-B00576E90FB4`.

```bash
cd <repo-root>/ios
xcodebuild -project MeshTracker.xcodeproj -scheme MeshTracker -configuration Debug \
  -destination 'id=3E5C778B-8B00-5E9A-9D74-B00576E90FB4' -derivedDataPath build \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device 3E5C778B-8B00-5E9A-9D74-B00576E90FB4 \
  build/Build/Products/Debug-iphoneos/MeshTracker.app
```

Run the build in the background and stream/tail it — it takes 1–3 min. `devicectl install`
prints an `installationURL` on success. Installing does NOT auto-launch the app.

## Gotchas

- **New Swift files require `xcodegen`** (project generated from `ios/project.yml`) before
  xcodebuild sees them.
- **SourceKit single-file diagnostics are noise** in this repo ("Cannot find type ...",
  "'configuration.h' file not found") — xcodebuild and `pio run` are the only real gates.
- Long string concatenations can hit the Swift type-checker timeout — split into `+=` lines
  (bit us in `SessionStore.writeCSV`).
- After deploying, the app may immediately BLE-connect to the Base or tag — which **locks
  out their USB PhoneAPI** (single client). Expect bench/CLI connects to time out until the
  app disconnects.
- Wire-protocol changes (payload bytes, portnum 260 ops) must land in firmware AND
  `MeshProto.swift` in the same round — protobufs are hand-rolled here, nothing regenerates.

## TestFlight release (when asked to ship, not for the dev loop)

```bash
ios/scripts/release.sh [version] --note "what changed"       # mainline train
ios/scripts/release.sh --exp <name> --note "what changed"    # experiment train
```
Needs the git-ignored `.release-env` (repo root: `ASC_KEY_ID`, `ASC_ISSUER_ID`) and the
`.p8` key in `~/.appstoreconnect/private_keys/`. Never commit either. Details:
`docs/testflight-release.md`.
