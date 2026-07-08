# T1000-E tracker firmware — v2.0 (MAJOR: field-approved)

- **Date:** 2026-07-07
- **Vendor base:** meshtastic/firmware `v2.7.15.567b8ea` + patch + drop-ins
- **What makes this major:** the complete tracking stack was validated outdoors and the approved
  GNSS profile ships as the DEFAULT — a fresh flash needs zero tuning:

| Default | Value |
|---|---|
| Navigation mode | 1 Fitness (the mode that actually ran during approval — this unit rejects Swimming/mode 7 with ACK 4) |
| Static freeze | 0.3 m/s ($PAIR070,3) |
| Min satellite SNR | 14 dB ($PAIR058,14) |
| Elevation mask | 10° ($PAIR072,10) |
| GNSS fix rate | 4 Hz ($PAIR050,250, probe-steered per boot) |
| LoRa TX spacing | 150 ms (~6.7 Hz cap; bench/US — use the app's France profile, 500 ms = 2 Hz, for EU868 sustained) |

Everything remains live-tunable from the MeshTracker app over BLE (GnssConfigModule, port 260);
accuracy is GST-backed; direct-to-tag mode works with no Base alive.

Flash: `tools/flash_t1000e.sh <flavor> [port|role]`. Verify: `shasum -a 256 -c SHA256SUMS`.
