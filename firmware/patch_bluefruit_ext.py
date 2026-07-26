# PlatformIO pre-build hook: auto-apply the Bluefruit 255 B scan-buffer patch when building the
# BT5 / Coded ODID sniffer (-DODID_PHY_EXT). Bluefruit hardcodes a 31 B scan buffer, which truncates
# extended (BT5) advertising PDUs. The S140 v7.3 SoftDevice supports up to 255. Idempotent + a no-op
# for the default BT4 legacy build. This makes BT5 builds self-contained (no manual patch step).
#
# FAIL-CLOSED (R4 finding 9): when ODID_PHY_EXT is set, every required framework file must end
# up patched (or already be patched). A missing file or an unrecognized upstream source ABORTS
# the build — a bridge image without the 255 B scanner would truncate every BT5 PDU and is
# worse than no build at all.
#
# Tracked copy: firmware/patch_bluefruit_ext.py (mirrored by firmware/sync-fork.sh). Wired in via
# variants/nrf52840/tracker-t1000-e/platformio.ini extra_scripts.
Import("env")  # noqa: F821
import os
import sys

flags = " ".join(str(x) for x in env.get("CPPDEFINES", [])) + " " + os.environ.get("PLATFORMIO_BUILD_FLAGS", "")
if "ODID_PHY_EXT" not in flags:
    print("patch_bluefruit_ext: ODID_PHY_EXT not set, leaving Bluefruit scan buffer at default (BT4)")
else:
    lib = os.path.expanduser(
        "~/.platformio/packages/framework-arduinoadafruitnrf52/libraries/Bluefruit52Lib/src"
    )
    subs = {
        os.path.join(lib, "BLEScanner.h"): (
            "_scan_data[BLE_GAP_SCAN_BUFFER_MAX]",
            "_scan_data[BLE_GAP_SCAN_BUFFER_EXTENDED_MAX_SUPPORTED]",
        ),
        os.path.join(lib, "BLEScanner.cpp"): (
            "_report_data.len     = BLE_GAP_SCAN_BUFFER_MAX;",
            "_report_data.len     = BLE_GAP_SCAN_BUFFER_EXTENDED_MAX_SUPPORTED;",
        ),
    }
    problems = []
    for path, (old, new) in subs.items():
        if not os.path.exists(path):
            problems.append(f"required framework file missing: {path}")
            continue
        txt = open(path).read()
        if old in txt:
            open(path, "w").write(txt.replace(old, new))
            print("patch_bluefruit_ext: patched ->255B:", os.path.basename(path))
        elif "BLE_GAP_SCAN_BUFFER_EXTENDED_MAX_SUPPORTED" in txt:
            print("patch_bluefruit_ext: already patched:", os.path.basename(path))
        else:
            problems.append(
                f"unrecognized upstream source (neither the expected pattern nor an applied "
                f"patch found): {path} — framework version changed? Update the patterns."
            )
    if problems:
        for p in problems:
            print("patch_bluefruit_ext: ERROR:", p, file=sys.stderr)
        sys.exit("patch_bluefruit_ext: ABORTING the ODID_PHY_EXT build — the 255 B scan-buffer "
                 "patch could NOT be guaranteed (a silently unpatched bridge truncates every "
                 "BT5 PDU).")
