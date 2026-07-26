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
  the ACK is 9 bytes and echoes the REQUEST's tid, making correlation exact rather than
  1-in-255. The release enforced ownership for COMMIT/ABORT, but not CHUNK; see the
  post-release transfer-isolation caveat below.
- **A/B generation slots replace the tmp+marker layout**: staging writes the inactive slot
  (header generation 0 = unplayable); COMMIT verifies content in place and promotes it by
  stamping generation = active+1. The previous committed track is **never opened for
  writing**, and the highest valid generation wins without a separate marker/selector file.
  The v4.3 bench verified that the previous generation survives CRC failure and an orderly
  reboot with an uncommitted staged slot. It did **not** power-cut the device or fault-inject
  a torn promotion write, so those cases remain architecture reasoning rather than measured
  release evidence. Legacy `simtrack.*` files are removed on first track op; re-upload after
  upgrading.
- **COMMIT idempotence is keyed on (tid, crc)**: a retry after a FAILED commit keeps
  NAKing — an older surviving track can never credit a failed replacement as "verified".
- **Record cap 800** (was an unhonorable 1600): both slots at cap total 16,032 B of the
  28 KiB shared LittleFS. The iOS decimator targets the same cap.
- **BEGIN during TRACK playback is NAKed** — playback pins its slot file; a commit landing
  mid-play promotes the other slot, so splicing playback state into fresh data is impossible.

> **Post-release capacity caveat:** v4.3's 800-record budget was logical, not an operational
> guarantee. These historical binaries promote a slot by rewriting offset 0, which can fail
> with `ENOSPC` under LittleFS copy-on-write pressure. Current post-v4.3 source replaces that
> rewrite with an appended commit footer and host-gates two full 800-record slots plus an
> 8 KiB prefs reserve against the exact bundled LittleFS geometry. The v4.3 artifacts and
> checksums are unchanged; that later proof does not apply retroactively to them.
>
> **Post-release transfer-isolation caveat:** although every v4.3 CHUNK carried a transfer id,
> the shipped handler parsed and discarded that field before writing. A wrong-tid CHUNK with
> an otherwise valid range could therefore mutate the current staging slot; only COMMIT/ABORT
> ownership was enforced as claimed. Current post-v4.3 source validates CHUNK ownership before
> any file access and verifies duplicate bytes exactly. Again, the immutable v4.3 artifacts and
> checksums are unchanged, and the stronger rule is not retroactive.

## Verification (tools/bench/verify_fixes.py, hard-asserted, exit-coded)

Full clean run on this exact source, flashed on the GPS tag: **22/22 PASS (exit 0)** —
adaptive band semantics; consumed-once per-frame ACK correlation (sender+tid+sub+offset,
ACKs indexed after each send so a prior ACK can never be reused) including the deliberate
duplicate chunk; wrong-tid COMMIT NAK; COMMIT + idempotent same-tid retry; **failed-commit
retry keeps NAKing** (the R4 f1 scenario); committed-slot survival across stray
BEGIN/ABORT; BEGIN-while-playing NAK; and **reboot durability with proof** — the reboot is
an orderly software reboot verified by the device's restarted log-uptime counter (~22 s).
The staged data is geographically distinct from the committed course, so the post-reboot
playback coordinates prove WHICH generation played. No power-cut or torn-write fault
injection was part of this release run.

Flash: `tools/flash_t1000e.sh <flavor> [port|role|serial|uf2]` — per-artifact checksums and
hardware-serial pinning on serial-DFU paths. The `uf2` shortcut is explicit, unpinned, and
single-volume only; use `tools/flash_uf2.py <role|serial> ...` for pinned double-tap recovery.
That tool enforces complete/unique blocks, nRF52840 family and the T1000-E application range,
then requires a T1000-only volume owned by the pinned USB serial. Rollback:
`firmware/known-good/restore.sh` (v3.0). License: GPL-3.0 (root `LICENSE`).
