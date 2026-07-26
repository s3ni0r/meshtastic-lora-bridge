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
mkdir -p src/modules src/gps vendor/bin
cp "$CLONE/bin/readprops.py"                         vendor/bin/readprops.py
cp "$CLONE/src/modules/HighRatePositionModule.h"   src/modules/HighRatePositionModule.h
cp "$CLONE/src/modules/HighRatePositionModule.cpp" src/modules/HighRatePositionModule.cpp
cp "$CLONE/src/gps/GnssRateProbe.h"                src/gps/GnssRateProbe.h
cp "$CLONE/src/gps/GnssRateProbe.cpp"              src/gps/GnssRateProbe.cpp
cp "$CLONE/src/gps/GnssTagSettings.h"              src/gps/GnssTagSettings.h
cp "$CLONE/src/gps/GnssTagSettings.cpp"            src/gps/GnssTagSettings.cpp
cp "$CLONE/src/gps/GnssMotion.h"                   src/gps/GnssMotion.h
cp "$CLONE/src/gps/GnssMotion.cpp"                 src/gps/GnssMotion.cpp
cp "$CLONE/src/gps/GnssSim.h"                      src/gps/GnssSim.h
cp "$CLONE/src/gps/GnssSim.cpp"                    src/gps/GnssSim.cpp
cp "$CLONE/src/modules/GnssConfigModule.h"         src/modules/GnssConfigModule.h
cp "$CLONE/src/modules/GnssConfigModule.cpp"       src/modules/GnssConfigModule.cpp
cp "$CLONE/src/modules/GnssSignaler.h"             src/modules/GnssSignaler.h
cp "$CLONE/src/modules/GnssSignaler.cpp"           src/modules/GnssSignaler.cpp
cp "$CLONE/patch_bluefruit_ext.py"                 patch_bluefruit_ext.py

# Vendor-file edits: one reviewable patch vs the build tag — diff against the TAG, not HEAD:
# the clone keeps a local t1000e-fork branch with changes COMMITTED, so a plain `git diff`
# (worktree vs HEAD) is empty and would silently wipe the patch.
BASE_TAG=v2.7.15.567b8ea
git -C "$CLONE" diff --no-ext-diff --binary --no-renames "$BASE_TAG" -- \
    bin/platformio-custom.py \
    src/main.cpp \
    src/configuration.h \
    src/gps/GPS.cpp \
    src/mesh/LR11x0Interface.cpp \
    src/mesh/RadioLibInterface.cpp \
    src/mesh/StreamAPI.cpp \
    src/modules/Modules.cpp \
    src/modules/Telemetry/DeviceTelemetry.h \
    src/motion/QMA6100PSensor.cpp \
    src/platform/nrf52/NRF52Bluetooth.cpp \
    variants/nrf52840/tracker-t1000-e/platformio.ini \
    > meshtastic-fork.patch

echo "synced: firmware/src/{modules,gps} + vendor/bin/readprops.py + firmware/meshtastic-fork.patch"
wc -l meshtastic-fork.patch
