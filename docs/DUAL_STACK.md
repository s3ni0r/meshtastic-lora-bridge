# Dual-stack design: Meshtastic + MeshCore (B1)

> **Status: POSTPONED (owner decision 2026-07-26). Survey complete and banked; no port
> work is planned for now — this document is the resume point when dual-stack is picked
> back up.**
> Studied from source: `github.com/ripplebiz/MeshCore` @ `a3a1aa5e` (2026-07-19, active),
> plus its protocol docs (`docs/packet_format.md`, `payloads.md`, `companion_protocol.md`,
> `number_allocations.md`). Governing principle (TODO §B1): **our product is the wire
> contract** — 19 B v4/v5 uplink payload, the command-op semantics (settings, MODE,
> SIGNAL with guaranteed delivery, SIM, TRACK, radio states), and typed discovery. Mesh
> stacks are port targets underneath it. Every roadmap decision (A1/A4 radio states, A2
> discovery, OTA) is checked against BOTH stacks below.

## 1. What MeshCore is (survey findings, file-referenced)

- **License: MIT** (Scott Powell / rippleradios). No copyleft — a sharp contrast with the
  Meshtastic fork's GPL-3.0 obligations. Our firmware-side code stays open either way;
  MIT removes the derivative-work friction for everything else.
- **Compact core**: `src/` is ~6 files (Packet, Dispatcher, Mesh, Identity, Utils) — the
  whole radio/mesh core is smaller than Meshtastic's module system. Apps are standalone
  programs under `examples/` (`companion_radio` = phone-facing node, `simple_sensor`,
  `simple_repeater`) built over the library; our tag firmware would be another such app.
- **T1000-E is first-class**: `variants/t1000-e/` with `CustomLR1110` (RadioLib wrapper,
  `helpers/radiolib/`), GPS power control (`start_gps/sleep_gps/stop_gps`), and
  `HAS_QMA6100P` + its INT pin already defined. Boards/build = PlatformIO, same as today.
- **Packet format** (`Packet.h`, 1-byte header = 2b route, 4b payload-type, 2b version):
  - `PAYLOAD_TYPE_GRP_DATA` (0x06): channel-hash (1 B) + MAC (2 B) + encrypted
    `{data_type u16, data_len u8, blob}` — **a cleaner PRIVATE_APP**: the u16 app id has a
    public allocation registry (`number_allocations.md`; dev range `0xFF00–0xFFFF` free,
    real IDs granted by PR once the app demonstrably works).
  - `PAYLOAD_TYPE_REQ / RESPONSE / ACK`: directed, MAC'd request/reply — a native home
    for the command channel with per-contact (ECDH) secrets.
  - `PAYLOAD_TYPE_RAW_CUSTOM` (0x0F): full-custom escape hatch if we ever need one.
  - `PAYLOAD_TYPE_ADVERT`: **signed** (Ed25519) identity broadcast with appdata flags
    (`is sensor`, `has location`, `has name`…) — a ready-made LoRa-side typed discovery.
- **Send semantics** (`Mesh.h`): `sendZeroHop()` exists — exactly today's
  `hop_limit=1, no rebroadcast` stream/downlink pattern; `sendFlood`/`sendDirect(path)`
  for mesh use we deliberately avoid. `createGroupDatagram(type, channel, ...)` /
  `createDatagram(type, dest, secret, ...)` build the payloads.
- **Duty/airtime is first-class** (`Dispatcher.h`): per-hour duty window
  (`getDutyCycleWindowMs`, default 3600000 ms) + `getAirtimeBudgetFactor()` maintain an
  explicit `tx_budget_ms` — cleaner than Meshtastic's AirTime plumbing; CAD retry policy
  and interference thresholds are virtual hooks.
- **Radio abstraction is thin and hookable** (`Dispatcher.h::Radio`): `recvRaw`,
  `startSendRaw`, `isInRecvMode`, `isReceiving` — the Dispatcher decides when the radio
  sits in RX. This is where the A4 DEAF state plugs in (see §3).
- **Identity model**: Ed25519 keypair per node; "node hash" = first pubkey byte; adverts
  are signed. Stronger than Meshtastic node-nums — our app-side identity gate maps to
  pubkey verification.
- **Phone link**: a documented, versioned **companion protocol** over BLE serial
  (`docs/companion_protocol.md`, protocol v1.12+; official JS/Python client libs exist;
  `helpers/nrf52/SerialBLEInterface`). It is NOT Meshtastic's PhoneAPI — different
  framing, different session model. Doc self-describes as still-in-development: expect
  churn; pin the firmware version we build against.
- **GPS driver is basic**: `MicroNMEALocationProvider` — no `$PAIR` rate control, no
  boot-window unlock. Our AG3335 knowledge (10 Hz unlock, `$PAIR382,1` latch, RTC_INT
  rescue — `gnss/UNLOCK_NOTES.md`) is **chip-level and stack-independent**; porting
  GnssRateProbe into a MeshCore SensorManager is work, but no new unknowns.

