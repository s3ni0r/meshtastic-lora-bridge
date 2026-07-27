# T1000-E tracker firmware — v4.5 (A2+A3: typed discovery, function names, rename)

The identity round, on top of v4.4's radio states. **First release where the Base flavor
matters**: all three flavors now advertise their TYPE over BLE, so external apps (AutoShot)
stop guessing from names. Embedded identity: **`v4.5.2248bb23`** (device metadata
`firmware_version`).

## Provenance

| What | Value |
|---|---|
| **Source of truth** | this repo, branch `tag-downlink`, commit **`2248bb2`** ("A2+A3: typed BLE discovery + function-stating names + persistent rename") |
| Vendor base | meshtastic/firmware tag `v2.7.15.567b8ea` (pinned by full OID) + `meshtastic-fork.patch` + `firmware/src/` drop-ins |
| Reconstruction | `firmware/apply-fork.sh`; Bluefruit 255 B scan-buffer hook runs fail-closed inside the first bridge-flavor `pio run` |
| Build entry | `python3 -I firmware/release_build.py` per flavor — pre/post attestation, pinned `/usr/bin/git` + pipx `pio`, fixed PATH |
| Toolchain | PlatformIO Core 6.1.19, env `tracker-t1000-e`; DFU zips: vendored adafruit-nrfutil |
| Build date | 2026-07-27 |
| Reproducibility scope | source-mapped, NOT bit-exact (documented limitation) |

## v4.5 over v4.4 (additive; BLE advertisement + defaults only — no LoRa wire change)

- **Typed BLE discovery (A2)** — all three flavors put manufacturer data in the BLE scan
  response: `[0xFFFF]['M']['T'][ver=1][type][nodeNum u32 LE]` with type 1 = bridge,
  2 = GPS tag, 3 = Base. Coexists with the stock Meshtastic service-UUID primary advert.
  **`docs/DISCOVERY.md` is the external consumer contract** (AutoShot). Boot log prints
  `DISC adv: ver=1 type=<t> node=0x<id>` — the bench-visible proof.
- **Function-stating factory names (A3)** — a factory-fresh owner defaults to
  `TAG-GPS-xxxx` / `TAG-BR-xxxx` / `BASE-xxxx` instead of `Meshtastic xxxx`. Renames
  (admin owner field) persist over them; existing provisioned names are untouched.
- No portnum-260 or stream-payload changes: the v4.4 wire contract (`docs/DOWNLINK.md`)
  applies verbatim. The MeshTracker build shipped alongside keys Base discovery on the
  typed advert (name heuristics only for pre-A2 firmware) and adds persistent rename over
  the direct link.

## Verification (hard-asserted, exit-coded, real hardware, 2026-07-27)

Dev builds of this exact source, per flavor, before the cut:

- GPS tag `!18e77545`: **`verify_fixes.py` 70/70 PASS (exit 0)** — full A/B/C surface
  (adaptive band, TRACK durability incl. uptime-verified reboots, sid signals, radio
  states with real LoRa deafness via the Base, PERMANENT persistence, EU868 duty-floor
  round-trip with air-path restore proof). Boot log shows
  `DISC adv: ver=1 type=2 node=0x18e77545`.
- Bridge `!b4dbb54c`: **`verify_bridge.py` 20/20 PASS (exit 0)** (capability honesty, sid
  signals, radio ops, spacing knob, adv+scan coexistence boot marker). Before this round
  the same board also completed a **~3 h instrumented soak on v4.4 with zero faults**
  (29.8 MB continuous log; the one prior silent USB-drop incident did not recur and
  remains unexplained — watch item).
- Base `!b0bb9cda`: flashed from this source, boot-verified (fresh uptime + log stream),
  `DISC adv: ver=1 type=3 node=0xb0bb9cda` captured, and the relay function re-proven
  (bridge ~2.3 pkt/s + GPS tag idle-tier heard over the air and forwarded).
- Released-artifact re-verification: recorded below after the fleet flash from THIS
  directory (same discipline as v4.4).

Post-cut re-verification (released artifacts, 2026-07-27): all three released UF2s flashed
to the fleet; **identities confirmed in device metadata (`v4.5.2248bb23` on all three)**;
`verify_fixes.py` **70/70 exit 0** re-run against the released gps-tag binary. The released
bridge binary streams correctly on the air (~2.3 pkt/s relay observed via the Base), but its
`verify_bridge.py` re-run is PENDING: this specific board's USB link wedged/failed to
re-enumerate twice during the attempt (app provably alive on LoRa throughout — the tracked
"bridge USB-CDC mute" bench issue, `TODO.md`; suspicion is board/cable hardware since the
other two boards ran dozens of identical reboot cycles cleanly tonight). The identical
SOURCE ran 20/20 as a dev build one hour earlier; the released-binary run will be recorded
here once the USB path is stable.

Sniffer-coexistence numbers (measured on this code line, live Dronetag): slow adv ≈ −14 %
scan callbacks, held BLE connection ≈ −40–45 % (transient by design) — details + caveats in
`docs/DOWNLINK.md`. Still unmeasured: LISTENING-vs-DEAF current draw; power-cut fault
injection (standing caveats). Fleet preset remains SHORT_TURBO (EU-illegal — deployment
preset decision still open, `TODO.md`).

Flash: `tools/flash_t1000e.sh <flavor> [port|role|serial]` (v4.5 = latest). Recovery:
`tools/flash_uf2.py` after a double-tap. Rollback: `firmware/known-good/restore.sh` (v3.0).
License: GPL-3.0.
