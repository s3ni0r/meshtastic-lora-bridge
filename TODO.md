# TODO — roadmap (rewritten 2026-07-26, post-R5)

The next milestones, grouped by theme and ordered so prerequisites come first. Shipped
history: [docs/HISTORY.md](docs/HISTORY.md). Wire contract: [docs/DOWNLINK.md](docs/DOWNLINK.md).

## A. Fleet configuration & identity UX

### A1. Config-channel parity for the BLE5/LoRa bridge tag

Today the portnum-260 channel (settings, mode, signals, simulator, naming) exists only in
the GPS-tag flavor; the bridge is TX-only and configurable over USB alone. Bring the bridge
to parity for every operation that is not GPS-chip-specific — its position source is the
external Dronetag, so GNSS knobs (nav mode, fix rate, SNR/elevation masks) stay out.
Per the settled model (RADIO_STATES §2 wins, review 2026-07-26): the bridge has NO
ADAPTIVE/CALIBRATION TX modes — its knob set is TX spacing, signals, naming, profiles
and the radio state.

- [x] **DONE (2026-07-26)** — `-DHIGHRATE_TX_ONLY` retired: runtime DEAF via the shared
      `TagRadioState` module on BOTH flavors; the bridge boots LISTENING and goes deaf on
      command; CLIENT_MUTE mirrors the GPS tag. (RX-cost quantification standby µA → RX mA
      still pending a powered measurement.)
- [x] **DONE** — RADIO op (0x06, ACK-before-mute + 2 s grace) and SIGNAL v5 correlated ACKs
      ship on both flavors; bridge advertises slow connectable BLE (~1.0 s interval)
      alongside the ODID scanner (`NRF52Bluetooth.cpp`).
- [x] **DONE** — explicit capability byte in every settings reply (GPS tag 0x3F, bridge
      0x38) + radio-status byte + the tag's OWN duty-floor u16 (reply = 20 bytes, v4).
- [x] **DONE** — bridge BLE advertising enabled (slow interval preserved across
      resumeAdvertising too).
- [x] **DONE** — iOS Tag Setup renders cards from the capability byte (bridge targets show
      signals/radio/profiles only; pre-v4 falls back per flavor).
- [x] Bench: `verify_bridge.py` covers the bridge op surface (D1–D6) on USB, and the
      sniffer-throughput A/B is MEASURED (2026-07-26, live Dronetag sim): slow adv costs
      ~14 % of scan callbacks, a held BLE session ~40–45 % — transient by design; numbers +
      caveats in docs/DOWNLINK.md. Tools: tools/bench/{sniff_stats,bridge_ab}.py.
      Still unmeasured: RX-power delta (LISTENING vs DEAF, standby µA vs RX mA) — needs a
      current probe, not a protocol bench.

### A2. Device-type advertisement (AutoShot-facing discovery contract)

Base and tags must expose their TYPE at BLE discovery time so external apps (AutoShot
first) can drive identification/connection cycles without name heuristics (today's
"contains 'base'" matching is exactly the fragility the reviews keep flagging).

- [x] **DONE (2026-07-27)** — carrier: manufacturer data in the SCAN RESPONSE
      (`FF FF 'M' 'T' ver type node-u32LE`; type 1 bridge / 2 gps / 3 base), coexisting with
      the stock service-UUID primary advert. All three flavors; boot log prints
      `DISC adv: ver=1 type=.. node=0x..` (verified on the GPS tag).
- [x] **DONE** — MeshTracker keys Base selection + tag fallback on the typed advert
      (`DiscoveryAd.parse`); name heuristics remain only for pre-A2 firmware.
- [x] **DONE** — `docs/DISCOVERY.md` (external contract for AutoShot: layout, consumer
      rules, node-id identity binding, slow-adv caveat for the bridge).
- [ ] Fleet rollout: the BRIDGE still runs v4.4 (pre-A2) firmware — flash it after the
      soak-instrument verdict; the Base needs a reflash too (v4.2 has no typed advert).

### A3. Persistent tag naming

