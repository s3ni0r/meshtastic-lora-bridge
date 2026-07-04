# T1000-E tracker firmware — v1.0

- **Date:** 2026-07-04
- **Source commit:** f8ab9c8 (branch `gps-lora-tag`)
- **Vendor base:** meshtastic/firmware `v2.7.15.567b8ea` + `firmware/meshtastic-fork.patch` + drop-ins
- **Files:** `<flavor>.uf2` (UF2 bootloader drag-flash) and `<flavor>-dfu.zip` (adafruit-nrfutil serial DFU)

| Flavor | Role on the mesh | Build flags |
|---|---|---|
| `gps-tag` | Self-contained tag: onboard AG3335 @ 4 Hz (boot-time unlock + France/EGNOS preset), LoRa TX-only, BLE kept | `-DGPS_TAG` |
| `bridge-tag` | BLE5/LoRa bridge: relays Dronetag Remote ID (BT5 Coded scan), GPS unpowered, LoRa TX-only, no BLE advertising | `-DODID_SNIFFER -DODID_PHY_EXT -DHIGHRATE_POSITION_SENDER -DHIGHRATE_POSITION_INTERVAL_MS=250 -DHIGHRATE_TX_ONLY` |
| `base-plain` | Receiver: forwards the PRIVATE_APP(256) stream to the iOS app over BLE | *(none)* |

Flash with `tools/flash_t1000e.sh <flavor> [port|role]` — see `firmware/FORK.md` §4–§6 for
builds/config. Post-flash node config (channel URL, region, role) is per-deployment; the flash
script prints the per-flavor cheat-sheet. Verify integrity: `shasum -a 256 -c SHA256SUMS`.

Verified on-device before release: gps-tag steers the GNSS to 3.97–4.07 fix/s with EGNOS active
($PAIR411,1 / $PAIR401,2), streams src=2; bridge-tag + base validated earlier on this branch
(docs/results.md).
