# Firmware fork — high-rate position stream on the T1000-E

Turns the moving T1000-E into a 2–4 Hz position streamer by (a) optionally raising the AG3335 GNSS
fix rate and (b) adding a dedicated sender on `PRIVATE_APP (256)` that bypasses PositionModule.

> **Bench/test only.** At >2.4 Hz this exceeds the EU868 10% duty cycle. Set
> `lora.override_duty_cycle=true` on the sender. Not for deployment. See `../PLAN.md` §1.

The files here (`src/modules/HighRatePositionModule.{h,cpp}`) are **drop-ins** for a Meshtastic
checkout. (Clang errors when viewed standalone are expected — the Meshtastic headers aren't on the
include path until they're inside the firmware tree.) All edits anchor on **symbols**, not line
numbers (those drift).

## 0. Prereqs

```bash
git clone https://github.com/meshtastic/firmware && cd firmware
git submodule update --init --recursive
# PlatformIO Core installed (pip install platformio)
```

## 1. Add the module

```bash
cp /path/to/meshtastic-tracker/firmware/src/modules/HighRatePositionModule.h   src/modules/
cp /path/to/meshtastic-tracker/firmware/src/modules/HighRatePositionModule.cpp src/modules/
```

## 2. Register it — `src/modules/Modules.cpp`

Add the include near the other `#include "modules/..."` lines:
```cpp
#include "modules/HighRatePositionModule.h"
```
Inside `setupModules()`, alongside the other `new XxxModule()` lines:
```cpp
#ifdef HIGHRATE_POSITION_SENDER
    highRatePositionModule = new HighRatePositionModule();
#endif
```

## 3. GNSS fix rate — this AG3335 is LOCKED at 1 Hz (verified exhaustively)

⚠️ **Bottom line:** on this T1000-E the AG3335 firmware **refuses all fix-rate commands** and there is
**no working way to raise it above 1 Hz.** Measured on-device with `-DGPS_DEBUG` (RMC steps by exactly
1.000 s every time): `$PAIR050,100` (Airoha) gets no `$PAIR001` ACK and no effect via RAM, save+reboot,
*and* save+hardware-RESETB; `$PMTK220,100`/`$PMTK300,100` (MediaTek) likewise. The interface itself
works — it answers `$PAIR021` and honors `$PAIR062` sentence config — so the rate is specifically
locked. Full table in `../docs/results.md` "GPS rate — exhaustive root-cause". **Leave it at 1 Hz; do
client-side interpolation for a real-time feel.**

⚠️ **And do NOT try to force it via the persist dance — it bricks the module.** Raising the rate above
1 Hz "officially" requires *persisting* it, and the documented persist sequence **bricks GPS detection
on the T1000-E**:

```
$PAIR050,100   (10 Hz)
$PAIR382,1     (stop engine / enter backup)   ← the culprit
$PAIR003       (power off GNSS subsystem)
$PAIR513       (save)
$PAIR002 / $PAIR004 (re-power / hot-start)
```

`$PAIR382,1` puts the AG3335 into a **VRTC-backed backup sleep**. On the T1000-E `GPS_VRTC_EN`
(P0.8) stays HIGH across reboots, so the sleep **survives every reboot and a plain hardware reset**,
and the module stops answering the `$PAIR021` probe → `No GNSS Module` forever. A bare `$PAIR513`
(the only save valid at 1 Hz) does **not** persist >1 Hz, so this dance is the *only* documented way —
and it's a trap on this hardware.

**Net: the onboard AG3335 is treated as a fixed ~1 Hz source.** `position.gps_update_interval=1`,
no `$PAIR050`. For a faster-*feeling* track, interpolate on the client (60 fps dead-reckoning between
1 Hz fixes) — not faster GPS. See `../docs/results.md` "GPS rate ceiling".

### Recovery safety-net (keep this — it un-bricks a slept GNSS)

If a module is already stuck asleep, the wake is the **`GPS_RTC_INT` pin going HIGH** (variant:
"normal LOW, wake by HIGH") — UART can't wake it. In `createGps()` (just after `new_gps->up();`,
before the stock `PIN_GPS_RESET` pulse):
```cpp
#if defined(HIGHRATE_POSITION_SENDER) && defined(GPS_RTC_INT)
    pinMode(GPS_RTC_INT, OUTPUT);
    digitalWrite(GPS_RTC_INT, HIGH); delay(300);          // wake from backup sleep
#ifdef PIN_GPS_RESET
    pinMode(PIN_GPS_RESET, OUTPUT);
    digitalWrite(PIN_GPS_RESET, GPS_RESET_MODE); delay(60);
    digitalWrite(PIN_GPS_RESET, !GPS_RESET_MODE);
#endif
    delay(400); digitalWrite(GPS_RTC_INT, LOW); delay(200);
#endif
```
And in `probe()`'s Airoha case (before the `$PAIR021` probe), keep it awake + at 1 Hz:
```cpp
#ifdef HIGHRATE_POSITION_SENDER
    _serial_gps->write("$PAIR002*38\r\n");      delay(200); // power on
    _serial_gps->write("$PAIR382,0*2F\r\n");    delay(200); // DISABLE backup sleep
    _serial_gps->write("$PAIR050,1000*12\r\n"); delay(200); // 1 Hz
    _serial_gps->write("$PAIR513*3D\r\n");      delay(300); // save (valid at 1 Hz)
#endif
```

