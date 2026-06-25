#!/usr/bin/env python3
"""Read the T1000-E ODID-sniffer serial log and measure Remote ID position novelty.

Parses the firmware's `ODID LOC ...` lines (NRF52Bluetooth.cpp sniffer) and reports the advert
arrival rate, BLE RSSI, whether a GPS fix is present, and the genuine position-novelty rate
(distinct lat/lon per second) plus the ODID TimeStamp novelty.

Usage: odid_sniff.py <port|tag|base> [seconds]
"""
import serial, time, sys, re, subprocess, os

arg = sys.argv[1] if len(sys.argv) > 1 else "tag"
dur = int(sys.argv[2]) if len(sys.argv) > 2 else 30

# resolve tag/base via nodes.py
port = arg
if arg in ("tag", "base"):
    here = os.path.dirname(os.path.abspath(__file__))
    py = os.path.expanduser("~/.local/pipx/venvs/meshtastic/bin/python")
    port = subprocess.check_output([py, os.path.join(here, "nodes.py"), "--port", arg]).decode().strip()

pat = re.compile(r"ODID LOC cnt=(\d+) dt=(\d+)ms lat=(-?\d+) lon=(-?\d+) ts=([\d.]+)s .*rssi=(-?\d+)")
rows = []
t0 = time.time()
try:
    s = serial.Serial(port, 115200, timeout=0.2)
except Exception as e:
    print("open fail:", e); sys.exit(1)
while time.time() - t0 < dur:
    d = s.read(4096)
    if not d:
        continue
    now = time.time()
    for line in d.decode("utf-8", "replace").splitlines():
        m = pat.search(line)
        if m:
            rows.append((now, int(m.group(1)), int(m.group(3)), int(m.group(4)), float(m.group(5)), int(m.group(6))))

n = len(rows)
print(f"port {port} | LOC adverts: {n} in {dur}s")
if n < 2:
    print("  too few — BLE link weak (Dronetag too far?) or not broadcasting Location yet")
    sys.exit()
span = rows[-1][0] - rows[0][0] or 1e-9
print(f"  advert arrival rate : {(n-1)/span:.1f} Hz")
rssis = [r[5] for r in rows]
print(f"  BLE RSSI            : min {min(rssis)}  max {max(rssis)}  avg {sum(rssis)/len(rssis):.0f} dBm")
fix = any(r[2] != 0 or r[3] != 0 for r in rows)
print(f"  GPS fix acquired    : {fix}")

def novelty(vals, times):
    dv, dt = [], []
    for v, t in zip(vals, times):
        if not dv or v != dv[-1]:
            dv.append(v); dt.append(t)
    return dv, dt

ts_d, _ = novelty([r[4] for r in rows], [r[0] for r in rows])
if len(ts_d) >= 2:
    print(f"  ODID-timestamp rate : {len(ts_d)} distinct = {(len(ts_d)-1)/span:.2f} Hz")

if fix:
    coords = [(r[2], r[3]) for r in rows if r[2] or r[3]]
    ctimes = [r[0] for r in rows if r[2] or r[3]]
    cd, ct = novelty(coords, ctimes)
    if len(cd) >= 2:
        pspan = ct[-1] - ct[0] or 1e-9
        print(f"  >>> POSITION NOVELTY: {len(cd)} distinct fixes = {(len(cd)-1)/pspan:.2f} Hz <<<")
        for c in cd[:6]:
            print(f"      {c[0]/1e7:.6f}, {c[1]/1e7:.6f}")
