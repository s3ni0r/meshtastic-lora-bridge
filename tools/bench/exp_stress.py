#!/usr/bin/env python
"""EXP-mediumfast-2hz-range — instrumented stress run (bridge -> LoRa -> Base).

Captures BOTH raw USB logs concurrently (no PhoneAPI sessions — a BLE-connected
phone does not disturb this) and computes matched-packet delivery:

  bridge log:  'Started Tx (id=0x....)' for our stream packets  -> sent-id set
               'Packet TX: Nms'                                 -> measured airtime
               'ODID LOC'                                       -> sniff source rate
               'N packets remain in the TX queue'               -> pileup detector
  base log:    'Lora RX (id=0x... fr=0xb4dbb54c'                -> received-id set
               'rxSNR=x rxRSSI=y'                               -> link margin stats

Preconditions: Dronetag beacon ON (the bridge only relays sniffed fixes); phone app
NOT holding either node's USB PhoneAPI. Run from repo root with the pipx python.

Usage: exp_stress.py [duration_s]      (default 1800)

Verdict (exit 0 requires ALL):
  - delivery (matched ids) >= 95 %  (same-room bench: anything less is a real problem)
  - achieved TX rate 1.6-2.4 Hz     (the 500 ms spacing cap doing its job)
  - median airtime 100-220 ms       (proves the modem really runs MEDIUM_FAST)
  - no sustained TX-queue pileup    (queue depth >= 3 in >1 % of samples fails)
"""
import re
import sys
import threading
import time

sys.path.insert(0, "tools")
import nodes
import serial as pyserial

_args = [a for a in sys.argv[1:] if a != "--smoke"]
DURATION = int(_args[0]) if _args else 1800
BRIDGE_HEX = "0xb4dbb54c"

state = {
    "sent_ids": set(), "airtimes": [], "odid": 0, "queue_hits": 0, "queue_samples": 0,
    "rx_ids": set(), "snr": [], "rssi": [],
    "bridge_bytes": 0, "base_bytes": 0, "stop": False, "err": [],
}
lock = threading.Lock()

RE_TX = re.compile(r"Started Tx \(id=(0x[0-9a-f]+) fr=" + BRIDGE_HEX)
RE_AIR = re.compile(r"Packet TX: (\d+)ms")
RE_ODID = re.compile(r"ODID LOC")
RE_QUEUE = re.compile(r"(\d+) packets? remain in the TX queue")
# The base flavor's RadioIf line carries rxSNR but NOT always rxRSSI (verified on
# hardware 2026-07-28: '... len=43 rxSNR=12.75 hopStart=1 relay=0x4c)') — RSSI optional.
RE_RX = re.compile(r"Lora RX \(id=(0x[0-9a-f]+) fr=" + BRIDGE_HEX
                   + r"[^\n]*?rxSNR=(-?[\d.]+)(?: rxRSSI=(-?\d+))?")


def reader(role, port, key):
    try:
        raw = pyserial.Serial(port, 115200, timeout=2)
        buf = b""
        while not state["stop"]:
            chunk = raw.read(4096)
            if not chunk:
                continue
            buf += chunk
            *lines, buf = buf.split(b"\n")
            for lb in lines:
                line = lb.decode("utf-8", "replace")
                with lock:
                    state[key] += len(lb) + 1
                    if key == "bridge_bytes":
                        m = RE_TX.search(line)
                        if m:
                            state["sent_ids"].add(m.group(1))
                        m = RE_AIR.search(line)
                        if m:
                            state["airtimes"].append(int(m.group(1)))
                        if RE_ODID.search(line):
                            state["odid"] += 1
                        m = RE_QUEUE.search(line)
                        if m:
                            state["queue_samples"] += 1
                            if int(m.group(1)) >= 3:
                                state["queue_hits"] += 1
                    else:
                        m = RE_RX.search(line)
                        if m:
                            state["rx_ids"].add(m.group(1))
                            state["snr"].append(float(m.group(2)))
                            if m.group(3) is not None:
                                state["rssi"].append(int(m.group(3)))
        raw.close()
    except Exception as e:
        with lock:
            state["err"].append(f"{role}: {e!r}")


