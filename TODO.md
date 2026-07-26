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

- [ ] Design first, aligned with the A4 model: `HIGHRATE_TX_ONLY` becomes the runtime DEAF
      state on BOTH flavors — the bridge is LISTENING only during the calibration stage,
      then goes deaf for the session, so the continuous-RX battery cost applies only to
      calibration windows (quantify it anyway: standby µA → RX mA; the bridge has no GNSS
      draw to hide it under). CLIENT_MUTE story mirrors the GPS tag.
- [ ] The go-deaf/radio-state op and correlated SIGNAL ACKs (A4 decisions) ship as part of
      this parity work — the bridge needs them for its calibration-stage role. The button
      LISTENING↔DEAF toggle is the field escape hatch on both flavors (BLE advertising on
      the bridge stays in scope for config parity, but deaf-recovery does NOT depend on it).
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

### A4. Radio states + persistent profiles — MODEL AGREED 2026-07-26 (owner sign-off)

State machines locked as Mermaid diagrams in [docs/RADIO_STATES.md](docs/RADIO_STATES.md)
(per-flavor HYBRID, PERMANENT, and the guaranteed-delivery session-start sequence — the
implementation reference for this package).

"TX-only" stops being a build flag and becomes a **runtime radio state** both tag flavors
walk through. Portnum 260 is needed only for the calibration stage; the session runs deaf.

**The two radio states (both flavors):**
- **LISTENING** — RX between transmissions: commands/signals/simulator work at LoRa range.
- **DEAF** — today's TX-only: radio sleeps between TX; best battery, zero TX deferral, no
  LoRa command can reach it. BLE/USB commands still work (phone path bypasses the radio).

**HYBRID profile (default — the AutoShot choreography):**
1. Power-on → LISTENING + adaptive TX, always (a fresh tag is always commandable at range).
2. Calibration stage: CALIBRATION mode (TTL dead-man unchanged) + convergence beeps —
   both flavors (the bridge has the same buzzer/LED; it only lacks GNSS knobs).
3. Session start: record-start signal, then the **go-deaf command**; the tag sends its
   correlated ACK FIRST, then mutes and runs session behavior (GPS tag adaptive, bridge
   relaying) fully deaf.
4. Deafness is NEVER persisted: reboot → LISTENING + adaptive. Recovery paths below.

**PERMANENT profile (explicit app consent):** boots straight into its configured behavior,
no transitions, no TTLs: fixed TX parameters (e.g. adaptive fallback disabled) AND a fixed
radio state (permanently LISTENING or permanently DEAF). Duty legality enforced at SET
time (CAPACITY.md math; illegal sustained rates rejected for the configured region); app
shows "persists across reboots" consequences explicitly.

**Agreed decisions (2026-07-26):**
- [ ] **Guaranteed signal delivery (the ACK's real purpose)** — a calibration SIGNAL
      (beep/flash) must REACH the tag no matter what: the user acts on hearing it, so a
      silently lost command is a calibration failure. Semantics: **at-least-once delivery,
      exactly-once playback** — the sender retransmits with the SAME seq until a
      correlated ACK arrives (ACK echoes op + pattern + seq; never satisfiable by a stale
      or foreign reply); the tag's existing seq-dedupe ACKs duplicates without replaying,
      so retries can never double-beep. Bounded retries (interval sized to the measured
      ~0.3 s downlink), then a LOUD in-app failure — "tag did not confirm the signal" is
      surfaced, never swallowed. The go-deaf/radio-state command gets the same
      retry-until-ACK treatment and always ACKs BEFORE muting; ordering: record-start
      beep (confirmed) → go-deaf.
- [ ] **Fully deaf** — no post-TX listen window (option rejected; simplicity + max battery).
- [ ] **Button escape hatch, no BLE dependency**: pressing the T1000-E button X times
      toggles LISTENING ↔ DEAF in the field, each direction with a DISTINCT beep
      signature (vocabulary addition owner-approved 2026-07-26). Pick X to not collide
      with stock Meshtastic button actions; works on both flavors even without BLE.
- [ ] Payload v5 status byte (radio state + active profile) for ongoing visibility after
      app restarts — the 20-byte payload stays in the same ShortFast symbol group, zero
      added airtime. ACK confirms transitions; the status byte answers "what state is
      this tag in NOW".
- [ ] Wire: settings v3 → v4 (profile byte + validation); a 260 op that restores Hybrid;
      known-good reflash remains the last-resort escape.

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
- [x] `CLAUDE.md` is a SYMLINK to `AGENTS.md` (no vendor-specific content anywhere), and
      the whole rule is ENFORCED by `tools/tests/test_agent_files_layout.py`: vendor entry
      files must be symlinks, `.claude/skills` entries must resolve inside
      `.agents/skills`, frontmatter must match directory names, ad-hoc locations fail.
- **Standing rule in force (now a failing test, not prose)**: anything written for agents
  lands in the shared standard layout (`AGENTS.md` + `.agents/`); tool-specific
  files/directories only ever contain links into it.

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
