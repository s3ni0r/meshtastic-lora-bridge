#!/usr/bin/env bash
# Inverse of sync-fork.sh: (re)build the git-ignored meshtastic-firmware clone from the TRACKED
# artifacts, so a fresh machine (or a lost clone) gets back to a buildable fork in one command.
#
#   firmware/meshtastic-fork.patch  -> vendor-file edits (GPS/config/radio/BLE/variant)
#   firmware/src/...                -> project-owned drop-ins (module + probe)
#
# After this, build any flavor per FORK.md §4, e.g.:
#   cd meshtastic-firmware && PLATFORMIO_BUILD_FLAGS="-DGPS_TAG" pio run -e tracker-t1000-e
set -euo pipefail
cd "$(dirname "$0")"

TAG=v2.7.15.567b8ea   # build base — matches the patch; see FORK.md before bumping
CLONE=meshtastic-firmware

if [ -d "$CLONE" ]; then
    if ! git -C "$CLONE" diff --quiet || [ -n "$(git -C "$CLONE" status --porcelain)" ]; then
        echo "ERROR: $CLONE has local changes — run ./sync-fork.sh first (or clean it deliberately)." >&2
        exit 1
    fi
else
    git clone https://github.com/meshtastic/firmware "$CLONE"
fi

git -C "$CLONE" fetch --tags --quiet
git -C "$CLONE" checkout --quiet "$TAG"
git -C "$CLONE" submodule update --init --recursive --quiet

# Project-owned drop-ins: mirror the ENTIRE tracked src/ tree into the clone. Copying the whole
# tree (instead of a hand-maintained list) is what keeps this script from drifting against
# sync-fork.sh — external review 2026-07-26 caught exactly that: four hardcoded files here had
# silently missed six newer drop-ins, so fresh reconstruction was broken.
cp -R src/. "$CLONE/src/"
cp patch_bluefruit_ext.py "$CLONE/"
git -C "$CLONE" apply ../meshtastic-fork.patch

# The Bluefruit BLE extension patch mutates the GLOBAL PlatformIO framework package (~/.platformio)
# — it's idempotent ("already patched" guard), but a fresh machine MUST run it before the first
# build or bridge-flavor builds differ (review R2 finding 8: order-dependent builds).
python3 "$CLONE/patch_bluefruit_ext.py" || echo "note: bluefruit patch skipped (framework package not installed yet — run it after the first 'pio run' fetches packages)"

echo "fork applied on $TAG — flavors build per FORK.md §4"