## 2. Contract mapping (our concept → each stack)

| Ours (the product) | Meshtastic today | MeshCore target |
|---|---|---|
| 19–20 B position payload | `PRIVATE_APP(256)`, PSK channel | `GRP_DATA` on a private channel, allocated u16 data-type (dev-range first) |
| No-rebroadcast sends | `hop_limit=1`, CLIENT_MUTE | `sendZeroHop()` (native) |
| Command channel (260 ops) | portnum 260 frames + replies | `REQ`/`RESPONSE` directed datagrams (per-contact secret) — same op bytes inside |
| Guaranteed SIGNAL delivery | retry-until-correlated-ACK (ours) | identical logic; native `ACK` type available as transport aid |
| Radio states LISTENING/DEAF | runtime flag around startReceive | Dispatcher hook: skip idle RX (`Radio.isInRecvMode` control) — small, likely upstreamable (MIT, PR-friendly) |
| TTL dead-man / profiles | our module (stack-agnostic) | same module, unchanged |
| Typed discovery (A2) | BLE advert extension (ours) | BLE: same; LoRa: signed `ADVERT` appdata flags come free |
| Identity gate | `my_node_num` check | Ed25519 pubkey check (stronger) |
| Duty legality (EU868) | CAPACITY.md math + our checks | native `tx_budget_ms` + our SET-time checks on top |
| Phone transport | hand-rolled PhoneAPI protobufs | hand-rolled companion-protocol framing (same tradition, second dialect) |

## 3. Implications for the roadmap (decide once, works twice)

- **A4 radio states**: keep the generic radio-state module fully stack-agnostic (states,
  persistence, ACK-before-mute, retry discipline). Per-stack shims are tiny: Meshtastic =
  the existing standby-vs-RX switch; MeshCore = a Dispatcher/Radio idle-RX hook. Nothing
  in the locked RADIO_STATES.md changes.
- **A1 bridge parity**: the capability-byte design (not reply-length) matters MORE now —
  it must describe knob sets across stacks too.
- **A2 discovery**: define the typed payload once; carry it in BLE advertisements on both
  stacks, and additionally in MeshCore's signed ADVERT appdata for LoRa-side discovery.
- **A3 naming**: MeshCore adverts carry a name natively; Meshtastic uses owner fields —
  the app treats "persisted display name" as one concept with two setters.
- **OTA (B2)**: both stacks sit on the SAME Adafruit-lineage nRF52 bootloader on this
  hardware — the OTA/DFU investigation is bootloader-level and stack-independent. One
  more reason to do B2's bootloader survey before stack-specific work.
- **Bench**: `tools/bench` grows a transport layer (Meshtastic python lib today; MeshCore
  via its companion protocol / `meshcore_py`) so the SAME 28+ assertions run against
  either stack — the suite becomes the cross-stack conformance test, as planned.
- **Provenance**: apply-fork/lock/attestation machinery generalizes: second vendor clone
  (`firmware/meshcore/`), same tracked patch+drop-in discipline, same OID pinning; the
  toolchain lock already covers the shared PlatformIO/RadioLib caches.
- **iOS**: one `TagTransport` abstraction with two dialects (PhoneAPI protobufs,
  companion framing) — both hand-rolled per app tradition; everything above the
  transport (Tag Setup, sessions, upload machinery) is already wire-contract-shaped.

## 4. Gaps & risks (honest list)

1. **GPS rate port** — MicroNMEA is 1 Hz-class; GnssRateProbe + unlock must be ported
   (known chip, real work, no unknowns).
2. **Companion protocol churn** — docs marked in-development; pin versions, wrap the
   dialect behind the app/bench transport abstraction.
3. **Dual maintenance cost** — two vendor trees, two release matrices; mitigated by the
   shared-module discipline (radio states, payload builders, GnssSim/GnssMotion are
   already drop-in-shaped) and by the conformance bench.
4. **LR1110 driver maturity in MeshCore** — RadioLib-wrapped and shipped for t1000-e,
   but OUR bar is the bench on real hardware; assume nothing until 28/28 passes on a
   MeshCore-flavored tag.
5. **Encryption differences** — GRP_DATA channel keys / REQ per-contact ECDH vs
   Meshtastic PSK channels: key management UX in the app needs its own design pass.

## 5. Proposed next steps (in order)

1. Owner sign-off on this mapping (§2) and the module boundaries (§3).
2. **Spike, not port**: a minimal MeshCore app on the spare/bridge T1000-E that streams
   the EXACT 19 B payload as `GRP_DATA` (dev-range data-type) via `sendZeroHop`, received
   by a second MeshCore node — proves radio driver, duty budget, and payload path on our
   hardware before any architecture lands.
3. Repo shape: `firmware/meshcore/` clone + tracked patch/drop-ins mirroring the
   Meshtastic discipline; extract the first shared module (payload builder) used by both.
4. Then A1+A4 implementation proceeds — radio-state module built stack-agnostic from
   day one against both shims.
