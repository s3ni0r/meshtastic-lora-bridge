#!/usr/bin/env bash
# Restore every connected T1000-E to the KNOWN-GOOD firmware (v3.0, payload v3 —
# the fleet state validated on 2026-07-13, before the tag-downlink experiments).
#
# The .uf2 / -dfu.zip files in this folder are byte-identical copies of
# firmware/releases/v3.0/ (verify: shasum -a 256 -c SHA256SUMS). Flashing goes
# through the standard fleet flasher — tools/flash_t1000e.sh — with the release
# pinned, so this works even after newer releases land in firmware/releases/.
#
#   firmware/known-good/restore.sh            # restore every connected board by role
#   firmware/known-good/restore.sh gpstag     # restore just one role (gpstag|tag|base)
#
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FLASH="$REPO/tools/flash_t1000e.sh"
[ -x "$FLASH" ] || { echo "flasher not found: $FLASH"; exit 1; }

declare -A FLAVOR_FOR_ROLE=([gpstag]=gps-tag [tag]=bridge-tag [base]=base-plain)
ROLES=("${1:-gpstag}" )
if [ $# -eq 0 ]; then ROLES=(gpstag tag base); fi

for role in "${ROLES[@]}"; do
  flavor="${FLAVOR_FOR_ROLE[$role]:-}"
  [ -n "$flavor" ] || { echo "unknown role: $role (use gpstag|tag|base)"; exit 1; }
  echo "== restore $role <- $flavor (v3.0 known-good)"
  if VERSION=v3.0 "$FLASH" "$flavor" "$role"; then
    echo "== $role restored"
  else
    echo "== $role NOT restored (not connected?) — continuing"
  fi
done
echo "Known-good restore pass complete."
