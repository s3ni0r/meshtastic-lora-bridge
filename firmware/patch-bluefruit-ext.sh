#!/usr/bin/env bash
# BT5 / EXTENDED ODID sniffing only: grow the Adafruit Bluefruit scan receive buffer 31 -> 255 bytes
# so a BT5 extended ODID message pack isn't truncated (status INCOMPLETE_TRUNCATED). Bluefruit hardcodes
# a 31-byte buffer; the S140 v7.3 SoftDevice supports up to 255 for extended adverts.
#
# The lib lives in the PlatformIO package OUTSIDE this repo, so a clean checkout reverts to 31 bytes.
# Re-run this before building with -DODID_PHY_EXT. NOT needed for the default BT4 legacy build.
# Idempotent: once patched, BLE_GAP_SCAN_BUFFER_MAX no longer matches, so re-runs are no-ops.
set -euo pipefail
LIB=~/.platformio/packages/framework-arduinoadafruitnrf52/libraries/Bluefruit52Lib/src
H="$LIB/BLEScanner.h"
C="$LIB/BLEScanner.cpp"
[ -f "$H" ] && [ -f "$C" ] || { echo "Bluefruit lib not found at $LIB"; exit 1; }
sed -i '' 's/_scan_data\[BLE_GAP_SCAN_BUFFER_MAX\]/_scan_data[BLE_GAP_SCAN_BUFFER_EXTENDED_MAX_SUPPORTED]/' "$H"
sed -i '' 's/_report_data.len     = BLE_GAP_SCAN_BUFFER_MAX;/_report_data.len     = BLE_GAP_SCAN_BUFFER_EXTENDED_MAX_SUPPORTED;/g' "$C"
echo "patched Bluefruit scan buffer -> 255 bytes (extended). Confirm:"
grep -n "BLE_GAP_SCAN_BUFFER_EXTENDED_MAX_SUPPORTED" "$H" "$C"
