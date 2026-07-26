#!/usr/bin/env bash
# Flash a released firmware flavor onto a Seeed T1000-E.
#
#   tools/flash_t1000e.sh <flavor> [port|role|serial]  flavor: gps-tag | bridge-tag | base-plain
#   tools/flash_t1000e.sh --list                    show available releases/flavors + connected boards
#   tools/flash_t1000e.sh gps-tag                   auto-detect one registry-known T1000-E
#   tools/flash_t1000e.sh gps-tag gpstag            resolve port by role via tools/nodes.py
#   tools/flash_t1000e.sh base-plain /dev/cu.usbmodem1111301
#   VERSION=v1.0 tools/flash_t1000e.sh gps-tag      pin a release (default: latest in firmware/releases)
#
# Flash path (proven on this fleet): 1200-baud touch drops the running app into the bootloader's
# serial-DFU CDC, then adafruit-nrfutil uploads the <flavor>-dfu.zip. UF2-volume copying is a
# separate, explicit `<flavor> uf2` mode. After flashing, the node keeps (or needs) its
# Meshtastic config — the script prints the per-flavor cheat-sheet.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES="$REPO/firmware/releases"
VERSION="${VERSION:-$(ls "$RELEASES" | sort -V | tail -1)}"
DIR="$RELEASES/$VERSION"

usage() {
    cat <<EOF
Flash a released firmware flavor onto a Seeed T1000-E.

Usage:
  $(basename "$0") <flavor> [port|role|serial]   flash a board
  $(basename "$0") --list                 show releases + connected boards (with roles)
  $(basename "$0") -h | --help            this help

Flavors (from firmware/releases/, currently $VERSION):
  gps-tag      self-contained tag — onboard AG3335 @ 4 Hz, LoRa RX + BLE kept
  bridge-tag   BLE5/LoRa bridge — relays Dronetag Remote ID, no BLE advertising
  base-plain   receiver — forwards the stream to the iOS app over BLE

Target selection (2nd argument):
  omitted           auto-detect — exactly one REGISTRY-KNOWN T1000-E must be connected
  tag|base|gpstag   role, resolved via tools/nodes.py (stable USB serial)
  16-hex serial     explicit hardware identity (must be on VID 0x239A or 0x2886)
  /dev/cu.usbmodemX explicit serial port
  uf2               EXPLICIT UF2-volume mode: copy onto an already-mounted T1000-E
                    bootloader drive (button double-tap). Volumes are never touched
                    otherwise, and success requires the bootloader to unmount the drive.
                    This shortcut is unpinned; use tools/flash_uf2.py for role/serial pinning.

Environment:
  VERSION=vX.Y      pin a release (default: latest in firmware/releases/)

Flash path: 1200-baud touch -> re-find the SAME hardware serial after re-enumeration ->
bootloader serial-DFU (adafruit-nrfutil, <flavor>-dfu.zip). The flavor's .uf2 AND -dfu.zip
are verified against SHA256SUMS (listed + matching) before any device is touched; a
per-flavor Meshtastic config cheat-sheet is printed after. Full docs: firmware/FORK.md §4–§6.

Examples:
  $(basename "$0") gps-tag                    # one registry-known board plugged in alone
  $(basename "$0") base-plain base            # reflash the known Base by role
  $(basename "$0") gps-tag 15B20E7A7AAD8AF0  # select exact hardware serial
  VERSION=v1.0 $(basename "$0") bridge-tag /dev/cu.usbmodem1111201
EOF
}

# adafruit-nrfutil lives in the PlatformIO tool package; run it with a python that has its deps.
NRFUTIL_DIR="$HOME/.platformio/packages/tool-adafruit-nrfutil"
PY="$HOME/.local/pipx/venvs/platformio/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"

