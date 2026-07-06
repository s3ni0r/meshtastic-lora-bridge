# Firmware fork — high-rate position stream on the T1000-E

Turns a T1000-E into a sub-second position streamer on `PRIVATE_APP (256)` (bypassing
PositionModule). **Two interchangeable TAG flavors** share the same 17-byte payload and the same
Base/iOS receiver — flags bits 5–7 carry the source type so receivers can tell them apart (§9):

| Flavor | Build flag | Position source | src bits |
|---|---|---|---|
| **BLE5/LoRa bridge** | `-DODID_SNIFFER …` | Dronetag Remote ID adverts (its GNSS, >1 Hz) | 1 |
| **GPS tag** | `-DGPS_TAG` | Onboard AG3335 **@ 10 Hz** (boot-time unlock, §3/§9) | 2 |
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
./apply-fork.sh   # clones meshtastic/firmware @ v2.7.15.567b8ea, copies drop-ins, applies the patch
```

### How the vendor tree is managed

`meshtastic-firmware/` is **git-ignored** (it has its own .git). The single source of truth for our
changes is the TRACKED outer repo:

- `meshtastic-fork.patch` — every edit to vendor files, one reviewable diff vs the build tag;
- `src/modules/…`, `src/gps/…`, `patch_bluefruit_ext.py` — project-owned drop-in files.

Workflow: **edit inside `meshtastic-firmware/` → build/flash → run `./sync-fork.sh`** (regenerates
the patch + copies the drop-ins) → commit the outer repo. `./apply-fork.sh` is the inverse — it
rebuilds the clone from the tracked artifacts on a fresh machine (it refuses to touch a dirty
clone). The clone also keeps a local `t1000e-fork` branch as an on-disk safety net, but it is not
pushed anywhere — never treat it as the canonical copy.

**Bumping the vendor base:** check out the new tag in the clone, re-apply the patch (fix
conflicts), rebuild all three flavors, then `sync-fork.sh` and update `TAG` in `apply-fork.sh`.
Mind the M5 lesson: build on the lineage the devices' SoftDevice matches (2.8.0 hung this
hardware).

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

## 3. GNSS fix rate — UNLOCKED to 10 Hz (2026-07-04; earlier "locked at 1 Hz" was a misdiagnosis)

**The AG3335 was never rate-locked.** Its command CPU auto-sleeps a few seconds after boot: NMEA
keeps streaming but later UART commands are silently ignored — which looked exactly like "the rate
command is refused" in every earlier probe (both units). The unlock, automated by `GnssRateProbe`
(v2) in every `GPS_TAG` boot:

1. **`$PAIR382,1` inside the boot window** ("lock system sleep" = keep the command CPU awake —
   Seeed's own driver blasts it 25x at scan start). `probe()`'s GPS_TAG preamble sends it 6x at
   GNSS power-on; the probe re-latches and verifies `$PAIR001,382,0`.
2. **`$PAIR050,100`** → ACK 0, effective immediately: **measured 10.0 fix/s sustained** (20
   GGA+RMC sentences/s). RAM-only; the probe re-applies each boot and re-runs if the rate sags.

Full root-cause, evidence log and spec references: `../docs/gnss/UNLOCK_NOTES.md`.

⚠️ Still true (the real trap): `$PAIR003`/`$PAIR650`-class power-offs without a *confirmed*
`$PAIR382,1` ACK leave the module deaf to UART until the **`GPS_RTC_INT` line pulses HIGH**
(variant: "normal LOW, wake by HIGH"). That wake + a reset pulse remain baked into `createGps()`
(gated on `HIGHRATE_POSITION_SENDER`) and in the probe's rescue path, so no sequence the firmware
sends can strand the module.

## 4. Build — one command per flavor

```bash
# TAG flavor A — BLE5/LoRa bridge (rides with a Dronetag; onboard GPS never powered):
PLATFORMIO_BUILD_FLAGS="-DODID_SNIFFER -DODID_PHY_EXT -DHIGHRATE_POSITION_SENDER \
  -DHIGHRATE_POSITION_INTERVAL_MS=250 -DHIGHRATE_TX_ONLY" pio run -e tracker-t1000-e

