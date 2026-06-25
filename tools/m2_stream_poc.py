#!/usr/bin/env python3
"""
M2 — Custom-stream proof of concept.

Proves the project's core architecture: stream position over LoRa on a custom PRIVATE_APP
portnum (256) at a target rate, bypassing Meshtastic's PositionModule throttles. Works on STOCK
firmware (host-injected via the serial API) — no fork needed to validate the rate/PDR path.

    pip install meshtastic            # provides the lib + pypubsub + pyserial

Single machine, both nodes on USB (recommended):
    python m2_stream_poc.py both \
        --send-port /dev/cu.usbmodem1112101 --recv-port /dev/cu.usbmodem1112201 \
        --rate 2 --count 60 --csv docs/m2_run1.csv

Two machines:
    python m2_stream_poc.py recv --port <recv-node> --duration 50 --csv run.csv
    python m2_stream_poc.py send --port <send-node> --rate 2 --count 60

12-byte payload (matches the firmware fork + iOS client):
    <i lat int32 deg*1e7 | <i lon int32 deg*1e7 | <H ms-in-sec | <B seq | <B flags

Rate and PDR are clock-independent. Latency needs a shared/synced clock (single-host is fine).
"""
import argparse
import struct
import sys
import time

PRIVATE_APP = 256
# Payload formats (little-endian). Extended adds alt/speed/heading/hacc; base = lat/lon/ms/seq/flags.
PAYLOAD_FMT_V1 = "<iiHBB"
PAYLOAD_FMT_V2 = "<iiHBBhBBB"
V1_LEN = struct.calcsize(PAYLOAD_FMT_V1)  # 12
V2_LEN = struct.calcsize(PAYLOAD_FMT_V2)  # 17
WARMUP_S = 4.0  # let the receiver's serial interface connect before streaming


def to_port(value):
    """Accept a /dev path OR a role name ('tag'/'base') resolved via nodes.py (USB serial)."""
    if value and value.lower() in ("tag", "base"):
        try:
            import nodes
        except ImportError:
            sys.exit("nodes.py not found — run from the tools/ dir or repo root")
        port = nodes.resolve(value)
        if not port:
            sys.exit(f"node '{value}' not connected")
        return port
    return value


def open_iface(port):
    import meshtastic.serial_interface
    return meshtastic.serial_interface.SerialInterface(devPath=to_port(port))


def pack(lat, lon, seq):
    ms_in_sec = int((time.time() % 1.0) * 1000) & 0xFFFF
    # v2 payload; metrics are simulated for host-injection tests
    return struct.pack(PAYLOAD_FMT_V2, int(lat * 1e7), int(lon * 1e7), ms_in_sec, seq & 0xFF, 0x01,
                       12, 5, 64, 3)  # alt=12m speed=5km/h heading=64(->90deg) hacc=3m


class Receiver:
    """Subscribes to incoming PRIVATE_APP packets and tallies rate / PDR / SNR."""

    def __init__(self, only_iface=None, csv_path=None):
        self.only_iface = only_iface
        self.rx = 0
        self.seen = set()
        self.first_t = None
        self.last_t = None
        self.snrs = []
        self.rssis = []
        self.csv = open(csv_path, "w") if csv_path else None
        if self.csv:
            self.csv.write("host_time,from,seq,lat,lon,alt_m,speed_kmh,heading,hacc_m,ms_in_sec,flags,rx_snr,rx_rssi\n")

    def on_receive(self, packet, interface=None):
        if self.only_iface is not None and interface is not self.only_iface:
            return  # ignore the sender interface's own echoes
        d = packet.get("decoded") or {}
        if d.get("portnum") not in ("PRIVATE_APP", PRIVATE_APP):
            return
        payload = d.get("payload")
        if not payload or len(payload) < V1_LEN:
            return
        alt = spd = hacc = 0
        heading = 0.0
        if len(payload) >= V2_LEN:
            lat_i, lon_i, off, seq, flags, alt, spd, hdg, hacc = struct.unpack(PAYLOAD_FMT_V2, payload[:V2_LEN])
            heading = hdg * 360.0 / 256.0
        else:
            lat_i, lon_i, off, seq, flags = struct.unpack(PAYLOAD_FMT_V1, payload[:V1_LEN])
        lat, lon = lat_i / 1e7, lon_i / 1e7
        now = time.monotonic()
        if self.first_t is None:
            self.first_t = now
        self.last_t = now
        self.rx += 1
        self.seen.add(seq)
        snr, rssi = packet.get("rxSnr"), packet.get("rxRssi")
        if snr is not None:
            self.snrs.append(snr)
        if rssi is not None:
            self.rssis.append(rssi)
        print(f"  rx seq={seq:3d} lat={lat:.6f} lon={lon:.6f} spd={spd}km/h hdg={heading:3.0f} "
              f"alt={alt}m ±{hacc}m snr={snr} rssi={rssi}")
        if self.csv:
            self.csv.write(f"{time.time():.3f},{packet.get('from')},{seq},{lat:.7f},{lon:.7f},"
                           f"{alt},{spd},{heading:.0f},{hacc},{off},{flags},{snr},{rssi}\n")
            self.csv.flush()

    def summary(self, sent=None):
        if self.csv:
            c, self.csv = self.csv, None  # prevent late callbacks writing to a closed file
            c.close()
        span = (self.last_t - self.first_t) if (self.first_t and self.last_t and self.last_t > self.first_t) else 0
        rate = (self.rx - 1) / span if span > 0 else 0.0
        print("\n--- M2 receiver summary ---")
        print(f"  received      : {self.rx} packets ({len(self.seen)} unique seq)")
        if sent:
            print(f"  sent          : {sent}")
            print(f"  PDR           : {100.0 * len(self.seen) / sent:.1f}%  (unique/sent)")
        print(f"  effective rate: {rate:.2f} Hz  (over {span:.1f}s active window)")
        if self.snrs:
            print(f"  SNR           : avg {sum(self.snrs)/len(self.snrs):.1f} dB  (min {min(self.snrs)}, max {max(self.snrs)})")
        if self.rssis:
            print(f"  RSSI          : avg {sum(self.rssis)/len(self.rssis):.0f} dBm (min {min(self.rssis)}, max {max(self.rssis)})")


