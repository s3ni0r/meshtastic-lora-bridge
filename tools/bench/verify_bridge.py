"""Bridge-tag (ODID_SNIFFER flavor) bench suite — the A1 config-parity gate.

Asserts, on real hardware (bridge on USB, exit 0 ONLY if everything passes):
  D1 settings v4 surface over USB: 20-byte reply; capability byte = 0x38 (signals + radio +
     profiles — NO GNSS knobs, NO TX modes, NO simulator/track); radio-status LISTENING+HYBRID
  D2 capability honesty: MODE (0x02), SIM (0x04) and TRACK (0x05) all NAK status 1 — the
     bridge advertises what it can't do and refuses it, never silently accepts
  D3 SIGNAL v5 on the bridge: correlated ACK; exact-duplicate re-ACK; conflict NAK (the
     bridge plays the same calibration role — it only lacks GNSS knobs)
  D4 RADIO op on the bridge: GO-DEAF ACK + grace re-ACK; USB path alive while DEAF;
     RADIO=LISTENING restores. (LoRa-side deafness is proven on the GPS tag by
     verify_fixes.py C3 — same shared TagRadioState module, same binary logic.)
  D5 TX-spacing knob: a SET that only changes txSpacingMs is accepted and echoed (the
     bridge's one live rate knob since -DHIGHRATE_TX_ONLY was retired)
  D6 sniffer coexistence evidence: the boot log carries the slow-adv + continuous-scan
     marker. The THROUGHPUT A/B (advertising on/off, connected BLE session) additionally
     needs a live Dronetag feeding ODID adverts — run it with the Dronetag powered and
     compare SNIFF cb/loc rates; without one this suite only proves the config surface.

Run from the repo root with the meshtastic pipx python. The bridge must NOT have a phone
connected over BLE (single PhoneAPI client).
"""
import re
import secrets
import struct
import sys
import time

import serial as pyserial

sys.path.insert(0, "tools")
import nodes
import meshtastic.serial_interface
from meshtastic import mesh_pb2
from pubsub import pub

BRIDGE = 0xB4DBB54C  # !b4dbb54c — the bridge tag's node num (tools/nodes.py role "tag")

FAILURES = []
CHECKS_RUN = 0


def check(name, ok, detail=""):
    global CHECKS_RUN
    CHECKS_RUN += 1
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    if not ok:
        FAILURES.append(name)


config_replies, sigacks, radioacks = [], [], []


def on_rx(packet, interface=None):
    d = packet.get("decoded") or {}
    pl = d.get("payload") or b""
    if len(pl) == 7 and pl[0] == 0x83:
        sigacks.append({"from": packet.get("from"), "status": pl[1], "pattern": pl[2],
                        "sid": struct.unpack_from("<I", pl, 3)[0]})
    elif len(pl) == 7 and pl[0] == 0x86:
        radioacks.append({"from": packet.get("from"), "status": pl[1], "state": pl[2],
                          "rid": struct.unpack_from("<I", pl, 3)[0]})
    elif len(pl) >= 15 and 0x80 <= pl[0] <= 0x86:
        # Settings echoes are 15 (v3) / 20 (v4) bytes for ANY op — including 0x85 for a
        # TRACK frame the bridge refuses (LENGTH disambiguates it from the GPS tag's 9-byte
        # TRACK ACK, and from the 7-byte SIGNAL/RADIO ACKs).
        config_replies.append(
            {"from": packet.get("from"), "op": pl[0] & 0x7F, "status": pl[1], "raw": bytes(pl)}
        )


port = nodes.resolve("tag")
if not port:
    print("FATAL: bridge tag not on USB (role 'tag' in tools/nodes.py)")
    sys.exit(1)
iface = meshtastic.serial_interface.SerialInterface(devPath=port)
pub.subscribe(on_rx, "meshtastic.receive")
time.sleep(1.5)


def cmd(payload):
    p = mesh_pb2.MeshPacket()
    p.to = BRIDGE
    p.decoded.portnum = 260
    p.decoded.payload = bytes(payload)
    p.id = iface._generatePacketId()
    iface._sendPacket(p)
    time.sleep(0.35)


