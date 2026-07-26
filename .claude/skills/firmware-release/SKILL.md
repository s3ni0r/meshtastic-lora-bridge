---
name: firmware-release
description: Edit fork firmware correctly (clone vs tracked artifacts), build the three T1000-E flavors, and cut a provenance-pinned release (uf2 + dfu.zip + SHA256SUMS + RELEASE.md). Use for any firmware change or "cut release vX.Y".
---

# Firmware editing, building, and cutting a release

## The two-tree rule (get this wrong and the fork silently drifts)

- **Edit/build** in the vendor clone: source under
  `firmware/meshtastic-firmware/src/...` and project-owned build hooks at their clone paths
  (gitignored; local safety branch `t1000e-fork`). Builds run there.
- `firmware/release_identity.py` is an outer-repo helper loaded by the clone-side
  `bin/readprops.py`; edit that helper directly in the tracked outer tree.
- `firmware/platformio-dependencies.lock.json` fingerprints every resolved file under
  `.pio/libdeps/tracker-t1000-e` by relative path and content. Release identity rejects a
  modified or injected cached library source even though `.pio/` is Git-ignored. After an
  intentional dependency change, resolve libraries in a freshly reconstructed clone, inspect
  the dependency/version changes, recompute the count + digest with
  `_dependency_tree_fingerprint`, and review the lock change before committing it.
- Python bytecode is executable build input, not disposable noise. The patched
  `bin/platformio-custom.py` executes `readprops.py` source explicitly, and `readprops.py`
  does the same for the outer release helper. Release builds still remove project bytecode,
  set `PYTHONDONTWRITEBYTECODE=1`, and fail attestation if any ignored `.pyc`/`.pyo` remains.
- `firmware/platformio-toolchain.lock.json` content-locks the EXTERNAL build inputs: the
  nordicnrf52 platform, the Arduino framework (in its Bluefruit-patched state), the GCC
  toolchain, adafruit-nrfutil, and the PlatformIO core venv that supplies `pio`. Attestation
  purges derived bytecode under those trees, then fingerprints them (symlinks hash as their
  literal targets). The lock is machine-local by design (absolute `~` roots) — a different
  machine fails closed until it deliberately regenerates and reviews the lock:
  `python3 -I firmware/release_identity.py write-toolchain-lock` (after a PlatformIO
  platform/toolchain update, review the diff before committing).
  `write-dependencies-lock` regenerates the libdeps lock the same way.
- The vendor base is pinned by **full commit OID** (`FIRMWARE_BASE_COMMIT` in
  `release_identity.py`, `BASE_OID` in `apply-fork.sh` — update BOTH when bumping): every
  attestation diff measures against the immutable object, and a moved
  `v2.7.15.567b8ea` tag fails closed instead of silently redefining the base.
- Release runs never resolve executables through PATH: Git is pinned to `/usr/bin/git`
  (Apple CLT shim), `pio` to the locked pipx venv launcher, and the child build gets a
  fixed system PATH.
- **Export** after editing: `firmware/sync-fork.sh` → refreshes the TRACKED
  `firmware/src/` source drop-ins, project-owned `firmware/vendor/` build-hook drop-ins, and
  `firmware/meshtastic-fork.patch`. Commit those.
- **Reconstruct** a fresh clone: `firmware/apply-fork.sh` (vendor tag `v2.7.15.567b8ea` +
  patch + whole-tree source/build-hook drop-in copy). The Bluefruit 255 B scan-buffer hook
  runs automatically inside the first bridge-flavor `pio run` (SCons extra_script, now
  fail-closed) — it is NOT a standalone step.
- Adding a NEW source or build-hook drop-in file? Also add it to the lists in `sync-fork.sh`
  and `apply-fork.sh`.

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
2. From the outer repo root, run the host-only layout/capacity gate, then the hardware bench
   gate with the dependency-bearing interpreter:
   ```bash
   set -euo pipefail
   REPO="$(git rev-parse --show-toplevel)"
   python3 "$REPO/tools/bench/verify_track_layout.py"
   /Users/s3ni0r/.local/pipx/venvs/meshtastic/bin/python -u \
     "$REPO/tools/bench/verify_fixes.py"
   ```
   Both exits must be 0 (see `bench-verify`).