list_boards() {
    "$PY" - "$REPO" <<'EOF'
from serial.tools import list_ports
import sys
known = {}
try:
    sys.path.insert(0, sys.argv[1] + '/tools')
    import nodes
    known = dict(nodes.NODES)
except Exception:
    pass
for p in list_ports.comports():
    if p.vid in (0x239A, 0x2886):  # both measured T1000-E bootloader generations
        sn = (p.serial_number or '').upper()
        if sn in known:
            role = known[sn].get('role', '?')
            status = f"role={role}, eligible for auto-detect"
        else:
            status = "UNREGISTERED — explicit port or 16-hex serial required"
        print(f"  {p.device}  vid=0x{p.vid:04X}  serial={sn or '?'}  {status}  ({p.product})")
EOF
}

case "${1:-}" in -h|--help|"") usage; exit 0;; esac

[ "$#" -le 2 ] || {
    echo "ERROR: expected <flavor> and at most one target; got $# arguments." >&2
    exit 2
}

if [ "${1:-}" = "--list" ]; then
    echo "Releases in $RELEASES:"
    for v in $(ls "$RELEASES" | sort -V); do
        echo "  $v: $(ls "$RELEASES/$v" | grep -c '\.uf2$') flavors — $(ls "$RELEASES/$v"/*.uf2 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
    done
    echo "Connected 0x239A/0x2886 USB candidates:"
    list_boards
    exit 0
fi

FLAVOR="$1"
UF2="$DIR/$FLAVOR.uf2"
DFUZIP="$DIR/$FLAVOR-dfu.zip"
[ -f "$UF2" ] || { echo "ERROR: unknown flavor '$FLAVOR' in $DIR (have: $(ls "$DIR"/*.uf2 | xargs -n1 basename | sed 's/.uf2//' | tr '\n' ' '))" >&2; exit 2; }

# Verify the SPECIFIC artifacts we are about to flash — both must be LISTED in the manifest
# and match it (review R2 finding 7: --ignore-missing alone let an unlisted file through, and
# the DFU zip was never preflighted). Runs before ANY device is touched.
for f in "$FLAVOR.uf2" "$FLAVOR-dfu.zip"; do
    grep -q "  $f\$" "$DIR/SHA256SUMS" || {
        echo "ERROR: $f is not listed in $DIR/SHA256SUMS — refusing to flash an unmanifested artifact." >&2
        exit 1
    }
done
if ! (cd "$DIR" && grep "  $FLAVOR.uf2\$\|  $FLAVOR-dfu.zip\$" SHA256SUMS | shasum -a 256 -c - >/dev/null); then
    echo "ERROR: SHA256 mismatch for $FLAVOR artifacts in $DIR — refusing to flash." >&2
    exit 1
fi
echo "   checksums OK ($FLAVOR.uf2 + $FLAVOR-dfu.zip verified against the manifest)"

# EXPLICIT UF2-volume mode only: `flash_t1000e.sh <flavor> uf2`. This is the ONLY path that
# touches mounted bootloader volumes — the old automatic scan could hit a device unrelated to
# the selected serial target (review R2 finding 3). Delegate to the one strict implementation:
# it validates every UF2 block and target range, rejects non-T1000/ambiguous volumes, copies,
# then requires the selected volume to unmount. `-` deliberately means no serial pin; for a
# pinned recovery use `tools/flash_uf2.py <role|serial> <image>` directly.
if [ "${2:-}" = "uf2" ]; then
    exec "$PY" "$REPO/tools/flash_uf2.py" - "$UF2"
fi

# Resolve the target port: explicit path/serial, registry role, or registry-only autodetect.
# Unknown devices are NEVER auto-selected: VID 0x239A is shared by unrelated Adafruit boards.
TARGET_SPEC="${2:-}"
TARGET="$TARGET_SPEC"
EXPECTED_SERIAL=""
AUTO_TARGET=0
if [ -n "$TARGET_SPEC" ] && [ -e "$TARGET_SPEC" ]; then
    : # Explicit device path: deliberate operator selection, identity is pinned below.
elif [[ "$TARGET_SPEC" =~ ^[0-9A-Fa-f]{16}$ ]]; then
    EXPECTED_SERIAL="$(printf '%s' "$TARGET_SPEC" | tr '[:lower:]' '[:upper:]')"
    TARGET="$("$PY" - "$EXPECTED_SERIAL" <<'EOF'
