# Real-time LoRa GPS tracker — build plan

Stream GPS from a moving **Seeed SenseCAP T1000-E** (Meshtastic) over LoRa to a second
T1000-E tethered to an **iPhone**, showing live position at up to **1 km**. Region: **EU868**.

- **Deployment target: 2 Hz sustained** (EU868-legal).
- **Bench-test target: full 2–4 Hz** (and probe higher to find the real ceiling) — duty-cycle
  self-limit lifted for controlled testing, user-authorized 2026-06-25. **Test-only, not for
  deployment.** See §1 "Bench testing mode".

> Status of findings below: verified against live `meshtastic/firmware` master + ETSI EN 300 220
> via two research passes (2026-06-25). Anchor all firmware edits on **symbol names**, not line
> numbers — they drift commit-to-commit.

## 1. The hard constraints (why the target is what it is)

- **Range is not the limiter.** At 1 km the link closes with ~50 dB margin on ShortFast.
  Airtime + the 10% duty cycle are the limiters.
- **ShortTurbo (SF7/500 kHz) is unusable in EU868.** `region=EU_868` is one 250 kHz sub-band
  (869.4–869.65 MHz, 10% duty, 27 dBm ERP). Firmware rejects a 500 kHz preset and silently
  falls back to LongFast. Use **ShortFast** (SF7/CR4-5/BW250, ~41 ms for a 40 B packet).
- **EU868 legal rate ceiling on ShortFast = ~2.4 pkt/s** (10% duty / 41 ms). 2 Hz = 8.2% (legal);
  3 Hz = 12.3% and 4 Hz = 16.4% are **not** legal as a sustained stream.
- **Duty cycle is enforced over a rolling 60-minute window** (`AirTime`, `utilizationTX[60]`),
  so **bursts** at 4 Hz are legal if the hourly average stays ≤10%.
- **Shrinking the payload is the real lever**: a 12 B payload drops airtime toward ~25–30 ms,
  lifting the legal sustained ceiling toward ~3.3 Hz.
- `override_duty_cycle=true` brute-forces higher rates but is an **ETSI violation for non-HAM**
  operation — bench/test only. (It also does nothing for the position path; see below.)

### Bench testing mode (test-only — authorized 2026-06-25)

For controlled bench/range testing the EU duty-cycle self-limit is lifted. **Not for deployment.**
Key realization: **2–4 Hz needs only ShortFast on EU868 — ShortTurbo is unnecessary** and would
require leaving the 868 MHz band (region=US915), making bench numbers non-representative. The
~2.4 Hz figure was a *regulatory* (duty-cycle) ceiling, **not technical**: the custom `PRIVATE_APP`
sender (§3) never passes through the duty-cycle gate (`isTxAllowedAirUtil`) — it is bounded only by
channel utilization (`isTxAllowedChannelUtil`, 40% with `role=TRACKER`). A 12 B packet at 4 Hz is
~12–16% utilization, well under 40%.

- **Bench config:** `region=EU_868`, `modem_preset=ShortFast`, `role=TRACKER`,
  `lora.override_duty_cycle=true` (belt-and-suspenders — unblocks any duty-cycle-checked path such
  as Python injection / telemetry).
- Push the custom sender to the full **2–4 Hz** and probe higher to find the real channel-util /
  airtime ceiling (~9 Hz on ShortFast at TRACKER's 40% cap; ~24 Hz raw).
- Keep logging `AirTime::utilizationTXPercent()` so we always know the would-be-legal headroom for
  deployment (2 Hz = ~8%).
- Switch to ShortTurbo (needs `region=US915`, off 868 MHz) **only** to probe rates ≫10 Hz or to
  minimize channel occupancy — changes the RF band, so less deployment-representative.

## 2. Hardware facts (T1000-E)

- MCU **Nordic nRF52840**, LoRa **Semtech LR1110**, GNSS **Airoha AG3335**, 700 mAh battery.
- AG3335 silicon supports up to 10 Hz fixes, but Meshtastic leaves it at its **1 Hz default**
  (it sends `$PAIR066/$PAIR062/$PAIR513` but never the `$PAIR050` fix-rate command).
- `gps_update_interval ≤ 10 s` keeps the GPS always-on (drains the 700 mAh cell in hours).

## 3. Architecture decision — bypass PositionModule

Stock PositionModule can't go sub-second (5 s `RUNONCE_INTERVAL`, whole-second config,
300 s/100 m smart-broadcast gate) and `override_duty_cycle` doesn't even affect it. **Don't use
it for the stream.** Instead:

