# Performance results

## M2 — custom PRIVATE_APP stream, bench (2026-06-25)

Setup: 2× T1000-E on USB (Tag → Base), firmware 2.7.15, **region=US, preset=ShortTurbo** (SF7/500 kHz),
nodes adjacent (RSSI ~−7 dBm). 12-byte `PRIVATE_APP(256)` payload **host-injected via the serial API
on stock firmware — no fork**. Tool: `tools/m2_stream_poc.py both`.

| Attempted | Sent | Received | PDR | Effective rate | SNR |
|---|---|---|---|---|---|
| 2 Hz | 60 | 60 | **100%** | 1.99 Hz | 13.7 dB |
| 4 Hz | 80 | 80 | **100%** | 3.95 Hz | 14.2 dB |
| 10 Hz | 150 | 104 | 69% | 3.60 Hz | 14.4 dB |

Findings:
- **2–4 Hz delivers at 100% PDR** — the full target range works, on stock firmware, via host injection,
  fully bypassing PositionModule. Architecture validated end-to-end.
- ~4 Hz is the clean ceiling of the **host-injection path** (laptop→node over USB CDC). At 10 Hz that
  path saturates (~31% loss; delivered rate plateaus ~3.6 Hz). The on-device firmware sender (fork)
  removes the USB bottleneck and should sustain higher more cleanly — not needed for the 2–4 Hz goal.
- Adjacent-node numbers (link quality not yet a factor). Range-vs-rate characterization is M7, on
  EU868/ShortFast (deployment-representative).

Raw logs: `docs/m2_run1.csv` (2 Hz), `docs/m2_run_4hz.csv`, `docs/m2_run_10hz.csv`.

> Bench used US/ShortTurbo (max headroom, no duty cycle) — the devices' as-found config. Deployment
> target is EU868/ShortFast (2 Hz legal); see `PLAN.md` §1.

## M5 — on-device fork stream (2026-06-25)

Tag flashed with the fork (built on **v2.7.15.567b8ea** + `HighRatePositionModule` + `$PAIR050` 4 Hz),
**no laptop attached to Tag** — it streams `PRIVATE_APP(256)` autonomously on-device. Fixed position
set (43.4897, −1.4942) so the module has coordinates indoors. Base = stock receiver. US/ShortTurbo.

| Metric | Value |
|---|---|
| Unique packets / 25 s | 71 → **~2.8 Hz on-device** |
| Received total | 86 (~17% duplicates — dedup by `seq`) |
| Coordinates | fixed position, exact | 
| `flags` | 0 (no live GPS lock indoors) |
| SNR / RSSI | ~14.4 dB / ~−8 dBm (adjacent) |

Findings:
- **On-device autonomous streaming validated end-to-end** (firmware → LoRa → stock receiver), no host
  on the moving node. This is the real deployment topology.
- ~2.8 Hz achieved (in the 2–4 Hz target). Target interval was 250 ms (4 Hz); actual ~353 ms due to
  ~100 ms OSThread scheduling + TX overhead. Lower `HIGHRATE_POSITION_INTERVAL_MS` to compensate.
- **Master 2.8.0 hangs on this hardware** (SoftDevice/config mismatch via single-bank DFU). Building
  the fork on **2.7.15** (matching Base's factory image) boots cleanly. Lesson: build on the device's
  installed version, not bleeding-edge master.

Raw log: `docs/m5_ondevice.csv`.

## M5b — real on-device GPS stream (2026-06-25)

Tag on a balcony (battery, live GPS: `fixed_position=false`, `gps_mode=ENABLED`, `gps_update_interval=1`),
Base on the desk. After GPS lock:

| Metric | Value |
|---|---|
| Packets / 90 s | 285, **0 gaps >2 s** |
| Median inter-arrival | 0.345 s → **~2.9 Hz** |
| `flags` lock=1 | **285 / 285** (live lock every packet) |
| Coordinates | real ≈ 43.4833, −1.5068; 38 distinct lat values (~few-m GPS jitter) |
| SNR / RSSI | ~14 dB / ~−9 dBm (balcony → desk, short range) |

Findings:
- **End-to-end real-GPS validation:** a battery-powered tracker autonomously streams its real GPS
  position over LoRa at ~2.9 Hz, decoded by a stock receiver. `$PAIR050` did **not** break acquisition.
- Earlier ~17% duplicates were a startup transient — this clean run shows ~0.
- **Caveat:** the ~2.9 Hz stream rate is set by the module tick (~353 ms), *not* proven to be the GPS
  fix rate. Confirming genuine 4 Hz GNSS fixes (vs 1 Hz repeated) needs a Tag serial RMC-rate check or
  a moving test (a walk would show whether the track updates 4×/s).

Raw log: `docs/m5_realgps2.csv`.

## M6 — live iPhone display (2026-06-25)

The custom iOS app (`ios/MeshTracker`) on a real **iPhone 17 Pro** connects to Base over BLE, decodes
the `PRIVATE_APP(256)` stream, and shows Tag's live position on a MapKit map with a real-time
**Hz / SNR / RSSI** readout and on-device CSV logging. **Full chain validated live:**

```
Tag (fork, real GPS) ──LoRa──▶ Base ──BLE──▶ iPhone (live map)
```

- Auto-connects to the Meshtastic GATT service (no PIN); decodes with a dependency-free hand-rolled
  protobuf reader (`FromRadio → MeshPacket → Data`), filters portnum 256, parses the 12-byte payload.
- Live map pin (green = GPS lock) + breadcrumb trail; CSV log at `Documents/meshtracker_log.csv`.
- Signed with a personal Apple Development team; deployed via `xcodebuild` + `devicectl` (no Xcode GUI
  run needed).

**This completes Phase 1:** real-time GPS position from a moving tracker, displayed live on the iPhone.

Remaining: 1 km range/PDR-vs-distance sweep (M7), rate tuning toward a clean 4 Hz, and the optional
Phase 2 Apple Watch GPS bridge.

## Extended telemetry — payload v2 (2026-06-25)

Grew the `PRIVATE_APP` payload **12 → 18 bytes**, adding **altitude, ground speed (km/h), heading,
satellites, and battery %**, plus moving/charging flags. All sourced from existing Meshtastic state
(`localPosition`, `powerStatus`) — negligible extra airtime at ~2.9 Hz (18 B ≪ budget).
Backward-compatible: 12-byte v1 clients still decode position.

- **Firmware:** `HighRatePositionModule` packs `alt(i16,m) speed(u8,km/h) heading(u8,×256/360)
  sats(u8) battery(u8,%)` + flags `bit0 lock / bit1 moving / bit2 charging`.
- **iOS:** `MeshProto` decodes the extras; `ContentView` shows a metrics row (speed, rotating heading
  arrow, altitude, sats, battery); CSV logs all fields.
- **Tools:** `m2_stream_poc.py` parses v2 (graceful for 12-byte) + new CSV columns.

Validated indoors (Tag fixed position): **battery reads live (82%)**, structure correct. Speed /
heading / sats are 0 without a GPS lock — they populate on an outdoor moving test (overlaps M7).

**Deferred — accelerometer fall/impact detection (QMA6100P):** flag bits reserved; needs dedicated
work + on-body testing (live sensor access has init-timing / I2C-contention risk), so kept out of
this change to protect the working firmware.