def stream(iface, rate, count, duration, channel):
    period = 1.0 / rate
    lat, lon = 43.4897, -1.4942  # arbitrary start; walks north to animate
    seq = n = 0
    t0 = time.monotonic()
    while True:
        if count and n >= count:
            break
        if duration and (time.monotonic() - t0) >= duration:
            break
        tick = time.monotonic()
        iface.sendData(pack(lat, lon, seq), portNum=PRIVATE_APP, wantAck=False,
                       hopLimit=1, channelIndex=channel)
        n += 1
        seq = (seq + 1) & 0xFF
        lat += 0.00001
        if n % max(1, int(rate * 5)) == 0:
            print(f"  tx {n} pkts, {n / (time.monotonic() - t0):.2f} Hz")
        slp = period - (time.monotonic() - tick)
        if slp > 0:
            time.sleep(slp)
    return n, n / (time.monotonic() - t0)


def cmd_both(args):
    from pubsub import pub
    print(f"both: recv={args.recv_port} send={args.send_port} rate={args.rate}Hz count={args.count}")
    recv_iface = open_iface(args.recv_port)
    receiver = Receiver(only_iface=recv_iface, csv_path=args.csv)
    pub.subscribe(receiver.on_receive, "meshtastic.receive")
    send_iface = open_iface(args.send_port)
    print(f"warmup {WARMUP_S:.0f}s...")
    time.sleep(WARMUP_S)
    print("streaming...")
    sent, tx_rate = stream(send_iface, args.rate, args.count, args.duration, args.channel)
    print(f"sent {sent} packets at {tx_rate:.2f} Hz; draining 3s...")
    time.sleep(3)
    receiver.summary(sent=sent)
    send_iface.close()
    recv_iface.close()


def cmd_send(args):
    iface = open_iface(args.port)
    print(f"send: portNum={PRIVATE_APP} rate={args.rate}Hz count={args.count or '∞'}")
    sent, tx_rate = stream(iface, args.rate, args.count, args.duration, args.channel)
    print(f"sent {sent} packets at {tx_rate:.2f} Hz")
    iface.close()


def cmd_recv(args):
    from pubsub import pub
    receiver = Receiver(csv_path=args.csv)
    pub.subscribe(receiver.on_receive, "meshtastic.receive")
    iface = open_iface(args.port)
    print(f"recv: listening on {args.port} for {args.duration or '∞'}s")
    t0 = time.monotonic()
    try:
        while not args.duration or (time.monotonic() - t0) < args.duration:
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    receiver.summary()
    iface.close()


def main():
    p = argparse.ArgumentParser(description="M2 custom PRIVATE_APP stream POC")
    sub = p.add_subparsers(dest="cmd", required=True)

    pb = sub.add_parser("both", help="drive sender + receiver together on one machine")
    pb.add_argument("--send-port", required=True)
    pb.add_argument("--recv-port", required=True)
    pb.add_argument("--rate", type=float, default=2.0)
    pb.add_argument("--count", type=int, default=60, help="packets to send (0 = until --duration)")
    pb.add_argument("--duration", type=float, default=0, help="seconds (0 = until --count)")
    pb.add_argument("--channel", type=int, default=0)
    pb.add_argument("--csv")
    pb.set_defaults(func=cmd_both)

    ps = sub.add_parser("send", help="stream from the moving node")
    ps.add_argument("--port", required=True)
    ps.add_argument("--rate", type=float, default=2.0)
    ps.add_argument("--count", type=int, default=0)
    ps.add_argument("--duration", type=float, default=0)
    ps.add_argument("--channel", type=int, default=0)
    ps.set_defaults(func=cmd_send)

    pr = sub.add_parser("recv", help="receive + log on the iPhone-side node")
    pr.add_argument("--port", required=True)
    pr.add_argument("--duration", type=float, default=0)
    pr.add_argument("--channel", type=int, default=0)
    pr.add_argument("--csv")
    pr.set_defaults(func=cmd_recv)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