def await_config_reply(mark, op, timeout=3.0):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        for reply in config_replies[mark:]:
            if reply["from"] == BRIDGE and reply["op"] == op:
                return reply
        time.sleep(0.05)
    return None


def config_cmd(payload, retries=3):
    op = payload[0]
    for _ in range(retries):
        mark = len(config_replies)
        cmd(payload)
        reply = await_config_reply(mark, op)
        if reply is not None:
            return reply
    return None


def await_sigack(mark, pattern, sid, timeout=3.0):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        for a in sigacks[mark:]:
            if a["from"] == BRIDGE and a["pattern"] == pattern and a["sid"] == sid:
                return a
        time.sleep(0.05)
    return None


def await_radioack(mark, state, rid, timeout=3.0):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        for a in radioacks[mark:]:
            if a["from"] == BRIDGE and a["state"] == state and a["rid"] == rid:
                return a
        time.sleep(0.05)
    return None


def sig_frame(pattern, sid):
    return bytes([0x03, pattern]) + struct.pack("<I", sid)


def radio_frame(state, rid):
    return bytes([0x06, state]) + struct.pack("<I", rid)


print("D1) settings v4 surface (USB): 20-byte reply, bridge capability byte")
r = config_cmd([0x00])
raw = r["raw"] if r else b""
check("GET replies (20-byte v4)", r is not None and r["status"] == 0 and len(raw) == 20,
      f"len={len(raw)}")
check("capability byte = bridge groups (0x38: signals+radio+profiles)",
      len(raw) == 20 and raw[16] == 0x38, f"cap=0x{raw[16]:02x}" if len(raw) == 20 else "no reply")
check("radio-status: LISTENING, HYBRID", len(raw) == 20 and (raw[17] & 0x03) == 0,
      f"status=0x{raw[17]:02x}" if len(raw) == 20 else "no reply")
SETTINGS = bytes(raw[2:16]) if len(raw) == 20 else b""

print("D2) capability honesty: unsupported ops NAK, never silently accepted")
r = config_cmd([0x02, 1])  # MODE=ADAPTIVE — the bridge has no TX modes
check("MODE NAKs on the bridge (status 1)", r is not None and r["status"] == 1)
r = config_cmd([0x04, 2, 0, 60, 0])  # SIM start
check("SIM NAKs on the bridge (status 1)", r is not None and r["status"] == 1)
# TRACK replies ride the settings-echo path with status 1 on the bridge (no 0x85 storage ACK)
r = config_cmd([0x05, 0x00] + list(struct.pack("<IHI", secrets.randbits(32) | 1, 10, 0)))
check("TRACK NAKs on the bridge (status 1)", r is not None and r["status"] == 1)

print("D3) SIGNAL v5 on the bridge: correlated ACK + dedupe + conflict NAK")
S1 = secrets.randbits(32) | 1
mk = len(sigacks)
cmd(sig_frame(2, S1))
a = await_sigack(mk, 2, S1)
check("signal ACKed (accepted + scheduled)", a is not None and a["status"] == 0)
mk = len(sigacks)
cmd(sig_frame(2, S1))
a = await_sigack(mk, 2, S1)
check("exact duplicate re-ACKed (no replay)", a is not None and a["status"] == 0)
mk = len(sigacks)
cmd(sig_frame(3, S1))
a = await_sigack(mk, 3, S1)
check("same sid, different pattern NAKs", a is not None and a["status"] == 1)
cmd(sig_frame(0, secrets.randbits(32) | 1))  # cancel — tidy bench

