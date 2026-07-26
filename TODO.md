# TODO — roadmap (rewritten 2026-07-26, post-R5)

The next milestones, grouped by theme and ordered so prerequisites come first. Shipped
history: [docs/HISTORY.md](docs/HISTORY.md). Wire contract: [docs/DOWNLINK.md](docs/DOWNLINK.md).

## A. Fleet configuration & identity UX

### A1. Config-channel parity for the BLE5/LoRa bridge tag

Today the portnum-260 channel (settings, mode, signals, simulator, naming) exists only in
the GPS-tag flavor; the bridge is TX-only and configurable over USB alone. Bring the bridge
to parity for every operation that is not GPS-chip-specific — its position source is the
external Dronetag, so GNSS knobs (nav mode, fix rate, SNR/elevation masks) stay out; TX
spacing, adaptive/calibration behavior, signals, naming and profiles all apply.

- [ ] Design first: enabling radio RX on the bridge ends `HIGHRATE_TX_ONLY` for that flavor
      — quantify the battery cost (standby µA → RX mA) and the CLIENT_MUTE story, mirroring
      what tag-downlink did for the GPS tag.
- [ ] Split `GnssConfigModule` into transport + capability sets; the settings reply must
      advertise WHICH knob groups the tag supports (extend the existing
      length-is-capability signal into an explicit capability byte — cleaner than a fourth
      length variant).
- [ ] Bridge flavor: enable BLE advertising (it currently advertises nothing) so the app
      can reach it directly like the GPS tag.
- [ ] iOS Tag Setup: render knob groups from the capability signal instead of assuming the
      GPS-tag feature set.
- [ ] Bench: extend `verify_fixes.py` (or a sibling) to run the non-GPS op set against the
      bridge on USB.

### A2. Device-type advertisement (AutoShot-facing discovery contract)

Base and tags must expose their TYPE at BLE discovery time so external apps (AutoShot
first) can drive identification/connection cycles without name heuristics (today's
"contains 'base'" matching is exactly the fragility the reviews keep flagging).

- [ ] Pick the carrier: BLE advertisement manufacturer-data or service-data field carrying
      {device type: base / gps-tag / bridge-tag, protocol version, node id short}. Must
      coexist with the stock Meshtastic advertisement (apps that don't know us keep
      working).
- [ ] Implement in all three flavors (the Base too — it is the AutoShot connection target).
- [ ] Replace MeshTracker's name heuristics with the typed advertisement (keep the
      heuristic as fallback for pre-upgrade fleets).
- [ ] Document the discovery contract in a new `docs/DISCOVERY.md` (external-consumer doc,
      like BATTERY_INTEGRATION.md) for the AutoShot team.

### A3. Persistent tag naming

- [ ] Flash-time default names that state the FUNCTION: `TAG-GPS-<short>`, `TAG-BR-<short>`,
      `BASE-<short>` (today naming is a manual `--set-owner` cheat-sheet step).
- [ ] App-side rename (both tag flavors + Base) that PERSISTS on the device — decide
      between the Meshtastic admin owner field (interoperable, shows in every Meshtastic
      app) vs a portnum-260 field (works over the LoRa downlink at range). Leaning: owner
      field via admin for BLE-direct, mirrored into the 260 settings for range renames.
- [ ] Renames must propagate into MeshTracker labels, session metadata, and the A2 typed
      advertisement.

### A4. Persistent operating profiles (both tag flavors)

Today every safety-relevant mode is deliberately RAM-only (CALIBRATION and the simulator
die by TTL; reboot = adaptive). Users need a sanctioned way to make a chosen behavior
permanent — e.g. "never fall back to adaptive".

