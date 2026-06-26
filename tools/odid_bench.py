#!/usr/bin/env python3
"""Benchmark the ODID sniffer over a long window: scan-callback load, extended/legacy split, parse
work, and fresh-fix rate. Run once per PHY build (BT4 legacy vs BT5 extended) and compare.

Parses two firmware log lines:
  SNIFF cb=<all callbacks> ext=<extended> loc=<Location decoded> in <ms>
  ODID LOC ... ts=<fix timestamp> lat=.. lon=..

Usage: odid_bench.py <tag|base|port> [seconds]
"""
import serial, time, sys, re, subprocess, os

arg = sys.argv[1] if len(sys.argv) > 1 else "tag"
dur = int(sys.argv[2]) if len(sys.argv) > 2 else 90
port = arg
if arg in ("tag", "base"):
    here = os.path.dirname(os.path.abspath(__file__))
    py = os.path.expanduser("~/.local/pipx/venvs/meshtastic/bin/python")
    port = subprocess.check_output([py, os.path.join(here, "nodes.py"), "--port", arg]).decode().strip()

re_sniff = re.compile(r"SNIFF cb=(\d+) ext=(\d+) loc=(\d+) in (\d+)ms")
re_loc = re.compile(r"ODID LOC cnt=(\d+) dt=(\d+)ms ts=(\d+) lat=(-?\d+) lon=(-?\d+)")
S, L = [], []
t0 = time.time()
s = serial.Serial(port, 115200, timeout=0.2)
while time.time() - t0 < dur:
    d = s.read(4096)
    if not d:
        continue
    now = time.time()
    for line in d.decode("utf-8", "replace").splitlines():
        m = re_sniff.search(line)
        if m:
            S.append(tuple(int(x) for x in m.groups()))
        m = re_loc.search(line)
        if m:
            L.append((now, int(m.group(3))))

print(f"port {port} | window {dur}s | SNIFF samples={len(S)}  ODID-LOC={len(L)}")
if S:
    cb = sum(x[0] for x in S); ext = sum(x[1] for x in S); loc = sum(x[2] for x in S)
    sec = sum(x[3] for x in S) / 1000 or 1
    print(f"  scan callbacks : {cb/sec:5.1f}/s   (extended {ext/sec:.1f}/s, legacy {(cb-ext)/sec:.1f}/s)")
    print(f"  PARSE work     : {(ext if ext else cb)/sec:5.1f}/s   (packets actually parsed)")
    print(f"  Location decode: {loc/sec:5.1f}/s")
if len(L) >= 3:
    span = L[-1][0] - L[0][0] or 1
    dts = []
    for _, ts in L:
        if not dts or ts != dts[-1]:
            dts.append(ts)
    print(f"  fresh-fix rate : {(len(dts)-1)/span:5.2f} Hz   (distinct fix timestamps — the real refresh)")
    print(f"  advert rate    : {(len(L)-1)/span:5.2f} Hz   (Location adverts decoded)")
elif not S:
    print("  no data — is the Dronetag broadcasting (sim running) and co-located?")
