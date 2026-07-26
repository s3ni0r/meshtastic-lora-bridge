# T1000-E tracker firmware — v4.2 (R3 review hardening — SUPERSEDES v4.0/v4.1)

Third external-review round. **Deploy this; v4.0/v4.1 predate the transfer-identity and
staging fixes.**

## Provenance

| What | Value |
|---|---|
| **Source of truth** | this repo, branch `tag-downlink`, commit **`aad8966`** ("fix: R3 external-review findings") |
| Vendor base | meshtastic/firmware tag `v2.7.15.567b8ea` + `meshtastic-fork.patch` + `firmware/src/` drop-ins |
| Reconstruction | `firmware/apply-fork.sh`; the Bluefruit framework hook runs automatically inside the first bridge-flavor `pio run` (SCons extra_script — it is NOT a standalone step) |
| Toolchain | PlatformIO Core 6.1.19, env `tracker-t1000-e`; DFU zips: vendored adafruit-nrfutil (`--dev-type 0x0052 --sd-req 0x0123`) |
| Build date | 2026-07-26 |
| Reproducibility scope | source-mapped, NOT bit-exact (deps float, dates embedded, global framework hook — unchanged, documented limitation) |

## v4.2 over v4.1 (wire change — pre-v4.2 apps must update; shipped MeshTracker has)

- **TRACK BEGIN carries a per-upload nonce** (`count u16, crc32 u32, nonce u8`, nonce ≠ 0);
  **every 0x85 ACK is `[status, sub, offLo, offHi, nonce]`** and clients must additionally
  validate the sender node — a delayed ACK from a previous upload or another tag can never
  satisfy the current transfer.
- **Transactional staging**: uploads build `simtrack.tmp`; the committed live slot stays
  playable throughout and is replaced only after the staged file's CRC verifies at COMMIT.
  Stray BEGIN/ABORT are harmless; ABORT discards staging only.
- **TRACK ops from mesh peers are rejected** (local phone/USB client only — the op is
  destructive by design and must not be remotely drivable).
- Exact duplicate-chunk matching (offset AND length); CRC32 value 0 handled correctly.

## Verification (tools/bench/, hard-asserted, exit-coded)

Full clean run on this exact firmware: **OVERALL PASS (exit 0)** — adaptive band semantics,
per-frame ACK correlation (sender+nonce+sub+offset) including the deliberate duplicate chunk,
COMMIT + idempotent COMMIT retry, committed-slot survival across stray BEGIN/ABORT, and
**reboot durability** (staged-without-commit discarded; committed slot plays after reboot).
The suite also caught + killed one bug during this round (an abandoned BEGIN disabling
playback of a valid slot) — the regression net works.

Flash: `tools/flash_t1000e.sh <flavor> [port|role|uf2]` — per-artifact checksums, hardware-
serial pinning (fail-closed), single-candidate UF2 mode. Rollback: `firmware/known-good/
restore.sh` (v3.0). License: GPL-3.0 (root `LICENSE`).