- [x] **DONE (2026-07-27)** — factory-default owner names state the function
      (`TAG-GPS-xxxx` / `TAG-BR-xxxx` / `BASE-xxxx`, NodeDB patch; only a factory-fresh
      owner gets them — renames persist over them).
- [x] **DONE** — app-side rename via the admin owner field over the DIRECT link (tags via
      the settings link or direct main link; the Base via its main link) — persists
      on-device, re-broadcasts as NodeInfo. DECIDED: range renames via a 260 mirror are NOT
      implemented — remote admin needs the passkey/PKI dance and close-range rename covers
      the actual workflow; revisit only if field use demands it.
- [x] **DONE** — names propagate: NodeInfo parsing on both links → PositionModel registry →
      track titles → session metadata (recorder uses titles). The typed advertisement
      carries the NODE ID (names are display-only by contract — DISCOVERY.md rule 3).

### A4. Radio states + persistent profiles — MODEL AGREED 2026-07-26 (owner sign-off)

State machines locked as Mermaid diagrams in [docs/RADIO_STATES.md](docs/RADIO_STATES.md)
(per-flavor HYBRID, PERMANENT, and the guaranteed-delivery session-start sequence — the
implementation reference for this package).

"TX-only" stops being a build flag and becomes a **runtime radio state** both tag flavors
walk through. Portnum 260 is needed only for the calibration stage; the session runs deaf.

**The two radio states (both flavors):**
- **LISTENING** — RX between transmissions: commands/signals/simulator work at LoRa range.
- **DEAF** — today's TX-only: radio sleeps between TX; best battery, no RX-in-progress
  deferral (pre-TX CAD backoff on a busy channel remains — that is collision avoidance,
  not capture), no LoRa command can reach it. BLE/USB commands still work.

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
radio state (permanently LISTENING or permanently DEAF). Closure rules (review
2026-07-26): radio-state commands in PERMANENT REWRITE the persisted profile — no
temporary states; duty legality enforced at SET **and revalidated at every boot and on
region/preset change** (illegal persisted params clamp to nearest legal spacing + a
"profile degraded" flag — never silent illegal TX); app shows "persists across reboots"
consequences explicitly.

**Agreed decisions (2026-07-26) — IMPLEMENTED + HIL-VERIFIED 2026-07-26 (69-assertion
suite; see docs/DOWNLINK.md "Measured results" for the evidence list):**
- [x] **Guaranteed signal delivery (the ACK's real purpose)** — a calibration SIGNAL
      (beep/flash) must REACH the tag no matter what: the user acts on hearing it, so a
      silently lost command is a calibration failure. Semantics: **at-least-once delivery,
      at-most-once playback per signal id** (design review 2026-07-26 tightened the
      earlier wording) — SIGNAL carries a client-chosen u32 sid (TRACK-tid discipline);
      the sender retransmits the SAME sid until a correlated ACK arrives (echo
      op + pattern + sid; never satisfiable by a stale or foreign reply). Tag dedupe is
      {sid, pattern}: exact re-send re-ACKs without replaying; same-sid different-pattern
      NAKs (the u8-seq collision hole, closed). ACK = accepted + playback scheduled
      (≲50 ms), not "audio finished". Accepted residual: RAM-only dedupe means a reboot
      inside the seconds-long retry window could replay one signal — documented, harmless
      for this vocabulary. Bounded retries (~0.3 s apart), then a LOUD in-app failure.
      GO-DEAF gets the same retry treatment with a TWO-LAYER confirmation (review fix):
      the tag ACKs then holds a ~2 s mute-grace (duplicates re-ACKed) before muting, and
      the app also accepts the next stream packet's v5 status byte reading DEAF — even if
      every ACK is lost, the stream proves the transition. Ordering: record-start beep
      (confirmed) → go-deaf.
- [x] **Fully deaf** — no post-TX listen window (option rejected; simplicity + max battery).
      HIL-proven: 3 Base-relayed LoRa attempts unanswered while DEAF, USB path alive.
- **Button toggle REMOVED (owner decision 2026-07-26, superseding the earlier hatch):**
  radio-state control is exclusively the iOS app — LoRa while LISTENING, BLE at close
  range in any state. Recovery ladder: LoRa → BLE → reboot (HYBRID never persists
  deafness). Accepted consequence: a PERMANENT·DEAF tag is reachable only via BLE/USB;
  the app states this at profile-set time.
- [x] Payload v5 status byte (radio state + active profile) — **REQUIRED phase 1**: it
      is the GO-DEAF fallback confirmation (review fix), not just visibility. The
      20-byte payload stays in the same ShortFast symbol group, zero added airtime.
      Ship with an explicit COMPATIBILITY CHECKLIST covering every consumer of the
      length-is-version rule (MeshTracker, tools/m2_stream_poc.py, bench decoders,
      BATTERY_INTEGRATION.md external guidance) — same checklist covers the new
      capability byte and profile byte.
- [x] Wire: settings v3 → v4 (profile byte + validation + capability/radio-status/duty-floor
      reply bytes); SET profile 0x00 restores Hybrid; known-good reflash remains the
      last-resort escape.
- [x] **Generic implementation (agreed)**: ONE shared radio-state module compiled into
      both flavors (states, persistence rules, radio-state op + ACK-before-mute, signal
      retry discipline, BLE/USB path in every state); flavor code only supplies what runs
      inside the states. BLE deaf-toggle works at close range in ANY state on both
      flavors — the bridge side rides A1's slow connectable advertising (≲0.3 %
      scan-time cost, bench A/B with the sniffer as acceptance gate).

