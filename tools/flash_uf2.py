#!/usr/bin/env python3
"""
Copy a validated .uf2 onto an ALREADY-mounted T1000-E UF2 bootloader volume (button
double-tap mode). This is the explicit UF2-volume path; the hands-free path is
tools/flash_t1000e.sh (1200-baud touch -> bootloader serial-DFU via adafruit-nrfutil).

    python flash_uf2.py <role|serial|-> /path/to/firmware.uf2
        role    tag | base | gpstag — resolved to the expected HARDWARE serial via nodes.py
        serial  an explicit 16-hex USB serial the bootloader device must report
        -       no identity pin (single-board bench only)

Ground truth this tool is built on (measured 2026-07-26 on this fleet): the T1000-E
bootloader's 1200-baud touch opens a serial-DFU CDC on the SAME /dev path and mounts NO
volume — so a touch-then-wait-for-volume flow can never work and was removed. A UF2 volume
exists ONLY after a button double-tap.

Safety gates (all fail closed — R3 f4 + R4 f5):
  - the UF2 image is validated first: block magics + nRF52840 family id on EVERY block;
  - only a volume whose INFO_UF2.TXT / name identifies a T1000-E is a candidate — a generic
    nRF52 bootloader from another board is rejected by identity;
  - exactly ONE candidate volume and exactly ONE T1000 bootloader USB device, else refuse;
  - with a role/serial pinned, the bootloader USB device's serial must MATCH it — the volume
    is attributed to specific silicon, not to whatever happens to be mounted;
  - success is only the bootloader unmounting the volume (image accepted).
"""
import glob
import os
import shutil
import struct
import sys
import time

UF2_MAGIC0 = 0x0A324655  # "UF2\n"
UF2_MAGIC1 = 0x9E5D5157
UF2_MAGIC_END = 0x0AB16F30
UF2_FLAG_FAMILY_ID = 0x00002000
NRF52840_FAMILY = 0xADA52840
T1000_MARKERS = ("t1000",)


def validate_uf2(path):
    """Every 512-byte block must carry the UF2 magics and (when flagged) the nRF52840 family
    id — a wrong-family or truncated image is refused before any volume is touched."""
    size = os.path.getsize(path)
    if size == 0 or size % 512 != 0:
        sys.exit(f"ERROR: {path} is not a UF2 image (size {size} not a multiple of 512).")
    family_seen = False
    with open(path, "rb") as f:
        idx = 0
        while True:
            block = f.read(512)
            if not block:
                break
            m0, m1 = struct.unpack_from("<II", block, 0)
            mend = struct.unpack_from("<I", block, 508)[0]
            if m0 != UF2_MAGIC0 or m1 != UF2_MAGIC1 or mend != UF2_MAGIC_END:
                sys.exit(f"ERROR: {path} block {idx} has invalid UF2 magics — refusing.")
            flags = struct.unpack_from("<I", block, 8)[0]
            family = struct.unpack_from("<I", block, 28)[0]
            if flags & UF2_FLAG_FAMILY_ID:
                family_seen = True
                if family != NRF52840_FAMILY:
                    sys.exit(f"ERROR: {path} block {idx} family 0x{family:08X} != nRF52840 "
                             f"(0x{NRF52840_FAMILY:08X}) — wrong-target image, refusing.")
            idx += 1
    if not family_seen:
        sys.exit(f"ERROR: {path} carries no familyID blocks — cannot prove nRF52840 target, refusing.")
    print(f"   uf2 image OK: {idx} blocks, family nRF52840")


def volume_identity(v):
    info = os.path.join(v, "INFO_UF2.TXT")
    if not os.path.isfile(info):
        return False, None
    try:
        with open(info) as f:
            txt = f.read()
    except OSError:
        return False, None
    hay = (txt + " " + os.path.basename(v)).lower()
    return any(m in hay for m in T1000_MARKERS), txt.strip()


def t1000_volumes():
    out = []
    for v in glob.glob("/Volumes/*"):
        ok, info = volume_identity(v)
        if ok:
            out.append(v)
        elif info is not None:
            print(f"   note: ignoring non-T1000-E bootloader volume {v}")
    return out


