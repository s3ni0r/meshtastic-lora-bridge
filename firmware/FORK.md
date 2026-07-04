# Firmware fork — high-rate position stream on the T1000-E

Turns a T1000-E into a sub-second position streamer on `PRIVATE_APP (256)` (bypassing
PositionModule). **Two interchangeable TAG flavors** share the same 17-byte payload and the same
Base/iOS receiver — flags bits 5–7 carry the source type so receivers can tell them apart (§9):

| Flavor | Build flag | Position source | src bits |
|---|---|---|---|
| **BLE5/LoRa bridge** | `-DODID_SNIFFER …` | Dronetag Remote ID adverts (its GNSS, >1 Hz) | 1 |
| **GPS tag** | `-DGPS_TAG` | Onboard AG3335 (+ boot-time 4 Hz rate probe, §9) | 2 |
| Base (receiver) | *(plain build)* | — | — |

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
cp /path/to/meshtastic-tracker/firmware/src/gps/GnssRateProbe.h                src/gps/
cp /path/to/meshtastic-tracker/firmware/src/gps/GnssRateProbe.cpp              src/gps/
```
(Or just `git apply ../meshtastic-fork.patch` for the vendor-file edits — `sync-fork.sh` keeps both
in lockstep.)

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

## 3. GNSS fix rate — unit #1's AG3335 is LOCKED at 1 Hz (verified exhaustively)

> **Scope:** everything in this section was measured on **unit #1** (the original T1000-E, now the
> bridge tag). The lock is a property of that unit's GNSS *firmware build*, not of the T1000-E as a
> product — so the `GPS_TAG` flavor re-runs a safe, automated version of this investigation
> (`GnssRateProbe`, §9) on every boot, and any new unit gets its own verdict in the log. The safety
> rails below (**never `$PAIR382,1`**, RTC_INT recovery) are baked into the probe.

⚠️ **Bottom line (unit #1):** the AG3335 firmware **refuses all fix-rate commands** and there is
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

## 4. Build — one command per flavor

```bash
# TAG flavor A — BLE5/LoRa bridge (rides with a Dronetag; onboard GPS never powered):
PLATFORMIO_BUILD_FLAGS="-DODID_SNIFFER -DODID_PHY_EXT -DHIGHRATE_POSITION_SENDER \
  -DHIGHRATE_POSITION_INTERVAL_MS=250 -DHIGHRATE_TX_ONLY" pio run -e tracker-t1000-e

# TAG flavor B — self-contained GPS tag (onboard AG3335 + 4 Hz rate probe, §9).
# GPS_TAG implies HIGHRATE_POSITION_SENDER + HIGHRATE_TX_ONLY + a 100 ms GPS parser tick:
PLATFORMIO_BUILD_FLAGS="-DGPS_TAG" pio run -e tracker-t1000-e

# Base (iPhone-side receiver): plain build — a sender-flavor Base would emit pointless heartbeats:
pio run -e tracker-t1000-e
```
Each build lands at `.pio/build/tracker-t1000-e/firmware.uf2` — copy it out under a flavor name
(e.g. `build-out/bridge-tag.uf2`, `build-out/gps-tag.uf2`, `build-out/base-plain.uf2`) before the
next build overwrites it.

Rate knobs (defaults shown): `-DHIGHRATE_MIN_SPACING_MS=150` caps the event-driven TX at ~6.7 Hz
(use ≥500 for EU868-legal 2 Hz deployment); `-DHIGHRATE_POSITION_INTERVAL_MS=250` is only the
fallback poll when a cross-task wake is missed.

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
- **TX-only radio** (`-DHIGHRATE_TX_ONLY`) — the Tag's role is relay-only, so `LR11x0Interface::
  startReceive()` idles the LR1110 in **standby instead of RX**: an in-progress foreign RX can never
  defer a TX (LoRa is half-duplex), no received packet is ever processed, and standby draws µA vs mA in
  continuous RX. CAD still runs pre-TX and the TX-done IRQ is wired in `startSend()`, so the transmit
  path is untouched. Trade-off: the Tag is deaf to the mesh — remote admin over LoRa and any future
  reverse channel (e.g. buzzer paging) need this flag dropped. **The Base must run a PLAIN build** (no
  `HIGHRATE_POSITION_SENDER`) — a sender-build Base emits pointless 0.5 Hz lock=0 heartbeats, which was
  the only regular traffic the Tag ever received.

**Measured on-device (Dronetag live, hacc 3 m):** `dec2send = 2–3 ms` (was 0–250 ms poll, mean
~125 ms); Tag `rxGood` pinned at 0 with TX flowing; Base receives the stream at the true novelty rate
(~2.3 pkt/s, median gap 356 ms) with no duplicate airtime.

Tag build:
```bash
PLATFORMIO_BUILD_FLAGS="-DODID_SNIFFER -DODID_PHY_EXT -DHIGHRATE_POSITION_SENDER \
  -DHIGHRATE_POSITION_INTERVAL_MS=250 -DHIGHRATE_TX_ONLY" pio run -e tracker-t1000-e
