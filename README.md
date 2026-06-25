# meshtastic-tracker

Real-time GPS over LoRa: a moving **Seeed T1000-E** (Meshtastic) streams its own GPS position to a
second T1000-E tethered to an **iPhone**, shown live on a map at multi-Hz. Region: **EU868**
(deployment target); bench-validated on US/ShortTurbo.

## Status (2026-06-25) — working end-to-end ✅

A battery-powered tracker autonomously streams its **real GPS position** over LoRa, displayed **live
on iPhone**:

```
Tag (T1000-E, fork) ──LoRa──▶ Base (T1000-E) ──BLE──▶ iPhone (MeshTracker app)
```

- **Firmware fork** on the moving node streams a 12-byte position on a custom `PRIVATE_APP(256)`
  portnum at ~2.8–4 Hz, **bypassing Meshtastic's PositionModule throttles** (built on v2.7.15 — see
  [firmware/FORK.md](firmware/FORK.md)).
- **Real GPS validated:** Tag on a balcony acquired a live lock and streamed real coordinates at
  **~2.9 Hz, 100% lock, 0 gaps** ([docs/results.md](docs/results.md)).
- **iOS app** ([ios/](ios/)) connects to Base over BLE, decodes the stream, and shows the live
  position on a MapKit map with a **Hz / SNR / RSSI** readout + CSV logging — running on a real
  iPhone 17 Pro.

Numbers & raw results: [docs/results.md](docs/results.md). Full plan, RF/firmware constraints, and
milestones: [PLAN.md](PLAN.md).

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
Full steps in [firmware/FORK.md](firmware/FORK.md). Summary (sender node):
```bash
cd firmware/meshtastic-firmware
PLATFORMIO_BUILD_FLAGS="-DHIGHRATE_POSITION_SENDER -DHIGHRATE_POSITION_INTERVAL_MS=250" \
  pio run -e tracker-t1000-e -t upload --upload-port <tag-port>
```
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

## Identifying the two nodes

Port names (`usbmodemXXXX`) can shuffle on replug, so address boards by **role**, resolved from the
stable nRF52 **USB serial** (survives reboot/reflash/DFU) via `tools/nodes.py`:

| Role | USB serial (physical ID) | Node ID | Node num |
|---|---|---|---|
| **Tag** (mover) | `92EBF6B5B6C9AC37` | `!b4dbb54c` | 3034297676 |
| **Base** (receiver, visually tagged) | `4A8693CC387EBD66` | `!b0bb9cda` | 2965085402 |

```bash
python tools/nodes.py               # show which port is Tag / Base right now
python tools/nodes.py --port base   # -> /dev/cu.usbmodemXXXX (for scripting)
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