- [ ] Profile model, chosen in the iOS app and persisted on the tag:
      - **Hybrid** (today's behavior, stays the default): adaptive at boot; calibration
        bursts via TTL dead-man; nothing risky persists.
      - **Permanent**: the selected TX parameters persist across reboots — including
        disabling the adaptive fallback for a fixed-rate tag.
- [ ] Safety design REQUIRED before code: a persistent max-rate profile must not be able to
      silently violate EU868 duty (CAPACITY.md math enforced at SET time: reject
      persist-requests whose sustained rate is illegal for the configured region) and must
      remain escapable at range (a 260 op that always restores Hybrid, plus the
      known-good reflash path).
- [ ] Wire: extend settings v3 → v4 (profile byte + validation), stream-flags echo of the
      active profile, app UI with explicit "this persists across reboots" consent.

## B. Platform & architecture

### B1. Dual-stack support: Meshtastic AND MeshCore

The largest architectural decision: everything today is a Meshtastic fork. MeshCore must be
supported permanently alongside it — not as a migration.

- [ ] Write the design doc FIRST (`docs/DUAL_STACK.md`) and get it reviewed before any
      code. Core principle to evaluate: our real product is the WIRE CONTRACT (19 B v4
      uplink + portnum-260 command set + discovery advertisement), not the mesh stack —
      port the contract, keep the app/tools stack-agnostic.
- [ ] Survey MeshCore's primitives: custom payload transport (PRIVATE_APP equivalent),
      BLE phone API, duty-cycle handling, nRF52/T1000-E support maturity, licensing.
- [ ] Repo shape decision: `firmware/meshtastic-firmware/` + `firmware/meshcore/` clones
      with the same tracked-patch + drop-in + `sync/apply` discipline; shared protocol
      sources factored so GnssSim/GnssMotion/payload builders compile in both trees.
- [ ] App/tools: transport abstraction where BLE GATT details differ; `nodes.py` and the
      bench must address a tag by role regardless of stack; the bench suite becomes the
      cross-stack conformance test (same 28+ assertions against either firmware).
- [ ] Release/provenance: the attestation machinery (base OID pin, locks, release_build)
      must generalize to a second vendor tree.

### B2. OTA firmware update of tags

The endgame for fleet operations: no USB, no double-tap — update a tag from the iPhone.

- [ ] Investigation first: the Adafruit-lineage bootloaders on this fleet support BLE OTA
      DFU in principle, but the fleet runs TWO bootloader generations (0x239A "T1000-E-BOOT"
      and Seeed 0.9.1 0x2886) — establish per-generation OTA capability, and whether
      Meshtastic's BLE stack (and later MeshCore's) leaves the OTA DFU service reachable
      (or needs a reboot-into-OTA admin command).
- [ ] Safety design is the hard part, and the existing review bar applies: signed/verified
      packages (extend the release attestation to the OTA artifact), power-loss behavior
      mid-update (bootloader dual-bank vs single-bank — we ship singlebank today),
      a never-brick guarantee consistent with `known-good/restore.sh` thinking, and an
      explicit "wrong-tag" guard (type + node-id check before any transfer, per A2).
- [ ] iOS: DFU client — decide dependency-free hand-rolled (app tradition) vs vendoring
      Nordic's protocol; fleet update UX (per-tag version display from the stamped
      `vX.Y.<sha8>` identity, staged rollout: one tag, verify stream, then the rest).
- [ ] Bench: an OTA regression gate on real hardware before this ever ships (update,
      verify identity + stream, deliberate mid-transfer abort, recovery).

## C. Repo & agent hygiene

### C1. Skills generic to all agents (standing rule) — DONE 2026-07-26

- [x] All five procedures live at the STANDARD agent-files location,
      `.agents/skills/<name>/SKILL.md` (same structure and frontmatter every agent tooling
      reads); `.claude/skills/<name>` are symlinks into it — one source of truth, zero
      duplication (harness skill loading verified through the links).
- [x] AGENTS.md and every living doc reference the standard paths.
- **Standing rule in force**: anything written for agents (procedures, onboarding,
  contracts) lands in the shared standard layout (`AGENTS.md` + `.agents/`); tool-specific
  directories only ever contain links or shims into it.

### C2. Repo noise cleanup — DONE 2026-07-26

- [x] Verified already ignored/untracked: `firmware/build-out/` (stale artifacts also
      deleted locally), `ios/build/`, `ios/dist/`, `__pycache__`, `.DS_Store` (stray root
      copy deleted).
- [x] `ios/MeshTrackerWatch/` removed (dormant — it was never a target in `project.yml`;
      the phase-2 Apple Watch idea remains in PLAN §8, the dead scaffold is in git
      history). watchOS deployment option dropped from `project.yml`.
- [x] `tools/` sweep: `m1_gps_rate_check.md` (superseded by `docs/gnss/UNLOCK_NOTES.md`)
      and `freshness_analyze.py` (no living references) deleted; `m2_stream_poc.py` KEPT —
      it is the reference decoder cited by `docs/BATTERY_INTEGRATION.md` and FORK.md.

## Carried over (still pending, unchanged)

- [ ] Tune sea/surf motion thresholds from recorded session `me` data, then accel-gate the
      adaptive TX (instant upshift on the pop-up) — needs real sessions at sea.
- [ ] Battery win measurement: %/hour parked vs moving via session `bt` slopes.
- [ ] iOS parked-position handling (ZUPT display fusion: freeze marker, average fixes,
      reject impossible jumps).
- [ ] GNSS: EPO/AGNSS TTFF injection design; drone nav-mode flag for airborne use.
- [ ] Experiments: Base-as-reference differential; orientation-vs-RSSI diagnostics.
- Engineering debt (review-acknowledged): bit-exact builds; async recorder I/O; map idle
  timer; host-side CI; **physical power-cut fault injection** for the track-slot commit
  path (still architecture reasoning, not measurement).

## Out of scope (decided)

- Inertial dead reckoning / EKF tight coupling (hardware can't support it).
- Impact / free-fall event bit (user decision 2026-07-04).
- Temperature + lux telemetry (available in `T1000xSensor.cpp`; not valuable here).
