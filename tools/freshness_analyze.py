#!/usr/bin/env python3
"""Analyze GPS freshness from a stream-capture CSV (from m2_stream_poc.py recv).

    python freshness_analyze.py [docs/freshness.csv]

Reports novelty rate (genuinely new positions/sec), staleness age per packet (how
old the reported position is when sent), longest frozen run, the lock(fresh)
fraction, and coordinate jitter — to tell real-time freshness from stale-as-live.
"""
import csv
import statistics as st
import sys


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "docs/freshness.csv"
    rows = [r for r in csv.DictReader(open(path)) if r.get("lat") and float(r["lat"]) != 0]
    n = len(rows)
    if n < 3:
        print("not enough locked packets:", n)
        return
    t = [float(r["host_time"]) for r in rows]
    span = t[-1] - t[0]
    rate = (n - 1) / span if span else 0
    print(f"file: {path}")
    print(f"packets (w/coords): {n}   span {span:.0f}s   packet-rate {rate:.2f} Hz")

    last_change = t[0]
    intervals, ages = [], []
    frozen = maxfrozen = 0
    prev = None
    for i, r in enumerate(rows):
        key = (r["lat"], r["lon"])
        if key != prev:
            if prev is not None:
                intervals.append(t[i] - last_change)
            last_change = t[i]
            prev = key
            frozen = 0
        else:
            frozen += 1
            maxfrozen = max(maxfrozen, frozen)
        ages.append(t[i] - last_change)

    nov = len(intervals) + 1
    print(f"novelty rate: ~{nov / span:.2f} Hz   ({nov} genuinely new positions)")
    if intervals:
        print(f"inter-fix interval: median {st.median(intervals):.2f}s  min {min(intervals):.2f}s  max {max(intervals):.2f}s")
    print(f"staleness age/packet: median {st.median(ages):.2f}s  p95 {sorted(ages)[int(0.95 * len(ages))]:.2f}s  MAX {max(ages):.2f}s")
    print(f"longest frozen run: {maxfrozen} packets (~{maxfrozen / rate:.1f}s)" if rate else "")
    fresh = sum(1 for r in rows if int(r.get("flags", 0)) & 1)
    print(f"lock=1 (fresh): {fresh}/{n} = {100 * fresh / n:.0f}%")
    lat = [float(r["lat"]) for r in rows]
    lon = [float(r["lon"]) for r in rows]
    print(f"coord jitter: lat spread {(max(lat) - min(lat)) * 111000:.1f}m  lon spread {(max(lon) - min(lon)) * 111000 * 0.72:.1f}m")
    sats = [int(r["sats"]) for r in rows if r.get("sats")]
    if sats:
        print(f"sats: {min(sats)}-{max(sats)}")


if __name__ == "__main__":
    main()