def stats():
    with lock:
        sent, rxd = len(state["sent_ids"]), len(state["sent_ids"] & state["rx_ids"])
        airs = sorted(state["airtimes"])
        med_air = airs[len(airs) // 2] if airs else None
        snr = state["snr"]
        return {
            "sent": sent, "matched": rxd,
            "delivery": (rxd / sent) if sent else 0.0,
            "med_air": med_air,
            "snr_min": min(snr) if snr else None,
            "snr_mean": (sum(snr) / len(snr)) if snr else None,
            "odid": state["odid"],
            "pileup": (state["queue_hits"] / state["queue_samples"]) if state["queue_samples"] else 0.0,
            "errs": list(state["err"]),
        }


def main():
    smoke = "--smoke" in sys.argv
    # Resolve BEFORE spawning threads (sequential — resolves must never race) and print
    # the pinned ports so a wrong/silent reader is visible immediately.
    ports = {}
    for role in ("tag", "base"):
        ports[role] = nodes.resolve(role)
        print(f"[stress] {role} -> {ports[role]}", flush=True)
        if not ports[role]:
            print(f"[stress] FATAL: {role} not on USB", flush=True)
            sys.exit(1)
    t_bridge = threading.Thread(target=reader, args=("tag", ports["tag"], "bridge_bytes"), daemon=True)
    t_base = threading.Thread(target=reader, args=("base", ports["base"], "base_bytes"), daemon=True)
    t0 = time.monotonic()
    t_bridge.start()
    t_base.start()
    print(f"[stress] running {DURATION}s (MEDIUM_FAST @ 2 Hz cap expected)"
          + (" [SMOKE: delivery+airtime gates only]" if smoke else ""), flush=True)
    last_sent = 0
    try:
        while time.monotonic() - t0 < DURATION:
            time.sleep(30)
            s = stats()
            el = time.monotonic() - t0
            rate = (s["sent"] - last_sent) / 30.0
            last_sent = s["sent"]
            with lock:
                io = f"io={state['bridge_bytes']}/{state['base_bytes']}B"
            print(f"[stress] t={el:5.0f}s sent={s['sent']} matched={s['matched']} "
                  f"delivery={s['delivery']*100:5.1f}% rate={rate:.2f}/s "
                  f"airtime~{s['med_air']}ms snr(min/mean)={s['snr_min']}/{None if s['snr_mean'] is None else round(s['snr_mean'],1)} "
                  f"odid={s['odid']} pileup={s['pileup']*100:.1f}% {io}", flush=True)
            if s["errs"]:
                print(f"[stress] !!! reader errors: {s['errs']}", flush=True)
                break
            with lock:
                if el > 45 and (state["bridge_bytes"] == 0 or state["base_bytes"] == 0):
                    state["err"].append("a reader captured 0 bytes — silent CDC or wrong port")
                    print("[stress] !!! a reader captured 0 bytes — aborting", flush=True)
                    break
            if not smoke and el > 90 and s["odid"] == 0:
                print("[stress] !!! no ODID callbacks — Dronetag beacon off? aborting", flush=True)
                break
    finally:
        state["stop"] = True
        time.sleep(3)

    s = stats()
    dur = time.monotonic() - t0
    overall_rate = s["sent"] / dur if dur else 0
    print(f"[stress] ---- verdict after {dur:.0f}s ----", flush=True)
    print(f"[stress] sent={s['sent']} matched={s['matched']} delivery={s['delivery']*100:.2f}% "
          f"overall_rate={overall_rate:.2f}/s med_airtime={s['med_air']}ms "
          f"snr_min={s['snr_min']} snr_mean={None if s['snr_mean'] is None else round(s['snr_mean'],1)} "
          f"pileup={s['pileup']*100:.2f}%", flush=True)
    gates = (s["delivery"] >= 0.95
             and s["med_air"] is not None and 100 <= s["med_air"] <= 220
             and s["pileup"] <= 0.01 and not s["errs"])
    if not smoke:
        gates = gates and 1.6 <= overall_rate <= 2.4
    print(f"[stress] RESULT: {'PASS' if gates else 'FAIL'}"
          + (" (smoke — rerun full test with the Dronetag ON for the 2 Hz gate)" if smoke and gates else ""),
          flush=True)
    sys.exit(0 if gates else 1)


if __name__ == "__main__":
    main()
