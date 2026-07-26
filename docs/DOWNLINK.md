# Tag downlink — remote control, radio states, signals, adaptive TX, simulator

> **Contract snapshot (2026-07-26, A1+A4 round, post-v4.3 working tree).**
> This document is the authoritative wire contract for branch `tag-downlink`. This round adds
> the A4 radio-state machinery (runtime LISTENING/DEAF + HYBRID/PERMANENT profiles, RADIO op
> 0x06), guaranteed-delivery SIGNAL v5 (u32 sid), settings wire v4 (profile byte; 20-byte
> replies with capability, radio-status and duty-floor bytes), stream payload v5 (20-byte,
> status byte) and **bridge parity**: BOTH tag flavors speak portnum 260 now. Behavioral
> reference and state diagrams: `RADIO_STATES.md`. Uplink payload byte map for external
> consumers: `BATTERY_INTEGRATION.md`. Verification: `tools/bench/verify_fixes.py` (GPS tag,
> 69 assertions incl. real-LoRa deafness, PERMANENT reboot persistence and an EU868 duty-floor
> round-trip) and `tools/bench/verify_bridge.py` (bridge op surface). Rollback:
> `../firmware/known-good/restore.sh` (validated v3.0 fleet state).

Both tags **listen** on LoRa after boot: an app connected to the Base can configure them,
switch modes, drive beeps and command radio states at any tracking distance — and can order
them **deaf** (TX-only) for the session, where nothing on the LoRa side can disturb them.

## What changed in the A1+A4 round (firmware)

- **`-DHIGHRATE_TX_ONLY` is retired.** "TX-only" is a runtime radio state (DEAF) owned by the
  shared `TagRadioState` module, compiled into BOTH tag flavors. The bridge boots LISTENING
  like the GPS tag and goes deaf on command. The Base is untouched.
- **Bridge parity (A1)**: the bridge serves portnum 260 (settings, signals, radio state,
  profiles — no GNSS knobs, no TX modes, no simulator: its capability byte says so), and
  advertises **slow connectable BLE** (~1.0 s interval, ≲0.3 % of scanner time) alongside the
  continuous ODID scan, so a phone can reach even a deaf bridge at close range.
- Duty legality is enforced by the tag itself: live SETs below the region duty floor are
  rejected; persisted values that a region change makes illegal are **clamped at use** and
  flagged (never silently transmitted). The floor is computed from the region's duty % and
  the measured airtime of the ACTIVE modem preset, and is reported in every settings reply.

## Radio states & profiles (A4 — the runtime model)

Two radio states, both flavors (state diagrams and plain-words walkthroughs:
`RADIO_STATES.md`):

- **LISTENING** — RX between transmissions; portnum-260 commands work at LoRa range.
- **DEAF** — radio idles in standby between sends (µA vs RX mA; a foreign RX-in-progress can
  never defer our TX). No LoRa command can reach it; **BLE/USB still work** (phone-injected
  frames are delivered locally).

Two persisted profiles (settings v4 byte 13):

- **HYBRID (0x00, default)** — boot ALWAYS lands in LISTENING (+ ADAPTIVE on the GPS tag).
  Deafness is runtime-only and never survives a reboot. Recovery ladder: LoRa while
  listening → BLE at close range in any state → reboot.
- **PERMANENT (bit0, + bit1 = boot-DEAF)** — fixed spacing (no adaptive tiers, no CALIBRATION
  choreography) and a fixed boot radio state. A RADIO command **rewrites the persisted
  profile** (no temporary states). A PERMANENT·DEAF tag is reachable only via BLE/USB — the
  app states this at consent time.

**GO-DEAF confirmation is two-layer:** the tag ACKs FIRST, holds a ~2 s mute-grace during
which duplicate GO-DEAFs are re-ACKed (lost-ACK retries still land), then mutes. The stream's
v5 status byte reports DEAF from the ACK moment — a deaf tag still streams, so the next
packet proves the transition even if every ACK is lost.

## Wire protocol (portnum 260)

