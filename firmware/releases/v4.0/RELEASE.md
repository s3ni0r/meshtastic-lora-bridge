# T1000-E tracker firmware — v4.0 (MAJOR: downlink + payload v4 + review hardening)

## Provenance (external-review requirement — pin everything)

| What | Value |
|---|---|
| **Source of truth** | this repo, branch `tag-downlink`, commit **`dc79a65`** ("fix: external-review findings 1-5") |
| Vendor base | meshtastic/firmware tag `v2.7.15.567b8ea` + `meshtastic-fork.patch` + `firmware/src/` drop-ins |
| Reconstruction | `firmware/apply-fork.sh` (now mirrors the WHOLE drop-in tree), then the FORK.md §4 build matrix |
| Toolchain | PlatformIO Core 6.1.19, env `tracker-t1000-e`; DFU zips: vendored adafruit-nrfutil (`--dev-type 0x0052 --sd-req 0x0123`) |
| Build date | 2026-07-26 |
| On-device version caveat | the firmware's own version string embeds the **internal build-clone hash `7638cc2`** (a local safety branch, never pushed). It is NOT the source reference — the outer-repo commit above is. |

## What's in it (vs v3.0 — the previous tracked release)

- **Downlink**: GPS tag listens; portnum 260 ops MODE (calibration w/ TTL dead-man ↔ adaptive),
  SIGNAL (beep-first language), SIM (parametric / shake / track replay, flags bit4), TRACK
  (CRC-gated slot upload). Full contract: `docs/DOWNLINK.md`.
- **Adaptive TX** (boot default): fast tier at the configured spacing while moving, 1 pkt/3 s
  when quasi-stationary; knobs persisted + phone-tunable (settings wire v3).
- **Payload v4 (19 B)**: byte 18 = QMA6100P motion-energy envelope; flags bit1 = moving.
- **Base**: priority TX fast-lane + 15 ms API idle poll (command latency 445→335 ms measured;
  ~200 ms via BLE) + FastQ/FastTX latency stamps.
- **Review hardening (this release)**: adaptive below-clock resets in the hysteresis band;
  track slots re-CRC at every play (partial uploads refuse, verified); duplicate-tolerant
  upload chunks; **default TX spacing now 500 ms = EU868-legal sustained** (bench 150 ms is an
  app profile, not the default).

## Defaults note

Fresh flashes / first-run settings: 4 Hz GNSS fix, **500 ms TX spacing (2 Hz, EU-legal)**,
Fitness nav, freeze 0.3 m/s, SNR 14 dB, elev 10°, idle 3000 ms, fast 5 km/h, slow 3 km/h,
sustain 15 s. Devices with previously persisted settings KEEP them — re-apply from the app if
you want the new default spacing.

Flash: `tools/flash_t1000e.sh <flavor> [port|role]` (checksums enforced — mismatch aborts).
Verify: `shasum -a 256 -c SHA256SUMS`. Rollback: `firmware/known-good/restore.sh` (v3.0).
License: GPL-3.0 (root `LICENSE`); this repository is the complete corresponding source.