### A1/A4 round findings (2026-07-26, need owner decisions)

- **Fleet preset is SHORT_TURBO, docs assume ShortFast.** Measured on the bench: base+tags
  run SHORT_TURBO (500 kHz BW) — EU-ILLEGAL, so EU deployment cannot ship the bench preset;
  CAPACITY.md's ShortFast math needs re-anchoring, and the deployment plan needs an explicit
  preset decision. The tags now self-report their duty floor (settings reply bytes 18–19),
  measured 5590 ms under LONG_FAST+EU868 on real hardware.
- Region cycling destroys EU-illegal presets (firmware behavior): any tooling that touches
  `lora.region` must save/restore the preset and re-prove the air path (bench C5 now does).

## B. Platform & architecture

### B1. Dual-stack support: Meshtastic AND MeshCore — **POSTPONED (owner decision 2026-07-26)**

On hold: the survey is done and banked ([docs/DUAL_STACK.md](docs/DUAL_STACK.md), studied
from source @ a3a1aa5e), but no spike, no second vendor tree, no port work for now.
Everything below stays as the ready-to-resume plan. Practical carry-over while postponed:
keep new modules stack-agnostic where it is FREE (the A4 radio-state module already is) —
no speculative abstraction beyond that.

- [x] **Survey DONE (2026-07-26)** — [docs/DUAL_STACK.md](docs/DUAL_STACK.md): studied
      MeshCore @ a3a1aa5e from source. Headlines: MIT license; T1000-E first-class
      (CustomLR1110 + QMA6100P + GPS power control); GRP_DATA = a cleaner PRIVATE_APP
      (u16 data-type with public registry, dev range free); sendZeroHop = our exact
      no-rebroadcast pattern; duty budget is first-class in the Dispatcher; signed
      Ed25519 ADVERTs give LoRa-side typed discovery for free; companion BLE protocol is
      documented but churning (pin versions); GPS driver is 1 Hz-class (our AG3335
      unlock ports — chip knowledge is stack-independent). Wire-contract mapping table +
      per-roadmap-item implications in the doc.
- [ ] Owner sign-off on the mapping + module boundaries (DUAL_STACK.md §2–3), then the
      SPIKE before any architecture: minimal MeshCore app streaming the exact 19 B
      payload as GRP_DATA via sendZeroHop on our hardware, bench-received.
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
      and `freshness_analyze.py` deleted (cited only inside the dated 2026-06-25
      measurement record in `docs/results.md`, which now notes the tool lives in git
      history — the earlier "no references" claim was imprecise); `m2_stream_poc.py`
      KEPT — it is the reference decoder cited by `docs/BATTERY_INTEGRATION.md` and
      FORK.md.

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