# TAG flavor B — self-contained GPS tag (onboard AG3335 unlocked, §3/§9). Default GNSS target is
# 4 Hz (-DGPSTAG_FIX_INTERVAL_MS=250; set 100 for 10 Hz — the probe STEERS to the target, e.g.
# back down from a flash-persisted 10 Hz). GPS_TAG implies HIGHRATE_POSITION_SENDER +
# HIGHRATE_TX_ONLY + a 100 ms GPS parser tick; the default 150 ms TX spacing passes 4 Hz untouched:
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

## 5. Flash

**Preferred:** `tools/flash_t1000e.sh <flavor> [port|role]` — flashes a **versioned release** from
`firmware/releases/` (UF2 or serial-DFU automatically, checksummed, with the per-flavor config
cheat-sheet printed after). `--list` shows releases + connected boards.

Manual UF2 fallback: hold the button and connect the magnetic charge cable **twice** until the
green LED is **solid**; a `T1000-E` USB drive mounts — drag the matching `.uf2` onto it. On a big
version jump, copy the matched nRF52 `*erase*.uf2` first.

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

### GnssRateProbe v2 — the boot-time 10 Hz unlock (and per-unit evidence machine)

Every `GPS_TAG` boot re-runs the unlock, non-blocking off the GPS thread (see §3 and
`../docs/gnss/UNLOCK_NOTES.md` for the root cause it exploits):

1. **Raw `$PAIR` tap** in `GPS::whileActive()` logs every module response verbatim ($PAIR001 ACK
   codes, $PAIR021 version, $PAIR051 fix-interval reply) — silence vs refusal is finally visible.
2. **Latch first**: `$PAIR382,1` as the opening step (plus a 6x blast in `probe()` at GNSS
   power-on) keeps the command CPU awake past its boot window; ACK `$PAIR001,382,0` = alive.
3. **France/Europe GNSS preset** (right after the latch, at 1 Hz so the `$PAIR513` persist is
   valid): `$PAIR066,1,1,1,1,0,0` = GPS+GLONASS+Galileo+BDS (max usable satellites -> best
   DOP/TTFF; Galileo is the European system; QZSS/NavIC are regional, off), `$PAIR410,1` = SBAS ON
   and `$PAIR411`/`$PAIR401` queries. **Verified on-device: `$PAIR411,1` + `$PAIR401,2` — EGNOS
   corrections active** (typ. 1–2 m class accuracy outdoors).
   **Motion tuning** (added after the 2026-07-06 field test showed a jittery walking track):
   `$PAIR080,<GPSTAG_NAV_MODE>` (default **1 = Fitness** — weights low-speed movement < 5 m/s;
   **5 = Drone**, 0 = Normal; note: Fitness/Swimming disable SBAS/EGNOS by design, so pick 0/5 to
   keep EGNOS), `$PAIR070,<GPSTAG_STATIC_THR_DMS>` static-nav threshold (default **3** dm/s =
   0.3 m/s — the chip freezes the output position below that speed: parked wander dies at the
   source), `$PAIR058,<GPSTAG_MIN_SNR>` (default **14** dB — masks weak multipath satellites;
   slight TTFF cost). All three carry a "not supported on LC29H(BA)" spec note — like $PAIR050
   did — so trust the on-device ACK codes in the boot log, not the datasheet.
