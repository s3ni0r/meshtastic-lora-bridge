#!/usr/bin/env bash
# Restore connected T1000-E boards to the KNOWN-GOOD firmware (v3.0, payload v3 — the fleet
# state validated 2026-07-13, before the tag-downlink experiments).
#
# Bash 3.2 compatible (stock macOS — review R2 finding 4: the previous version used
# associative arrays and silently exited 0 on flash failures; this one does neither).
#
#   firmware/known-good/restore.sh            # restore gpstag + tag + base (whichever connect)
#   firmware/known-good/restore.sh gpstag     # restore one role (gpstag|tag|base)
#
# The .uf2 / -dfu.zip files here are byte-identical copies of firmware/releases/v3.0/
# (verify: shasum -a 256 -c SHA256SUMS). Flashing goes through tools/flash_t1000e.sh with the
# release pinned. Exit code: 0 only if EVERY requested role flashed successfully.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FLASH="$REPO/tools/flash_t1000e.sh"
[ -x "$FLASH" ] || { echo "flasher not found: $FLASH" >&2; exit 1; }

flavor_for_role() {
    case "$1" in
        gpstag) echo "gps-tag" ;;
        tag)    echo "bridge-tag" ;;
        base)   echo "base-plain" ;;
        *)      echo "" ;;
    esac
}

if [ $# -eq 0 ]; then
    ROLES="gpstag tag base"
else
    ROLES="$*"
fi

FAILED=""
for role in $ROLES; do
    flavor="$(flavor_for_role "$role")"
    if [ -z "$flavor" ]; then
        echo "unknown role: $role (use gpstag|tag|base)" >&2
        exit 2
    fi
    echo "== restore $role <- $flavor (v3.0 known-good)"
    if VERSION=v3.0 "$FLASH" "$flavor" "$role"; then
        echo "== $role restored"
    else
        echo "== $role FAILED to restore" >&2
        FAILED="$FAILED $role"
    fi
done

if [ -n "$FAILED" ]; then
    echo "RESTORE INCOMPLETE — failed:$FAILED" >&2
    exit 1
fi
echo "Known-good restore complete: $ROLES"
