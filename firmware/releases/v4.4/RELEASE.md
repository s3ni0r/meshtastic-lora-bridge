# T1000-E tracker firmware — v4.4 (A1+A4: radio states, guaranteed delivery, bridge parity)

The radio-state round. **Deploy this; the wire grew on portnum 260 and the stream** (all
additive — pre-v4.4 apps keep working on the v3/v4 surfaces they know, but only the shipped
MeshTracker build drives the new RADIO op, sid signals and profiles). Embedded identity:
**`v4.4.e2b8a9e8`** (readable in device metadata `firmware_version`).

## Provenance

| What | Value |
|---|---|
| **Source of truth** | this repo, branch `tag-downlink`, commit **`e2b8a9e`** ("bench: sniffer coexistence A/B measured") — firmware content identical to `ba3d2f8`, the commit that ran the release gates |
| Vendor base | meshtastic/firmware tag `v2.7.15.567b8ea` (pinned by full OID) + `meshtastic-fork.patch` + `firmware/src/` drop-ins |
| Reconstruction | `firmware/apply-fork.sh`; Bluefruit 255 B scan-buffer hook runs fail-closed inside the first bridge-flavor `pio run` |
| Build entry | `python3 -I firmware/release_build.py` per flavor — pre/post attestation (clean outer HEAD, patch/drop-in parity, content-locked libdeps + toolchain trees, no ignored bytecode), pinned `/usr/bin/git` + pipx `pio`, fixed PATH |
| Toolchain | PlatformIO Core 6.1.19, env `tracker-t1000-e`; DFU zips: vendored adafruit-nrfutil (`--dev-type 0x0052 --sd-req 0x0123`) |
| Build date | 2026-07-26 |
| Reproducibility scope | source-mapped, NOT bit-exact (deps content-locked but dates embedded; documented limitation) |

## v4.4 over v4.3 (additive wire changes on 260 + stream; `-DHIGHRATE_TX_ONLY` retired)

- **Runtime radio states (A4)** on BOTH tag flavors via the shared `TagRadioState` module:
  LISTENING / DEAF, HYBRID (deafness never persists) / PERMANENT (persisted; RADIO commands
  REWRITE the profile). New **RADIO op 0x06** `[state u8][rid u32]` → 7-byte ACK
  `[0x86,status,state,rid]`, ACK-BEFORE-MUTE with a ~2 s re-ACKing grace window.
- **SIGNAL v5**: `[0x03][pattern][sid u32]` → 7-byte ACK `[0x83,status,pattern,sid]`;
  {sid,pattern} dedupe ring (8 deep): exact re-send re-ACKs without replay, conflict NAKs.
  Legacy 3-byte form kept (settings-echo reply).
- **Settings v4**: SET accepts 14 bytes (profile byte); every settings echo is **20 bytes**:
  14 B settings + capability byte (GPS tag 0x3F / bridge 0x38) + radio-status byte + the
  tag's own **duty-floor u16** (region law × measured airtime at the ACTIVE preset — clients
  must never re-derive it from preset assumptions).
- **Stream payload v5 (20 B)**: byte 19 = radio status (bit0 DEAF · bit1 PERMANENT · bit2
  duty-clamped) — the GO-DEAF fallback confirmation channel.
- **Bridge parity (A1)**: the bridge serves portnum 260 (signals/radio/profiles; MODE, SIM
  and TRACK NAK per its capability byte), boots LISTENING, and advertises slow connectable
  BLE (~1.0 s interval) alongside the continuous ODID scan.
- **Duty legality is self-enforced**: live SETs below the floor reject; persisted values a
  region change makes illegal clamp at use + flag "duty-degraded". Under EU868+LONG_FAST the
  measured floor (5590 ms) exceeds the settable range — every SET rejects, clamp stays on.

Full contract: `docs/DOWNLINK.md`; behavior: `docs/RADIO_STATES.md`; payload byte map:
`docs/BATTERY_INTEGRATION.md`.

## Verification (hard-asserted, exit-coded, real hardware, 2026-07-26)

On this exact firmware source as dev builds (2026-07-26), then re-verified against the
RELEASED artifacts (2026-07-27): the released `gps-tag.uf2` was flashed via
`flash_t1000e.sh`, its `v4.4.e2b8a9e8` identity confirmed in device metadata, and the full
suite re-run against it — **70/70 PASS (exit 0)**. The released `bridge-tag.uf2` was then
flashed the same way (2026-07-27), `v4.4.e2b8a9e8` confirmed in device metadata, and
`verify_bridge.py` re-run against it — **20/20 PASS (exit 0)**. (First post-flash run
surfaced radio-status 0x03: a PERMANENT-DEAF profile persisted during app-side testing —
correct boot-per-profile behavior, restored to HYBRID over USB; recorded here because a
boot-deaf bridge is silent on LoRa commands by design and the profile survives reflashes.)

- `tools/bench/verify_fixes.py` (GPS tag `!18e77545` + Base `!b0bb9cda`): **70/70 PASS
  (exit 0)** — the full v4.3 regression surface (adaptive band, TRACK correlation/A-B
  slots/failed-commit/reboot-with-generation-proof) plus: 20-byte v4 reply surface; sid
  dedupe/conflict/unknown NAKs; GO-DEAF ACK-before-mute + in-grace re-ACK; stream status
  fallback; **real LoRa deafness** (3 Base-relayed attempts unanswered while DEAF, delivery
  restored after un-deafen, retry-until-ACK sender contract); PERMANENT·DEAF surviving an
  uptime-verified reboot + profile rewrite via RADIO; EU868 duty-floor round-trip with full
  radio-identity restore (region + preset together) and a post-restore air-path proof.
- `tools/bench/verify_bridge.py` (bridge `!b4dbb54c`): **20/20 PASS (exit 0)** — 20-byte
  surface, capability honesty (MODE/SIM/TRACK NAK), sid signals, deaf/listen over the local
  path, TX-spacing knob, uptime-verified reboot with the adv+scan coexistence boot marker.
- Sniffer coexistence A/B (live Dronetag, its built-in flight sim): slow advertising costs
  ~14 % of scan callbacks; a held BLE connection ~40–45 % (transient by design). Numbers +
  source-drift caveats: `docs/DOWNLINK.md`.
- Not measured in this release: LISTENING-vs-DEAF current draw (needs a probe); physical
  power-cut fault injection on the track-slot commit path (unchanged standing caveat).

Fleet note (measured 2026-07-26): the bench fleet preset is **SHORT_TURBO**, which is not
EU868-legal — EU deployment requires an explicit preset decision and re-anchored duty math
(`docs/CAPACITY.md` assumes ShortFast). The duty-floor reply byte makes the tags
self-describing either way.

Flash: `tools/flash_t1000e.sh <flavor> [port|role|serial]` (hands-free, checksum + serial
pinned; `dev` flashes the current build tree). Recovery: `tools/flash_uf2.py` after a
double-tap. Rollback: `firmware/known-good/restore.sh` (v3.0). License: GPL-3.0.
