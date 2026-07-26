# T1000-E tracker firmware — v4.1 (R2 review hardening — SUPERSEDES v4.0)

v4.0's binaries predate the second external review; v4.1 is the same feature set rebuilt from
the R2-fixed source. **Deploy this, not v4.0.**

## Provenance

| What | Value |
|---|---|
| **Source of truth** | this repo, branch `tag-downlink`, commit **`b44cd57`** ("fix: R2 external-review findings") |
| Vendor base | meshtastic/firmware tag `v2.7.15.567b8ea` + `meshtastic-fork.patch` + `firmware/src/` drop-ins |
| Reconstruction | `firmware/apply-fork.sh` (mirrors all drop-ins + runs the idempotent bluefruit framework patch) |
| Toolchain | PlatformIO Core 6.1.19, env `tracker-t1000-e`; DFU zips: vendored adafruit-nrfutil (`--dev-type 0x0052 --sd-req 0x0123`) |
| Build date | 2026-07-26 |
| Reproducibility scope | source-mapped, NOT bit-exact (see v4.0 RELEASE.md — unchanged limitation) |

## v4.1 over v4.0 (all bench-verified — `tools/bench/`, full suite PASS on this build)

- **Correlated TRACK ACKs**: op-0x05 replies are `[0x85, status, sub, offLo, offHi]` — clients
  match (sub, offset) exactly; stale/foreign ACKs can never credit a frame. ⚠ Wire change:
  pre-v4.1 apps that expected the generic 15-byte reply for op 0x05 must update (the shipped
  MeshTracker build already has).
- **Durable, idempotent COMMIT**: success writes the `simtrack.ok` marker (committed CRC);
  playback requires marker + content CRC — a reboot between last-chunk and COMMIT leaves an
  unplayable slot; repeated COMMITs on a committed slot report success.
- Everything else identical to v4.0 (downlink, adaptive TX with band-correct hysteresis,
  payload v4, simulator, EU-legal 500 ms default spacing).

Flash: `tools/flash_t1000e.sh <flavor> [port|role|uf2]` — per-artifact checksums enforced,
hardware-serial re-resolution after the DFU touch, UF2 volumes only in explicit `uf2` mode.
Rollback: `firmware/known-good/restore.sh` (v3.0; Bash-3.2-safe, failures propagate).
License: GPL-3.0 (root `LICENSE`); this repository is the complete corresponding source.
