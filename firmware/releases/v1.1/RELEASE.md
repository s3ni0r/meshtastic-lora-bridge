# T1000-E tracker firmware — v1.1

- **Date:** 2026-07-06
- **Source commit:** (release commit's parent — see git log; artifacts built from the working tree that became this commit)
- **Vendor base:** meshtastic/firmware `v2.7.15.567b8ea` + patch + drop-ins
- **New since v1.0:**
  - **BLE-configurable GNSS settings** (gps-tag): GnssConfigModule on portnum 260 — nav mode,
    static-freeze threshold, SNR mask, GNSS fix rate, LoRa TX spacing; persisted on the tag,
    applied live, driven from the MeshTracker iOS settings sheet. No more reflash-for-tuning.
  - Motion-tuning defaults: Fitness nav mode, 0.3 m/s static freeze, 14 dB SNR mask
    (field-test response: less jerky track, frozen-when-parked).
  - bridge-tag/base-plain: rebuilt from the same tree (no functional change vs v1.0).

Flash: `tools/flash_t1000e.sh <flavor> [port|role]` (defaults to the latest release).
Verify: `shasum -a 256 -c SHA256SUMS`.
