#!/usr/bin/env python3
"""Downlink latency + mode-switch validation for the tag-downlink branch.

Sends WELL-CONSTRUCTED commands (priority HIGH, hop_limit 1, want_ack off — the exact packet
shape the phone app will use) from the Base's USB serial API to the GPS tag over LoRa, and
measures phone->tag latency against the tag's own USB debug console ("GnssConfig: SIGRX ...").
Both timestamps come from THIS host's clock (send instant vs. serial-line arrival), so there is
no cross-device clock problem; the tag->host serial print adds only a few ms.

    python downlink_latency.py signal [--n 20] [--pattern 1]   # N single-blip signals, stats
    python downlink_latency.py mode                            # adaptive/calibration echo + TTL test
    python downlink_latency.py beep                            # one pattern-3 (triple blip+beep)
    python downlink_latency.py cancel                          # pattern 5 (stop everything)

Prereqs: Base + GPS tag both on USB (nodes.py roles 'base'/'gpstag'); no phone app connected
to the Base (single PhoneAPI client!). The tag console must be free (no other reader).
"""
import argparse
import random
import re
import statistics
import sys
import threading
import time

import serial as pyserial

sys.path.insert(0, __import__("os").path.dirname(__file__))
import nodes  # noqa: E402

GNSS_CONFIG_PORTNUM = 260


# ---------------------------------------------------------------- tag console watcher

class TagConsole:
    """Raw reader for the tag's USB debug console with host-clock line stamps."""

    def __init__(self, port):
        self.ser = pyserial.Serial(port, 115200, timeout=0.05)
        self.lines = []  # (t_host_monotonic, line)
        self.lock = threading.Lock()
        self.running = True
        self.buf = b""
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        while self.running:
            data = self.ser.read(4096)
            if not data:
                continue
            now = time.monotonic()
            self.buf += data
            while b"\n" in self.buf:
                raw, self.buf = self.buf.split(b"\n", 1)
                line = raw.decode("utf-8", "replace").strip()
                if line:
                    with self.lock:
                        self.lines.append((now, line))

    def wait_for(self, pattern, since, timeout):
        """First line matching regex `pattern` stamped after monotonic `since`."""
        rx = re.compile(pattern)
        deadline = time.monotonic() + timeout
        idx = 0
        while time.monotonic() < deadline:
            with self.lock:
                lines = self.lines[idx:]
                idx = len(self.lines)
            for t, line in lines:
                if t >= since and rx.search(line):
                    return t, line
            time.sleep(0.005)
        return None, None

    def close(self):
        self.running = False
        self.thread.join(timeout=1)
        self.ser.close()


# ---------------------------------------------------------------- base-side sender

class BaseLink:
    """Meshtastic serial API on the Base + a PRIVATE_APP stream watcher (flags observer)."""

    def __init__(self, port):
        import meshtastic.serial_interface
        from pubsub import pub

        self.iface = meshtastic.serial_interface.SerialInterface(devPath=port)
        self.stream_flags = None  # latest flags byte seen from the tag's stream
        self.stream_count = 0
        self.stream_t0 = None
        pub.subscribe(self._on_receive, "meshtastic.receive")

    def _on_receive(self, packet, interface=None):
        d = packet.get("decoded") or {}
        if d.get("portnum") not in ("PRIVATE_APP", 256):
            return
        payload = d.get("payload") or b""
        if len(payload) >= 12:
            self.stream_flags = payload[11]
            self.stream_count += 1
            if self.stream_t0 is None:
                self.stream_t0 = time.monotonic()

    def stream_rate(self):
        if not self.stream_t0 or self.stream_count < 2:
            return 0.0
        return (self.stream_count - 1) / max(time.monotonic() - self.stream_t0, 1e-9)

    def send_cmd(self, dest, payload):
        """The well-constructed packet: HIGH priority, hop_limit 1, no ack, portnum 260."""
        from meshtastic import mesh_pb2

        p = mesh_pb2.MeshPacket()
        p.to = dest
        p.decoded.portnum = GNSS_CONFIG_PORTNUM
        p.decoded.payload = bytes(payload)
        p.id = self.iface._generatePacketId()
        p.hop_limit = 1
        p.want_ack = False
        p.priority = mesh_pb2.MeshPacket.Priority.HIGH
        t = time.monotonic()
        self.iface._sendPacket(p)
        return t

    def close(self):
        self.iface.close()


# ---------------------------------------------------------------- tests

def resolve_or_die(role):
    port = nodes.resolve(role)
    if not port:
        sys.exit(f"node '{role}' not connected (see tools/nodes.py)")
    return port


def tag_nodenum():
    for n in nodes.NODES.values():
        if n.get("role") == "gpstag":
            return int(n["num"])
    sys.exit("gpstag node num not in tools/nodes.py registry")


