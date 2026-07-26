"""Bridge sniffer-coexistence A/B — air-side leg (run from repo root, pipx python).

Measures what actually matters end-to-end: the rate at which the bridge's LoRa relay
delivers NOVEL Dronetag positions to the Base, with the ODID scanner competing against
BLE advertising / a connected BLE session. Usage:

    .../python -u tools/bench/bridge_ab.py <label> [seconds]

Prints packets/s, novel-positions/s (distinct ms-in-second+coords), and payload version mix.
Run once per condition (adv-on idle / BLE-connected / adv-off v4.3 firmware) and compare.
"""
import struct
import sys
import time

sys.path.insert(0, "tools")
import nodes
import meshtastic.serial_interface
from pubsub import pub

BRIDGE = 0xB4DBB54C

label = sys.argv[1] if len(sys.argv) > 1 else "run"
window = float(sys.argv[2]) if len(sys.argv) > 2 else 120.0

pkts = []          # (t, ms_in_sec, lat_i, lon_i, paylen)
def on_rx(packet, interface=None):
    d = packet.get("decoded") or {}
    pl = d.get("payload") or b""
    if d.get("portnum") in ("PRIVATE_APP", 256) and packet.get("from") == BRIDGE and len(pl) >= 12:
        lat, lon = struct.unpack_from("<ii", pl, 0)
        ms = struct.unpack_from("<H", pl, 8)[0]
        pkts.append((time.monotonic(), ms, lat, lon, len(pl)))

iface = meshtastic.serial_interface.SerialInterface(devPath=nodes.resolve("base"))
pub.subscribe(on_rx, "meshtastic.receive")
print(f"[{label}] measuring {window:.0f}s of bridge relay via the Base…")
t0 = time.monotonic()
while time.monotonic() - t0 < window:
    time.sleep(5)
    print(f"  t={time.monotonic()-t0:5.0f}s pkts={len(pkts)}")
iface.close()

span = pkts[-1][0] - pkts[0][0] if len(pkts) > 1 else 0
novel = sum(1 for i in range(1, len(pkts)) if pkts[i][1:4] != pkts[i - 1][1:4])
lens = sorted({p[4] for p in pkts})
print(f"[{label}] RESULT: {len(pkts)} pkts in {span:.1f}s = {len(pkts)/span if span else 0:.2f}/s | "
      f"novel {novel} = {novel/span if span else 0:.2f}/s | payload lens {lens}")
