"""Bench regression suite for the downlink protocol state machines (R4-rigorous).

Asserts, on real hardware (tag on USB, exit code 0 ONLY if everything passes):
  A  adaptive hysteresis: the band (slow<v<fast) never counts toward the downshift
  B1 track upload (tid u32 in every frame): every ACK correlated (sender node, tid, sub,
     offset) AND consumed-once (an ACK emitted before the request was sent can never credit
     it — R4 finding 8a); wrong-tid COMMIT NAKs; COMMIT acked; COMMIT RETRY idempotent
  B2 transactional A/B slots: a stray BEGIN/ABORT does NOT destroy the committed slot, and
     BEGIN during track playback is refused (splice guard)
  B3 failed-commit retry: a transfer whose declared CRC does not match its data must NAK at
     COMMIT and KEEP NAKing on retry — the surviving older track must never credit it
     (R4 finding 1) — and the committed slot must still play
  B4 reboot durability with PROOF OF GENERATION (R4 finding 8c): the staged-but-uncommitted
     upload carries geographically DISTINCT data; after a VERIFIED reboot (port must drop and
     return — R4 finding 8b) the coordinates that actually play must match the committed
     track, not the staged one.

Run from the repo root with the meshtastic pipx python.
"""
import re
import struct
import subprocess
import sys
import time
import zlib

import serial as pyserial

sys.path.insert(0, "tools")
import nodes
import meshtastic.serial_interface
from meshtastic import mesh_pb2
from pubsub import pub

TAG = 417822021
COMMIT_LON = -1.5586   # committed course longitude
STAGED_LON = -1.5486   # deliberately distinct staged course (~800 m east)
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
        lat = struct.unpack_from("<i", pl, 0)[0] / 1e7
        lon = struct.unpack_from("<i", pl, 4)[0] / 1e7
        rows.append((time.monotonic(), pl[11], pl[14], lat, lon))
    elif len(pl) == 9 and pl[0] == 0x85:
        acks.append({"from": packet.get("from"), "status": pl[1], "sub": pl[2],
                     "off": pl[3] | (pl[4] << 8),
                     "tid": struct.unpack_from("<I", pl, 5)[0]})


def connect():
    i = meshtastic.serial_interface.SerialInterface(devPath=nodes.resolve("gpstag"))
    pub.subscribe(on_rx, "meshtastic.receive")
    time.sleep(1.5)
    return i


iface = connect()


def cmd(payload):
    """Send one op-260 frame; returns the ack-list index BEFORE the send, so callers can
    require an ACK that arrived strictly AFTER this request (consumed-once semantics)."""
    mark = len(acks)
    p = mesh_pb2.MeshPacket()
    p.to = TAG
    p.decoded.portnum = 260
    p.decoded.payload = bytes(payload)
    p.id = iface._generatePacketId()
    iface._sendPacket(p)
    time.sleep(0.35)
    return mark


