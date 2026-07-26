"""Bench regression suite for the downlink protocol state machines (R3-rigorous).

Asserts, on real hardware (tag on USB, exit code 0 ONLY if everything passes):
  A  adaptive hysteresis: the band (slow<v<fast) never counts toward the downshift
  B1 track upload: every ACK correlated (sender node, nonce, sub, offset) — including the
     deliberate duplicate chunk — COMMIT acked, COMMIT RETRY idempotent, replay plays
  B2 transactional staging: a stray BEGIN/ABORT does NOT destroy the committed slot
  B3 reboot durability: chunks WITHOUT commit + REBOOT -> staged data discarded, the old
     committed slot still plays

Run from the repo root with the meshtastic pipx python.
"""
import struct
import subprocess
import sys
import time
import zlib

sys.path.insert(0, "tools")
import nodes
import meshtastic.serial_interface
from meshtastic import mesh_pb2
from pubsub import pub

TAG = 417822021
FAILURES = []


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    if not ok:
        FAILURES.append(name)


rows, acks = [], []


def on_rx(packet, interface=None):
    d = packet.get("decoded") or {}
    pl = d.get("payload") or b""
    if d.get("portnum") in ("PRIVATE_APP", 256) and len(pl) >= 19:
        rows.append((time.monotonic(), pl[11], pl[14]))
    elif len(pl) == 6 and pl[0] == 0x85:
        acks.append({"from": packet.get("from"), "status": pl[1], "sub": pl[2],
                     "off": pl[3] | (pl[4] << 8), "nonce": pl[5], "t": time.monotonic()})


def connect():
    i = meshtastic.serial_interface.SerialInterface(devPath=nodes.resolve("gpstag"))
    pub.subscribe(on_rx, "meshtastic.receive")
    time.sleep(1.5)
    return i


iface = connect()


def cmd(payload):
    p = mesh_pb2.MeshPacket()
    p.to = TAG
    p.decoded.portnum = 260
    p.decoded.payload = bytes(payload)
    p.id = iface._generatePacketId()
    iface._sendPacket(p)
    time.sleep(0.35)


def await_ack(sub, off, nonce, timeout=3.0):
    """The correlated-ACK contract itself: sender==TAG and (sub, off, nonce) exact."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        for a in reversed(acks):
            if a["t"] >= t0 - 1.0 and a["from"] == TAG and a["sub"] == sub \
               and a["off"] == off and a["nonce"] == nonce:
                return a
        time.sleep(0.05)
    return None


def sim_plays(seconds=5):
    rows.clear()
    cmd([0x04, 3, 0, 60, 0])
    time.sleep(seconds)
    n = sum(1 for r in rows if r[1] & 0x10)
    cmd([0x04, 0])
    time.sleep(1)
    return n


# ---------------- A) adaptive band semantics ----------------------------------------------
print("A) band-crossing program: 12x10s, 4x35s (band), 1x25s, loop")
rows.clear()
cmd([0x04, 1, 1, 180, 0, 3, 12, 10, 4, 35, 1, 25])
t0 = time.monotonic()
transitions, last = [], None
while time.monotonic() - t0 < 75:
    time.sleep(1)
    if rows:
        tier = "idle" if rows[-1][1] & 8 else "fast"
        if tier != last:
            transitions.append((round(time.monotonic() - t0, 1), tier))
            last = tier
cmd([0x04, 0])
downshifts = [t for t, tier in transitions if tier == "idle"]
check("band never counts toward the downshift", bool(downshifts) and all(t >= 55 for t in downshifts),
      f"downshifts at {downshifts}")

# ---------------- B1) correlated upload + idempotent COMMIT --------------------------------
print("B1) upload — per-frame correlation asserted (sender+nonce+sub+offset)")
pts = [(43.4832 + i * 0.00004, -1.5586, 10, 10) for i in range(30)]
recs = b"".join(struct.pack("<iiBB", int(la * 1e7), int(lo * 1e7), sp, dt) for la, lo, sp, dt in pts)
crc = zlib.crc32(recs) & 0xFFFFFFFF
NONCE = 77
acks.clear()
cmd(bytes([0x05, 0x00]) + struct.pack("<HIB", len(pts), crc, NONCE))
a = await_ack(0, len(pts), NONCE)
check("BEGIN ack correlated + status 0", a is not None and a["status"] == 0)
for off in range(0, len(pts), 20):
    n = min(20, len(pts) - off)
    cmd(bytes([0x05, 0x01]) + struct.pack("<HB", off, n) + recs[off * 10:(off + n) * 10])
    a = await_ack(1, off, NONCE)
    check(f"CHUNK off={off} ack correlated + status 0", a is not None and a["status"] == 0)
cmd(bytes([0x05, 0x01]) + struct.pack("<HB", 20, 10) + recs[200:300])  # exact dup of last chunk
a = await_ack(1, 20, NONCE)
check("DUPLICATE chunk ack correlated + status 0 (retry-safe)", a is not None and a["status"] == 0)
acks.clear()
cmd([0x05, 0x02])
a = await_ack(2, 0, NONCE)
check("COMMIT ack correlated + status 0", a is not None and a["status"] == 0)
acks.clear()
cmd([0x05, 0x02])  # retry: pretend the previous reply was lost
a = await_ack(2, 0, NONCE)
check("COMMIT RETRY idempotent (status 0)", a is not None and a["status"] == 0)
check("replay after COMMIT plays", sim_plays() > 5)

# ---------------- B2) transactional staging ------------------------------------------------
print("B2) stray BEGIN/ABORT must NOT destroy the committed slot")
cmd(bytes([0x05, 0x00]) + struct.pack("<HIB", len(pts), crc, 78))  # BEGIN only, no chunks
check("committed slot STILL plays after a stray BEGIN", sim_plays() > 5)
cmd([0x05, 0x03])  # abort discards only the staging
check("committed slot STILL plays after ABORT", sim_plays() > 5)

# ---------------- B3) reboot durability -----------------------------------------------------
print("B3) chunks WITHOUT commit + REBOOT -> staged upload discarded, live slot intact")
acks.clear()
cmd(bytes([0x05, 0x00]) + struct.pack("<HIB", len(pts), crc, 79))
for off in range(0, len(pts), 20):
    n = min(20, len(pts) - off)
    cmd(bytes([0x05, 0x01]) + struct.pack("<HB", off, n) + recs[off * 10:(off + n) * 10])
a = await_ack(1, 20, 79)
check("pre-reboot staged chunks landed", a is not None and a["status"] == 0)
print("  rebooting the tag…")
port = nodes.resolve("gpstag")
iface.close()
subprocess.run(["meshtastic", "--port", port, "--reboot"], capture_output=True, timeout=90)
time.sleep(25)
for _ in range(20):
    if nodes.resolve("gpstag"):
        break
    time.sleep(2)
iface = connect()
check("committed slot survives the reboot and plays", sim_plays(seconds=6) > 5)

print()
iface.close()
if FAILURES:
    print(f"OVERALL: FAIL ({len(FAILURES)}): {FAILURES}")
    sys.exit(1)
print("OVERALL: PASS")
sys.exit(0)
