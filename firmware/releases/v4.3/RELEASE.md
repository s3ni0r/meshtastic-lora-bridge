# T1000-E tracker firmware — v4.3 (R4 review hardening — SUPERSEDES v4.0–v4.2)

Fourth external-review round. **Deploy this; the TRACK wire changed** (u32 transfer id in
every sub-op, 9-byte ACK) — pre-v4.3 apps cannot upload tracks to it and vice versa. The
shipped MeshTracker build updates in lockstep.

## Provenance

| What | Value |
|---|---|
| **Source of truth** | this repo, branch `tag-downlink`, commit **`a0c7de9`** ("fix: R4 external-review findings 1-10") |
| Vendor base | meshtastic/firmware tag `v2.7.15.567b8ea` + `meshtastic-fork.patch` + `firmware/src/` drop-ins |
| Reconstruction | `firmware/apply-fork.sh`; the Bluefruit framework hook runs automatically inside the first bridge-flavor `pio run` (SCons extra_script) and now **fails closed** — a bridge build cannot silently ship without the 255 B BT5 scan buffer |
| Toolchain | PlatformIO Core 6.1.19, env `tracker-t1000-e`; DFU zips: vendored adafruit-nrfutil (`--dev-type 0x0052 --sd-req 0x0123`) |
| Build date | 2026-07-26 |
| Reproducibility scope | source-mapped, NOT bit-exact (deps float, dates embedded, global framework hook — unchanged, documented limitation) |

## v4.3 over v4.2 (WIRE CHANGE on op 0x05)

- **Every TRACK sub-op carries the client's u32 transfer id** (`[0x05, sub, tid u32 LE, …]`);
  the ACK is 9 bytes and echoes the REQUEST's tid — cross-transfer CHUNK/COMMIT/ABORT can
  never mutate someone else's staging, and correlation is exact, not 1-in-255.
- **A/B generation slots replace the tmp+marker layout**: staging writes the inactive slot
  (header generation 0 = unplayable); COMMIT verifies content in place and promotes it by
  stamping generation = active+1. The previous committed track is **never opened for
  writing** — power loss, torn writes and CRC failures at any point leave it playable
  (highest valid generation wins; there is no marker/selector file to tear). Legacy
  `simtrack.*` files are removed on first track op; re-upload after upgrading.
- **COMMIT idempotence is keyed on (tid, crc)**: a retry after a FAILED commit keeps
  NAKing — an older surviving track can never credit a failed replacement as "verified".
- **Record cap 800** (was an unhonorable 1600): both slots at cap total 16,032 B of the
  28 KiB shared LittleFS. The iOS decimator targets the same cap.
- **BEGIN during TRACK playback is NAKed** — playback pins its slot file; a commit landing
  mid-play promotes the other slot, so splicing playback state into fresh data is impossible.

## Verification (tools/bench/verify_fixes.py, hard-asserted, exit-coded)

Full clean run on this exact source, flashed on the GPS tag: **22/22 PASS (exit 0)** —
adaptive band semantics; consumed-once per-frame ACK correlation (sender+tid+sub+offset,
ACKs indexed after each send so a prior ACK can never be reused) including the deliberate
duplicate chunk; wrong-tid COMMIT NAK; COMMIT + idempotent same-tid retry; **failed-commit
retry keeps NAKing** (the R4 f1 scenario); committed-slot survival across stray
BEGIN/ABORT; BEGIN-while-playing NAK; and **reboot durability with proof** — the reboot is
verified by the device's restarted log-uptime counter (~22 s), and the staged
data is geographically distinct from the committed course, so the post-reboot playback
coordinates prove WHICH generation played.

Flash: `tools/flash_t1000e.sh <flavor> [port|role|uf2]` — per-artifact checksums,
hardware-serial pinning, T1000-only volume identity (fail-closed). `tools/flash_uf2.py` is
the explicit double-tap/UF2-volume path: full image validation (block magics + nRF52840
family), single-candidate + bootloader-USB-serial pinning. Rollback:
`firmware/known-good/restore.sh` (v3.0). License: GPL-3.0 (root `LICENSE`).
