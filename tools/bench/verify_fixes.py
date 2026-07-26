"""Bench regression suite for the downlink protocol state machines (R4-rigorous).

Asserts, on real hardware (tag on USB, exit code 0 ONLY if everything passes):
  A  adaptive hysteresis: the band (slow<v<fast) never counts toward the downshift
  B1 track upload (tid u32 in every frame): every ACK correlated (sender node, tid, sub,
     offset) AND consumed-once (an ACK emitted before the request was sent can never credit
     it — R4 finding 8a); wrong-tid CHUNK/COMMIT NAK; changed-byte duplicate NAK; exact
     duplicate ACK; active-tid BEGIN NAK; COMMIT acked; COMMIT RETRY idempotent
  B2 transactional A/B slots: a stray BEGIN/ABORT does NOT destroy the committed slot, and
     BEGIN during track playback is refused (splice guard)
  B3 failed-commit retry: a transfer whose declared CRC does not match its data must NAK at
     COMMIT and KEEP NAKing on retry — the surviving older track must never credit it
     (R4 finding 1) — and the committed slot must still play
  B4 reboot durability with PROOF OF GENERATION (R4 finding 8c): the staged-but-uncommitted
     upload carries geographically DISTINCT data; after an orderly reboot VERIFIED by the
     restarted log-uptime counter (the macOS port path need not change), the coordinates that
     actually play must match the committed track, not the staged one, and COMMIT retry must
     remain idempotent from its on-disk proof.

Run from the repo root with the meshtastic pipx python.
"""
import re
import secrets
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
# Make both the transfer ids and course unique per invocation. The firmware deliberately
# rejects BEGIN reuse of the active committed tid, so fixed ids make a second suite run NAK
# its own BEGIN and can let the prior run's identical course masquerade as a fresh commit.
_RUN_NONCE = secrets.randbits(24)
COMMIT_LON = -1.60 + (_RUN_NONCE / 0xFFFFFF) * 0.04
STAGED_LON = COMMIT_LON + 0.01  # deliberately distinct staged course (~800 m east)
_TIDS = set()


def fresh_tid():
    while True:
        tid = secrets.randbits(32)
        if tid != 0 and tid not in _TIDS:
            _TIDS.add(tid)
            return tid


FAILURES = []
CHECKS_RUN = 0


def check(name, ok, detail=""):
    global CHECKS_RUN
    CHECKS_RUN += 1
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    if not ok:
        FAILURES.append(name)


rows, acks, config_replies = [], [], []


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
    elif len(pl) >= 2 and 0x80 <= pl[0] <= 0x84:
        config_replies.append(
            {"from": packet.get("from"), "op": pl[0] & 0x7F, "status": pl[1]}
        )


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


