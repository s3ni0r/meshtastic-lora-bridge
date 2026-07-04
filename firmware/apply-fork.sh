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

mkdir -p "$CLONE/src/modules" "$CLONE/src/gps"
cp src/modules/HighRatePositionModule.h   "$CLONE/src/modules/"
cp src/modules/HighRatePositionModule.cpp "$CLONE/src/modules/"
cp src/gps/GnssRateProbe.h                "$CLONE/src/gps/"
cp src/gps/GnssRateProbe.cpp              "$CLONE/src/gps/"
cp patch_bluefruit_ext.py                 "$CLONE/"
git -C "$CLONE" apply ../meshtastic-fork.patch

echo "fork applied on $TAG — flavors build per FORK.md §4"
