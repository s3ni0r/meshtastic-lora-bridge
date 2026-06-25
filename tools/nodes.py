#!/usr/bin/env python3
"""Identify the two T1000-E nodes by stable hardware ID, independent of /dev port name.

USB serial = the nRF52 chip serial; it survives reboot, reflash, and DFU, so it's the
reliable physical identifier (port names like usbmodem1112101 can shuffle on replug).

    python nodes.py                 # show current port <-> role mapping
    python nodes.py --port base     # print just the port for a role (for scripting/$())

Other tools import resolve()/registry() from here.
"""
import argparse
import sys

from serial.tools import list_ports

# Registry keyed on USB serial. Confirmed 2026-06-25 via `meshtastic --info`.
NODES = {
    "92EBF6B5B6C9AC37": {"role": "tag",  "name": "Tag",  "node_id": "!b4dbb54c",
                         "num": 3034297676, "mac": "db:d5:b4:db:b5:4c"},
    "4A8693CC387EBD66": {"role": "base", "name": "Base", "node_id": "!b0bb9cda",
                         "num": 2965085402, "mac": "fb:a7:b0:bb:9c:da"},
}
BY_ROLE = {v["role"]: sn for sn, v in NODES.items()}


def connected():
    """role -> {port, serial, name, node_id, num, mac} for currently-connected known nodes."""
    out = {}
    for p in list_ports.comports():
        sn = (p.serial_number or "").upper()
        if sn in NODES:
            out[NODES[sn]["role"]] = {"port": p.device, "serial": sn, **NODES[sn]}
    return out


def resolve(role):
    """Return the /dev port for 'tag' or 'base', or None if not connected."""
    return connected().get(role.lower(), {}).get("port")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", metavar="ROLE", help="print only the port path for tag|base")
    args = ap.parse_args()
    found = connected()

    if args.port:
        port = found.get(args.port.lower(), {}).get("port")
        if not port:
            sys.exit(f"{args.port} not connected")
        print(port)
        return

    if not found:
        print("No known nodes connected.")
    for role in ("tag", "base"):
        n = found.get(role)
        if n:
            print(f"  {n['name']:4} {n['node_id']}  serial={n['serial']}  ->  {n['port']}")
        else:
            print(f"  {role.capitalize():4} (serial {BY_ROLE[role]})  ->  not connected")


if __name__ == "__main__":
    main()
