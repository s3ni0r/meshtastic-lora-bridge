#!/usr/bin/env python3
"""Dump a node's raw serial debug console for a few seconds.

    python serial_monitor.py /dev/cu.usbmodemXXXX [seconds]

Meshtastic multiplexes protobuf frames + text logs on the same CDC; protobuf bytes show as
garbage but DEBUG/INFO/WARN text lines are readable. Useful when the protocol handshake fails.
"""
import sys
import time

import serial

port = sys.argv[1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
s = serial.Serial(port, 115200, timeout=0.5)
end = time.time() + secs
while time.time() < end:
    data = s.read(4096)
    if data:
        sys.stdout.write(data.decode("utf-8", "replace"))
        sys.stdout.flush()
s.close()