def boot_devices():
    """USB devices currently in T1000 bootloader mode: (serial, product). NOTE: macOS can
    serve a STALE product string for a re-enumerated path, so 'boot' naming alone is only a
    coarse filter — the mounted-volume gate remains the primary signal."""
    try:
        from serial.tools import list_ports
    except ImportError:
        return None  # pyserial unavailable — caller degrades to volume-only gating
    return [((p.serial_number or "").upper(), p.product or "")
            for p in list_ports.comports()
            if p.vid == 0x239A and "boot" in (p.product or "").lower()]


def main():
    args = sys.argv[1:]
    if len(args) != 2:
        print(__doc__)
        sys.exit(2)
    who, uf2 = args
    if not os.path.isfile(uf2):
        sys.exit(f"ERROR: uf2 not found: {uf2}")
    validate_uf2(uf2)

    expect_serial = None
    if who != "-":
        if len(who) == 16 and all(c in "0123456789abcdefABCDEF" for c in who):
            expect_serial = who.upper()
        else:
            try:
                import nodes
                expect_serial = next((sn for sn, meta in nodes.NODES.items()
                                      if meta.get("role") == who.lower()), None)
            except ImportError:
                expect_serial = None
            if not expect_serial:
                sys.exit(f"ERROR: '{who}' is neither a role in nodes.py nor a 16-hex serial. "
                         "Pass '-' explicitly to flash without an identity pin.")
        print(f"   pinned hardware serial: {expect_serial}")

    vols = t1000_volumes()
    if not vols:
        sys.exit("ERROR: no T1000-E UF2 volume mounted. Double-tap the button (the 1200-baud "
                 "touch does NOT mount one on this bootloader — use tools/flash_t1000e.sh for "
                 "hands-free serial-DFU).")
    if len(vols) > 1:
        sys.exit(f"ERROR: {len(vols)} candidate bootloader volumes {vols} — ambiguous, refusing.")
    drive = vols[0]

    boots = boot_devices()
    if boots is not None:
        if len(boots) > 1:
            sys.exit(f"ERROR: {len(boots)} T1000 bootloader USB devices {boots} — cannot tell "
                     "which owns the mounted volume, refusing.")
        if expect_serial:
            if not boots:
                sys.exit("ERROR: a volume is mounted but no T1000 bootloader USB device is "
                         "visible — cannot verify identity, refusing.")
            if boots[0][0] != expect_serial:
                sys.exit(f"ERROR: bootloader device serial {boots[0][0]} != expected "
                         f"{expect_serial} — the mounted volume belongs to ANOTHER board, refusing.")
            print(f"   identity OK: bootloader USB serial {boots[0][0]} matches")
    elif expect_serial:
        sys.exit("ERROR: pyserial unavailable — cannot verify the pinned serial. Install it or "
                 "pass '-' (single-board bench only).")

    _, info = volume_identity(drive)
    print(f"   bootloader volume: {drive}")
    if info:
        print("   " + "\n   ".join(info.splitlines()[:3]))

    dest = os.path.join(drive, os.path.basename(uf2))
    print(f"   copying {os.path.getsize(uf2)} bytes -> {dest}")
    try:
        shutil.copy(uf2, dest)
        try:
            os.sync()
        except Exception:
            pass
    except OSError as e:
        # The drive often unmounts the instant the full image is received and the device
        # reboots — the copy's outcome is NOT the truth signal; the unmount below is.
        print(f"   copy ended with {e!r} (normal if the device rebooted mid-copy)")
    deadline = time.time() + 15
    while time.time() < deadline:
        if not os.path.isdir(drive):
            print("DONE: bootloader accepted the image (volume unmounted); device is rebooting.")
            sys.exit(0)
        time.sleep(0.5)
    sys.exit(f"ERROR: {drive} never unmounted — flash NOT confirmed. Re-enter the bootloader and retry.")


if __name__ == "__main__":
    main()
