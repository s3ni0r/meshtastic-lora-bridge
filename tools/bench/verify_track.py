"""Verify track upload + replay end-to-end over the tag's USB PhoneAPI.

Uploads a 60-point square course (~15 km/h, 1 s/point) via op 0x05 BEGIN/CHUNK/COMMIT,
starts replay (SIM src=3, loop), and checks the stream walks the square with SIM-flagged
packets at the uploaded speeds. Then stops.
"""
import struct, sys, time, zlib
sys.path.insert(0, "tools")
import nodes
import meshtastic.serial_interface
from meshtastic import mesh_pb2
from pubsub import pub

TAG = 417822021
BASE_LAT, BASE_LON = 43.4832, -1.5586

# Build a square: 4 legs x 15 points, ~4.2 m/point (15 km/h at 1 s)
pts = []
lat, lon = BASE_LAT, BASE_LON
step = 4.2 / 111320.0
for leg, (dla, dlo) in enumerate([(step, 0), (0, step), (-step, 0), (0, -step)]):
    for _ in range(15):
        lat += dla
        lon += dlo
        pts.append((lat, lon, 15, 10))  # 15 km/h, dt=1.0 s

recs = b"".join(struct.pack("<iiBB", int(la * 1e7), int(lo * 1e7), sp, dt) for la, lo, sp, dt in pts)
crc = zlib.crc32(recs) & 0xFFFFFFFF
print(f"track: {len(pts)} records, {len(recs)} B, crc 0x{crc:08x}")

rows = []
def on_rx(packet, interface=None):
    d = packet.get("decoded") or {}
    if d.get("portnum") in ("PRIVATE_APP", 256):
        pl = d.get("payload") or b""
        if len(pl) >= 19:
            b = list(pl)
            rows.append((time.monotonic(), b[11], b[14],
                         int.from_bytes(pl[0:4], "little", signed=True) / 1e7,
                         int.from_bytes(pl[4:8], "little", signed=True) / 1e7))

replies = []
def on_reply(packet, interface=None):
    d = packet.get("decoded") or {}
    pl = d.get("payload") or b""
    if len(pl) >= 2 and pl[0] & 0x80:
        replies.append((pl[0], pl[1]))

iface = meshtastic.serial_interface.SerialInterface(devPath=nodes.resolve("gpstag"))
pub.subscribe(on_rx, "meshtastic.receive")
pub.subscribe(on_reply, "meshtastic.receive")
time.sleep(1.5)

def cmd(payload):
    p = mesh_pb2.MeshPacket()
    p.to = TAG
    p.decoded.portnum = 260
    p.decoded.payload = bytes(payload)
    p.id = iface._generatePacketId()
    iface._sendPacket(p)
    time.sleep(0.25)

# BEGIN
cmd(bytes([0x05, 0x00]) + struct.pack("<HI", len(pts), crc))
# CHUNKS of 20 records
n_per = 20
for off in range(0, len(pts), n_per):
    n = min(n_per, len(pts) - off)
    chunk = recs[off * 10:(off + n) * 10]
    cmd(bytes([0x05, 0x01]) + struct.pack("<HB", off, n) + chunk)
    print(f"  chunk off={off} n={n}")
# COMMIT
cmd([0x05, 0x02])
time.sleep(1.0)
stat = [r for r in replies if r[0] == 0x85]
print("upload replies (op 0x85):", stat[-6:] if stat else "none seen")

# REPLAY, loop, ttl 90
rows.clear()
cmd([0x04, 3, 1, 90, 0])
print("replay started — observing 25 s…")
t0 = time.monotonic()
while time.monotonic() - t0 < 25:
    time.sleep(2.5)
    if rows:
        t, fl, spd, la, lo = rows[-1]
        print(f"  t={t - t0:5.1f}s flags=0x{fl:02x} sim={bool(fl & 0x10)} spd={spd} lat={la:.6f} lon={lo:.6f}")

sim = [r for r in rows if r[1] & 0x10]
lats = [r[3] for r in sim]; lons = [r[4] for r in sim]
speeds = set(r[2] for r in sim)
cmd([0x04, 0])
iface.close()
ok = (len(sim) > 20 and 15 in speeds
      and max(lats) - min(lats) > 0.0003 and max(lons) - min(lons) > 0.0003)
print(f"\n{len(sim)} sim packets · speeds {sorted(speeds)} · lat span {max(lats)-min(lats):.6f} · "
      f"lon span {max(lons)-min(lons):.6f}" if sim else "NO SIM PACKETS")
print("VERDICT:", "PASS — uploaded track replays on the tag" if ok else "CHECK NEEDED")
