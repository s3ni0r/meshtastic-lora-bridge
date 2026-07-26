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
  - exactly ONE candidate volume, else refuse;
  - with a role/serial pinned, the volume is attributed to its OWNING USB device through the
    IORegistry (diskutil BSD name -> ancestor USB serial) and that serial must match the pin —
    specific silicon, not whatever happens to be mounted (product strings are unreliable:
    macOS caches them stale AND the fleet has two bootloader generations with different names);
  - success is only the bootloader unmounting the volume (image accepted).
"""
import glob
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import time

UF2_MAGIC0 = 0x0A324655  # "UF2\n"
UF2_MAGIC1 = 0x9E5D5157
UF2_MAGIC_END = 0x0AB16F30
UF2_FLAG_FAMILY_ID = 0x00002000
NRF52840_FAMILY = 0xADA52840
# tracker-t1000-e uses src/platform/nrf52/nrf52840_s140_v7.ld:
#   FLASH ORIGIN = 0x27000, LENGTH = 0xED000 - 0x27000
# Keep SoftDevice below and bootloader/settings above completely outside application UF2s.
T1000_APP_FLASH_START = 0x00027000
T1000_APP_FLASH_END = 0x000ED000  # exclusive
UF2_BLOCK_SIZE = 512
UF2_DATA_OFFSET = 32
UF2_MAX_PAYLOAD = 476  # bytes before the trailing magic at offset 508
T1000_MARKERS = ("t1000",)


def validate_uf2(path):
    """Validate a plain nRF52840 application UF2 for the T1000-E flash layout.

    This intentionally accepts less than the general UF2 specification: every physical block
    must be a main-flash, family-tagged block; numbering must describe this exact file; and
    payload ranges must be non-overlapping and wholly inside the T1000-E application partition.
    """
    size = os.path.getsize(path)
    if size == 0 or size % UF2_BLOCK_SIZE != 0:
        sys.exit(
            f"ERROR: {path} is not a UF2 image "
            f"(size {size} not a multiple of {UF2_BLOCK_SIZE})."
        )
    physical_blocks = size // UF2_BLOCK_SIZE
    seen_numbers = set()
    payload_ranges = []
    with open(path, "rb") as f:
        idx = 0
        while True:
            block = f.read(UF2_BLOCK_SIZE)
            if not block:
                break
            m0, m1 = struct.unpack_from("<II", block, 0)
            mend = struct.unpack_from("<I", block, 508)[0]
            if m0 != UF2_MAGIC0 or m1 != UF2_MAGIC1 or mend != UF2_MAGIC_END:
                sys.exit(f"ERROR: {path} block {idx} has invalid UF2 magics — refusing.")
            flags, target, payload_size, block_no, total, family = struct.unpack_from(
                "<IIIIII", block, 8
            )
            if flags != UF2_FLAG_FAMILY_ID:
                sys.exit(
                    f"ERROR: {path} block {idx} flags 0x{flags:08X} are unsupported — "
                    "every block must be a plain main-flash block with only the family-ID flag."
                )
            if family != NRF52840_FAMILY:
                sys.exit(
                    f"ERROR: {path} block {idx} family 0x{family:08X} != nRF52840 "
                    f"(0x{NRF52840_FAMILY:08X}) — wrong-target image, refusing."
                )
            if payload_size == 0 or payload_size > UF2_MAX_PAYLOAD:
                sys.exit(
                    f"ERROR: {path} block {idx} payload size {payload_size} is outside "
                    f"1..{UF2_MAX_PAYLOAD} bytes."
                )
            if total == 0 or total != physical_blocks:
                sys.exit(
                    f"ERROR: {path} block {idx} declares {total} blocks, but the file contains "
                    f"{physical_blocks} — incomplete/inconsistent UF2."
                )
            if block_no >= total:
                sys.exit(
                    f"ERROR: {path} block {idx} has block number {block_no}, outside 0..{total - 1}."
                )
            if block_no in seen_numbers:
                sys.exit(f"ERROR: {path} repeats UF2 block number {block_no} — refusing.")
            seen_numbers.add(block_no)

            if target > 0xFFFFFFFF - payload_size:
                sys.exit(
                    f"ERROR: {path} block {idx} target 0x{target:08X} + {payload_size} "
                    "overflows the 32-bit address space."
                )
            end = target + payload_size
            if target < T1000_APP_FLASH_START or end > T1000_APP_FLASH_END:
                sys.exit(
                    f"ERROR: {path} block {idx} range 0x{target:08X}..0x{end:08X} is outside "
                    f"the T1000-E application partition 0x{T1000_APP_FLASH_START:08X}.."
                    f"0x{T1000_APP_FLASH_END:08X}."
                )
            payload_ranges.append((target, end, block_no))
            idx += 1

    if seen_numbers != set(range(physical_blocks)):
        missing = sorted(set(range(physical_blocks)) - seen_numbers)
        sys.exit(f"ERROR: {path} is missing UF2 block number(s) {missing[:8]} — refusing.")
    payload_ranges.sort()
    for previous, current in zip(payload_ranges, payload_ranges[1:]):
        if current[0] < previous[1]:
            sys.exit(
                f"ERROR: {path} UF2 blocks {previous[2]} and {current[2]} overlap in flash "
                f"(0x{current[0]:08X} < 0x{previous[1]:08X})."
            )
    print(
        f"   uf2 image OK: {physical_blocks} complete blocks, family nRF52840, "
        f"targets inside 0x{T1000_APP_FLASH_START:08X}..0x{T1000_APP_FLASH_END:08X}"
    )


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


USB_DEVICE_CLASSES = {"IOUSBHostDevice", "IOUSBDevice", "AppleUSBDevice"}
USB_SERIAL_KEYS = ("USB Serial Number", "kUSBSerialNumberString")


def _is_usb_device(entry):
    cls = entry.get("IOObjectClass") or entry.get("IOClass")
    if not isinstance(cls, str):
        return False
    return (
        cls in USB_DEVICE_CLASSES
        or cls.endswith("USBDevice")
        or cls.endswith("USBHostDevice")
    )


def _usb_device_serial(entry):
    for key in USB_SERIAL_KEYS:
        value = entry.get(key)
        if isinstance(value, bytes):
            value = value.decode("ascii", errors="ignore")
        if isinstance(value, str):
            value = value.strip()
            if re.fullmatch(r"[0-9A-Fa-f]{8,}", value):
                return value.upper()
    return None


def _owner_serial_from_ioreg(tree, bsd_name):
    """Return the serial on the nearest USB-device ancestor of one BSD media node.

    `tree` is plistlib's structured result from `ioreg -a`. Only the recursion path that
    contains the exact BSD node is inspected. Once the nearest USB device is reached, a
    missing serial fails closed instead of borrowing a parent hub's or sibling's serial.
    """
    roots = tree if isinstance(tree, list) else [tree]

    def walk(entry, ancestors):
        if not isinstance(entry, dict):
            return False, None
        path = ancestors + (entry,)
        if entry.get("BSD Name") == bsd_name:
            for ancestor in reversed(path):
                if _is_usb_device(ancestor):
                    return True, _usb_device_serial(ancestor)
            return True, None
        children = entry.get("IORegistryEntryChildren") or []
        if isinstance(children, list):
            for child in children:
                found, serial = walk(child, path)
                if found:
                    return found, serial
        return False, None

    for root in roots:
        found, serial = walk(root, ())
        if found:
            return serial
    return None


def volume_owner_serial(volume):
    """Resolve a mounted volume to its owning USB hardware serial through plist trees.

    `diskutil info -plist` supplies the exact BSD node (including a partition suffix), then
    `ioreg -a` supplies the parent/child tree. No text-order or "nearest preceding line"
    heuristic is used.
    """
    try:
        info = subprocess.run(
            ["diskutil", "info", "-plist", volume], capture_output=True, timeout=15
        )
        if info.returncode != 0 or not info.stdout:
            return None
        info_plist = plistlib.loads(info.stdout)
        bsd = info_plist.get("DeviceIdentifier")
        if not isinstance(bsd, str) or not re.fullmatch(r"disk\d+(?:s\d+)*", bsd):
            return None
        reg = subprocess.run(
            ["ioreg", "-a", "-l", "-w", "0", "-p", "IOService"],
            capture_output=True,
            timeout=20,
        )
        if reg.returncode != 0 or not reg.stdout:
            return None
        return _owner_serial_from_ioreg(plistlib.loads(reg.stdout), bsd)
    except Exception:
        return None


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
    else:
        print("   WARNING: no hardware-serial pin ('-' selected); single-board recovery only")

    vols = t1000_volumes()
    if not vols:
        sys.exit("ERROR: no T1000-E UF2 volume mounted. Double-tap the button (the 1200-baud "
                 "touch does NOT mount one on this bootloader — use tools/flash_t1000e.sh for "
                 "hands-free serial-DFU).")
    if len(vols) > 1:
        sys.exit(f"ERROR: {len(vols)} candidate bootloader volumes {vols} — ambiguous, refusing.")
    drive = vols[0]

    if expect_serial:
        owner = volume_owner_serial(drive)
        if owner is None:
            sys.exit("ERROR: could not resolve which USB device owns the mounted volume — "
                     "cannot verify the pinned serial. Pass '-' explicitly (single-board "
                     "bench only) to flash without the identity pin.")
        if owner != expect_serial:
            sys.exit(f"ERROR: the mounted volume belongs to USB serial {owner}, not the pinned "
                     f"{expect_serial} — that is ANOTHER board, refusing.")
        print(f"   identity OK: volume owner USB serial {owner} matches the pin")

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