- **Custom `PRIVATE_APP` portnum = 256**, not `POSITION_APP`.
- Dedicated GPS-fix-driven sender thread → `service->sendToMesh()` with a `MeshPacket`:
  `decoded.portnum=256`, `want_ack=false`, `hop_limit=1`, self-throttled by a ms timer.
- **12-byte fixed payload**: `lat int32 (deg*1e7) | lon int32 | time_offset uint16 (ms-in-sec) |
  seq uint8 | fixFlags uint8`. Far under `DATA_PAYLOAD_LEN=233`.
- This path is gated **only** by `isTxAllowedChannelUtil` (relaxed by `role=TRACKER` → 40%) and
  the real 10% duty cycle (the compliance backstop). PositionModule keeps running for normal
  telemetry/neighbor-info.

## 4. Firmware fork points (symbol anchors)

| File | Symbol | Change |
|---|---|---|
| `src/gps/GPS.cpp` | `GNSS_MODEL_AG3335` init block | after `$PAIR062` writes, before `$PAIR513` save, send `$PAIR050,<ms>` (see checksums below) |
| `src/modules/PositionModule.cpp` | (leave `RUNONCE_INTERVAL`/`sendOurPosition` intact) | add a **separate** GPS-fix-driven high-rate sender; do not touch the 5 s loop |
| `src/airtime.h` | `max_channel_util_percent=40`, `polite_channel_util_percent=25` | set `role=TRACKER` for the 40% branch, or skip the gate in the custom send path |
| `src/airtime.h` | `polite_duty_cycle_percent=50` | optional; only affects telemetry/neighbor-info, **not** the stream. Keep `dutyCycle=10` as the legal backstop |
| `userPrefs.jsonc` | build-time defaults | `EU_868`, `ShortFast`, `role=TRACKER` |

**`$PAIR050` checksums** (NMEA XOR between `$` and `*`, verified — but confirm on-device):
`250ms=*24` (4 Hz), `200ms=*21` (5 Hz), `100ms=*22` (10 Hz), `500ms=*26` (2 Hz), `1000ms=*12` (1 Hz).

> ⚠️ Some AG3335/LC29H firmware revisions accept only 100/1000 ms (reject 250). **Validate first**
> (Milestone M1). Fallback: `$PAIR050,100` (10 Hz hardware) + decimate to the TX cadence.

## 5. Build + flash

```bash
git clone https://github.com/meshtastic/firmware && cd firmware
git submodule update --init --recursive
pio run -e tracker-t1000-e         # → .pio/build/tracker-t1000-e/firmware-*.uf2
```
- Enter UF2 bootloader: hold button, connect the magnetic charge cable **twice** until the green
  LED is **solid**; a `T1000-E` USB drive mounts. On big version jumps, copy the matched nRF52
  `*erase*.uf2` first, then drag the firmware `.uf2`.