> The module's TX cadence is independent of the GNSS fix rate, so the LoRa rate/PDR path (Step 6) was
> validated to 4 Hz on a counter regardless — the GPS is what's pinned at 1 Hz, not the link.

## 4. Build

```bash
# Sender (moving node): high-rate stream + fast GPS, 4 Hz
PLATFORMIO_BUILD_FLAGS="-DHIGHRATE_POSITION_SENDER -DHIGHRATE_POSITION_INTERVAL_MS=250" \
  pio run -e tracker-t1000-e
#   → .pio/build/tracker-t1000-e/firmware-tracker-t1000-e-*.uf2   (rename/keep as sender.uf2)

# Receiver (iPhone-side node): plain build
pio run -e tracker-t1000-e
```
(`-DHIGHRATE_POSITION_INTERVAL_MS=500` for 2 Hz.)

## 5. Flash (UF2)

Hold the button and connect the magnetic charge cable **twice** until the green LED is **solid**; a
`T1000-E` USB drive mounts. Drag the matching `.uf2` onto it (sender build → moving node, plain build
→ receiver). On a big version jump, copy the matched nRF52 `*erase*.uf2` first.

## 6. Configure both nodes (CLI or iOS app)

```bash
meshtastic --set lora.region EU_868
meshtastic --set lora.modem_preset SHORT_FAST
meshtastic --set lora.hop_limit 1
meshtastic --set lora.override_duty_cycle true     # BENCH/TEST ONLY
meshtastic --set device.role TRACKER               # raises channel-util gate 25%→40%
meshtastic --set device.rebroadcast_mode LOCAL_ONLY
meshtastic --set position.gps_update_interval 1
# Same private channel/PSK on both nodes so the link is isolated.
```
After flashing, confirm via serial log the active preset is **ShortFast** (not LongFast — i.e. no
"region too narrow" error), `region=EU_868`, `role=TRACKER`.

## 7. Validate

- Receiver side: run `../tools/m2_stream_poc.py recv --port <recv-node> --csv run.csv` (it decodes
  the same 12-byte PRIVATE_APP payload the firmware now emits) — or the iOS client once built.
- Confirm the effective rate at the receiver matches the send cadence and log RSSI/SNR vs distance.
- Compliance check: read `AirTime::utilizationTXPercent()` (device metrics) — at 2 Hz it should sit
  ~8% (deployment-legal); at 4 Hz ~16% (bench-only, why `override_duty_cycle` is set).

## 8. Low-latency event-driven sender (`feat/low-latency-bridge`)

The ODID-sniffer build no longer polls: a fresh fix is sent in ~ms instead of aging up to a full
250 ms tick (mean ~125 ms — the dominant Tag-side latency before this branch).

- **Event-driven TX** — `odidDecodeLocation` detects fix **novelty** (ODID `ts`/lat/lon change vs the
  last decode, stored in `g_odidTs`) and wakes the sender:
  `highRatePositionModule->wakeFreshFix()` = `setIntervalFromNow(0)` + `mainDelay.interrupt()` — the
  same cross-task pattern NimbleBluetooth uses for the phone API.
- **Novelty dedupe** — `HighRatePositionModule` sends only when the fix actually changed
  (`lastSentTs/Lat/Lon`), paced by `HIGHRATE_MIN_SPACING_MS` (default 150 ms ≈ 6.7 Hz cap; use ≥500 for
  EU868 duty). Duplicate re-adverts (~5 Hz) no longer burn airtime; a 2 s heartbeat keeps liveness when
  the fix is frozen or lost. `HIGHRATE_POSITION_INTERVAL_MS` is now just the fallback poll (a missed
  cross-task wake degrades to the old polling latency, never worse).
- **Scanner resume-first** — `odidScanCb` copies the report out (`parseReportByType`) and calls
  `Scanner.resume()` BEFORE decode/logging: S140 pauses scanning from report delivery until resume, so
  work done before it = adverts silently missed.
- **Latest-wins queue** — stock-PositionModule `prevPacketId` + `service->cancelSending()` before each
  send, so a stale queued position never transmits ahead of a fresh one.
- **Validation metric** — the every-20th send log prints `dec2send=<ms>` (sniffer-decode → LoRa-enqueue);
  expect single-digit-to-low-tens ms vs ~125 ms mean on `main`.