from serial.tools import list_ports
import sys
serial = sys.argv[1]
matches = [
    p.device for p in list_ports.comports()
    if p.vid in (0x239A, 0x2886) and (p.serial_number or "").upper() == serial
]
if len(matches) == 1:
    print(matches[0])
EOF
)"
    [ -n "$TARGET" ] || {
        echo "ERROR: no unique T1000-E USB port with serial $EXPECTED_SERIAL (VID 0x239A/0x2886)." >&2
        exit 2
    }
elif [ -n "$TARGET_SPEC" ]; then
    RESOLVED="$(cd "$REPO/tools" && "$PY" nodes.py --port "$TARGET_SPEC" 2>/dev/null || true)"
    [ -n "$RESOLVED" ] || {
        echo "ERROR: '$TARGET_SPEC' is neither a device path, 16-hex serial, nor connected role" >&2
        echo "       (tag|base|gpstag)." >&2
        exit 2
    }
    EXPECTED_SERIAL="$("$PY" - "$REPO" "$TARGET_SPEC" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1] + "/tools")
import nodes
print(nodes.BY_ROLE.get(sys.argv[2].lower(), ""))
EOF
)"
    TARGET="$RESOLVED"
else
    AUTO_TARGET=1
    MAPPED="$("$PY" - "$REPO" <<'EOF'
from serial.tools import list_ports
import sys
sys.path.insert(0, sys.argv[1] + "/tools")
import nodes
c = [
    p.device for p in list_ports.comports()
    if p.vid in (0x239A, 0x2886) and (p.serial_number or "").upper() in nodes.NODES
]
print('\n'.join(c))
EOF
)"
    COUNT="$(printf '%s' "$MAPPED" | grep -c . || true)"
    if [ "$COUNT" -eq 1 ]; then
        TARGET="$MAPPED"
    else
        echo "ERROR: $COUNT registry-known T1000-E boards connected — specify a role, port," >&2
        echo "       or exact 16-hex serial. Unregistered boards are never auto-selected:" >&2
        list_boards >&2
        exit 2
    fi
fi

echo "== Flashing $FLAVOR ($VERSION) -> $TARGET"

# Pin the target by HARDWARE SERIAL before the touch: the 1200-baud reset re-enumerates the
# USB device and the /dev path can change or get swapped with another board (review R2
# finding 3). After the touch we re-find the SAME silicon, not the same path.
IDENTITY="$("$PY" - "$TARGET" <<'EOF'
from serial.tools import list_ports
import sys
for p in list_ports.comports():
    if p.device == sys.argv[1]:
        print(f"{(p.serial_number or '').upper()} {(p.vid or 0):04X}")
        break
EOF
)"
HWSER="${IDENTITY%% *}"
TARGET_VID="${IDENTITY#* }"
if ! [[ "$HWSER" =~ ^[0-9A-F]{16}$ ]]; then
    echo "ERROR: could not read a 16-hex hardware serial for $TARGET — refusing BEFORE" >&2
    echo "       the hazardous 1200-baud touch." >&2
    exit 1
fi
case "$TARGET_VID" in
    239A|2886) ;;
    *)
        echo "ERROR: $TARGET reports VID 0x$TARGET_VID, not a measured T1000-E VID" >&2
        echo "       (0x239A/0x2886) — refusing before the 1200-baud touch." >&2
        exit 1
        ;;
esac
if [ -n "$EXPECTED_SERIAL" ] && [ "$HWSER" != "$EXPECTED_SERIAL" ]; then
    echo "ERROR: $TARGET now belongs to serial $HWSER, not requested $EXPECTED_SERIAL — refusing." >&2
    exit 1
fi
if [ "$AUTO_TARGET" -eq 1 ] && ! "$PY" - "$REPO" "$HWSER" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1] + "/tools")
import nodes
raise SystemExit(0 if sys.argv[2] in nodes.NODES else 1)
EOF
then
    echo "ERROR: auto-selected port is no longer a registry-known board — refusing." >&2
    exit 1
fi
echo "   target hardware identity: serial=$HWSER vid=0x$TARGET_VID"

