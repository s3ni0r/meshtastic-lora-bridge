#!/usr/bin/env bash
# Flash a released firmware flavor onto a Seeed T1000-E.
#
#   tools/flash_t1000e.sh <flavor> [port|role]      flavor: gps-tag | bridge-tag | base-plain
#   tools/flash_t1000e.sh --list                    show available releases/flavors + connected boards
#   tools/flash_t1000e.sh gps-tag                   auto-detect (works when exactly ONE T1000-E is attached)
#   tools/flash_t1000e.sh gps-tag gpstag            resolve port by role via tools/nodes.py
#   tools/flash_t1000e.sh base-plain /dev/cu.usbmodem1111301
#   VERSION=v1.0 tools/flash_t1000e.sh gps-tag      pin a release (default: latest in firmware/releases)
#
# Flash path (proven on this fleet): 1200-baud touch drops the running app into the bootloader's
# serial-DFU CDC, then adafruit-nrfutil uploads the <flavor>-dfu.zip. If a UF2 volume is already
# mounted (user double-tapped the button), the .uf2 is copied instead. After flashing, the node
# keeps (or needs) its Meshtastic config — the script prints the per-flavor cheat-sheet.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES="$REPO/firmware/releases"
VERSION="${VERSION:-$(ls "$RELEASES" | sort -V | tail -1)}"
DIR="$RELEASES/$VERSION"

usage() {
    cat <<EOF
Flash a released firmware flavor onto a Seeed T1000-E.

Usage:
  $(basename "$0") <flavor> [port|role]   flash a board
  $(basename "$0") --list                 show releases + connected boards (with roles)
  $(basename "$0") -h | --help            this help

Flavors (from firmware/releases/, currently $VERSION):
  gps-tag      self-contained tag — onboard AG3335 @ 4 Hz, LoRa TX-only, BLE kept
  bridge-tag   BLE5/LoRa bridge — relays Dronetag Remote ID, no BLE advertising
  base-plain   receiver — forwards the stream to the iOS app over BLE

Target selection (2nd argument):
  omitted           auto-detect — works when exactly ONE T1000-E is connected
  tag|base|gpstag   role, resolved via tools/nodes.py (stable USB serial)
  /dev/cu.usbmodemX explicit serial port
  uf2               EXPLICIT UF2-volume mode: copy onto an already-mounted T1000/nRF52
                    bootloader drive (button double-tap). Volumes are never touched
                    otherwise, and success requires the bootloader to unmount the drive.

Environment:
  VERSION=vX.Y      pin a release (default: latest in firmware/releases/)

Flash path: 1200-baud touch -> re-find the SAME hardware serial after re-enumeration ->
bootloader serial-DFU (adafruit-nrfutil, <flavor>-dfu.zip). The flavor's .uf2 AND -dfu.zip
are verified against SHA256SUMS (listed + matching) before any device is touched; a
per-flavor Meshtastic config cheat-sheet is printed after. Full docs: firmware/FORK.md §4–§6.

Examples:
  $(basename "$0") gps-tag                    # one new board plugged in alone
  $(basename "$0") base-plain base            # reflash the known Base by role
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
    if p.vid == 0x239A:  # Adafruit/Seeed nRF52 bootloader VID (app + bootloader)
        sn = (p.serial_number or '').upper()
        role = known.get(sn, {}).get('role', '?')
        print(f"  {p.device}  serial={sn}  role={role}  ({p.product})")
EOF
}

case "${1:-}" in -h|--help|"") usage; exit 0;; esac

if [ "${1:-}" = "--list" ]; then
    echo "Releases in $RELEASES:"
    for v in $(ls "$RELEASES" | sort -V); do
        echo "  $v: $(ls "$RELEASES/$v" | grep -c '\.uf2$') flavors — $(ls "$RELEASES/$v"/*.uf2 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
    done
    echo "Connected T1000-E boards:"
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
# the selected serial target (review R2 finding 3).
if [ "${2:-}" = "uf2" ]; then
    for v in /Volumes/*; do
        [ -f "$v/INFO_UF2.TXT" ] || continue
        if ! grep -qiE "t1000|nrf52" "$v/INFO_UF2.TXT"; then
            echo "   note: UF2 volume $v is not a T1000/nRF52 bootloader — leaving it alone" >&2
            continue
        fi
        echo "== Flashing $FLAVOR ($VERSION) -> UF2 volume $v"
        cp "$UF2" "$v/" 2>/dev/null || true # exit code meaningless (device reboots mid-copy)
        for _ in $(seq 1 30); do
            if [ ! -d "$v" ]; then
                echo "DONE (UF2): bootloader accepted the image (volume unmounted); device reboots."
                exit 0
            fi
            sleep 0.5
        done
        echo "ERROR: $v never unmounted — flash NOT confirmed. Re-enter the bootloader and retry." >&2
        exit 1
    done
    echo "ERROR: no T1000/nRF52 UF2 volume mounted (double-tap the button first)." >&2
    exit 1
fi

# Resolve the target port: explicit path, role name via nodes.py, or single-board autodetect.
TARGET="${2:-}"
if [ -n "$TARGET" ] && [ ! -e "$TARGET" ]; then
    RESOLVED="$(cd "$REPO/tools" && "$PY" nodes.py --port "$TARGET" 2>/dev/null || true)"
    [ -n "$RESOLVED" ] || { echo "ERROR: '$TARGET' is neither a device path nor a connected role (tag|base|gpstag)" >&2; exit 2; }
    TARGET="$RESOLVED"
elif [ -z "$TARGET" ]; then
    MAPPED="$("$PY" - <<'EOF'
from serial.tools import list_ports
c = [p.device for p in list_ports.comports() if p.vid == 0x239A]
print('\n'.join(c))
EOF
)"
    COUNT="$(printf '%s' "$MAPPED" | grep -c . || true)"
    if [ "$COUNT" -eq 1 ]; then
        TARGET="$MAPPED"
    else
        echo "ERROR: $COUNT T1000-E boards connected — specify a port or role:" >&2
        list_boards >&2
        exit 2
    fi
fi

echo "== Flashing $FLAVOR ($VERSION) -> $TARGET"

# Pin the target by HARDWARE SERIAL before the touch: the 1200-baud reset re-enumerates the
# USB device and the /dev path can change or get swapped with another board (review R2
# finding 3). After the touch we re-find the SAME silicon, not the same path.
HWSER="$("$PY" - "$TARGET" <<'EOF'
from serial.tools import list_ports
import sys
for p in list_ports.comports():
    if p.device == sys.argv[1]:
        print((p.serial_number or '').upper())
        break
EOF
)"
[ -n "$HWSER" ] && echo "   target hardware serial: $HWSER"

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
if [ -n "$HWSER" ]; then
    NEWTARGET=""
    for _ in $(seq 1 24); do
        NEWTARGET="$("$PY" - "$HWSER" <<'EOF'
from serial.tools import list_ports
import sys
for p in list_ports.comports():
    if (p.serial_number or '').upper() == sys.argv[1]:
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
else
    echo "   warning: could not read the hardware serial pre-touch — using $TARGET as-is" >&2
    sleep 5
fi

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