def await_config_reply(mark, op, timeout=3.0):
    """Accept only this tag's post-send reply for the requested config/simulator op."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        for reply in config_replies[mark:]:
            if reply["from"] == TAG and reply["op"] == op:
                return reply
        time.sleep(0.05)
    return None


def config_cmd(payload, retries=3):
    """Send an idempotent op 0x00-0x04 and retry only when its direct reply is lost."""
    op = payload[0]
    for _ in range(retries):
        mark = len(config_replies)
        cmd(payload)
        reply = await_config_reply(mark, op)
        if reply is not None:
            return reply
    return None


def tf(sub, tid, rest=b""):
    return bytes([0x05, sub]) + struct.pack("<I", tid) + rest


def sim_plays(seconds=5):
    """Run TRACK replay briefly; returns (n_simulated_packets, [lon...])."""
    rows.clear()
    reply = config_cmd([0x04, 3, 0, 60, 0])
    if reply is None or reply["status"] != 0:
        return 0, []
    time.sleep(seconds)
    got = [(r[3], r[4]) for r in rows if r[1] & 0x10]
    config_cmd([0x04, 0])
    time.sleep(1)
    return len(got), [lo for _, lo in got]


# ---------------- A) adaptive band semantics ----------------------------------------------
print("A) band-crossing program: 12x10s, 4x35s (band), 1x25s, loop")
rows.clear()
sim_reply = config_cmd([0x04, 1, 1, 180, 0, 3, 12, 10, 4, 35, 1, 25])
check(
    "SIM program start acknowledged",
    sim_reply is not None and sim_reply["status"] == 0,
    "no exact-sender post-send reply" if sim_reply is None else f"status={sim_reply['status']}",
)
t0 = time.monotonic()
transitions, last = [], None
while time.monotonic() - t0 < 75:
    time.sleep(1)
    if rows:
        tier = "idle" if rows[-1][1] & 8 else "fast"
        if tier != last:
            transitions.append((round(time.monotonic() - t0, 1), tier))
            last = tier
config_cmd([0x04, 0])
downshifts = [t for t, tier in transitions if tier == "idle"]
check("band never counts toward the downshift", bool(downshifts) and all(t >= 55 for t in downshifts),
      f"downshifts={downshifts}, transitions={transitions}, rows={len(rows)}")

# ---------------- B1) correlated upload, tid discipline, idempotent COMMIT -----------------
print("B1) upload — per-frame consumed-once correlation (sender+tid+sub+offset)")
pts = [(43.4832 + i * 0.00004, COMMIT_LON, 10, 10) for i in range(30)]
TID = fresh_tid()
WRONG_TID = fresh_tid()
print(f"  run nonce=0x{_RUN_NONCE:06x}, commit tid=0x{TID:08x}, lon={COMMIT_LON:.7f}")
acks.clear()
recs = b"".join(struct.pack("<iiBB", int(la * 1e7), int(lo * 1e7), sp, dt) for la, lo, sp, dt in pts)
crc = zlib.crc32(recs) & 0xFFFFFFFF
m = cmd(tf(0x00, TID, struct.pack("<HI", len(pts), crc)))
a = await_ack(m, 0, len(pts), TID)
check("BEGIN ack correlated + status 0", a is not None and a["status"] == 0)
for off in range(0, len(pts), 20):
    n = min(20, len(pts) - off)
    if off == 20:
        # A foreign transfer must be rejected BEFORE file access or offset advancement. Poison
        # the bytes too: if firmware accidentally appends this, the following correct chunk and
        # final CRC assertion expose the mutation.
        poison = bytearray(recs[off * 10:(off + n) * 10])
        poison[0] ^= 0x01
        m = cmd(tf(0x01, WRONG_TID, struct.pack("<HB", off, n) + bytes(poison)))
        a = await_ack(m, 1, off, WRONG_TID)
        check("CHUNK with WRONG tid NAKed before mutation", a is not None and a["status"] == 1)
    m = cmd(tf(0x01, TID, struct.pack("<HB", off, n) + recs[off * 10:(off + n) * 10]))
    a = await_ack(m, 1, off, TID)
    check(f"CHUNK off={off} ack correlated + status 0", a is not None and a["status"] == 0)
changed_dup = bytearray(recs[200:300])
changed_dup[0] ^= 0x01
m = cmd(tf(0x01, TID, struct.pack("<HB", 20, 10) + bytes(changed_dup)))
a = await_ack(m, 1, 20, TID)
check("same-range CHUNK with CHANGED bytes NAKed", a is not None and a["status"] == 1)
m = cmd(tf(0x01, TID, struct.pack("<HB", 20, 10) + recs[200:300]))  # exact dup of last chunk
a = await_ack(m, 1, 20, TID)
check("DUPLICATE chunk acked AFTER its own send (not a reused ACK)", a is not None and a["status"] == 0)
m = cmd(tf(0x02, WRONG_TID))  # a COMMIT for some OTHER transfer must not touch this staging
a = await_ack(m, 2, 0, WRONG_TID)
check("COMMIT with WRONG tid NAKed", a is not None and a["status"] == 1)
m = cmd(tf(0x02, TID))
a = await_ack(m, 2, 0, TID)
check("COMMIT ack correlated + status 0", a is not None and a["status"] == 0)
m = cmd(tf(0x02, TID))  # retry: pretend the previous reply was lost
a = await_ack(m, 2, 0, TID)
check("COMMIT RETRY (same tid) idempotent status 0", a is not None and a["status"] == 0)
m = cmd(tf(0x00, TID, struct.pack("<HI", len(pts), crc)))
a = await_ack(m, 0, len(pts), TID)
check("BEGIN cannot reuse the active committed tid", a is not None and a["status"] == 1)
n, lons = sim_plays()
check("replay after COMMIT plays the committed course", n > 5 and lons and
      all(abs(lo - COMMIT_LON) < 0.002 for lo in lons), f"n={n}")

# ---------------- B2) A/B slots: stray ops + splice guard -----------------------------------
print("B2) stray BEGIN/ABORT must NOT destroy the committed slot; BEGIN-while-playing refused")
STRAY_TID = fresh_tid()
PLAYING_TID = fresh_tid()
cmd(tf(0x00, STRAY_TID, struct.pack("<HI", len(pts), crc)))  # stray BEGIN, no chunks
n, _ = sim_plays()
check("committed slot STILL plays after a stray BEGIN", n > 5)
m = cmd(tf(0x03, STRAY_TID))
a = await_ack(m, 3, 0, STRAY_TID)
check("ABORT of the stray staging acked", a is not None and a["status"] == 0)
n, _ = sim_plays()
check("committed slot STILL plays after ABORT", n > 5)
rows.clear()
config_cmd([0x04, 3, 0, 60, 0])  # start playback, then try to BEGIN into the pinned slot pair
time.sleep(2)
m = cmd(tf(0x00, PLAYING_TID, struct.pack("<HI", len(pts), crc)))
a = await_ack(m, 0, len(pts), PLAYING_TID)
check("BEGIN during track playback NAKed (splice guard)", a is not None and a["status"] == 1)
config_cmd([0x04, 0])
time.sleep(1)

# ---------------- B3) failed COMMIT retry must keep NAKing (R4 finding 1) -------------------
print("B3) transfer with a WRONG declared CRC: COMMIT NAKs, retry NAKs, old track intact")
BADTID = fresh_tid()
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
STID = fresh_tid()
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
m = cmd(tf(0x02, TID))  # original success proof must survive process/RAM reset
a = await_ack(m, 2, 0, TID)
check("COMMIT RETRY remains idempotent AFTER reboot", a is not None and a["status"] == 0)

print()
iface.close()
if FAILURES:
    print(f"OVERALL: FAIL ({len(FAILURES)}/{CHECKS_RUN}): {FAILURES}")
    sys.exit(1)
print(f"OVERALL: PASS ({CHECKS_RUN}/{CHECKS_RUN} assertions)")
sys.exit(0)
