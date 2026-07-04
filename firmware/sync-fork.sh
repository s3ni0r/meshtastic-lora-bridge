#!/usr/bin/env bash
# Mirror our Meshtastic-fork changes from the (git-ignored) build clone into the tracked tree, so the
# branch is self-contained and reviewable. Run this whenever you edit files under meshtastic-firmware/.
#
#   firmware/meshtastic-firmware/   <- full Meshtastic checkout, git-ignored (the build tree)
#   firmware/src/...                <- our project-owned files, tracked as clean drop-ins
#   firmware/meshtastic-fork.patch  <- our edits to vendor files (GPS/Modules/BLE), tracked + reviewable
#
# To reproduce on a fresh clone: copy the src/ drop-ins in, then
#   git -C meshtastic-firmware apply ../meshtastic-fork.patch
set -euo pipefail
cd "$(dirname "$0")"
CLONE=meshtastic-firmware
[ -d "$CLONE" ] || { echo "clone not found: $CLONE"; exit 1; }

# Project-owned files: clean full drop-in copies.
mkdir -p src/modules src/gps
cp "$CLONE/src/modules/HighRatePositionModule.h"   src/modules/HighRatePositionModule.h
cp "$CLONE/src/modules/HighRatePositionModule.cpp" src/modules/HighRatePositionModule.cpp
cp "$CLONE/src/gps/GnssRateProbe.h"                src/gps/GnssRateProbe.h
cp "$CLONE/src/gps/GnssRateProbe.cpp"              src/gps/GnssRateProbe.cpp
cp "$CLONE/patch_bluefruit_ext.py"                 patch_bluefruit_ext.py

# Vendor-file edits: one reviewable patch vs the build tag (v2.7.15.567b8ea).
git -C "$CLONE" diff -- \
    src/main.cpp \
    src/configuration.h \
    src/gps/GPS.cpp \
    src/mesh/LR11x0Interface.cpp \
    src/modules/Modules.cpp \
    src/platform/nrf52/NRF52Bluetooth.cpp \
    variants/nrf52840/tracker-t1000-e/platformio.ini \
    > meshtastic-fork.patch

echo "synced: firmware/src/{modules,gps} drop-ins + firmware/meshtastic-fork.patch"
wc -l meshtastic-fork.patch
