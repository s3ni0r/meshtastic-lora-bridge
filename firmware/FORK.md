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

## 3. (Optional) Raise the GNSS fix rate — `src/gps/GPS.cpp`

In `GPS::setup()`, in the `IS_ONE_OF(gnssModel, GNSS_MODEL_AG3335, GNSS_MODEL_AG3352)` branch, the
tail currently reads:
```cpp
            delay(250);
            _serial_gps->write("$PAIR513*3D\r\n"); // save configuration
```
Insert the fix-rate command just before it (guarded so only the sender build gets fast GPS):
```cpp
#ifdef HIGHRATE_POSITION_SENDER
            _serial_gps->write("$PAIR050,250*24\r\n"); // 4 Hz fix rate (bench/test)
#endif
            delay(250);
            _serial_gps->write("$PAIR513*3D\r\n"); // save configuration
```
Checksums: `250ms=*24` (4 Hz), `200ms=*21` (5 Hz), `100ms=*22` (10 Hz), `500ms=*26` (2 Hz).
**Validate acceptance first (M1, `../tools/m1_gps_rate_check.md`)** — some AG3335 revisions reject
250 ms. If so, use `$PAIR050,100*22` (10 Hz) and the module will decimate naturally to its send rate.

> The module's TX cadence is independent of the GNSS fix rate, so you can test the LoRa rate/PDR
> path (Step 6) **before** confirming the GPS rate — it'll just repeat stale fixes until §3 lands.

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
