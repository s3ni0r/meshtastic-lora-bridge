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
  C1 settings v4 surface: 20-byte reply, capability byte, radio-status byte, duty floor
  C2 SIGNAL v5 (u32 sid): correlated ACK; exact-duplicate re-ACK (no replay); same-sid
     different-pattern NAK; unknown-pattern NAK; legacy 3-byte form still settings-echoes
  C3 RADIO op (A4): GO-DEAF ACK-before-mute + in-grace duplicate re-ACK; the v5 stream
     status byte flips to DEAF (the two-layer fallback confirmation); a REAL LoRa command
     via the Base gets NO ACK while deaf (radio provably muted) and works again after
     RADIO=LISTENING over USB
  C4 PERMANENT profile: SET persists; uptime-VERIFIED reboot boots DEAF; RADIO command
     REWRITES the profile; HYBRID restored (HYBRID boot-listening is every run's C3 baseline)
  C5 EU868 duty floor round-trip: a spacing stored under a no-duty region survives the
     region change but is flagged DEGRADED (boot clamp); a live SET below the floor is
     REJECTED. The floor comes from the TAG's own reply bytes 18-19 (never re-derived from
     preset assumptions — the fleet runs LongFast, whose EU floor exceeds the whole settable
     range): if the floor is settable, a legal SET must clear the flag; if it is beyond
     5000 ms, EVERY spacing must keep rejecting and the clamp stays flagged.
     Region + settings restored in `finally`.

Needs the GPS tag AND the Base on USB (C3 sends real LoRa downlinks through the Base).
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


rows, acks, config_replies, sigacks, radioacks = [], [], [], [], []


