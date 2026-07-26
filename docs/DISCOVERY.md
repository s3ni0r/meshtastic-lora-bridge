# BLE discovery contract — device typing for external apps (A2)

> **Audience:** external consumers that discover and connect to this fleet's devices over
> BLE — AutoShot first. Shipped in firmware ≥ the A2 round (post-v4.4 source, all three
> flavors); `docs/BATTERY_INTEGRATION.md` covers the position stream you'll hear after
> connecting, `docs/DOWNLINK.md` the command channel.

## What problem this solves

Identifying WHICH device you're looking at (Base vs GPS tag vs BLE5/LoRa bridge) used to
require name heuristics ("contains 'base'") — fragile the moment anyone renames a node.
Every fleet device now states its TYPE in its BLE advertisement, before any connection.

## The advertisement

Fleet devices advertise the standard Meshtastic BLE service in the PRIMARY advertising PDU
(unchanged — stock Meshtastic apps keep working):

```
Service UUID: 6ba1b218-15a8-461f-9fa8-5dcae273eafd   (scan filter — use this)
```

The SCAN RESPONSE additionally carries **manufacturer-specific data** (AD type 0xFF):

| Offset | Size | Value | Meaning |
|---|---|---|---|
| 0 | 2 | `0xFF 0xFF` | company id 0xFFFF (BT SIG "internal use"; disambiguated by the magic) |
| 2 | 2 | `'M' 'T'` (0x4D 0x54) | fleet magic |
| 4 | 1 | `0x01` | discovery contract version |
| 5 | 1 | device type | `1` = BLE5/LoRa bridge · `2` = GPS tag · `3` = **Base** (your connection target) |
| 6 | 4 | node id, u32 LE | the device's Meshtastic node number (e.g. `0xB0BB9CDA` → `!b0bb9cda`) |

Total: 10 bytes of manufacturer data. The device name (also in the scan response, after the
typed field) may be truncated — treat names as display-only; **type and identity come from
this field**. Active scanning is required to receive scan responses (CoreBluetooth's default).

## Consumer rules

1. **Scan filtered on the service UUID**, read `kCBAdvDataManufacturerData` (iOS) from the
   advertisement, and match `FF FF 4D 54` before parsing further. Reject other lengths /
   magics — 0xFFFF is shared by every prototype on earth.
2. **Ignore unknown versions** (byte 4 ≠ 1) rather than guessing; the version only bumps on
   breaking layout changes.
3. **Key device identity on the node id**, not the BLE peripheral UUID (iOS rotates those)
   and not the name (users rename devices — the fleet's factory defaults are
   `TAG-GPS-xxxx` / `TAG-BR-xxxx` / `BASE-xxxx`, but never rely on them).
4. A device WITHOUT the typed field may still be a fleet device on pre-A2 firmware — fall
   back to name heuristics only for those, and prefer upgrading the fleet.
5. Device types you don't recognize: list, don't connect.
6. After connecting (Meshtastic PhoneAPI over the service above), verify identity with
   `my_info.my_node_num == the advertised node id` before trusting the link — advertisement
   and GATT session are not atomically bound.

## Notes for the AutoShot flow

- **Connect target = type 3 (Base).** Tags (1, 2) are not connection targets during normal
  operation; they surface here so setup UIs can show the whole fleet with correct labels.
- The bridge (type 1) advertises SLOWLY (~1 s interval) — allow a few seconds of scanning
  before concluding it's absent. Base and GPS tag advertise at stock Meshtastic cadence.
- A deaf/session-mode tag (see `RADIO_STATES.md`) still advertises BLE — the typed
  advertisement is also the close-range recovery discovery path.

## Reference implementation

`ios/MeshTracker/MeshProto.swift` → `DiscoveryAd.parse` (12 lines); firmware side:
`firmware/meshtastic-fork.patch` → `NRF52Bluetooth.cpp::startAdv` (logs
`DISC adv: ver=1 type=<t> node=0x<id>` at boot — the bench-visible proof).