3. While the committed outer tree is still clean, build through the **tracked outer wrapper**,
   never by setting release variables on `pio` directly. The ignored clone's build hook cannot
   be its own root of trust: a tampered hook could skip its self-check. `release_build.py`,
   launched with Python isolated mode, attests the clone before invoking PlatformIO, runs a
   clean build with exact flavor flags, re-attests before and after compilation, validates the
   UF2 plus embedded `vX.Y.<sha8>` identity, and only then exports UF2/HEX to `build-out`.
   It strips every inherited `PLATFORMIO_*`, `PYTHON*`, `SCONS*`, and `GIT_*` override before
   setting its one controlled `PLATFORMIO_BUILD_FLAGS` value, so callers cannot redirect source,
   dependencies, scripts, import caches, Git state, or output away from the attested paths.
   The attestor requires clean outer `HEAD`, exact patch/drop-in parity, the locked 1,733-file
   dependency tree, and no unexpected ignored executable input. Resolve dependencies with a
   normal development build first; missing or mismatched inputs fail closed:
   ```bash
   set -euo pipefail
   REPO="$(git rev-parse --show-toplevel)"     # run this block from the OUTER repo
   RELEASE=vX.Y
   SOURCE_SHA="$(git -C "$REPO" rev-parse HEAD)"
   IDENTITY="$RELEASE.$(printf '%.8s' "$SOURCE_SHA")"
   BUILD_OUT="$REPO/firmware/build-out"

   # Keep .pio/libdeps (it is content-locked), but remove project bytecode before preflight.
   find "$REPO/firmware/meshtastic-firmware" \
     -path "$REPO/firmware/meshtastic-firmware/.pio" -prune -o \
     -type f \( -name '*.pyc' -o -name '*.pyo' \) -print -delete

   for flavor in gps-tag bridge-tag base-plain; do
     python3 -I "$REPO/firmware/release_build.py" \
       --release "$RELEASE" --source-sha "$SOURCE_SHA" --flavor "$flavor"
   done
   ```
4. Continue in the same shell. Package into `build-out` using absolute paths, then verify the
   stamped identity in every UF2 and the actual `.bin` payload inside every DFU archive
   **before** copying artifacts into the release directory:
   ```bash
   : "${REPO:?run step 3 first}" "${RELEASE:?run step 3 first}" \
     "${BUILD_OUT:?run step 3 first}" "${IDENTITY:?run step 3 first}"
   NRF="$HOME/.platformio/packages/tool-adafruit-nrfutil"
   PY="$HOME/.local/pipx/venvs/platformio/bin/python"
   for flavor in gps-tag bridge-tag base-plain; do
     (cd "$NRF" && PYTHONPATH=site-packages "$PY" adafruit-nrfutil.py dfu genpkg \
       --dev-type 0x0052 --sd-req 0x0123 \
       --application "$BUILD_OUT/$flavor.hex" "$BUILD_OUT/$flavor-dfu.zip")
   done
   "$PY" - "$REPO" "$BUILD_OUT" "$IDENTITY" <<'PY'
   import pathlib, struct, sys, zipfile

   repo, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
   identity = sys.argv[3].encode()
   sys.path.insert(0, str(repo / "tools"))
   import flash_uf2

   def uf2_runs(path):
       raw = path.read_bytes()
       chunks = []
       for offset in range(0, len(raw), flash_uf2.UF2_BLOCK_SIZE):
           block = raw[offset:offset + flash_uf2.UF2_BLOCK_SIZE]
           target, size = struct.unpack_from("<II", block, 12)
           start = flash_uf2.UF2_DATA_OFFSET
           chunks.append((target, block[start:start + size]))
       runs, run_end = [], None
       for target, payload in sorted(chunks):
           if target != run_end:
               runs.append(bytearray())
           runs[-1].extend(payload)
           run_end = target + len(payload)
       return runs

   for flavor in ("gps-tag", "bridge-tag", "base-plain"):
       uf2 = root / f"{flavor}.uf2"
       flash_uf2.validate_uf2(uf2)
       if not any(identity in run for run in uf2_runs(uf2)):
           raise SystemExit(f"{flavor}.uf2 does not contain {identity.decode()}")
       with zipfile.ZipFile(root / f"{flavor}-dfu.zip") as archive:
           payloads = [n for n in archive.namelist() if n.endswith(".bin")]
           if len(payloads) != 1 or identity not in archive.read(payloads[0]):
               raise SystemExit(f"{flavor}-dfu.zip payload does not contain {identity.decode()}")
       print(f"{flavor}: release identity OK ({identity.decode()})")
   PY

   RELEASE_DIR="$REPO/firmware/releases/$RELEASE"
   mkdir -p "$RELEASE_DIR"
   cp "$BUILD_OUT"/{gps-tag,bridge-tag,base-plain}.uf2 "$RELEASE_DIR/"
   cp "$BUILD_OUT"/{gps-tag,bridge-tag,base-plain}-dfu.zip "$RELEASE_DIR/"
   ```
5. Still in that shell:
   `cd "$RELEASE_DIR" && shasum -a 256 *.uf2 *-dfu.zip > SHA256SUMS && shasum -a 256 -c SHA256SUMS`
6. Write `RELEASE.md` (copy the previous release's structure): pinned source commit, embedded
   `vX.Y.<sha8>` identity, vendor tag, toolchain (PlatformIO 6.1.19), wire changes, and
   verification statement. Honesty rule: builds are **source-mapped, NOT bit-exact** — say so.
7. Flash the RELEASED gps-tag artifact (see `flash-t1000e`), confirm its stamped identity in
   device metadata/logs, and verify boot from the log stream plus fresh uptime. Ideally re-run
   the bench against the released binary, THEN commit the release directory.
8. Wire changes on portnum 260 / the payload must ship with the matching `MeshProto.swift`
   update and `docs/DOWNLINK.md` contract row in the same release.

Rollback of the whole fleet: `firmware/known-good/restore.sh` (validated v3.0).
