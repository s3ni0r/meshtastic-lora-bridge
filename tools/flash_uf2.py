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


def matching_drives(exclude=()):
    out = []
    for v in glob.glob("/Volumes/*"):
        if v in exclude:
            continue
        info = os.path.join(v, "INFO_UF2.TXT")
        if not os.path.isfile(info):
            continue
        try:
            with open(info) as f:
                txt = f.read().lower()
        except OSError:
            continue
        if "t1000" in txt or "nrf52" in txt:
            out.append(v)
    return out


def wait_for_drive(timeout=30, pre_existing=()):
    """Exactly ONE matching NEW drive, or fail closed (review R3 finding 4): a pre-existing
    volume is never assumed to be the board we just touched, and ambiguity refuses."""
    print("[2/3] waiting for UF2 bootloader drive ...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        fresh = matching_drives(exclude=pre_existing)
        if len(fresh) == 1:
            return fresh[0]
        if len(fresh) > 1:
            sys.exit(f"ERROR: {len(fresh)} candidate bootloader volumes {fresh} — ambiguous, refusing.")
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
    if port.lower() in ("tag", "base", "gpstag"):  # resolve a role name to its port via nodes.py (USB serial)
        try:
            import nodes
            resolved = nodes.resolve(port)
        except ImportError:
            resolved = None
        if not resolved:
            sys.exit(f"node '{port}' not connected (or nodes.py missing)")
        print(f"resolved {port} -> {resolved}")
        port = resolved
    if not os.path.isfile(uf2):
        print("ERROR: uf2 not found:", uf2)
        sys.exit(2)

    if not no_touch:
        # Snapshot BEFORE the touch: only a volume that APPEARS afterwards can be the board we
        # reset — pre-existing drives are never trusted (review R3 finding 4).
        pre = tuple(matching_drives())
        touch_1200(port)
        time.sleep(2)
        drive = wait_for_drive(pre_existing=pre)
    else:
        # --no-touch: the device was put in DFU deliberately; require exactly one candidate.
        drives = matching_drives()
        if len(drives) > 1:
            sys.exit(f"ERROR: {len(drives)} candidate bootloader volumes {drives} — ambiguous, refusing.")
        drive = drives[0] if drives else wait_for_drive()
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
        # The drive often unmounts the instant the full image is received and the device
        # reboots — so the copy's outcome is NOT the truth signal; the unmount below is.
        print(f"      copy ended with {e!r} (normal if the device rebooted mid-copy)")
    # Truth signal: the bootloader unmounts the volume only when it ACCEPTED the image.
    deadline = time.time() + 15
    while time.time() < deadline:
        if not os.path.isdir(drive):
            print("DONE: bootloader accepted the image (volume unmounted); device is rebooting.")
            sys.exit(0)
        time.sleep(0.5)
    print(f"ERROR: {drive} never unmounted — flash NOT confirmed. Re-enter the bootloader and retry.")
    sys.exit(1)


if __name__ == "__main__":
    main()
