# Payload + battery integration spec — T1000-E tracker fleet (handoff for external apps)

Self-contained reference for consuming this tracker system's **uplink stream** (position,
battery, motion) from an external app. No other context needed. The **downlink command
channel** (mode switching, operator signals, simulator — portnum 260 ops) is specified
separately in `DOWNLINK.md`; an app that wants to command the tag reads both. Ground truth in
this repo: `firmware/src/modules/HighRatePositionModule.cpp` (sender),
`ios/MeshTracker/MeshProto.swift` (reference decoder),
`tools/m2_stream_poc.py` (Python reference decoder).

## The fleet (Meshtastic fork, base v2.7.15)

| Role | What it does | How its battery reaches you |
|---|---|---|
| **GPS tag** | Streams its onboard GNSS fixes over LoRa | **Inside every stream packet** (Path A) |
| **BLE5-sniffer / bridge tag** | Sniffs Dronetag Remote ID, re-streams over LoRa | **Inside every stream packet** (Path A) — reports **its own cell**, NOT the drone's (Remote ID broadcasts carry no battery) |
| **Base** | LoRa→BLE relay to a phone; never streams positions | **Device telemetry** every 15 s over its BLE link (Path B) |

Both paths arrive as standard Meshtastic **`FromRadio`** protobuf frames (BLE PhoneAPI or USB
serial API — same bytes).

## Transport (if the app connects itself)

Meshtastic BLE GATT:
- Service `6ba1b218-15a8-461f-9fa8-5dcae273eafd`
- `ToRadio` write: `f75c76d2-129e-4dad-a1dd-7866124401e7`
- `FromRadio` read: `2c55e69e-4993-11ed-b878-0242ac120002`
- `FromNum` notify: `ed9da18c-a800-4f66-a670-aa7547e34453`

Start the flow by writing `ToRadio{ want_config_id = <random u32> }` (protobuf field 3, varint).
On every `FromNum` notification, read `FromRadio` repeatedly until an empty read (queue drained).

> ⚠️ **One PhoneAPI client per node.** A Meshtastic node accepts ONE app connection; if
> MeshTracker (or the official app) is already connected to the Base over BLE, a second app
> cannot connect to that same node (and a BLE client also locks out its USB serial API). Plan
> for either exclusive access or getting the data relayed from the app that owns the link.

## Path A — battery inside the position stream (tags, real-time)

Stream packets are `MeshPacket`s on **portnum 256 (`PRIVATE_APP`)**, broadcast over LoRa (the
Base relays them to its phone) and also cc'd to the phone queue when connected directly to a
tag's own BLE.

Protobuf unwrap (field numbers → wire types):

```
FromRadio.packet            field 2, length-delimited   → MeshPacket
  MeshPacket.from           field 1, fixed32            → sender node id (key battery by this)
  MeshPacket.decoded        field 4, length-delimited   → Data
    Data.portnum            field 1, varint             → must be 256
    Data.payload            field 2, length-delimited   → the bytes below
```

Payload (little-endian; **version = length**: 12 = position only, 17 = +telemetry,
18 = +battery (v3, firmware release v3.0), **19 = +motion (v4, tag-downlink branch,
2026-07-26)**):

| Offset | Type | Meaning |
|---|---|---|
| 0 | int32 | latitude · 1e7 (0,0 with lon = heartbeat, no fix) |
| 4 | int32 | longitude · 1e7 |
| 8 | uint16 | ms-in-second of the fix |
| 10 | uint8 | sequence number |
| 11 | uint8 | flags: **bit0 = GPS lock**, **bit1 = `moving`** (v4 accel classifier), bits 2–3 = TX-mode echo (bit2 adaptive, bit3 slow tier), **bit4 = SIMULATED fix** (on-tag test simulator — never treat as a real track), **bits 5–7 = source** (0 legacy, 1 bridge, 2 GPS tag) |
| 12 | int16 | altitude, m |
| 14 | uint8 | speed, km/h |
| 15 | uint8 | heading · 256/360 |
| 16 | uint8 | horizontal accuracy, m (GST 1-σ; 0 = unknown) |
| **17** | **uint8** | **battery: 0–100 = %, 101 = externally powered (USB), 255 = unknown** |
| 18 | uint8 | motion energy (v4): high-passed \|accel\| envelope, **mg/4** (multiply by 4), 0–254; 255 = no accel sample |

Decode rule:

```python
if len(payload) >= 18 and payload[17] != 255:
    battery[from_id] = payload[17]      # 101 means "on USB power"
```

Properties worth relying on:
- Arrives at the tag's TX rate (2–6.7 Hz moving, 0.5 Hz heartbeat when fixless) — heartbeats
  **do** carry the battery byte, so parked/indoor tags still report.
- Old 17-byte firmware simply lacks the byte — fall back to Path B for those nodes.
- The value is the **sender's own cell** (T1000-E, 700 mAh).

## Path B — standard device telemetry (Base + fallback for any node)

Stock Meshtastic `DeviceMetrics` on **portnum 67 (`TELEMETRY_APP`)**. Same `FromRadio →
MeshPacket → Data` unwrap as above, then:

```
Data.payload = Telemetry
  Telemetry.device_metrics      field 2, length-delimited   (other variants: ignore)
    DeviceMetrics.battery_level field 1, varint    0–100; 101 = externally powered
    DeviceMetrics.voltage       field 2, fixed32   IEEE-754 float, volts
```

Cadence:
- **The node you're BLE-connected to** pushes its own every **15 s** (fork tweak; stock
  Meshtastic is 60 s). If `MeshPacket.from == 0`, attribute it to the connected node (get its
  id from `FromRadio.my_info.my_node_num` — my_info is FromRadio field 3, my_node_num field 1).
- **Remote nodes over LoRa**: every ~30 min (Meshtastic default broadcast interval), relayed by
  the Base like any mesh packet.

## Presentation conventions used by MeshTracker (adopt for consistency)

- `101` → plug/bolt icon + "USB", green.
- `≤ 10 %` red, `≤ 20 %` amber, otherwise neutral.
- Voltage only exists on Path B; show it as secondary detail where available.
- Path A wins when both exist for a node (it's fresher); keep the reading's age visible if it
  can exceed ~1 min (Path-B-via-LoRa can be 30 min old).

## Gotchas

1. Battery **255 / missing byte ≠ 0%** — treat as unknown, never render as empty.
2. The first seconds after a tag boots may send 255 (power status not sampled yet).
3. `battery_level` can read `101` on USB even with a full cell — it's a "powered" flag, not a
   percentage above 100.
4. Node ids (`MeshPacket.from`) are stable per device — current fleet: Base `!b0bb9cda`,
   bridge tag `!b4dbb54c`, GPS tag `!18e77545`.
5. All multi-byte payload fields little-endian; protobuf varints/fixed32 per protobuf spec.