| Op | Payload after op byte | Meaning |
|---|---|---|
| `0x00` GET | — | reply echoes current settings |
| `0x01` SET | 8 (v2) / 13 (v3) / **14-byte (v4)** settings wire | v4 appends `profileBits u8` (0x00 HYBRID · 0x01 PERMANENT·LISTENING · 0x03 PERMANENT·DEAF). A live SET whose sustained spacing is below the region duty floor is **rejected** (status 1). On the bridge the GNSS-chip fields are stored but inert |
| `0x02` MODE | `mode u8` (+ `ttl_s u16 LE`, CALIBRATION only; 0 → 90 s default) | GPS tag, HYBRID only: `0` CALIBRATION (TTL dead-man) / `1` ADAPTIVE. NAK (1) on the bridge and in PERMANENT |
| `0x03` SIGNAL | **v5: `pattern u8, sid u32 LE`** (legacy `pattern u8, seq u8` kept) | render an operator signal (table below). v5 delivery discipline: **at-least-once delivery, at-most-once playback per sid** — the sender retransmits the SAME sid until the correlated ACK arrives; the tag remembers the last 8 {sid, pattern} pairs: exact re-send → re-ACK without replay; same sid with a DIFFERENT pattern → NAK; unknown pattern → NAK. ACK = accepted + playback scheduled (≲50 ms), not "audio finished". Dedupe is RAM-only (a reboot inside the retry window could replay one signal — accepted residual) |
| `0x04` SIM | `src u8, flags u8 (bit0 loop), ttl_s u16 LE` (+ `nSeg u8, nSeg×(speed u8, dur u8)` for src 1) | GPS tag only (NAK on the bridge). Indoor synthetic-fix generator: src 0 off · 1 segment program · 2 accel-coupled · 3 track replay · 0xFF TTL keep-alive. Simulated packets set flags bit4; TTL dead-man; never persisted |
| `0x05` TRACK | `sub u8, tid u32 LE`, then per sub (BEGIN/CHUNK/COMMIT/ABORT — see v4.3 contract, unchanged) | GPS tag only, phone/USB-direct only. A/B slot storage, ≤800 records, appended-footer commit, 9-byte correlated ACK `[0x85, status, sub, offLo, offHi, tid]` |
| `0x06` RADIO | `state u8` (0 LISTENING / 1 DEAF), `rid u32 LE` | **ACK-BEFORE-MUTE**: the 7-byte ACK leaves first; GO-DEAF then holds the ~2 s grace (duplicates re-ACKed, grace re-armed) before muting. LISTENING applies immediately and kicks the radio back into RX. In PERMANENT the persisted profile is rewritten (flash failure → NAK). Idempotent; retry the SAME rid until ACKed |

**Replies:**

- Settings echo (GET/SET/MODE/legacy-SIGNAL): `[0x80|op, status, 14-byte v4 settings,
  capability u8, radio-status u8, dutyFloorMs u16 LE]` = **20 bytes** (v3 firmware replies 15;
  the length is the version signal). `status`: 0 ok / 1 rejected / 2 malformed.
- SIGNAL v5 ACK: `[0x83, status, pattern, sid u32 LE]` (7 B — length-distinguished from the
  legacy 0x83 settings echo).
- RADIO ACK: `[0x86, status, state, rid u32 LE]` (7 B).
- TRACK ACK: `[0x85, status, sub, offLo, offHi, tid u32 LE]` (9 B, unchanged).

**Capability byte** (reply byte 16; bit set = knob group live): bit0 GNSS chip knobs · bit1
TX modes · bit2 simulator/TRACK · bit3 signals · bit4 RADIO op · bit5 profiles. GPS tag =
`0x3F`; bridge = `0x38`. Clients render from THIS byte, never from flavor heuristics.

**Radio-status byte** (reply byte 17 == stream payload v5 byte 19): bit0 DEAF (committed —
set from the ACK moment, before the grace elapses) · bit1 PERMANENT profile · bit2
duty-degraded (a persisted spacing is being clamped to the region floor).