- Recovery: reflash the Adafruit nRF52 bootloader via `adafruit-nrfutil` (serial DFU) or SWD.
- **After every flash, confirm the active preset is ShortFast** (not LongFast — i.e. no "region
  too narrow" error), `region=EU_868`, `role=TRACKER`.

## 6. iOS minimal client (not a fork of the stock app)

The stock Meshtastic-Apple app debounces saves 2–5 s → can't render 2 Hz. Build a minimal
CoreBluetooth client:
- GATT service `6BA1B218-15A8-461F-9FA8-5DCAE273EAFD`; chars `TORADIO F75C76D2-…`,
  `FROMRADIO 2C55E69E-…`, `FROMNUM ED9DA18C-…`.
- Handshake: write `ToRadio{want_config_id=nonce}` → drain `FROMRADIO` until `configCompleteId==nonce`.
- Drain loop: on `FROMNUM` notify, read `FROMRADIO` until zero-length; decode `FromRadio` →
  `MeshPacket`; match `decoded.portnum==256`; parse the 12 B payload directly.
- Render: SwiftUI `Map` + `MapPolyline` breadcrumb + current marker, live (no debounce).
- Log CSV per packet: host arrival time, seq, lat, lon, `rxSnr`, `rxRssi`, `rxTime`, `hopStart`, id.

## 7. Measurement

- **Effective rate** = unique-seq / elapsed (+ inter-arrival jitter).
- **PDR vs range** = received-seq / max-seq, binned by embedded coords (iOS CSV or Python logger;
  cross-check with the Range Test module).
- **Latency** = host arrival − embedded fix time (needs shared/synced clock; single-host or GPS-disciplined).
- **Legality acceptance test**: `AirTime::utilizationTXPercent()` plateaus < 10% and no
  "TX air util… Skip send" warnings over a full hour at 2 Hz.
- **Battery**: log DeviceMetrics %/hour under always-on GPS + stream.

## 8. Milestones

- **M0** Baseline: stock firmware both units, `EU_868`/`ShortFast`/`TRACKER`; confirm 1 Hz position
  link + stock-app map. (Proves the 1 Hz / 5 s / 0.1 Hz floors are real.)
- **M1** GNSS rate proof (no firmware commit): send `$PAIR050,250` / `$PAIR050,100` over UART;
  confirm `$PAIR001,050,0` ACK + RMC timestamps advance. → `tools/m1_gps_rate_check.md`
- **M2** Custom-stream proof in Python: `sendData(payload, portNum=256, wantAck=False, hopLimit=1)`
  at 2 Hz; receive + log on the second node. → `tools/m2_stream_poc.py`
- **M3** iOS minimal client: BLE + 12 B parse + live map + CSV; validate vs M2 with no debounce lag.
- **M4** Fork — GNSS rate: add validated `$PAIR050` to `GPS.cpp`; confirm fresh fixes.
- **M5** Fork — high-rate sender: GPS-fix-driven OSThread → `PRIVATE_APP(256)`, throttled 2 Hz.
- **M6** End-to-end 2 Hz, live map + CSV; run the duty-cycle acceptance test.
- **M7** Range/PDR characterization: walk to 1 km; build rate/PDR/SNR-vs-range curves.
- **M8** (stretch, legal-aware) payload minimization toward ~3.3 Hz sustained + 4 Hz burst mode.
- **M9** (Phase 2, conditional) Apple Watch bridge: Watch GPS → WCSession → iPhone → BLE
  `PRIVATE_APP(256)` (not stock provide-location, not `POSITION_APP`). ~1 Hz Watch novelty;
  onboard AG3335 stays primary (~1.5 m CEP vs Watch ~5–10 m).

## 9. Open validations (load-bearing unknowns)

- Does **your** AG3335 honor `$PAIR050,250`? (M1) — biggest unknown.
- nRF52 scheduler: any minimum tick that caps the sub-second sender after bypassing `RUNONCE_INTERVAL`? (M5)
- iOS BLE connection interval granted for the nRF52840 (~15 vs 30 ms) — measure (shouldn't bottleneck ≤4 Hz).
- National regulator: confirm your country permits 250 kHz occupied bandwidth in the P sub-band.
- Phase 2: ensure each injected packet has a fresh id (avoid `wasSeenRecently` dedup).
