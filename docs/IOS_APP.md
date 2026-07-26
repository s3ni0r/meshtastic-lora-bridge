# MeshTracker (iOS) — features and architecture

SwiftUI + CoreBluetooth app (`ios/`), dependency-free: Meshtastic protobufs are
**hand-rolled** in `MeshProto.swift` (encode + decode of exactly the frames this system
uses — nothing regenerates, wire changes are edited by hand in lockstep with firmware).
Project is generated from `ios/project.yml` — run `xcodegen` after adding files.
Deployment: build → install on the physical iPhone every time (see
`.claude/skills/deploy-ios/SKILL.md`); TestFlight via `ios/scripts/release.sh`
(`docs/testflight-release.md`).

## Connectivity model

`BLEManager` scans for the standard Meshtastic GATT service and prefers a **Base**
(name-matched); if none appears within ~6 s it falls back to a **direct tag link** (that
tag only, BLE range). One BLE client per node — a connected app locks out the node's USB
PhoneAPI (bench implication documented in `tools/bench/README.md`). Every connection attempt
owns a `linkGeneration`; replaced peripherals are detached/cancelled and every delegate
callback is identity-fenced. Config replies are adopted only when their exact sender
(`MeshPacket.from`) matches and their per-link sequence follows the current GET/SET request.

`TagConfigManager` is a second, short-lived link straight to a GPS tag for configuration
while the Base link keeps streaming. It trusts nothing until the peripheral's own
`my_info.my_node_num` matches the target (identity gate); the peripheral↔node mapping is
persisted only after that match and deleted on mismatch, and callbacks from a previous
central/peripheral are fenced out. A remembered UUID that fails or does not prove identity
within its timeout is forgotten and scanning resumes; stopping the manager cancels its tasks
and detaches both delegates.

## Screens / aspects

- **Map (ContentView)** — live multi-tag tracking: per-tag colored trails + heading
  arrows, favorites, per-tag show/hide, pin/follow focus, map styles, fit-all; metric
  tiles (speed/heading/alt/accuracy/SNR/RSSI + battery + motion mg/moving); status capsule
  with connection route ("Direct" prefix on tag links), REC state with write-failure
  surfacing, and the tag's live TX tier (`idle / fast / cal`, `SIM` when simulated).
- **Tag Setup (TagSetupView)** — the GPS tag configuration space, over the Base downlink or
  a direct link:
  - GNSS knobs (nav mode, static freeze, SNR/elevation masks, fix rate, TX spacing) with
    one-tap France/US profiles; settings wire v3 adds the four adaptive-TX knobs (v3-gated
    UI — the tag's reply length is the capability signal). Duty-cycle legality is computed
    and shown next to the rates.
  - **TX mode** card: CALIBRATION (TTL dead-man, auto-refreshed while the screen is open)
    vs ADAPTIVE, confirmed by the stream-flags echo, never by an ack.
  - **Operator signals** test panel (beep language v2: counted / record-start / problem).
  - **Simulator** card: parametric speed programs (persisted), shake-to-move, and track
    replay — import a GPX or a recorded session, decimate to the 800-record slot cap
    (`TrackReplay.swift`), upload over a direct link (BEGIN/CHUNK/COMMIT with a u32
    transfer id, every frame individually ACK-verified against a sequenced per-link ACK
    queue), then play/stop from anywhere. Uploads are owned `Task`s bound to one tag, one
    link generation and one upload generation. Cancellation remains distinct from failure,
    and every post-`await` UI mutation revalidates that generation, so a replaced task cannot
    fail or complete its successor.
- **Sessions** — measurement-grade recording: every received packet lands verbatim as
  crash-safe JSONL under `Documents/sessions/<uuid>/` (`SessionStore.swift`); recovery on
  next launch rebuilds finalization from the raw files and discovers tracks by scanning
  the directory (never trusting possibly-unpersisted metadata). Library with stats,
  full-resolution map projection of past sessions, moment explorer (scrubber, accuracy
  circles, fix scatter), CSV + GPX exports carrying battery (`bt`) and motion (`me`)
  per point — the dataset that will tune the sea-motion thresholds.

## Wire contracts the app implements

Uplink 19-byte payload v4 (`docs/BATTERY_INTEGRATION.md`); downlink portnum 260 ops and the
packet-building rules — `priority=HIGH`, `hop_limit=1`, `want_ack=false`, confirmation via
stream flags (`docs/DOWNLINK.md`). Telemetry fallback: portnum 67 DeviceMetrics (Base every
15 s; pre-v3 tags).