def on_rx(packet, interface=None):
    d = packet.get("decoded") or {}
    pl = d.get("payload") or b""
    if d.get("portnum") in ("PRIVATE_APP", 256) and len(pl) >= 19:
        lat = struct.unpack_from("<i", pl, 0)[0] / 1e7
        lon = struct.unpack_from("<i", pl, 4)[0] / 1e7
        # 6th element: v5 status byte (bit0 DEAF, bit1 PERMANENT, bit2 degraded); None pre-v5.
        # 7th: sender node — with the bridge also streaming since A1, every consumer must
        # filter to THE tag under test or a second node's packets pollute the assertion.
        rows.append((time.monotonic(), pl[11], pl[14], lat, lon,
                     pl[19] if len(pl) >= 20 else None, packet.get("from")))
    elif len(pl) == 9 and pl[0] == 0x85:
        acks.append({"from": packet.get("from"), "status": pl[1], "sub": pl[2],
                     "off": pl[3] | (pl[4] << 8),
                     "tid": struct.unpack_from("<I", pl, 5)[0]})
    elif len(pl) == 7 and pl[0] == 0x83:  # SIGNAL v5 correlated ACK
        sigacks.append({"from": packet.get("from"), "status": pl[1], "pattern": pl[2],
                        "sid": struct.unpack_from("<I", pl, 3)[0]})
    elif len(pl) == 7 and pl[0] == 0x86:  # RADIO-op correlated ACK
        radioacks.append({"from": packet.get("from"), "status": pl[1], "state": pl[2],
                          "rid": struct.unpack_from("<I", pl, 3)[0]})
    elif len(pl) >= 2 and 0x80 <= pl[0] <= 0x84:
        config_replies.append(
            {"from": packet.get("from"), "op": pl[0] & 0x7F, "status": pl[1], "raw": bytes(pl)}
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


def await_sigack(mark, pattern, sid, timeout=3.0):
    """SIGNAL v5 correlated-ACK contract: sender==TAG, {pattern, sid} exact, appended after mark."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        for a in sigacks[mark:]:
            if a["from"] == TAG and a["pattern"] == pattern and a["sid"] == sid:
                return a
        time.sleep(0.05)
    return None


def await_radioack(mark, state, rid, timeout=3.0):
    """RADIO-op correlated-ACK contract: sender==TAG, {state, rid} exact, appended after mark."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        for a in radioacks[mark:]:
            if a["from"] == TAG and a["state"] == state and a["rid"] == rid:
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
    got = [(r[3], r[4]) for r in rows if r[1] & 0x10 and r[6] == TAG]
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
# Watch 95 s, not 75: the downshift lands ~60-65 s in (10 s fast + 35 s band + 15 s sustain,
# plus sim-start latency) — a 75 s window put the expected event within seconds of the edge
# and produced a spurious FAIL on 2026-07-27 (downshifts=[] with the sim running correctly).
while time.monotonic() - t0 < 95:
    time.sleep(1)
    tag_rows = [r for r in rows if r[6] == TAG]
    if tag_rows:
        tier = "idle" if tag_rows[-1][1] & 8 else "fast"
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


# ---------------- C) A4 radio states, sid signals, profiles (A1+A4 round) -------------------
def sig_frame(pattern, sid):
    return bytes([0x03, pattern]) + struct.pack("<I", sid)


def radio_frame(state, rid):
    return bytes([0x06, state]) + struct.pack("<I", rid)


def stream_status(window_s=4.0):
    """Watch the live stream and return the latest v5 status byte (None = no v5 packet seen).
    The window must EXCEED the adaptive idle-tier spacing (3 s default) — a shorter sample
    races the packet cadence and fails spuriously on a stationary tag."""
    rows.clear()
    time.sleep(window_s)
    v5 = [r[5] for r in rows if r[5] is not None and r[6] == TAG]
    return v5[-1] if v5 else None


def read_uptime(port):
    """Seconds-since-boot from the log stream (the R4 reboot proof; None = not readable)."""
    try:
        raw = pyserial.Serial(port, 115200, timeout=1)
        buf = b""
        t0 = time.monotonic()
        while time.monotonic() - t0 < 8 and len(buf) < 8000:
            buf += raw.read(512)
        raw.close()
        secs = [int(x) for x in re.findall(rb"\?\?:\?\?:\?\? (\d+) ", buf)]
        return max(secs) if secs else None
    except Exception as e:
        print(f"  (uptime read failed: {e!r})")
        return None


def reboot_tag(label):
    """Orderly reboot with the same uptime PROOF discipline as B4; reconnects `iface`."""
    global iface
    port = nodes.resolve("gpstag")
    iface.close()
    rb = subprocess.run(["meshtastic", "--port", port, "--reboot"], capture_output=True, timeout=90)
    check(f"{label}: reboot command accepted", rb.returncode == 0, f"rc={rb.returncode}")
    time.sleep(25)
    back = None
    for _ in range(25):
        back = nodes.resolve("gpstag")
        if back:
            break
        time.sleep(2)
    check(f"{label}: tag re-enumerated", back is not None)
    up = read_uptime(back) if back else None
    check(f"{label}: uptime restarted (reboot really happened)", up is not None and up < 90, f"uptime≈{up}s")
    iface = connect()


print("C1) settings v4 reply surface: 20 bytes, capability byte, radio-status byte")
r = config_cmd([0x00])
raw = r["raw"] if r else b""
check("GET replies (20-byte v4)", r is not None and r["status"] == 0 and len(raw) == 20, f"len={len(raw)}")
check("capability byte advertises the GPS-tag groups (0x3F)", len(raw) == 20 and raw[16] == 0x3F,
      f"cap=0x{raw[16]:02x}" if len(raw) == 20 else "no reply")
check("radio-status: LISTENING, HYBRID, not degraded", len(raw) == 20 and (raw[17] & 0x07) == 0,
      f"status=0x{raw[17]:02x}" if len(raw) == 20 else "no reply")

print("C2) SIGNAL v5 (u32 sid): correlated ACK, dedupe, conflict + unknown NAK")
S1 = fresh_tid()
mk = len(sigacks)
cmd(sig_frame(2, S1))
a = await_sigack(mk, 2, S1)
check("v5 signal ACKed (accepted + scheduled)", a is not None and a["status"] == 0)
mk = len(sigacks)
cmd(sig_frame(2, S1))
a = await_sigack(mk, 2, S1)
check("exact {sid,pattern} duplicate re-ACKed (no replay)", a is not None and a["status"] == 0)
mk = len(sigacks)
cmd(sig_frame(3, S1))
a = await_sigack(mk, 3, S1)
check("same sid with a DIFFERENT pattern NAKs", a is not None and a["status"] == 1)
S2 = fresh_tid()
mk = len(sigacks)
cmd(sig_frame(99, S2))
a = await_sigack(mk, 99, S2)
check("unknown pattern NAKs", a is not None and a["status"] == 1)
mk = len(config_replies)
cmd([0x03, 1, _RUN_NONCE & 0xFF])
r = await_config_reply(mk, 3)
check("legacy 3-byte SIGNAL still settings-echoes (compat)",
      r is not None and r["status"] == 0 and len(r["raw"]) == 20)
cmd(sig_frame(0, fresh_tid()))  # cancel — leave no loops/heartbeat running

print("C3) RADIO op: ACK-before-mute, in-grace re-ACK, v5 stream fallback, REAL LoRa deafness")
base_iface = meshtastic.serial_interface.SerialInterface(devPath=nodes.resolve("base"))
time.sleep(1.5)


def base_send(payload):
    """The Base-relayed LoRa downlink — the exact packet shape senders use (docs/DOWNLINK.md)."""
    p = mesh_pb2.MeshPacket()
    p.to = TAG
    p.decoded.portnum = 260
    p.decoded.payload = bytes(payload)
    p.priority = mesh_pb2.MeshPacket.Priority.HIGH
    p.hop_limit = 1
    p.want_ack = False
    p.id = base_iface._generatePacketId()
    base_iface._sendPacket(p)
    time.sleep(0.35)


def lora_signal(pattern, sid, attempts=3):
    """The REAL sender discipline (docs/RADIO_STATES.md §4): retransmit the SAME sid until the
    correlated ACK arrives — the tag's {sid, pattern} dedupe makes re-sends safe. Returns the
    ACK, or None after all attempts (which is the deafness PROOF when muting is expected)."""
    for _ in range(attempts):
        mk = len(sigacks)
        base_send(sig_frame(pattern, sid))
        a = await_sigack(mk, pattern, sid, timeout=4.0)
        if a is not None:
            return a
    return None


st = stream_status()
check("stream carries the v5 status byte", st is not None)
check("baseline: stream reads LISTENING (bit0=0)", st is not None and (st & 0x01) == 0,
      f"status=0x{st:02x}" if st is not None else "no v5 packet")
a = lora_signal(1, fresh_tid())
check("LoRa SIGNAL via the Base ACKs while LISTENING (retry-until-ACK)", a is not None and a["status"] == 0)
R1 = fresh_tid()
mk = len(radioacks)
cmd(radio_frame(1, R1))
a = await_radioack(mk, 1, R1)
check("GO-DEAF ACKed (ACK precedes the mute)", a is not None and a["status"] == 0)
mk = len(radioacks)
cmd(radio_frame(1, R1))
a = await_radioack(mk, 1, R1)
check("duplicate GO-DEAF inside the grace window re-ACKed", a is not None and a["status"] == 0)
time.sleep(3.0)  # grace (2 s, re-armed once by the duplicate) elapses -> radio mutes
st = stream_status()
check("stream status byte flips to DEAF (the two-layer fallback confirmation)",
      st is not None and (st & 0x01) == 1, f"status=0x{st:02x}" if st is not None else "no v5 packet")
check("LoRa SIGNAL gets NO ACK while DEAF (3 attempts — radio provably muted)",
      lora_signal(1, fresh_tid()) is None)
r = config_cmd([0x00])
check("USB command path still works while DEAF", r is not None and len(r["raw"]) == 20 and (r["raw"][17] & 1) == 1)
R2 = fresh_tid()
mk = len(radioacks)
cmd(radio_frame(0, R2))
a = await_radioack(mk, 0, R2)
check("RADIO=LISTENING via USB ACKed", a is not None and a["status"] == 0)
time.sleep(1.0)
st = stream_status()
check("stream back to LISTENING", st is not None and (st & 0x01) == 0)
a = lora_signal(1, fresh_tid())
check("LoRa delivery restored after un-deafen (retry-until-ACK)", a is not None and a["status"] == 0)

print("C4) PERMANENT profile: persisted, boots DEAF (uptime-verified), RADIO rewrites, restore")
r = config_cmd([0x00])
raw = r["raw"] if r else b""
check("pre-PERMANENT GET ok", r is not None and len(raw) == 20)
v4set = bytearray(raw[2:16])  # current 14-byte settings, to mutate + restore
v4set[13] = 0x03              # PERMANENT | PERM_DEAF
r = config_cmd([0x01] + list(v4set))
check("SET PERMANENT-DEAF accepted", r is not None and r["status"] == 0)
time.sleep(3.0)  # profile side-effect goes deaf through the same grace
st = stream_status()
check("runtime now DEAF + PERMANENT", st is not None and (st & 0x03) == 0x03,
      f"status=0x{st:02x}" if st is not None else "no v5 packet")
reboot_tag("C4")
st = stream_status(4.5)
check("PERMANENT-DEAF SURVIVES the reboot (boots muted)", st is not None and (st & 0x03) == 0x03,
      f"status=0x{st:02x}" if st is not None else "no v5 packet")
check("LoRa still deaf after the PERMANENT boot (3 attempts)", lora_signal(1, fresh_tid()) is None)
R3 = fresh_tid()
mk = len(radioacks)
cmd(radio_frame(0, R3))
a = await_radioack(mk, 0, R3)
check("RADIO=LISTENING ACKed in PERMANENT", a is not None and a["status"] == 0)
r = config_cmd([0x00])
check("...and it REWROTE the profile (PERMANENT-LISTENING persisted)",
      r is not None and len(r["raw"]) == 20 and r["raw"][15] == 0x01 and (r["raw"][17] & 1) == 0,
      f"profile=0x{r['raw'][15]:02x} status=0x{r['raw'][17]:02x}" if r and len(r["raw"]) == 20 else "no reply")
v4set[13] = 0x00
r = config_cmd([0x01] + list(v4set))
check("HYBRID restored", r is not None and r["status"] == 0 and r["raw"][15] == 0x00)
# HYBRID boot-listening needs no extra reboot here: every suite run STARTS from a boot and
# C3's baseline asserts LISTENING — that IS the HYBRID boot-state evidence.

print("C5) EU868 duty floor: boot clamp flags DEGRADED, live SET below floor rejected")
from meshtastic.protobuf import config_pb2
region_before = config_pb2.Config.LoRaConfig.RegionCode.Name(iface.localNode.localConfig.lora.region)
# The preset must be captured and restored too: entering EU_868 makes the firmware ITSELF
# reset an EU-illegal preset (this fleet runs SHORT_TURBO, 500 kHz — not allowed in EU) to
# LONG_FAST, silently splitting the tag from the base/bridge air path. That exact failure
# cost three suite runs on 2026-07-26 — hence the post-restore LoRa proof below.
preset_before = config_pb2.Config.LoRaConfig.ModemPreset.Name(iface.localNode.localConfig.lora.modem_preset)
settings_before = bytes(v4set)  # HYBRID settings as restored above
# Fail-closed: if the current region is not readable we must NOT cycle regions — a wrong
# restore would strand the tag off-band. The C5 assertions then fail visibly, never silently.
check("C5 preflight: current region readable (restore target)", region_before not in ("UNSET", ""),
      f"region={region_before!r}")


def set_lora(*pairs):
    """Write lora.* fields via the CLI (device reboots) and reconnect."""
    global iface
    port = nodes.resolve("gpstag")
    iface.close()
    args = ["meshtastic", "--port", port]
    for key, value in pairs:
        args += ["--set", key, value]
    rc = subprocess.run(args, capture_output=True, timeout=120)
    check(f"lora write {pairs} accepted", rc.returncode == 0,
          f"rc={rc.returncode} err={rc.stderr[-160:]!r}")
    time.sleep(25)  # config write reboots the node
    for _ in range(25):
        if nodes.resolve("gpstag"):
            break
        time.sleep(2)
    iface = connect()


def set_region(region):
    set_lora(("lora.region", region))


def run_c5_duty_floor():
    v150 = bytearray(settings_before)
    v150[5:7] = (150).to_bytes(2, "little")
    r = config_cmd([0x01] + list(v150))
    check("spacing 150 ms accepted under the no-duty region (floor 0)", r is not None and r["status"] == 0)
    set_region("EU_868")
    r = config_cmd([0x00])
    raw = r["raw"] if r else b""
    sp = int.from_bytes(raw[7:9], "little") if len(raw) == 20 else None
    floor = int.from_bytes(raw[18:20], "little") if len(raw) == 20 else 0
    check("tag reports its OWN duty floor under EU868 (reply bytes 18-19)", floor > 0,
          f"floor={floor} ms")
    print(f"  measured duty floor: {floor} ms (region duty % x airtime at the ACTIVE preset)")
    check("stored 150 ms spacing SURVIVES the region change (clamped at use, not reverted)",
          sp == 150, f"spacing={sp}")
    check("radio-status flags DUTY-DEGRADED under EU868", len(raw) == 20 and (raw[17] & 0x04) == 0x04,
          f"status=0x{raw[17]:02x}" if len(raw) == 20 else "no reply")
    r = config_cmd([0x01] + list(v150))
    check("live SET below the duty floor REJECTED under EU868", r is not None and r["status"] == 1)
    if 0 < floor <= 5000:
        legal = bytearray(settings_before)
        legal[5:7] = int(floor).to_bytes(2, "little")
        r = config_cmd([0x01] + list(legal))
        check(f"legal {floor} ms SET accepted under EU868", r is not None and r["status"] == 0)
        check("...and the DEGRADED flag clears",
              r is not None and len(r["raw"]) == 20 and (r["raw"][17] & 0x04) == 0)
    else:
        # The active preset's floor exceeds the whole settable range (LongFast under EU868:
        # ~560 ms airtime -> floor ~5.6 s > 5000 ms cap). There IS no legal sustained SET —
        # the firmware must keep rejecting everything and keep the clamp flagged, never
        # silently accept an illegal rate.
        vmax = bytearray(settings_before)
        vmax[5:7] = (5000).to_bytes(2, "little")
        r = config_cmd([0x01] + list(vmax))
        check("floor beyond the settable range: even 5000 ms REJECTED (no legal SET exists)",
              r is not None and r["status"] == 1)
        r = config_cmd([0x00])
        check("...and the DEGRADED clamp stays flagged (never silent illegal TX)",
              r is not None and len(r["raw"]) == 20 and (r["raw"][17] & 0x04) == 0x04)


if region_before in ("UNSET", ""):
    print("  C5 SKIPPED after failed preflight — region cycle would be unrestorable")
else:
    try:
        run_c5_duty_floor()
    finally:
        print(f"  restoring region {region_before} + preset {preset_before} + settings…")
        try:
            # One write, BOTH fields: region alone leaves the EU-forced LONG_FAST behind and
            # the tag ends up air-deaf to the SHORT_TURBO fleet (the 2026-07-26 incident).
            set_lora(("lora.region", region_before), ("lora.modem_preset", preset_before))
            r = config_cmd([0x01] + list(settings_before))
            check("region + preset + settings restored", r is not None and r["status"] == 0)
            # PROOF the suite leaves the air path intact: a Base-relayed LoRa signal must ACK.
            a = lora_signal(1, fresh_tid())
            check("post-restore LoRa via the Base ACKs (air path proven intact)",
                  a is not None and a["status"] == 0)
        except Exception as e:  # a failed restore must be LOUD, never silent
            check("region + preset + settings restored", False, repr(e))

base_iface.close()

print()
iface.close()
if FAILURES:
    print(f"OVERALL: FAIL ({len(FAILURES)}/{CHECKS_RUN}): {FAILURES}")
    sys.exit(1)
print(f"OVERALL: PASS ({CHECKS_RUN}/{CHECKS_RUN} assertions)")
sys.exit(0)
