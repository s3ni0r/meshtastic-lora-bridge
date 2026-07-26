"""Re-verify the review fixes on-device.

A) Adaptive band semantics: program [12 km/h x 10 s][4 km/h x 35 s][1 km/h x 25 s] loop.
   4 km/h sits INSIDE the hysteresis band (slow=3, fast=5). Expected: fast tier through the
   ENTIRE 35 s band segment (pre-fix, the below-clock would have run there); downshift only
   ~15 s into the true 1 km/h segment.
B) Track integrity: upload a small track, COMMIT, replay OK; then corrupt-path check — BEGIN
   without finishing, then try to play: must be REFUSED (status 1, no sim packets).
"""
import struct, sys, time, zlib
sys.path.insert(0, "tools")
import nodes
import meshtastic.serial_interface
from meshtastic import mesh_pb2
from pubsub import pub

TAG = 417822021
rows, replies = [], []

def on_rx(packet, interface=None):
    d = packet.get("decoded") or {}
    pl = d.get("payload") or b""
    if d.get("portnum") in ("PRIVATE_APP", 256) and len(pl) >= 19:
        rows.append((time.monotonic(), pl[11], pl[14]))
    elif len(pl) >= 2 and pl[0] & 0x80:
        replies.append((pl[0], pl[1]))

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
    time.sleep(0.3)

print("A) band-crossing program: 12x10s, 4x35s (band), 1x25s, loop")
rows.clear()
cmd([0x04, 1, 1, 180, 0, 3, 12, 10, 4, 35, 1, 25])
t0 = time.monotonic()
transitions = []
last_tier = None
while time.monotonic() - t0 < 75:
    time.sleep(1)
    if rows:
        fl = rows[-1][1]
        tier = "idle" if fl & 8 else "fast"
        if tier != last_tier:
            transitions.append((round(time.monotonic() - t0, 1), tier, rows[-1][2]))
            print(f"  t={transitions[-1][0]:5.1f}s tier -> {tier} (spd={rows[-1][2]})")
            last_tier = tier
cmd([0x04, 0])
# Expected: fast until ~60 s (10+35+15 into the 1 km/h segment); NO downshift during the band.
downshifts = [t for t, tier, _ in transitions if tier == "idle"]
band_ok = all(t >= 55 for t in downshifts) and len(downshifts) >= 1
print(f"  downshift(s) at {downshifts} — band did{'' if band_ok else ' NOT'} stay fast: {'PASS' if band_ok else 'FAIL'}")

print("B1) good upload + replay")
pts = [(43.4832 + i * 0.00004, -1.5586, 10, 10) for i in range(30)]
recs = b"".join(struct.pack("<iiBB", int(la * 1e7), int(lo * 1e7), sp, dt) for la, lo, sp, dt in pts)
crc = zlib.crc32(recs) & 0xFFFFFFFF
replies.clear()
cmd(bytes([0x05, 0x00]) + struct.pack("<HI", len(pts), crc))
for off in range(0, len(pts), 20):
    n = min(20, len(pts) - off)
    cmd(bytes([0x05, 0x01]) + struct.pack("<HB", off, n) + recs[off * 10:(off + n) * 10])
# duplicate re-send of the last chunk (retry-safety):
cmd(bytes([0x05, 0x01]) + struct.pack("<HB", 20, 10) + recs[200:300])
cmd([0x05, 0x02])
time.sleep(0.5)
ok85 = [s for (o, s) in replies if o == 0x85]
print(f"  upload replies: {ok85} (dup chunk must also be status 0)")
rows.clear()
cmd([0x04, 3, 0, 60, 0])
time.sleep(6)
good_replay = sum(1 for r in rows if r[1] & 0x10) > 5
print(f"  replay after COMMIT: {'PASS' if good_replay else 'FAIL'} ({len(rows)} pkts)")
cmd([0x04, 0])

print("B2) PARTIAL upload must refuse to play")
replies.clear()
cmd(bytes([0x05, 0x00]) + struct.pack("<HI", len(pts), crc))  # BEGIN only — no chunks, no commit
rows.clear()
cmd([0x04, 3, 0, 60, 0])  # try to play
time.sleep(4)
sim_after_partial = sum(1 for r in rows if r[1] & 0x10)
start_reply = [s for (o, s) in replies if o == 0x84]
print(f"  play attempt on partial slot: sim packets={sim_after_partial}, SIM reply status={start_reply}")
partial_ok = sim_after_partial == 0 and (1 in start_reply)
print(f"  refused: {'PASS' if partial_ok else 'FAIL'}")
cmd([0x05, 0x03])  # abort cleanup
cmd([0x04, 0])
iface.close()
print("\nOVERALL:", "PASS" if (band_ok and good_replay and partial_ok) else "CHECK NEEDED")