4. Baseline (5 s, sentences-per-fix calibrated), then `$PAIR050,<GPSTAG_FIX_INTERVAL_MS>` — ACK 0,
   effective immediately: **WINNER at the target** (measured 3.99 fix/s @ 250 ms; 10.02 @ 100 ms),
   resident 10 s rate logs, auto re-steer if the rate ever sags or drifts off-target (a previous
   session's persisted rate is steered back too).
5. If a unit ever behaves differently, the fallback ladder still runs on evidence: ACK-gated
   dance (382,1 → 003 → 050,100 → 513 → 002, aborted unless the latch ACKs), $PAIR004 hot start,
   hardware reset, an echo test ($PAIR062,3,1 GSV-on) separating deaf-vs-mute, a reset+latch-spam
   window re-opener, GPS_RTC_INT rescue, and a 1000 ms restore so the module is never left
   half-configured.

### Direct-to-tag mode (no Base needed)

The sender cc's every position to the phone queue (`sendToMesh(..., ccToPhone=true)`), so a phone
connected **directly to a tag's BLE** receives the stream with no Base alive: the app prefers a
Base (sees the whole fleet over LoRa), and if none appears within ~6 s it falls back to the
nearest tag (that one tag only, BLE range). When the stream link is direct, the GNSS settings
sheet reuses it (a second PhoneAPI client on one node would fight over the FromRadio queue).

### Live GNSS settings over BLE (no reflash)

`GnssConfigModule` (portnum **260**, GPS_TAG builds) makes every GNSS/TX knob runtime-adjustable
from the phone: the MeshTracker app's gear button on a GPS-tag row opens a settings sheet that
connects to the TAG's own BLE (the Base link keeps streaming), reads current values, and applies
changes **live** — nav mode ($PAIR080: normal/fitness/stationary/drone/swimming/bike, with EGNOS
badges), static-freeze threshold ($PAIR070), SNR mask ($PAIR058), GNSS fix rate ($PAIR050) and
LoRa TX spacing, plus France-EU868 / US-bench one-tap profiles. Settings persist in the tag's
flash (`/prefs/gnsstag.dat`, `GnssTagSettings.{h,cpp}`); on SET the probe re-runs its tuning +
rate-steering ladder (~10 s to confirmation). Wire format + status codes: `GnssConfigModule.h`.
Compile-time `GPSTAG_*` macros are first-run defaults only now. Validated end-to-end over the
serial PhoneAPI (same code path as BLE): GET/SET/reject-invalid/restore all confirmed on-device.

### Accuracy pack (v1.2)

- **GST-backed hacc**: `$PAIR062,8,1` (ACK 0) turns on the receiver's own per-fix error
  statistics; the probe's raw tap parses `$G?GST` (TinyGPS++ custom fields are compiled out on
  this platform) and the payload's hacc byte carries the true 1-σ horizontal error — the HDOP×3 m
  heuristic remains only as fallback.
- **Elevation mask**: `$PAIR072` (ACK 0 — the spec's BA-lineage "unsupported" note is wrong for
  this build, same as $PAIR050/070/058) — settings-v2 knob, default 10°, slider in the app.
- **Boot diagnostics** (verdicts in the `<<` tap log): AIC anti-interference **on**
  (`$PAIR075,1`); jamming-detect events enabled (`$PAIR391,1`); **EASY predicted ephemeris is
  genuinely unsupported** (`$PAIR490,1` → ACK 3) — so TTFF assistance requires EPO injection
  (TODO), not a free toggle. Nav mode 7 (Swimming) is rejected by our unit (ACK 4).

### Configure + verify the GPS tag

Node settings are the §6 list (same channel/PSK as Base) with **`device.role CLIENT_MUTE`**: the
tag is a pure sender — firmware-side `HIGHRATE_TX_ONLY` already keeps the LR1110 out of RX (deaf
to LoRa, TX untouched), CLIENT_MUTE keeps it from ever rebroadcasting, and **BLE stays fully
usable** (unlike the bridge, the GPS tag keeps advertising, so the Meshtastic app connects
normally). At 4 Hz/ShortTurbo the ~7% channel utilization sits well under CLIENT_MUTE's gate, so
TRACKER's 40% allowance isn't needed. Plus `position.gps_update_interval=1`, GPS **enabled**.
Give each node a distinct name for sanity (`meshtastic --set-owner "TAG-GPS"` /
`"TAG-BRIDGE"` / `"BASE"`).

Watch the serial log after flashing:
- `GnssProbe: 'PAIR382,1' -> ACK code 0 (ok)` — sleep lock latched (interface alive);
- `GnssProbe: << $PAIR411,1` + `<< $PAIR401,2` — SBAS/EGNOS active;
- `GnssProbe: *** WINNER … ***` then `GnssProbe: GNSS rate 3.97-4.07 fix/s (8.0 sent/s)` every
  10 s — the live ground truth at the 4 Hz target;
- `HighRate: src=2 seq=…` — the stream is flowing with the GPS-tag source type.
On the receiver, `tools/m2_stream_poc.py recv --csv run.csv` shows `src=gps` rows; outdoors with a
position lock the iOS per-source "GPS refresh" should read up to ~10 Hz (TX-capped by
`HIGHRATE_MIN_SPACING_MS`).
