---
name: firmware-release
description: Edit fork firmware correctly (clone vs tracked artifacts), build the three T1000-E flavors, and cut a provenance-pinned release (uf2 + dfu.zip + SHA256SUMS + RELEASE.md). Use for any firmware change or "cut release vX.Y".
---

# Firmware editing, building, and cutting a release

## The two-tree rule (get this wrong and the fork silently drifts)

- **Edit** in the vendor clone: `firmware/meshtastic-firmware/src/...` (gitignored; local
  safety branch `t1000e-fork`). Builds run there.
- **Export** after editing: `firmware/sync-fork.sh` → refreshes the TRACKED
  `firmware/src/` drop-ins + `firmware/meshtastic-fork.patch`. Commit those.
- **Reconstruct** a fresh clone: `firmware/apply-fork.sh` (vendor tag `v2.7.15.567b8ea` +
  patch + whole-tree drop-in copy). The Bluefruit 255 B scan-buffer hook runs automatically
  inside the first bridge-flavor `pio run` (SCons extra_script, now fail-closed) — it is
  NOT a standalone step.
- Adding a NEW drop-in file? Also add it to the list in `sync-fork.sh`.

## Build the three flavors (from `firmware/meshtastic-firmware/`)

```bash
PLATFORMIO_BUILD_FLAGS="-DGPS_TAG" pio run -e tracker-t1000-e
PLATFORMIO_BUILD_FLAGS="-DODID_SNIFFER -DODID_PHY_EXT -DHIGHRATE_POSITION_SENDER \
  -DHIGHRATE_POSITION_INTERVAL_MS=250 -DHIGHRATE_TX_ONLY" pio run -e tracker-t1000-e
pio run -e tracker-t1000-e     # base-plain
```
Copy `.pio/build/tracker-t1000-e/firmware.{uf2,hex}` out under a flavor name after EACH
build (the next build overwrites it). Run builds backgrounded with logs to a file.

## Release checklist (order matters — provenance pins a commit)

1. **Commit the source changes first** — `RELEASE.md` pins that hash.
2. Bench gate: `tools/bench/verify_fixes.py` → exit 0 on hardware (see `bench-verify`).
3. Build all three flavors from that commit; package each:
   ```bash
   NRF="$HOME/.platformio/packages/tool-adafruit-nrfutil"
   PY="$HOME/.local/pipx/venvs/platformio/bin/python"
   (cd "$NRF" && PYTHONPATH=site-packages "$PY" adafruit-nrfutil.py dfu genpkg \
     --dev-type 0x0052 --sd-req 0x0123 --application <flavor>.hex \
     firmware/releases/vX.Y/<flavor>-dfu.zip)
   cp <flavor>.uf2 firmware/releases/vX.Y/<flavor>.uf2
   ```
4. `cd firmware/releases/vX.Y && shasum -a 256 *.uf2 *-dfu.zip > SHA256SUMS && shasum -a 256 -c SHA256SUMS`
5. Write `RELEASE.md` (copy the previous release's structure): pinned source commit, vendor
   tag, toolchain (PlatformIO 6.1.19), wire changes, verification statement. Honesty rule:
   builds are **source-mapped, NOT bit-exact** — say so.
6. Flash the RELEASED gps-tag artifact (see `flash-t1000e`), verify boot (log stream +
   fresh uptime) and ideally re-run the bench against the released binary, THEN commit the
   release directory.
7. Wire changes on portnum 260 / the payload must ship with the matching `MeshProto.swift`
   update and `docs/DOWNLINK.md` contract row in the same release.

Rollback of the whole fleet: `firmware/known-good/restore.sh` (validated v3.0).
