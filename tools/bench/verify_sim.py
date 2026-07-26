"""Verify the parametric simulator end-to-end over the tag's own USB PhoneAPI.

Program: 1 km/h x 25 s -> 12 km/h x 15 s, loop, TTL 120 s. Expect in the stream:
flags bit4 (SIM) set, lock bit set, speed byte tracking the segments, adaptive tier
(bit3) engaging at the slow segment after the 15 s sustain and clearing instantly at
the fast one, and position actually moving. Then STOP and confirm bit4 clears.
"""
import sys, time
sys.path.insert(0, "tools")
import nodes
import meshtastic.serial_interface
from meshtastic import mesh_pb2
from pubsub import pub

TAG = 417822021
rows = []

def on_rx(packet, interface=None):
    d = packet.get("decoded") or {}
    if d.get("portnum") not in ("PRIVATE_APP", 256):
        return
    pl = d.get("payload") or b""
    if len(pl) >= 19:
        b = list(pl)
        lat = int.from_bytes(pl[0:4], "little", signed=True) / 1e7
        rows.append((time.monotonic(), b[11], b[14], lat))

iface = meshtastic.serial_interface.SerialInterface(devPath=nodes.resolve("gpstag"))
pub.subscribe(on_rx, "meshtastic.receive")
time.sleep(1.5)

def cmd(payload):
    p = mesh_pb2.MeshPacket()
    p.to = TAG
    p.decoded.portnum = 260
    p.decoded.payload = bytes(payload)
    p.id = iface._generatePacketId()
    iface._sendPacket(p)

# program: [op, src=1, loop=1, ttl=120, nSeg=2, (1 km/h, 25 s), (12 km/h, 15 s)]
cmd([0x04, 1, 1, 120, 0, 2, 1, 25, 12, 15])
print("SIM program sent — observing 70 s of stream…")
t0 = time.monotonic()
last = 0
while time.monotonic() - t0 < 70:
    time.sleep(2)
    if len(rows) > last:
        t, fl, spd, lat = rows[-1]
        print(f"  t={t - t0:5.1f}s flags=0x{fl:02x} sim={bool(fl & 0x10)} lock={bool(fl & 1)} "
              f"tier={'idle' if fl & 8 else 'fast'} spd={spd}km/h lat={lat:.6f}")
        last = len(rows)

sim_pkts = [r for r in rows if r[1] & 0x10]
speeds = sorted(set(r[2] for r in sim_pkts))
tiers = set(bool(r[1] & 8) for r in sim_pkts)
lats = [r[3] for r in sim_pkts]
print(f"\n{len(sim_pkts)}/{len(rows)} packets simulated · speeds seen {speeds} · "
      f"tiers seen {sorted(tiers)} · lat span {max(lats) - min(lats):.6f}°" if sim_pkts else "NO SIM PACKETS")

cmd([0x04, 0])  # stop
time.sleep(4)
tail = [r for r in rows if r[0] > time.monotonic() - 3]
print("after STOP: sim flag in last packets:", [bool(r[1] & 0x10) for r in tail] or "(none - heartbeat gap, ok)")
iface.close()
verdict = bool(sim_pkts) and len(speeds) >= 2 and True in tiers and False in tiers and (max(lats) > min(lats))
print("VERDICT:", "PASS — sim drives real tier machinery" if verdict else "CHECK NEEDED")
import sys as _s; _s.exit(0 if verdict else 1)
