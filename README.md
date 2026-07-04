# meshtastic-tracker

Real-time GPS over LoRa: moving **Seeed T1000-E tags** (Meshtastic fork) stream positions to a
T1000-E Base tethered to an **iPhone**, shown live on a map at multi-Hz. Region: **EU868**
(deployment target); bench-validated on US/ShortTurbo.

## Status (2026-07-04) — two tag flavors, AG3335 unlocked, multi-tag iOS app ✅

```
Tag A: BLE5/LoRa bridge (Dronetag Remote ID → LoRa)  ─┐
                                                      ├─LoRa─▶ Base ──BLE──▶ iPhone (MeshTracker)
Tag B: GPS tag (onboard AG3335 @ 4 Hz → LoRa)        ─┘
```

- **Two interchangeable tag firmwares**, same 17-byte `PRIVATE_APP(256)` payload; flags bits 5–7
  identify the source (1 = bridge, 2 = GPS tag) on top of the LoRa `from` node id
  ([firmware/FORK.md](firmware/FORK.md)).
- **AG3335 GNSS unlocked to 10 Hz** — the historical "1 Hz firmware lock" was a misdiagnosis (the
  command CPU auto-sleeps post-boot; the fix is a boot-window `$PAIR382,1` latch + `$PAIR050`).
  Deployed at a **4 Hz target**, steered per boot by `GnssRateProbe`, with a France/Europe GNSS
  preset (GPS+GLONASS+Galileo+BDS, **EGNOS SBAS verified active**). Full story:
  [docs/gnss/UNLOCK_NOTES.md](docs/gnss/UNLOCK_NOTES.md).
- **GPS tag runs `role=CLIENT_MUTE` + TX-only radio** (never receives LoRa) while keeping BLE for
  the Meshtastic app.
- **iOS app v2**: per-tag colored trails + heading arrows, favorites (persisted), per-tag
  show/hide, stable focus with pin/follow, map styles (standard/hybrid/satellite), fit-all, metric
  tiles (speed/heading/alt/accuracy/SNR/RSSI), CSV logging, app icon.

Numbers & raw results: [docs/results.md](docs/results.md). Plan/constraints: [PLAN.md](PLAN.md).

## Layout

- [`PLAN.md`](PLAN.md) — verified build plan, RF/firmware constraints (EU868), milestones M0–M9.
- [`firmware/`](firmware/) — the Meshtastic fork: [`FORK.md`](firmware/FORK.md) (apply/build/flash) +
  `src/modules/HighRatePositionModule.{h,cpp}`. The full clone lives in
  `firmware/meshtastic-firmware/` (gitignored).
- [`ios/`](ios/) — **MeshTracker**, a minimal SwiftUI + CoreBluetooth app (`project.yml` → xcodegen),
  with a dependency-free protobuf decoder (no SPM deps).
- [`tools/`](tools/) — `m2_stream_poc.py` (stream + measure), `m1_gps_rate_check.md`,
  `flash_uf2.py`, `serial_monitor.py`.
- [`docs/`](docs/) — `results.md` + raw CSV logs (logs gitignored).

## Build & run

### Firmware fork
Full steps + the three-flavor build matrix in [firmware/FORK.md](firmware/FORK.md). Summary:
```bash
cd firmware/meshtastic-firmware
# GPS tag (onboard AG3335, 4 Hz target; 100 = 10 Hz):
PLATFORMIO_BUILD_FLAGS="-DGPS_TAG" pio run -e tracker-t1000-e
# BLE5/LoRa bridge tag:
PLATFORMIO_BUILD_FLAGS="-DODID_SNIFFER -DODID_PHY_EXT -DHIGHRATE_POSITION_SENDER \
  -DHIGHRATE_POSITION_INTERVAL_MS=250 -DHIGHRATE_TX_ONLY" pio run -e tracker-t1000-e
# Base: plain build. Flash: tools/flash_uf2.py, or serial DFU via adafruit-nrfutil.
```

**Flashing more T1000-Es:** versioned, checksummed binaries live in
[`firmware/releases/`](firmware/releases/) (v1.0 = all three flavors) — flash any board with
`tools/flash_t1000e.sh <flavor> [port|role]` (`--list` shows releases + connected boards).
> Build on the device's **installed** Meshtastic version (v2.7.15 here). Master 2.8.0 **hangs** this
> hardware via single-bank DFU (SoftDevice mismatch). `meshtastic --enter-dfu` puts a node in DFU.

### iOS app
```bash
cd ios && xcodegen generate
xcodebuild -project MeshTracker.xcodeproj -scheme MeshTracker \
  -destination 'id=<iphone-udid>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <iphone-udid> \
  "$(ls -d ~/Library/Developer/Xcode/DerivedData/MeshTracker-*/Build/Products/Debug-iphoneos/MeshTracker.app | head -1)"
```
> Requires your Apple ID in **Xcode → Settings → Accounts**, and trusting the dev profile on the
> phone (Settings → General → VPN & Device Management) on first launch.

### Measurement tools (laptop ↔ node over USB)
```bash
pip install meshtastic
# host-injected stream test:
python tools/m2_stream_poc.py both --send-port <a> --recv-port <b> --rate 2 --count 60 --csv run.csv
# capture an on-device stream on the receiver:
python tools/m2_stream_poc.py recv --port <base-port> --duration 60 --csv run.csv
```

## Identifying the nodes

Port names (`usbmodemXXXX`) can shuffle on replug, so address boards by **role**, resolved from the
stable nRF52 **USB serial** (survives reboot/reflash/DFU) via `tools/nodes.py`:

| Role | USB serial (physical ID) | Node ID | Node num |
|---|---|---|---|
| **Tag** (BLE5 bridge) | `92EBF6B5B6C9AC37` | `!b4dbb54c` | 3034297676 |
| **GpsTag** (onboard GPS @ 4 Hz) | `15B20E7A7AAD8AF0` | `!18e77545` | 417822021 |
| **Base** (receiver, visually tagged) | `4A8693CC387EBD66` | `!b0bb9cda` | 2965085402 |

```bash
python tools/nodes.py               # show which port is which right now
python tools/nodes.py --port gpstag # -> /dev/cu.usbmodemXXXX (for scripting)
```
`flash_uf2.py` and `m2_stream_poc.py` accept `tag`/`base` anywhere a port is expected, e.g.
`python tools/m2_stream_poc.py recv --port base` or `python tools/flash_uf2.py tag firmware.uf2`.

## Constraints (EU868) — see [PLAN.md](PLAN.md)
- **2 Hz sustained** is the legal EU868 target (ShortFast); 3–4 Hz sustained exceeds the 10% duty
  cycle (bench-only). **ShortTurbo is unusable in EU868** (firmware reverts it to LongFast).
- Bench used **US/ShortTurbo** (no firmware duty cycle) — the devices' as-found config.

## Phase 2 (not started)
Bridge an **Apple Watch** GPS through the tracker (Watch → WatchConnectivity → iPhone → BLE →
node) if the onboard GNSS proves inadequate. Notes in [PLAN.md](PLAN.md) §8 / firmware design.
