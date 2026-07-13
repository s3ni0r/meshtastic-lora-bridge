# T1000-E tracker firmware — v3.0 (MAJOR: payload v3 — live battery)

- **Date:** 2026-07-13
- **Vendor base:** meshtastic/firmware `v2.7.15.567b8ea` + patch + drop-ins
- **What makes this major:** the stream wire format changes — payload grows 17 → **18 bytes**:

| Change | Detail |
|---|---|
| Byte 17 = battery | The sending tag's own cell, in **every** stream packet: 0-100 %, **101 = USB-powered** (same magic as stock telemetry), 255 = unknown. Both tag flavors (the bridge reports the bridge's cell — Remote ID carries no Dronetag battery). |
| flags bit1 | Reserved for `moving` (QMA6100P gate, TODO.md) — no future wire change needed. |
| Base battery path | `DeviceTelemetry` pushes DeviceMetrics to the phone every **15 s** (stock: 60 s). BLE-only, zero LoRa cost — the Base never streams positions, so this is its battery channel. |
| Airtime | ShortFast 45 → **48 ms** (41 B on-air crosses a symbol-group boundary). EU868 @ 2 Hz = **9.5 % duty — still legal**, no headroom below 500 ms spacing. CAPACITY.md recomputed. |

Receivers key on payload length (12 / 17 / **18**), so old apps still track v3 tags (they
just don't show battery) and the v2.2+ app shows battery from v3 tags per packet, with
portnum-67 telemetry as the fallback for un-reflashed tags.

Everything from v2.0 carries over unchanged: field-approved GNSS defaults (Fitness, freeze
0.3 m/s, SNR 14 dB, elev 10°, 4 Hz fix, 150 ms TX spacing), live BLE tuning (port 260),
GST-backed accuracy, direct-to-tag mode.

Flash: `tools/flash_t1000e.sh <flavor> [port|role]` (v3.0 is now the default release).
Verify: `shasum -a 256 -c SHA256SUMS`.