```

## 9. GPS tag flavor (`gps-lora-tag` branch) — onboard AG3335 → LoRa, same payload

`-DGPS_TAG` turns a T1000-E into a **self-contained tag**: its own AG3335 fixes stream on
`PRIVATE_APP(256)` in the exact bridge format, so the Base and iOS app need no per-flavor logic.
One flag implies the whole role (`HIGHRATE_POSITION_SENDER`, `HIGHRATE_TX_ONLY`, 100 ms GPS parser
tick); it is mutually exclusive with `ODID_SNIFFER` (compile error if combined).

### Payload identity — telling the tags apart

`flags` byte (offset 11): bit0 = lock, **bits 5–7 = source type** — `1` = ODID bridge, `2` = GPS
tag, `0` = legacy/pre-fork. Old 12-byte clients keep working (they only mask bit0). Receivers thus
distinguish tags two independent ways: the LoRa `from` node id (unique per device) and the source
type (which *kind* of tag). The iOS app tracks each `from` as its own colored trail and shows the
flavor label; `tools/m2_stream_poc.py recv` prints/logs both.

### Event-driven internal GPS (mirror of the sniffer path)

`GPS.cpp::publishUpdate()` stashes every *published* fix into `g_gpsTag*` globals (lat/lon deg·1e7,
alt m, speed km/h, heading, hacc ≈ HDOP × 3 m, plus a **0.1 s-in-hour timestamp with centiseconds**
— the novelty key, same semantics as the ODID `ts`) and calls
`highRatePositionModule->wakeFreshFix()`. A fresh fix is on the LoRa queue in ~ms; novelty dedupe,
`HIGHRATE_MIN_SPACING_MS` pacing, the 2 s heartbeat, and latest-wins queueing behave exactly as on
the bridge (§8). With `gps_update_interval=1` the GPS stays always-on, so fixes publish at the
chip's true cadence.

### GnssRateProbe — the automated 4 Hz attempt (why it's safe to retry per unit)

Unit #1's 1 Hz lock (§3) was a property of *that unit's* GNSS firmware. Every `GPS_TAG` boot
re-tests the installed unit with a **non-blocking, RAM-only** prober driven off the GPS thread:

1. Waits ~15 s for boot + NMEA flow, measures the **as-shipped baseline** for 5 s and calibrates
   sentences-per-fix (fix epochs = NMEA time-of-day changes at centisecond resolution — works
   before a position lock; the sentence-rate cross-check defeats tick-aliasing at 10 Hz).
2. Walks candidates in order, 4 s measurement each, stopping at the first that holds
   **≥ 3.5 fix/s**: `$PAIR050,250` → `$PAIR050,100` → `$PAIR080,1`+`$PAIR050,250` (nav-mode gate)
   → `$PMTK220/300,250` → `$PAIR003 › $PAIR050,250 › $PAIR002` (engine-stop sandwich — the one
   documented "apply while stopped" path that does **not** use the `$PAIR382,1` backup-sleep brick).
3. Logs `GnssProbe: *** WINNER …` and stays resident (10 s rate logs, auto re-apply if the RAM
   setting sags — e.g. after a GPS power event), **or** logs
   `GnssProbe: VERDICT — all candidates refused … locked (same as unit #1)` and the stream simply
   rides 1 Hz novelty (client interpolation still applies).

Hard safety rails: **never `$PAIR382,1`**, never a persist dance; checksums computed at runtime;
commands only while `GPS_ACTIVE`; the §3 anti-brick preamble + `GPS_RTC_INT` recovery net stay in
place (they're gated on `HIGHRATE_POSITION_SENDER`, which `GPS_TAG` implies). Worst case on a
locked unit = a few ignored sentences at boot and an honest verdict in the log.

### Configure + verify the GPS tag

Node settings are the §6 list (same channel/PSK as Base; `role=TRACKER`,
`position.gps_update_interval=1`, GPS **enabled** — do *not* reuse the bridge's GPS-off habits).
Give each node a distinct name for sanity (`meshtastic --set-owner "TAG-GPS"` /
`"TAG-BRIDGE"` / `"BASE"`).

Watch the serial log after flashing:
- `GnssProbe: baseline 1.00 fix/s, 2.0 sentences/fix` — probe armed and measuring;
- per-candidate verdicts, then either `*** WINNER` or the locked verdict;
- `GnssProbe: GNSS rate X.XX fix/s` every 10 s — the live ground truth;
- `HighRate: src=2 seq=…` — the stream is flowing with the GPS-tag source type.
On the receiver, `tools/m2_stream_poc.py recv --csv run.csv` shows `src=gps` rows at the novelty
rate; the iOS app's per-source "GPS refresh" is the end-to-end number that must read ~4 Hz if the
probe won (else ~1 Hz).