print("D4) RADIO op on the bridge: deaf/listen via USB (shared TagRadioState module)")
R1 = secrets.randbits(32) | 1
mk = len(radioacks)
cmd(radio_frame(1, R1))
a = await_radioack(mk, 1, R1)
check("GO-DEAF ACKed", a is not None and a["status"] == 0)
mk = len(radioacks)
cmd(radio_frame(1, R1))
a = await_radioack(mk, 1, R1)
check("duplicate GO-DEAF inside the grace re-ACKed", a is not None and a["status"] == 0)
time.sleep(3.0)  # grace elapses -> muted
r = config_cmd([0x00])
check("USB path alive while DEAF; status byte reads DEAF",
      r is not None and len(r["raw"]) == 20 and (r["raw"][17] & 0x01) == 0x01,
      f"status=0x{r['raw'][17]:02x}" if r and len(r["raw"]) == 20 else "no reply")
R2 = secrets.randbits(32) | 1
mk = len(radioacks)
cmd(radio_frame(0, R2))
a = await_radioack(mk, 0, R2)
check("RADIO=LISTENING ACKed", a is not None and a["status"] == 0)
r = config_cmd([0x00])
check("status byte back to LISTENING", r is not None and len(r["raw"]) == 20 and (r["raw"][17] & 0x01) == 0)

print("D5) TX-spacing knob live (the runtime replacement for -DHIGHRATE_TX_ONLY's era)")
if len(SETTINGS) == 14:
    v = bytearray(SETTINGS)
    orig = int.from_bytes(v[5:7], "little")
    v[5:7] = (700).to_bytes(2, "little")
    r = config_cmd([0x01] + list(v))
    echo = int.from_bytes(r["raw"][7:9], "little") if r and len(r["raw"]) == 20 else None
    check("SET spacing 700 ms accepted + echoed", r is not None and r["status"] == 0 and echo == 700,
          f"echo={echo}")
    v[5:7] = orig.to_bytes(2, "little")
    r = config_cmd([0x01] + list(v))
    check(f"spacing restored to {orig} ms", r is not None and r["status"] == 0)
else:
    check("TX-spacing knob exercised", False, "no baseline settings")

print("D6) sniffer coexistence: reboot + capture the BLE-setup boot marker")
# The marker prints ONCE, at BLE setup during boot — and the SNIFF stats line only prints
# when ODID adverts actually arrive (never on a Dronetag-less bench, the scanner is
# coded-PHY-only). So: orderly reboot, then read the boot log from re-enumeration onward.
import subprocess
iface.close()
port = nodes.resolve("tag")
rb = subprocess.run(["meshtastic", "--port", port, "--reboot"], capture_output=True, timeout=90)
check("D6: reboot command accepted", rb.returncode == 0, f"rc={rb.returncode}")
time.sleep(8)
back = None
for _ in range(30):
    back = nodes.resolve("tag")
    if back:
        break
    time.sleep(2)
check("D6: bridge re-enumerated", back is not None)
marker = False
uptime = None
if back:
    # The CDC can drop and re-enumerate once more right after coming back — re-resolve and
    # retry the open instead of trusting the first port sighting (macOS ground truth).
    buf = b""
    for attempt in range(4):
        try:
            port_now = nodes.resolve("tag") or back
            rawport = pyserial.Serial(port_now, 115200, timeout=1)
            t0 = time.monotonic()
            while time.monotonic() - t0 < 30 and len(buf) < 200000:
                buf += rawport.read(1024)
                if b"slow connectable adv + continuous scan" in buf:
                    break
            rawport.close()
            break
        except Exception as e:
            print(f"  (log read attempt {attempt + 1}: {e!r})")
            time.sleep(3)
    marker = b"slow connectable adv + continuous scan" in buf
    secs = [int(x) for x in re.findall(rb"\?\?:\?\?:\?\? (\d+) ", buf)]
    uptime = max(secs) if secs else None
check("D6: uptime restarted (real reboot)", uptime is not None and uptime < 90, f"uptime≈{uptime}s")
check("bridge boot log shows slow connectable adv + continuous ODID scan", marker)

print()
if FAILURES:
    print(f"OVERALL: FAIL ({len(FAILURES)}/{CHECKS_RUN}): {FAILURES}")
    sys.exit(1)
print(f"OVERALL: PASS ({CHECKS_RUN}/{CHECKS_RUN} assertions)")
sys.exit(0)
