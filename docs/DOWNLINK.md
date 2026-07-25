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
| `0x01` SET | 8-byte settings wire | unchanged (nav mode, thresholds, rates) |
| `0x02` MODE | `mode u8` (+ `ttl_s u16 LE`, CALIBRATION only; 0 → 90 s default) | `0` = **CALIBRATION**: fixed max rate (the configured `txSpacingMs`), guarded by the TTL dead-man; `1` = **ADAPTIVE**: speed-gated throughput |
| `0x03` SIGNAL | `pattern u8, seq u8` | render an operator signal (table below); duplicate `seq` is acknowledged but not replayed — re-sends are safe |

Reply (all ops): `[0x80|op, status, 8-byte settings]` — status 0 ok / 1 rejected / 2 malformed.

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

### Signals (AutoShot's torch grammar, transplanted — docs/feedback-signals.md over there)

Blip = 0.12 s ON (0.2 s gaps) on the green LED (P0.24); burn = 2 s ON/OFF. Beeper (P0.25) plays
D6 1175 Hz — the same pitch as AutoShot's CalibrationBeeper. **Vocabulary frozen** (additions
need the same owner sign-off as AutoShot torch signatures):

| id | Pattern | Meaning |
|---|---|---|
| 1 | single blip | resection ack (lock / read window / spot / walk started) |
| 2 | double blip | band converged (2nd of the walk = stop walking) |
| 3 | triple blip **+ triple beep** | **recording started** — also arms the local heartbeat |
| 4 | repeating burns | calibration failed, come back — self-capped at 120 s |
| 5 | cancel | stop everything (burns, heartbeat, pending blips) — "recording stopped" |

Heartbeat (after pattern 3): one low blip / 3 s, generated **locally** — zero airtime; its
absence = not recording, exactly like AutoShot's torch heartbeat. Disable the stock status blink
once per tag: `meshtastic --set device.led_heartbeat_disabled true`.

## Measured results (bench, 2026-07-25, tag streaming throughout)

- **Delivery: 20/20 signal commands, zero losses** (`tools/downlink_latency.py signal --n 20`).
- **Phone→tag hop latency** (host-clock send → tag console `SIGRX`, includes ~ms serial print):
  **min 317 / median 445 / p90 547 / max 713 ms**. The floor is the Base's *stock* transmit
  path (CAD + contention backoff + main-loop scheduling), not packet construction — priority
  HIGH / hop 1 / no-ack alone did **not** beat the historical ~0.5 s buzz measurement. Good
  enough for fire-and-forget cues; if a crisper recording-start beep is ever wanted, the next
  lever is Base-side (tighten its TX backoff for this packet class).
- **Mode machinery**: CALIBRATION command echoed in the stream after 1.6 s (bounded by the
  slow-tier packet cadence, as designed); **TTL dead-man reverted after exactly 20.0 s** with
  no refresh; idempotent ADAPTIVE re-send confirmed instantly; **slow tier self-engaged after
  17.7 s** quasi-stationary (15 s sustain + cadence).
- Open item for the field: indoor bench had no stable GPS lock, so tier *flags* are validated
  but the actual pkt/s effect of slow-vs-fast tier (0.33 vs 2–6.7 Hz) needs one outdoor walk;
  bench stream hovered ~1.1 pkt/s on heartbeats/partial fixes.

## Test harness

`tools/downlink_latency.py` (run with the meshtastic pipx python) — `signal` (N-trial latency
distribution), `mode` (echo + TTL + tier timings), `beep` / `cancel` (audible pattern 3 / stop).
Keep the phone app disconnected from the Base during tests (single PhoneAPI client).
