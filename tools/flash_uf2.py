#!/usr/bin/env python3
"""
Flash a .uf2 to an nRF52 (T1000-E) by triggering the UF2 bootloader via a 1200-baud touch,
then copying the file to the mounted bootloader drive. Hands-free (no button double-tap) when
the running firmware supports the TinyUSB 1200bps-touch-to-DFU reset.

    python flash_uf2.py /dev/cu.usbmodemXXXX /path/to/firmware.uf2

If no drive mounts within the timeout, double-tap the device button to force the bootloader,
then re-run (the touch step is harmless if it's already in the bootloader).
"""
import glob
import os
import shutil
import sys
import time

import serial


def touch_1200(port):
    print(f"[1/3] 1200bps touch on {port} ...")
    try:
        s = serial.Serial(port, 1200)
        s.setDTR(False)
        time.sleep(0.3)
        s.close()
    except Exception as e:
        print(f"      (touch raised {e!r} — ok if already in bootloader)")


def wait_for_drive(timeout=30):
    print("[2/3] waiting for UF2 bootloader drive ...")
    deadline = time.time() + timeout
    seen_before = set(glob.glob("/Volumes/*"))
    while time.time() < deadline:
        for v in glob.glob("/Volumes/*"):
            if os.path.isfile(os.path.join(v, "INFO_UF2.TXT")):
                return v
        time.sleep(1)
    return None


def main():
    args = sys.argv[1:]
    no_touch = False
    if args and args[0] == "--no-touch":  # device already sent to DFU (e.g. via `meshtastic --enter-dfu`)
        no_touch = True
        args = args[1:]
    if len(args) != 2:
        print(__doc__)
        sys.exit(2)
    port, uf2 = args
    if not os.path.isfile(uf2):
        print("ERROR: uf2 not found:", uf2)
        sys.exit(2)

    if not no_touch:
        touch_1200(port)
        time.sleep(2)
    drive = wait_for_drive()
    if not drive:
        print("ERROR: no UF2 drive appeared. Double-tap the button to enter the bootloader, then re-run.")
        sys.exit(1)

    print(f"      bootloader drive: {drive}")
    try:
        with open(os.path.join(drive, "INFO_UF2.TXT")) as f:
            print("      " + f.read().strip().replace("\n", "\n      "))
    except Exception:
        pass

    dest = os.path.join(drive, os.path.basename(uf2))
    size = os.path.getsize(uf2)
    print(f"[3/3] copying {size} bytes -> {dest}")
    try:
        shutil.copy(uf2, dest)
        try:
            os.sync()
        except Exception:
            pass
    except OSError as e:
        # The drive often unmounts the instant the full image is received and the device reboots.
        print(f"      copy ended with {e!r} — this is normal if the device rebooted after flashing.")
    print("DONE. Device is flashing and will reboot in a few seconds.")


if __name__ == "__main__":
    main()
