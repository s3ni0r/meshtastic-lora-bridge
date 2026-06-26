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

## Freshness fix — verified (2026-06-25)

After the stale-as-live bug surfaced on a walk (position frozen 66 s while reported `lock=1`), added a
**freshness gate** (coords unchanged >2.5 s → `lock=0`) + a **heartbeat** (always stream, even pre-lock).
Re-measured with Tag locked on the balcony (45 s / 127 packets, `tools/freshness_analyze.py`):

| Metric | Value |
|---|---|
| Packet rate | 2.80 Hz |
| **Novelty rate** | **~1.02 Hz** (the AG3335's real fix rate) |
| **Staleness age / packet** | median 0.34 s, p95 0.77 s, **max 1.23 s** |
| Longest frozen run | ~1.1 s (one 1 Hz gap) |
| **lock=1 (fresh)** | **100%** |
| Coord jitter | ~70 m lat / ~10 m lon (7 sats — multipath drift) |

- **Freshness CONFIRMED:** every reported position is ≤1.23 s old and never stale-frozen (was 66 s).
  The novelty is the GPS chip's honest ~1 Hz.
- Residual **~70 m drift = multipath / limited sky view** (only 7 sats) — a *fix-quality* issue, not
  freshness. This (plus faster TTFF) motivates **Phase 2: the Apple Watch as a better GPS source**.
- Also confirmed: the GPS is ~1 Hz at the chip (`$PAIR050` 4 Hz not effective on this AG3335); not a
  Meshtastic publish throttle (`shouldPublish` fires per fix when always-on).

## GPS rate ceiling — DEFINITIVE (2026-06-25)

Tested a lean **position-only** (12-byte) payload with `$PAIR050` at **both 250 ms (4 Hz) and 100 ms
(10 Hz)**. Measured **novelty** (genuinely-new positions/sec, shown live on the iPhone): **max ~1.1 Hz
in every case.**

- **The AG3335 is hard-capped at ~1 Hz** — it ignores the `$PAIR050` fix-rate command at any value.
- **The payload is not a factor** (position-only still 1.1 Hz). The earlier ">1 Hz" reading of
  `m5_realgps.csv` was the ~2.8 Hz *packet* rate over a *fixed* position, not new fixes.
- The Apple Watch GPS is also ~1 Hz. The LoRa link + BLE bridge proved 4 Hz (counter test), but **no
  GPS source feeds it faster**.
- **Conclusion: ~1 Hz is the genuine position-novelty ceiling.** A faster-*feeling* track requires
  **display interpolation** (animate the dot at 60 fps between 1 Hz fixes via dead-reckoning), not
  faster GPS — same approach Maps/Strava use.

## GPS rate — exhaustive root-cause + the brick (2026-06-25)

Follow-up deep dive (with a hardware un-brick in hand, so we could probe aggressively). Measured the
**raw GPS NMEA output rate on-device** via `-DGPS_DEBUG` (count `$G?RMC`/sec — needs no fix). The RMC
UTC field steps by **exactly 1.000 s** in every configuration → a true, hard **1.00 Hz**.

**This AG3335's firmware locks the fix rate at 1 Hz — it refuses every rate command:**

| Command (family) | Method | Result |
|---|---|---|
| `$PAIR050,100` (Airoha) | RAM only | no `$PAIR001` ACK, stays 1 Hz |
| `$PAIR050,100` + `$PAIR513` | save + reboot | stays 1 Hz |
| `$PAIR050,100` + `$PAIR513` | save + **hardware RESETB** | stays 1 Hz |
| `$PMTK220,100` + `$PMTK300,100` (MediaTek) | RAM | no ACK, stays 1 Hz |

Yet the **command interface works**: the module answers `$PAIR021` (detected as `AG3335`) and honors
`$PAIR062` sentence config (output is GGA+RMC only). So it's not a wiring/baud/checksum issue — **the
rate command specifically is locked.** (Checksums independently verified: `$PAIR050,100*22`,
`$PMTK220,100*2F`.)

**The brick + recovery.** The *only* documented way to make `$PAIR050` "take" is to stop the engine
first with `$PAIR382,1` — which on this hardware enters a **VRTC-backed backup sleep that survives
reboots and hardware resets**, killing the `$PAIR021` probe (`No GNSS Module`) permanently. Recovery
is **not** possible over UART; it requires pulsing the **`GPS_RTC_INT` line HIGH** (variant: "normal
LOW, wake by HIGH") + a hardware reset. That wake is now a permanent safety-net in `createGps()`
(gated on `HIGHRATE_POSITION_SENDER`); see `firmware/FORK.md §3`.

**Final answer: 1 Hz is a hard firmware limit on this T1000-E's AG3335.** No UART command raises it,
and the one documented override bricks the chip. The productive path to real-time *feel* is **client
display interpolation**, not faster GPS.

## Dronetag Remote ID → LoRa bridge — BREAKTHROUGH (2026-06-26)

Sidesteps the locked GPS entirely: the T1000-E **nRF52840 sniffs a Dronetag's Remote ID BLE
advertisements** and re-broadcasts the position over LoRa — using the Dronetag's faster GPS instead of
the AG3335. The nRF BLE radio and the LR1110 LoRa chip are independent, so scan + TX don't contend.

```
Dronetag (RID, GNSS 10Hz / DRI 4Hz)  ──BLE adv (ASTM F3411, legacy 1M)──▶
  T1000-E Tag: BLE observer → decode ODID Location → PRIVATE_APP(256) ──LoRa──▶ Base ──BLE──▶ iPhone
```

- **Firmware:** `NRF52Bluetooth.cpp` adds a BLE observer (`Bluefruit.begin(1,1)` + continuous Scanner)
  that filters Service Data UUID `0xFFFA` / app `0x0D`, decodes the 25-byte ODID Location message
  (lat/lon int32 deg*1e7 — same as our payload), and hands the fix to `HighRatePositionModule` via
  `g_odidLat/g_odidLon/g_odidMs`. Gated behind `-DODID_SNIFFER`. **The `Scanner.resume()` after every
  report is mandatory** (S140 auto-pauses). `odidLastMs`-based freshness drives the lock flag.
- **Validated end-to-end:** Tag decodes the Dronetag fix (43.4831, −1.5068, coords tracking live),
  transmits over LoRa, **Base receives it at 2.86 Hz** (`tools/m2_stream_poc.py recv`), iPhone shows it.
- **Refresh rate:** novelty is the Dronetag's GNSS rate, **>1 Hz** (vs the locked 1 Hz onboard). In the
  bench test the *measured* novelty was capped by BLE packet loss (Dronetag on the balcony, Tag at the
  desk, RSSI −78 → ~1.3 Hz). **Co-located** (the real rig — both ride together, RSSI ~−20) the catch
  rate is full; the held-fix ODID-timestamp cadence read ~2.1 Hz with continuous scan.
- **Tool:** `tools/odid_sniff.py` parses the sniffer log → advert rate, RSSI, position-novelty Hz.
- **Pending:** field test (Dronetag + Tag co-located outdoors + moving, Base/iPhone at home) to confirm
  the full 2–4 Hz moving track at LoRa range. EU868 duty cycle still applies (>2.4 Hz = bench only).

## Sniffer rate optimization + simulated-flight finding (2026-06-26)

Branch `feat/odid-sniffer-rate`. Tuned the Tag as a dedicated BLE observer:
- **Onboard AG3335 GPS disabled** — `createGps()` gated behind `!ODID_SNIFFER` in `main.cpp`, so the
  locked-1Hz chip is never created/powered/probed (no thread, `PIN_GPS_EN` stays low).
- **Scan-only** — keep `Bluefruit.begin(1,1)` but stop advertising (no phone link needed on the Tag),
  so the observer gets ~100% radio time. (Not `begin(0,1)` — that skips per-peripheral CONN_CFG setup.)
- **Result: Location advert catch rate 2.9 Hz → ~5 Hz** (continuous scan). The scanner is no longer the
  bottleneck — refresh is now bound by the Dronetag, not by us.
- BT4/BT5 PHY selectable via `-DODID_PHY_EXT` (BT5 needs `firmware/patch-bluefruit-ext.sh` — Bluefruit's
  scan buffer is 31 B, extended PDUs need 255 B).

**Why the iOS "GPS refresh" drops during the indoor sim (investigated, not a bug):** the Dronetag's
flight **simulator runs at a VARIABLE rate** — it swings between ~4.5 Hz fresh fixes and ~1 Hz with
multi-second stalls, and stops broadcasting entirely between runs. Proven by logging the ODID fix
timestamp: during slow phases, frozen-position runs of 33–89 adverts showed the timestamp advance by
**0** (one run = ~17 s with no new fix); during fast phases it advanced at ~4.5 Hz. Adverts kept arriving
at ~5 Hz (re-broadcasts) throughout, so the *stream* rate stayed steady while *novelty* faithfully
tracked the sim's real cadence. Not a bridge/app bug. A real moving GPS feeds a steady rate, which the
bridge has ample headroom to carry.

**BT4 vs BT5 — validated, but ranking inconclusive on this device.** BT5 extended scanning **works** on
the T1000-E (`-DODID_PHY_EXT` + `patch-bluefruit-ext.sh` to grow Bluefruit's 31 B scan buffer to 255 B):
it receives the Dronetag's BT5 message-pack PDU and decoded Location at **4.54 Hz**. But BT4 legacy
**also** reached **4.57 Hz** on the same Dronetag — legacy is *not* throttled here, so the two PHYs are
**equivalent for refresh**. The sim's variable rate makes a clean sequential A/B impossible (each capture
lands in a different phase — an early BT4-slow vs BT5-fast comparison briefly looked like a 4.5× BT5 win,
then BT4 also hit 4.5 Hz). A definitive PHY ranking needs a constant-rate source (a real flight). **Default
stays BT4** (simpler — no out-of-repo lib patch); BT5 is implemented + validated for RID devices that *do*
throttle legacy.

> Metric note: the app's "GPS refresh" measures position-*change* (novelty), so it reads ~0 when the
> target is stationary even with a live GPS. A fix-timestamp-based "fresh-fix rate" would be a truer
> "is the data fresh?" indicator (deferred — bundles with a future app update).