**Duty floor** (reply bytes 18–19, ms; 0 = no limit/bench override): the tag's own legal
minimum sustained spacing = region duty % × measured airtime of a 44-byte-on-air stream
packet at the ACTIVE preset. Clients must use this number, never preset assumptions — the
bench itself once assumed ShortFast while the fleet ran another preset. If the floor exceeds
the settable range (e.g. LONG_FAST under EU868: measured **5590 ms** > the 5000 ms cap), no
legal SET exists: everything rejects and the tag runs clamped + flagged.

**Sender contract** (unchanged): `priority = HIGH`, `hop_limit = 1`, `want_ack = false`,
direct-addressed. For MODE/SET the stream-flags echo remains the confirmation channel; for
SIGNAL v5 and RADIO the correlated ACK is the confirmation (retry the same sid/rid, bounded,
then fail LOUDLY — the operator must never believe a beep happened when it did not).

### Modes (GPS tag, HYBRID profile — unchanged semantics)

- **CALIBRATION (0)** — full configured rate, TTL dead-man (unrefreshed → ADAPTIVE).
- **ADAPTIVE (1, boot default)** — speed-gated tiers (≥5 km/h fast; <3 km/h sustained 15 s →
  idle spacing; band holds). Both flags bits 2–3 read 0 in PERMANENT (no modes there).

### Signals — language v2 (BEEP-FIRST; vocabulary frozen)

| id | Sound | Meaning |
|---|---|---|
| 1..8 | N short beeps (D6) + N blips | counted progress |
| 10 | one long HIGH beep (G6, 600 ms) + flash | recording started (then silent LED heartbeat / 3 s) |
| 11 | LOW beep (D5, 500 ms) + LED burn / 2 s | problem — self-capped 120 s |
| 0 | silence | cancel everything / recording stopped |

Both flavors render signals since A1 (same piezo/LED; ONE signal owner thread).

## Measured results

**A1+A4 HIL round (2026-07-26, GPS tag `!18e77545` + Base `!b0bb9cda`, dev firmware):**

- 69-assertion suite: A/B1–B4 regression intact; C1 20-byte v4 reply surface; C2 sid
  dedupe/conflict/unknown NAKs; C3 GO-DEAF ACK-before-mute, in-grace re-ACK, stream status
  flip to DEAF, **LoRa commands provably unanswered while deaf (3 attempts) and restored
  after un-deafen**; C4 PERMANENT·DEAF survives an uptime-verified reboot, RADIO rewrites
  the persisted profile; C5 EU868 round-trip: stored 150 ms spacing survives + DEGRADED
  flag, sub-floor SETs rejected, measured floor **5590 ms at LONG_FAST** (beyond the
  settable range → every SET rejects, clamp stays flagged), full radio identity restored
  with a post-restore LoRa delivery proof.
- Fleet finding (2026-07-26): the bench fleet's actual modem preset is **SHORT_TURBO**
  (500 kHz BW), not the ShortFast that `CAPACITY.md` plans for deployment — and SHORT_TURBO
  is not EU868-legal, so entering EU makes the firmware itself degrade the preset to
  LONG_FAST. Deployment must pick an EU-legal preset and re-derive the duty numbers; the
  tags now measure and report their own floor either way.
- v4.3-era latency legs (`rawlat`, SHORT_TURBO): phone→tag ≈ 0.2–0.35 s (unchanged this
  round; re-measured 2026-07-26: 3/3 complete, median 467 ms including ~100 ms measurement
  overhead on a busy bench).

## Test harness

`tools/bench/verify_fixes.py` — the 69-assertion GPS-tag gate (needs tag + Base on USB; C5
cycles the region and RESTORES region+preset with an air-path proof). `tools/bench/verify_bridge.py`
— the bridge op-surface gate (D1–D6; the sniffer-throughput A/B additionally needs a live
Dronetag). `tools/downlink_latency.py` — signal/mode latency legs. Keep the phone app
disconnected during USB tests (single PhoneAPI client).