# Preflight the complete DFU toolchain BEFORE opening the port at 1200 baud. A touch without
# an immediately usable DFU client can leave this bootloader's CDC permanently mute.
[ -d "$NRFUTIL_DIR" ] || {
    echo "ERROR: adafruit-nrfutil package directory missing: $NRFUTIL_DIR" >&2
    exit 1
}
[ -f "$NRFUTIL_DIR/adafruit-nrfutil.py" ] || {
    echo "ERROR: adafruit-nrfutil.py missing under $NRFUTIL_DIR" >&2
    exit 1
}
if ! (cd "$NRFUTIL_DIR" && PYTHONPATH=site-packages "$PY" adafruit-nrfutil.py version >/dev/null); then
    echo "ERROR: adafruit-nrfutil or its Python dependencies are unusable — refusing before touch." >&2
    exit 1
fi
echo "   DFU toolchain preflight OK"

# Normal path: 1200-baud touch -> bootloader serial-DFU -> nrfutil upload of the DFU zip.
echo "   1200-baud touch on $TARGET"
"$PY" - "$TARGET" <<'EOF'
import serial, sys, time
try:
    s = serial.Serial(sys.argv[1], 1200)
    s.setDTR(False); time.sleep(0.3); s.close()
except Exception as e:
    print(f"   (touch: {e!r} — ok if already in bootloader)")
EOF

# Re-find the SAME hardware after re-enumeration (by serial, not by the stale /dev path).
NEWTARGET=""
for _ in $(seq 1 24); do
    NEWTARGET="$("$PY" - "$HWSER" <<'EOF'
from serial.tools import list_ports
import sys
for p in list_ports.comports():
    if p.vid in (0x239A, 0x2886) and (p.serial_number or '').upper() == sys.argv[1]:
        print(p.device)
        break
EOF
)"
    [ -n "$NEWTARGET" ] && break
    sleep 0.5
done
if [ -z "$NEWTARGET" ]; then
    echo "ERROR: device with serial $HWSER did not re-enumerate after the touch." >&2
    exit 1
fi
if [ "$NEWTARGET" != "$TARGET" ]; then
    echo "   re-enumerated: $TARGET -> $NEWTARGET (same silicon $HWSER)"
fi
TARGET="$NEWTARGET"

echo "   serial DFU upload: $(basename "$DFUZIP")"
(cd "$NRFUTIL_DIR" && PYTHONPATH=site-packages "$PY" adafruit-nrfutil.py dfu serial \
    --package "$DFUZIP" -p "$TARGET" -b 115200 --singlebank) || {
    echo "ERROR: DFU upload failed. Double-tap the device button (UF2 drive mounts) and re-run." >&2
    exit 1
}

echo "DONE. Device reboots with $FLAVOR."
case "$FLAVOR" in
gps-tag) cat <<'EOT'
-- Configure (once per node; same channel URL as your Base):
   meshtastic --port <port> --seturl '<channel-url-from-base>'
   meshtastic --port <port> --set lora.region <REGION> --set device.role CLIENT_MUTE \
     --set device.rebroadcast_mode LOCAL_ONLY --set position.gps_update_interval 1
   meshtastic --port <port> --set-owner "TAG-GPS-n" --set-owner-short "TGn"
   Verify in serial log: GnssProbe WINNER ~4 fix/s, HighRate src=2.
EOT
;;
bridge-tag) cat <<'EOT'
-- Configure (once per node; same channel URL as your Base):
   meshtastic --port <port> --seturl '<channel-url-from-base>'
   meshtastic --port <port> --set lora.region <REGION> --set device.role CLIENT_MUTE \
     --set device.rebroadcast_mode LOCAL_ONLY
   Note: bridge advertises no BLE — configure over USB. Verify: ODID sniffer log + HighRate src=1.
EOT
;;
base-plain) cat <<'EOT'
-- Configure (once per node): set region + channel; name it so the iOS app finds it:
   meshtastic --port <port> --set lora.region <REGION> --set-owner "BASE-n" --set-owner-short "BSn"
   The iOS app connects to names containing "base" (see ios/MeshTracker/BLEManager.swift).
EOT
;;
esac
