# Tag downlink — remote mode control + operator signals (tag-downlink branch)

The GPS tag now **listens** on LoRa: an app connected to the Base can switch the tag's TX mode
and drive its LED/buzzer at any tracking distance — no reflash, no BLE proximity. Bench-validated
2026-07-25 on real hardware (Base `!b0bb9cda` → GPS tag `!18e77545`).

## What changed (firmware, GPS-tag flavor only)

- `HIGHRATE_TX_ONLY` is gone from the GPS_TAG flavor: the LR1110 idles in RX instead of standby.
  `CLIENT_MUTE` still guarantees the tag never rebroadcasts mesh traffic. The **bridge tag keeps
  TX-only** (its explicit build flag) and the Base is untouched — **no Base firmware change is
  needed for any of this**.
- `GnssConfigModule` (portnum **260**) now serves mesh-originated requests (replies over LoRa to
  the requester; phone-direct path unchanged) and two new ops.
- Rollback: `firmware/known-good/restore.sh` reflashes the validated v3.0 fleet state.

## Wire protocol (portnum 260)

| Op | Payload after op byte | Meaning |
|---|---|---|
| `0x00` GET | — | reply echoes current settings |
| `0x01` SET | 8-byte (v2) or **13-byte (v3)** settings wire | v3 appends the adaptive knobs: `idleSpacingMs u16` (1000–30000), `adaptFastKmh u8` (2–30), `adaptSlowKmh u8` (1..fast−1), `adaptSustainS u8` (3–120) — persisted, live-applied |
| `0x02` MODE | `mode u8` (+ `ttl_s u16 LE`, CALIBRATION only; 0 → 90 s default) | `0` = **CALIBRATION**: fixed max rate (the configured `txSpacingMs`), guarded by the TTL dead-man; `1` = **ADAPTIVE**: speed-gated throughput |
| `0x03` SIGNAL | `pattern u8, seq u8` | render an operator signal (table below); duplicate `seq` is acknowledged but not replayed — re-sends are safe |
| `0x04` SIM | `src u8, flags u8 (bit0 loop), ttl_s u16 LE` (+ `nSeg u8, nSeg×(speed u8, dur u8)` for src 1) | indoor synthetic-fix generator ON the tag: src 0 = off, 1 = segment program (≤8, one packet), 2 = accel-coupled "shake to move", 3 = track replay (phase 2), 0xFF = TTL keep-alive. Every simulated packet sets **flags bit4**; dead-man TTL (default 600 s); never persisted. Bench-validated 2026-07-26: full adaptive cycle (idle → instant fast → 15 s downshift → idle) driven by a simulated 1↔12 km/h loop, 140/140 marked, STOP immediate |

Reply (all ops): `[0x80|op, status, settings]` — status 0 ok / 1 rejected / 2 malformed. v3
firmware always replies with 13-byte settings; **the reply length is the capability signal**
(apps must send 8-byte SETs to tags that reply with 8).

**iOS (MeshTracker Tag Setup)**: TX-mode card — Calibration/Adaptive buttons with the live mode
read back from the stream-flags echo, calibration TTL (120 s) auto-refreshed every 45 s while
the screen is open; "Adaptive mode tuning" card (v3 tags only) exposes all four knobs; the map's
tag rows append the live tier (`· idle / · fast / · cal`). Field observation 2026-07-26: a
static balcony tag shows 0.1–0.3 Hz — the idle tier working as designed (3 s spacing ceiling).

**How the sender must build the packet** (this IS the phone-app contract):
`priority = HIGH`, `hop_limit = 1`, `want_ack = false`, direct-addressed to the tag's node id.
Confirmation is **not** an ack: the tag echoes its mode in **every stream packet's flags** —
bit2 = ADAPTIVE active, bit3 = slow tier engaged (bit0 lock, bit1 reserved `moving`, bits 5–7
source type). Re-send the idempotent command until the stream reflects it.

### Modes

- **CALIBRATION (0)** — full configured rate for AutoShot's calibration phase. ETSI duty is an
  hourly aggregate, so max-rate bursts are legal (~18 min/h at 6.7 Hz); the **TTL dead-man**
  makes over-runs impossible: the app must refresh the MODE command before the TTL lapses or
  the tag reverts to ADAPTIVE on its own. Never persisted — reboot also lands in ADAPTIVE.
