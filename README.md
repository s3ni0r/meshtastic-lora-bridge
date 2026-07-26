# meshtastic-tracker

Real-time GPS over LoRa: moving **Seeed T1000-E tags** (custom Meshtastic fork) stream
19-byte positions at multi-Hz to a T1000-E **Base** tethered to an **iPhone**, shown live on
a map. Since branch `tag-downlink` the link is **bidirectional**: the phone switches the
tag's TX mode, drives operator beeps and an on-tag indoor simulator through the Base at LoRa
range (~0.2–0.35 s). Region: **EU868** (deployment target); bench-validated on hardware.

```
Tag A: BLE5/LoRa bridge (Dronetag Remote ID → LoRa)  ─┐
                                                      ├─LoRa─▶ Base ──BLE──▶ iPhone (MeshTracker)
Tag B: GPS tag (onboard AG3335 @ 4 Hz → LoRa)        ─┘
```

**Current state (2026-07-26):** firmware **v4.3** deployed (four external-review rounds
absorbed; TRACK wire = u32 transfer id + A/B slot storage), payload **v4** (position +
battery + motion), adaptive speed-gated TX, beep-first calibration signals, and GPX/session
track replay on the tag. The immutable v4.3 binary passed its historical hardware suite
(22/22); the post-v4.3 working-tree hardening passed the expanded physical-hardware suite
(28/28), including reboot recovery and post-reboot COMMIT retry. Dated narrative:
[docs/HISTORY.md](docs/HISTORY.md).

## The aspects, and where each is documented

| Aspect | Authoritative doc |
|---|---|
| Uplink stream payload (19 B v4: position, battery, motion, flags) | [docs/BATTERY_INTEGRATION.md](docs/BATTERY_INTEGRATION.md) |
| Downlink command channel (modes, signals, simulator, track upload) | [docs/DOWNLINK.md](docs/DOWNLINK.md) — **the wire contract** |
| Firmware fork (architecture, flavors, build matrix, GNSS unlock) | [firmware/FORK.md](firmware/FORK.md) + [docs/gnss/UNLOCK_NOTES.md](docs/gnss/UNLOCK_NOTES.md) |
| iOS app (map, tag setup, sessions, simulator UI, BLE model) | [docs/IOS_APP.md](docs/IOS_APP.md) |
| Radio & regulatory (EU868 duty math, presets × regions × fleet) | [docs/CAPACITY.md](docs/CAPACITY.md) + [PLAN.md](PLAN.md) |
| Hardware verification (the shipping gate) | [tools/bench/README.md](tools/bench/README.md); raw numbers in [docs/results.md](docs/results.md) |
| Operations (flashing, releases, rollback, TestFlight) | [firmware/releases/](firmware/releases/) · `tools/flash_t1000e.sh` · [docs/testflight-release.md](docs/testflight-release.md) |
| Agent onboarding + step-by-step procedures | [AGENTS.md](AGENTS.md) + `.claude/skills/` |
| Roadmap (sensor fusion, sea-threshold tuning) | [TODO.md](TODO.md); history: [docs/HISTORY.md](docs/HISTORY.md) |

## Quick start

### Firmware (three flavors — full matrix in [firmware/FORK.md](firmware/FORK.md))

```bash
cd firmware/meshtastic-firmware
PLATFORMIO_BUILD_FLAGS="-DGPS_TAG" pio run -e tracker-t1000-e          # GPS tag
PLATFORMIO_BUILD_FLAGS="-DODID_SNIFFER -DODID_PHY_EXT -DHIGHRATE_POSITION_SENDER \
  -DHIGHRATE_POSITION_INTERVAL_MS=250 -DHIGHRATE_TX_ONLY" pio run -e tracker-t1000-e  # bridge
pio run -e tracker-t1000-e                                             # base
```

Flash **released**, checksummed binaries by role (fail-closed: manifest checksums +
hardware-serial pinning):

```bash
tools/flash_t1000e.sh gps-tag gpstag        # latest release; VERSION=vX.Y pins one
```

Rollback of the whole fleet to the validated v3.0 state: `firmware/known-good/restore.sh`.
> Build against the device's **installed** Meshtastic version (v2.7.15 here) — master 2.8.0
> hangs this hardware via single-bank DFU (SoftDevice mismatch).

### iOS app

```bash
cd ios && xcodegen generate
xcodebuild -project MeshTracker.xcodeproj -scheme MeshTracker -configuration Debug \
  -destination 'id=<iphone-udid>' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <iphone-udid> \
  build/Build/Products/Debug-iphoneos/MeshTracker.app
```
> First run: Apple ID in Xcode → Settings → Accounts; trust the dev profile on the phone.
> TestFlight: `ios/scripts/release.sh` ([docs/testflight-release.md](docs/testflight-release.md)).

### Verify on hardware (before shipping any firmware change)

```bash
~/.local/pipx/venvs/meshtastic/bin/python -u tools/bench/verify_fixes.py   # exit 0 or it doesn't ship
```

## Identifying the nodes

Port names shuffle on replug — address boards by **role**, resolved from the stable nRF52
USB serial via `tools/nodes.py` (`python tools/nodes.py` lists live ports; tools accept
`tag`/`base`/`gpstag` anywhere a port is expected):

| Role | USB serial (physical ID) | Node ID | Node num |
|---|---|---|---|
| **Tag** (BLE5 bridge) | `92EBF6B5B6C9AC37` | `!b4dbb54c` | 3034297676 |
| **GpsTag** (onboard GPS @ 4 Hz) | `15B20E7A7AAD8AF0` | `!18e77545` | 417822021 |
| **Base** (receiver, visually tagged) | `4A8693CC387EBD66` | `!b0bb9cda` | 2965085402 |

## Constraints (EU868) — details in [PLAN.md](PLAN.md) / [docs/CAPACITY.md](docs/CAPACITY.md)

- **2 Hz sustained** is the legal EU868 target (ShortFast, ~9.5% duty with the 19 B payload);
  higher sustained rates are bench-only. ShortTurbo is unusable in EU868.
- The adaptive TX mode exists to spend that budget where it matters: full rate while
  moving, 1 pkt/3 s when quasi-stationary; CALIBRATION bursts are TTL-dead-man guarded.

## License

**GPL-3.0** (see [LICENSE](LICENSE)). The firmware under `firmware/` is a derivative of
[Meshtastic firmware](https://github.com/meshtastic/firmware) (GPL-3.0); the complete
corresponding source for every binary in `firmware/releases/` is this repository itself
(`firmware/meshtastic-fork.patch` + `firmware/src/` drop-ins applied to the pinned upstream
tag via `firmware/apply-fork.sh`). The iOS app, tools and docs are released under the same
license.
