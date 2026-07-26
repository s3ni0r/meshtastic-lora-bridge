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

TAG=v2.7.15.567b8ea   # human-readable name only — the OID below is the actual build base
# Full commit OID the fork is based on. Tags are movable refs: a re-pointed upstream (or
# local) tag must never silently change what "the vendor base" means, so checkout and
# release attestation both pin the immutable object id (release_identity.py holds the same
# constant — update BOTH when bumping the base; see FORK.md).
BASE_OID=567b8ea1c2b2d100c24b0d6cbc437ec89fae0a56
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
git -C "$CLONE" checkout --quiet "$BASE_OID"
# Belt and braces: the named tag must still describe this OID — a mismatch means upstream
# (or someone local) moved the tag, and docs/patch context would silently lie about the base.
if [ "$(git -C "$CLONE" rev-parse "$TAG^{commit}" 2>/dev/null)" != "$BASE_OID" ]; then
    echo "ERROR: tag $TAG no longer points at pinned base $BASE_OID — refusing." >&2
    exit 1
fi
git -C "$CLONE" submodule update --init --recursive --quiet

# Project-owned drop-ins: mirror the ENTIRE tracked src/ tree into the clone. Copying the whole
# tree (instead of a hand-maintained list) is what keeps this script from drifting against
# sync-fork.sh — external review 2026-07-26 caught exactly that: four hardcoded files here had
# silently missed six newer drop-ins, so fresh reconstruction was broken.
cp -R src/. "$CLONE/src/"
cp vendor/bin/readprops.py "$CLONE/bin/readprops.py"
cp patch_bluefruit_ext.py "$CLONE/"
git -C "$CLONE" apply ../meshtastic-fork.patch

# NOTE on the Bluefruit BLE extension patch (review R3 finding 5 — do NOT "run" it here):
# patch_bluefruit_ext.py is a PlatformIO extra_script (SCons hook, uses Import("env")) — it
# CANNOT execute standalone, and it only acts on ODID_PHY_EXT (bridge-flavor) builds. It is
# wired via the patched variant platformio.ini and runs AUTOMATICALLY, idempotently, during
# the first bridge-flavor `pio run` on a machine. Consequence (documented, not hidden): it
# mutates the GLOBAL ~/.platformio framework package, so bridge builds converge only after
# that first run — see releases/*/RELEASE.md "Reproducibility scope".

echo "fork applied on $TAG — flavors build per FORK.md §4"
