"""Bridge sniffer scan-level stats — the SNIFF/LOC side of the coexistence A/B.

Reads the bridge's raw USB debug log (115200; PhoneAPI-free, safe alongside any BLE client)
for a bounded window and reports the ODID scanner's own counters:

  SNIFF cb=<callbacks> ext=<extended> loc=<Location decodes> in <ms>   (every ~5 s)
  ODID LOC cnt=.. dt=<ms> ...                                          (per NOVEL fix)

Usage:  .../python -u tools/bench/sniff_stats.py <label> [seconds]

Compare cb/s + loc/s + novelty dt across conditions (advertising on/off, BLE-connected).
"""
import re
import statistics
import sys
import time

import serial as pyserial

sys.path.insert(0, "tools")
import nodes

label = sys.argv[1] if len(sys.argv) > 1 else "run"
window = float(sys.argv[2]) if len(sys.argv) > 2 else 120.0

port = nodes.resolve("tag")
if not port:
    sys.exit("bridge not on USB")

sniff = []  # (cb, ext, loc, ms)
dts = []    # novel-fix inter-arrival, ms
raw = pyserial.Serial(port, 115200, timeout=1)
print(f"[{label}] reading {window:.0f}s of scanner stats from {port}…")
buf = b""
t0 = time.monotonic()
last_report = t0
while time.monotonic() - t0 < window:
    buf += raw.read(2048)
    if time.monotonic() - last_report >= 15:
        print(f"  t={time.monotonic()-t0:5.0f}s sniff_lines={len(sniff)} novel={len(dts)}")
        last_report = time.monotonic()
    # consume complete lines only; keep the tail fragment
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        m = re.search(rb"SNIFF cb=(\d+) ext=(\d+) loc=(\d+) in (\d+)ms", line)
        if m:
            sniff.append(tuple(int(x) for x in m.groups()))
        m = re.search(rb"ODID LOC cnt=\d+ dt=(\d+)ms", line)
        if m:
            dt = int(m.group(1))
            if dt:  # 0 = first fix, no interval yet
                dts.append(dt)
raw.close()

cb = sum(s[0] for s in sniff)
ext = sum(s[1] for s in sniff)
loc = sum(s[2] for s in sniff)
span_s = sum(s[3] for s in sniff) / 1000.0
print(f"[{label}] RESULT over {span_s:.1f}s of scanner time:")
if span_s:
    print(f"  callbacks {cb} = {cb/span_s:.2f}/s | extended {ext} = {ext/span_s:.2f}/s | "
          f"Location decodes {loc} = {loc/span_s:.2f}/s")
if dts:
    print(f"  novel-fix dt: median {statistics.median(dts):.0f} ms · mean {statistics.mean(dts):.0f} ms "
          f"· n={len(dts)} (≈{1000/statistics.median(dts):.2f} novel/s)")
else:
    print("  no novel-fix lines seen (Dronetag off or out of range?)")