def run_signal(args):
    base = BaseLink(resolve_or_die("base"))
    tag = TagConsole(resolve_or_die("gpstag"))
    dest = tag_nodenum()
    time.sleep(2.0)  # let the API session settle + stream watcher warm up

    lat, lost = [], 0
    seq0 = random.randrange(1, 200)
    for i in range(args.n):
        seq = (seq0 + i) % 256
        t_send = base.send_cmd(dest, [0x03, args.pattern, seq])
        t_seen, line = tag.wait_for(rf"SIGRX pattern={args.pattern} seq={seq}\b", t_send, timeout=3.0)
        if t_seen is None:
            lost += 1
            print(f"  #{i + 1:02d} seq={seq:3d} LOST (3 s)")
        else:
            ms = (t_seen - t_send) * 1000
            lat.append(ms)
            print(f"  #{i + 1:02d} seq={seq:3d} {ms:7.1f} ms   [{line}]")
        time.sleep(random.uniform(1.2, 2.4))  # vary phase vs. the position stream

    print(f"\nstream rate during test: {base.stream_rate():.2f} pkt/s (flags=0x{base.stream_flags or 0:02x})")
    if lat:
        lat.sort()
        p90 = lat[int(0.9 * (len(lat) - 1))]
        print(f"downlink latency over {len(lat)} ok / {lost} lost:")
        print(f"  min {lat[0]:.0f} ms · median {statistics.median(lat):.0f} ms · p90 {p90:.0f} ms · max {lat[-1]:.0f} ms")
    else:
        print(f"NO commands arrived ({lost} lost) — is the tag on the downlink build?")
    tag.close()
    base.close()


def wait_flags(base, mask, want, timeout, label):
    """Wait until (stream_flags & mask) == want; returns elapsed or None."""
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        f = base.stream_flags
        if f is not None and (f & mask) == want:
            return time.monotonic() - t0
        time.sleep(0.05)
    print(f"  TIMEOUT waiting for {label} (flags=0x{(base.stream_flags or 0):02x})")
    return None


def run_mode(args):
    base = BaseLink(resolve_or_die("base"))
    tag = TagConsole(resolve_or_die("gpstag"))
    dest = tag_nodenum()
    time.sleep(2.5)
    print(f"stream flags now: 0x{(base.stream_flags or 0):02x} (bit2 = adaptive, bit3 = slow tier)")

    print("\n1) MODE -> CALIBRATION (ttl 20 s) — expect bit2 to CLEAR, then self-restore ~20 s later")
    t = base.send_cmd(dest, [0x02, 0x00, 20, 0])
    dt = wait_flags(base, 0x04, 0x00, timeout=8, label="calibration echo (bit2 clear)")
    if dt is not None:
        print(f"  echoed in the stream after {dt * 1000:.0f} ms")
    t_seen, line = tag.wait_for(r"MODE=CALIBRATION", t, timeout=3.0)
    if line:
        print(f"  tag log: {line}")

    print("  waiting for the TTL dead-man (~20 s, no refresh sent)…")
    dt = wait_flags(base, 0x04, 0x04, timeout=35, label="auto-revert to ADAPTIVE")
    if dt is not None:
        print(f"  REVERTED on its own after {dt:.1f} s — dead-man works")

    print("\n2) MODE -> ADAPTIVE explicitly (idempotent)")
    base.send_cmd(dest, [0x02, 0x01])
    dt = wait_flags(base, 0x04, 0x04, timeout=8, label="adaptive echo")
    if dt is not None:
        print(f"  confirmed in {dt * 1000:.0f} ms; stationary tag should engage slow tier (bit3) after ~15 s")
        dt2 = wait_flags(base, 0x08, 0x08, timeout=40, label="slow tier (needs GPS lock + stationary)")
        if dt2 is not None:
            print(f"  slow tier engaged after {dt2:.1f} s — watch the stream drop to ~0.3 pkt/s")

    print(f"\nstream rate over the test: {base.stream_rate():.2f} pkt/s")
    tag.close()
    base.close()


def run_oneshot(args, pattern):
    base = BaseLink(resolve_or_die("base"))
    dest = tag_nodenum()
    time.sleep(1.5)
    base.send_cmd(dest, [0x03, pattern, random.randrange(256)])
    time.sleep(1.0)
    base.close()
    print(f"pattern {pattern} sent")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("test", choices=["signal", "mode", "beep", "cancel"])
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--pattern", type=int, default=1)
    args = ap.parse_args()
    if args.test == "signal":
        run_signal(args)
    elif args.test == "mode":
        run_mode(args)
    elif args.test == "beep":
        run_oneshot(args, 3)
    else:
        run_oneshot(args, 5)


if __name__ == "__main__":
    main()