def await_ack(mark, sub, off, tid, timeout=3.0):
    """The correlated-ACK contract: sender==TAG, (sub, off, tid) exact, AND the ACK must have
    been appended after `mark` — an ACK from any earlier frame can never be reused."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        for a in acks[mark:]:
            if a["from"] == TAG and a["sub"] == sub and a["off"] == off and a["tid"] == tid:
                return a
        time.sleep(0.05)
    return None


def tf(sub, tid, rest=b""):
    return bytes([0x05, sub]) + struct.pack("<I", tid) + rest


def sim_plays(seconds=5):
    """Run TRACK replay briefly; returns (n_simulated_packets, [lon...])."""
    rows.clear()
    cmd([0x04, 3, 0, 60, 0])
    time.sleep(seconds)
    got = [(r[3], r[4]) for r in rows if r[1] & 0x10]
    cmd([0x04, 0])
    time.sleep(1)
    return len(got), [lo for _, lo in got]


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

# ---------------- B1) correlated upload, tid discipline, idempotent COMMIT -----------------
print("B1) upload — per-frame consumed-once correlation (sender+tid+sub+offset)")
pts = [(43.4832 + i * 0.00004, COMMIT_LON, 10, 10) for i in range(30)]
TID = 0xC0FFEE01
acks.clear()
recs = b"".join(struct.pack("<iiBB", int(la * 1e7), int(lo * 1e7), sp, dt) for la, lo, sp, dt in pts)
crc = zlib.crc32(recs) & 0xFFFFFFFF
m = cmd(tf(0x00, TID, struct.pack("<HI", len(pts), crc)))
a = await_ack(m, 0, len(pts), TID)
check("BEGIN ack correlated + status 0", a is not None and a["status"] == 0)
for off in range(0, len(pts), 20):
    n = min(20, len(pts) - off)
    m = cmd(tf(0x01, TID, struct.pack("<HB", off, n) + recs[off * 10:(off + n) * 10]))
    a = await_ack(m, 1, off, TID)
    check(f"CHUNK off={off} ack correlated + status 0", a is not None and a["status"] == 0)
m = cmd(tf(0x01, TID, struct.pack("<HB", 20, 10) + recs[200:300]))  # exact dup of last chunk
a = await_ack(m, 1, 20, TID)
check("DUPLICATE chunk acked AFTER its own send (not a reused ACK)", a is not None and a["status"] == 0)
m = cmd(tf(0x02, TID + 1))  # a COMMIT for some OTHER transfer must not touch this staging
a = await_ack(m, 2, 0, TID + 1)
check("COMMIT with WRONG tid NAKed", a is not None and a["status"] == 1)
m = cmd(tf(0x02, TID))
a = await_ack(m, 2, 0, TID)
check("COMMIT ack correlated + status 0", a is not None and a["status"] == 0)
m = cmd(tf(0x02, TID))  # retry: pretend the previous reply was lost
a = await_ack(m, 2, 0, TID)
check("COMMIT RETRY (same tid) idempotent status 0", a is not None and a["status"] == 0)
n, lons = sim_plays()
check("replay after COMMIT plays the committed course", n > 5 and lons and
      all(abs(lo - COMMIT_LON) < 0.002 for lo in lons), f"n={n}")

# ---------------- B2) A/B slots: stray ops + splice guard -----------------------------------
print("B2) stray BEGIN/ABORT must NOT destroy the committed slot; BEGIN-while-playing refused")
cmd(tf(0x00, 0x51AB0001, struct.pack("<HI", len(pts), crc)))  # stray BEGIN, no chunks
n, _ = sim_plays()
check("committed slot STILL plays after a stray BEGIN", n > 5)
m = cmd(tf(0x03, 0x51AB0001))
a = await_ack(m, 3, 0, 0x51AB0001)
check("ABORT of the stray staging acked", a is not None and a["status"] == 0)
n, _ = sim_plays()
check("committed slot STILL plays after ABORT", n > 5)
rows.clear()
cmd([0x04, 3, 0, 60, 0])  # start playback, then try to BEGIN into the pinned slot pair
time.sleep(2)
m = cmd(tf(0x00, 0x51AB0002, struct.pack("<HI", len(pts), crc)))
a = await_ack(m, 0, len(pts), 0x51AB0002)
check("BEGIN during track playback NAKed (splice guard)", a is not None and a["status"] == 1)
cmd([0x04, 0])
time.sleep(1)

# ---------------- B3) failed COMMIT retry must keep NAKing (R4 finding 1) -------------------
print("B3) transfer with a WRONG declared CRC: COMMIT NAKs, retry NAKs, old track intact")
BADTID = 0xBADC0DE1
bad_crc = (crc ^ 0xDEADBEEF) & 0xFFFFFFFF  # declared CRC will not match the data
m = cmd(tf(0x00, BADTID, struct.pack("<HI", len(pts), bad_crc)))
a = await_ack(m, 0, len(pts), BADTID)
check("bad-CRC BEGIN accepted (failure must surface at COMMIT)", a is not None and a["status"] == 0)
for off in range(0, len(pts), 20):
    nrec = min(20, len(pts) - off)
    cmd(tf(0x01, BADTID, struct.pack("<HB", off, nrec) + recs[off * 10:(off + nrec) * 10]))
m = cmd(tf(0x02, BADTID))
a = await_ack(m, 2, 0, BADTID)
check("COMMIT of mismatching data NAKed", a is not None and a["status"] == 1)
m = cmd(tf(0x02, BADTID))  # the client's NAK-retry — this is the exact R4 f1 scenario
a = await_ack(m, 2, 0, BADTID)
check("COMMIT RETRY after failure STILL NAKed (old track can never credit it)",
      a is not None and a["status"] == 1)
n, lons = sim_plays()
check("committed slot unharmed by the failed transfer", n > 5 and lons and
      all(abs(lo - COMMIT_LON) < 0.002 for lo in lons))

# ---------------- B4) verified reboot + proof of generation ---------------------------------
print("B4) DISTINCT staged data w/o commit + VERIFIED reboot -> the COMMITTED course plays")
staged_pts = [(43.4832 + i * 0.00004, STAGED_LON, 10, 10) for i in range(30)]
staged_recs = b"".join(struct.pack("<iiBB", int(la * 1e7), int(lo * 1e7), sp, dt) for la, lo, sp, dt in staged_pts)
staged_crc = zlib.crc32(staged_recs) & 0xFFFFFFFF
STID = 0x5EED0001
m = cmd(tf(0x00, STID, struct.pack("<HI", len(staged_pts), staged_crc)))
for off in range(0, len(staged_pts), 20):
    nrec = min(20, len(staged_pts) - off)
    m = cmd(tf(0x01, STID, struct.pack("<HB", off, nrec) + staged_recs[off * 10:(off + nrec) * 10]))
a = await_ack(m, 1, 20, STID)
check("pre-reboot staged chunks landed", a is not None and a["status"] == 0)
print("  rebooting the tag…")
port = nodes.resolve("gpstag")
iface.close()
rb = subprocess.run(["meshtastic", "--port", port, "--reboot"], capture_output=True, timeout=90)
check("reboot command accepted (exit 0)", rb.returncode == 0, f"rc={rb.returncode}")
time.sleep(25)
back = None
for _ in range(25):
    back = nodes.resolve("gpstag")
    if back:
        break
    time.sleep(2)
check("tag re-enumerated after reboot", back is not None)
# PROOF the reboot happened (R4 finding 8b): the /dev path can persist across re-enumeration
# on macOS, so "port disappeared" proves nothing. Meshtastic log lines carry seconds-since-boot
# ("| ??:??:?? <secs> ["); after a real reboot that counter restarts near zero, while a device
# that silently ignored the command would still show its long pre-reboot uptime.
uptime = None
if back:
    try:
        raw = pyserial.Serial(back, 115200, timeout=1)
        buf = b""
        t0 = time.monotonic()
        while time.monotonic() - t0 < 8 and len(buf) < 8000:
            buf += raw.read(512)
        raw.close()
        secs = [int(m) for m in re.findall(rb"\?\?:\?\?:\?\? (\d+) ", buf)]
        uptime = max(secs) if secs else None
    except Exception as e:
        print(f"  (uptime read failed: {e!r})")
check("device uptime restarted (reboot really happened)", uptime is not None and uptime < 90,
      f"uptime≈{uptime}s")
iface = connect()
n, lons = sim_plays(seconds=6)
check("committed slot survives the reboot and plays", n > 5)
check("...and it is the COMMITTED course, not the staged one (generation proof)",
      bool(lons) and all(abs(lo - COMMIT_LON) < 0.002 for lo in lons) and
      all(abs(lo - STAGED_LON) > 0.005 for lo in lons),
      f"lons≈{lons[:3]}")

print()
iface.close()
if FAILURES:
    print(f"OVERALL: FAIL ({len(FAILURES)}): {FAILURES}")
    sys.exit(1)
print("OVERALL: PASS")
sys.exit(0)