- **ADAPTIVE (1, boot default)** — speed gate on the payload's own km/h byte: ≥ 5 km/h → full
  rate on the next packet (eager up); < 3 km/h sustained 15 s → 1 packet / 3 s (skeptical
  down); in between → hold current tier. Compile defaults: `GPSTAG_IDLE_SPACING_MS 3000`,
  `GPSTAG_ADAPT_FAST_KMH 5`, `GPSTAG_ADAPT_SLOW_KMH 3`, `GPSTAG_ADAPT_SLOW_SUSTAIN_MS 15000`,
  `GPSTAG_CALIB_TTL_DEFAULT_S 90`.

### Signals — language v2 (BEEP-FIRST, owner direction 2026-07-25)

The beeper (P0.25) is the primary channel; the green LED (P0.24) mirrors every beep.
**Vocabulary frozen** (additions need owner sign-off):

| id | Sound | Meaning |
|---|---|---|
| 1..8 | **N short beeps** (D6 1175 Hz — AutoShot's CalibrationBeeper pitch) + N blips | counted progress: convergence steps etc. — "how many" IS the message |
| 10 | **one long HIGH beep** (G6, 600 ms) + long flash | **recording started** — then the LED heartbeat (silent blip / 3 s, locally generated, zero airtime; its absence = not recording) |
| 11 | **LOW beep** (D5, 500 ms) + LED burn every 2 s | problem / calibration failed — repeats, self-capped 120 s |
| 0 | silence | cancel everything — doubles as "recording stopped" |

Pitch encodes meaning: counted mid-tone = progress, long high = go, repeating low = bad news.
Disable the stock status blink once per tag: `meshtastic --set device.led_heartbeat_disabled true`.
**iOS**: the MeshTracker Tag Setup tab has an "Operator signals (test)" card (1×/2×/3×, Record
start, Problem, Stop) — works via the Base over LoRa or on a direct tag link.

## Measured results (bench, 2026-07-25, tag streaming throughout)

Leg decomposition via `rawlat` (raw serial injection; Base logs FastQ/FastTX stamps for
HIGH-priority packets — fork instrumentation):

| Stage of the fix | total median | ingest (host→queued) | queue (→TX start) | air+dispatch |
|---|---|---|---|---|
| Stock TX path (baseline) | **445 ms** (max 713) | — | — | — |
| + priority fast-lane (skip contention for HIGH+ local) | 411 ms | 189 ms | **20 ms** | 174 ms |
| + 15 ms API idle poll (was a 250 ms lottery) | **335 ms** (max 474) | **137 ms** | 20 ms | 157 ms |

- Delivery: 20/20 and 12/12 across runs, zero losses; dup-seq dedupe verified on-device.
- Measured numbers INCLUDE ~50–100 ms of measurement overhead (console prints + host serial
  reads on both ends). True USB command→beep ≈ **~250 ms**.
- **The phone-BLE path is faster still**: BLE `toRadio` writes ingest inside the write callback
  (no poll at all), so iPhone-tap→beep ≈ **~200 ms** — verify by feel with the iOS signals card.
- Remaining lever if ever needed: tag-side RX dispatch (~50–80 ms through the main-loop pass).
- **Mode machinery**: CALIBRATION echoed in-stream in 1.6 s (bounded by packet cadence);
  **TTL dead-man reverted at exactly 20.0 s** unrefreshed; idempotent re-send confirmed;
  **slow tier self-engaged at 17.7 s** quasi-stationary.
- Open item for the field: tier *flags* validated indoors; the actual pkt/s effect of
  slow-vs-fast tier (0.33 vs 2–6.7 Hz) needs one outdoor walk with a stable lock.

## Test harness

`tools/downlink_latency.py` (run with the meshtastic pipx python) — `signal` (N-trial latency),
`rawlat` (leg decomposition), `mode` (echo + TTL + tier timings), `count --pattern N` /
`record` / `problem` / `cancel` (audible checks). Keep the phone app disconnected from the Base
during USB tests (single PhoneAPI client).
