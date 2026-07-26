# AGENTS.md — meshtastic-tracker

Guidance for ANY coding agent working in this repository. It encodes the architecture you'd
otherwise need to read many files to learn, the exact commands that work on this machine,
and the operational hazards that have already burned real time on real hardware. Repeatable
procedures live in `.agents/skills/*/SKILL.md`.

**Agent-files genericity rule (ENFORCED by `tools/tests/test_agent_files_layout.py`):**
everything written for agents lives in the shared standard layout — this file at the repo
root plus `.agents/skills/<name>/SKILL.md` (standard frontmatter). Tool-specific entry
points are SYMLINKS into it, never copies and never their own content: `CLAUDE.md →
AGENTS.md`, `.claude/skills/<name> → .agents/skills/<name>`, and any future vendor file
(`.cursorrules`, `.github/copilot-instructions.md`, `GEMINI.md`, …) follows the same
pattern. The layout test fails closed on ad-hoc locations, duplicated content, or a skill
whose frontmatter drifts from its directory name — run it with the other host gates.

## What this project is

Real-time GPS over LoRa: moving **Seeed T1000-E** tags (custom Meshtastic fork) stream
19-byte positions at multi-Hz to a T1000-E **Base** tethered to an iPhone running the
**MeshTracker** app (`ios/`). Deployment region **EU868** (duty-cycle-legal 2 Hz sustained);
bench work may exceed that only on the bench (see Hazards). Since branch `tag-downlink` the
GPS tag also *listens*: mode switching, operator beeps and an on-tag indoor simulator ride a
command channel through the Base at LoRa range (~0.2–0.35 s phone→tag).

```
Tag A: BLE5/LoRa bridge (Dronetag Remote ID → LoRa) ─┐
                                                     ├─LoRa─▶ Base ──BLE──▶ iPhone (MeshTracker)
Tag B: GPS tag (onboard AG3335, 4 Hz target → LoRa) ─┘
```

## Authoritative documents (read before touching the related area)

| Doc | Contract it owns |
|---|---|
| `docs/DOWNLINK.md` | **The wire contract**: portnum 260 ops (GET/SET/MODE/SIGNAL/SIM/TRACK), TRACK A/B slot semantics + u32 transfer-id ACKs, signal language, measured latencies |
| `docs/BATTERY_INTEGRATION.md` | Uplink payload byte map (19 B v4) for external consumers |
| `firmware/FORK.md` | Fork architecture, per-flavor build flags, GNSS unlock story |
| `docs/CAPACITY.md` | Airtime / EU868 duty math |
| `docs/DISCOVERY.md` | BLE typed-discovery contract for external apps (AutoShot): manufacturer-data layout, consumer rules |
| `docs/IOS_APP.md` | MeshTracker features + architecture (BLE model, screens, upload machinery) |
| `docs/HISTORY.md` | Dated milestone narrative (what shipped when, and why) |
| `PLAN.md`, `TODO.md`, `README.md` | Goals, roadmap state, current status (README = aspect index) |
| `tools/bench/README.md` | Hardware regression suite |

## Repository map

- `firmware/meshtastic-firmware/` — the vendor clone (**gitignored**; local safety branch
  `t1000e-fork`). This is where builds run and where firmware is EDITED.
- `firmware/src/` + `firmware/meshtastic-fork.patch` — the TRACKED fork: drop-in sources and
  the patch to vendor files. `firmware/sync-fork.sh` exports clone → repo after editing;
  `firmware/apply-fork.sh` reconstructs a fresh clone from vendor tag + patch + drop-ins.
  **Edit in the clone, then run `sync-fork.sh`. Never let the two drift.**
- `firmware/platformio-dependencies.lock.json` + `firmware/platformio-toolchain.lock.json` —
  path/content fingerprints for every resolved `.pio/libdeps` input AND the external
  platform/framework/toolchain/nrfutil/pio-venv trees. Release identity fails closed on an
  ignored cached edit or injection anywhere in them; the vendor base is pinned by full
  commit OID (movable tags are only cross-checked); release runs use the pinned
  `/usr/bin/git` and pipx `pio` with a fixed PATH. Ignored Python bytecode is executable
  input too: release builds must follow the cache-free, `PYTHONDONTWRITEBYTECODE=1`
  procedure in `.agents/skills/firmware-release/SKILL.md`. Never stamp a release by
  invoking `pio` directly; the trusted entry point is `python3 -I firmware/release_build.py`.
- `firmware/releases/vX.Y/` — versioned artifacts (`<flavor>.uf2`, `<flavor>-dfu.zip`,
  `SHA256SUMS`, `RELEASE.md` with pinned source commit). `firmware/known-good/restore.sh`
  reflashes the validated v3.0 fleet state (rollback).
- `ios/` — MeshTracker (SwiftUI). Protobufs are **hand-rolled** in `MeshProto.swift` (no
  codegen). Project is generated from `project.yml` (**run `xcodegen` after adding files**).
- `tools/` — `nodes.py` (fleet registry + role→port resolution), `flash_t1000e.sh`
  (hands-free serial-DFU flasher), `flash_uf2.py` (explicit double-tap/UF2-volume flasher),
  `downlink_latency.py`, `tools/bench/` (hardware regression suite).

## Fleet (bench hardware, resolved by `tools/nodes.py`)

| Role | Node id | USB serial |
|---|---|---|
| GPS tag (`gpstag`) | `!18e77545` (num 417822021) | `15B20E7A7AAD8AF0` |
| Base (`base`) | `!b0bb9cda` | `4A8693CC387EBD66` |
| Bridge tag (`tag`) | `!b4dbb54c` | `92EBF6B5B6C9AC37` |

## Commands that work on this machine

Python for anything meshtastic/serial: `/Users/s3ni0r/.local/pipx/venvs/meshtastic/bin/python`
(plain `python3` lacks the deps). Run bench/tools from the **repo root**.

```bash
# Firmware — one build per flavor (from firmware/meshtastic-firmware/):
PLATFORMIO_BUILD_FLAGS="-DGPS_TAG" pio run -e tracker-t1000-e                  # GPS tag
PLATFORMIO_BUILD_FLAGS="-DODID_SNIFFER -DODID_PHY_EXT -DHIGHRATE_POSITION_SENDER \
  -DHIGHRATE_POSITION_INTERVAL_MS=250" pio run -e tracker-t1000-e  # bridge (TX-only is runtime now)
pio run -e tracker-t1000-e                                                     # base

# Flash — POLICY (enforced by tools/tests/test_flash_policy.py): tools/flash_t1000e.sh is
# the ONE flasher, hands-free (release flavors AND `dev` = the current .pio build). Its
# touch -> re-find-same-silicon -> touchless-nrfutil dance is what makes serial-DFU reliable;
# raw `adafruit-nrfutil --touch` is banned (re-enumeration race wedged boards 4x).
tools/flash_t1000e.sh gps-tag gpstag             # release artifacts, by role
tools/flash_t1000e.sh dev gpstag                 # current dev build (build the flavor first!)
# Recovery only (board wedged; operator double-taps -> UF2 volume):
/Users/s3ni0r/.local/pipx/venvs/meshtastic/bin/python tools/flash_uf2.py gpstag <file.uf2>

# Host-only TRACK layout/capacity gate (must pass before the HIL suite):
python3 tools/bench/verify_track_layout.py

# Hardware regression suite (exit 0 = the ONLY acceptable outcome before shipping firmware):
/Users/s3ni0r/.local/pipx/venvs/meshtastic/bin/python -u tools/bench/verify_fixes.py

# iOS — build + install on the iPhone (STANDING RULE: every iOS change ends with this,
# not just a compile check; device id = the connected iPhone 17 Pro):
(
  cd ios
  xcodebuild -project MeshTracker.xcodeproj -scheme MeshTracker -configuration Debug \
    -destination 'id=3E5C778B-8B00-5E9A-9D74-B00576E90FB4' -derivedDataPath build \
    -allowProvisioningUpdates build
  xcrun devicectl device install app --device 3E5C778B-8B00-5E9A-9D74-B00576E90FB4 \
    build/Build/Products/Debug-iphoneos/MeshTracker.app
)

# Back at the repo root; TestFlight release needs the git-ignored .release-env:
ios/scripts/release.sh [version] --note "text"
```

## Protocol invariants (breaking any of these breaks the shipped app/fleet)

- Stream payload: **20-byte v5** on `PRIVATE_APP(256)` — see `docs/BATTERY_INTEGRATION.md`
  for the byte map. Payload LENGTH is the version signal (12/17/18/19/20). Flags: bit0 lock,
  bit1 moving, bit2 adaptive, bit3 slow tier, bit4 simulated, bits 5–7 source type. Byte 19
  = radio status (bit0 DEAF, bit1 PERMANENT, bit2 duty-clamped) — the GO-DEAF fallback
  confirmation.
- Command channel: portnum **260** on BOTH tag flavors (A1 parity), ops per
  `docs/DOWNLINK.md` (GET/SET/MODE/SIGNAL/SIM/TRACK/**RADIO 0x06**). Settings replies are
  20 bytes (v4): 14B settings + capability byte + radio-status byte + duty-floor u16 (the
  tag's OWN legal-minimum spacing — never re-derive from preset assumptions). SIGNAL v5
  carries a u32 sid with {sid,pattern} dedupe; RADIO carries a u32 rid; both get 7-byte
  correlated ACKs. TRACK is unchanged (u32 tid, 9-byte ACKs, A/B slots, cap 800).
- Senders build downlink packets with `priority=HIGH(100)`, `hop_limit=1`, `want_ack=false`.
  MODE/SET confirm via the stream echo; SIGNAL v5 / RADIO / TRACK via their correlated ACKs
  (retry the SAME sid/rid/tid until ACKed, bounded, then fail LOUDLY).
- Radio states (A4): runtime LISTENING/DEAF via the shared `TagRadioState` module (both
  flavors; `-DHIGHRATE_TX_ONLY` retired). HYBRID boots LISTENING always; PERMANENT persists
  its radio state and RADIO commands REWRITE the profile. GO-DEAF = ACK first, ~2 s grace
  re-ACKing duplicates, then mute. Both tags run `role=CLIENT_MUTE`; the Base needs no
  flavor logic.
- CALIBRATION mode and the simulator are TTL-dead-man guarded and never persisted — reboot
  always lands in ADAPTIVE with real GPS (HYBRID).
- Fleet radio reality (measured 2026-07-26): the bench fleet preset is **SHORT_TURBO** (not
  the ShortFast CAPACITY.md plans for EU deployment, and EU-illegal — entering EU_868 makes
  the firmware degrade the preset to LONG_FAST, splitting the air path). Any bench flow that
  cycles regions must restore region AND preset together and re-prove LoRa delivery
  (verify_fixes.py C5 does).

## Operational hazards (each of these cost real bench time — do not rediscover them)

1. **Single PhoneAPI client per node.** A BLE-connected phone app locks out USB serial — a
   healthy node looks dead to the CLI/bench. Disconnect the app before USB work.
2. **USB descriptors lie on macOS.** Product strings are served stale across re-enumeration,
   and the fleet has two bootloader generations with different identities (older
   `T1000-E-BOOT`/VID 0x239A vs Seeed 0.9.1 `T1000-E`/VID **0x2886**). Never infer app-vs-
   bootloader from descriptors: app mode streams logs at 115200 (bootloader is silent), and
   a real reboot shows the log uptime counter (`??:??:?? <secs>`) restarting near zero.
3. **The 1200-baud touch opens serial-DFU, not a UF2 disk** — same `/dev` path, no volume.
   A UF2 disk only exists after a button double-tap. A DFU session that isn't spoken to
   promptly goes permanently deaf (mute CDC) — only power-cycle/double-tap recovers it, so
   **never "probe" a healthy board's port at 1200 baud**. After the FOURTH wedge (2026-07-26,
   raw `adafruit-nrfutil --touch 1200` lost the re-enumeration race and dropped the board off
   the bus) this became an ENFORCED POLICY: ALL flashing goes through `tools/flash_t1000e.sh`
   (hands-free; its own touch -> re-find the same silicon by serial -> touchless nrfutil);
   DIY nrfutil/touch invocations anywhere else fail `tools/tests/test_flash_policy.py`.
   UF2 volume (`tools/flash_uf2.py`, operator double-tap) is the RECOVERY path.
4. **Never pipe a flasher through `head`/`grep -m N`.** The reader exiting SIGPIPE-kills
   nrfutil mid-upload and leaves an invalid app (bricked-to-bootloader). Redirect to a file
   and tail it afterwards.
5. **Monitor long operations actively** — bounded waits, output to a log file, progress
   shown every 15–30 s, 2× expected duration with no output = stall. Never wait blindly and
   never wait forever. The standard shape lives in `.agents/skills/long-running-ops/SKILL.md`.
6. **`| tail -1` (and friends) mask failures** — DFU errors have printed while exit codes
   read 0. Keep exit codes honest; check them stepwise.
7. **Secrets:** `.release-env` (repo root, git-ignored, ASC key ids) and the `.p8` under
   `~/.appstoreconnect/private_keys/` must never be committed.
8. **`lora.override_duty_cycle` is bench-only.** EU868 deployment must respect duty math in
   `docs/CAPACITY.md` (ShortFast 2 Hz sustained ≈ 9.5%... only legal per the plan's rules).

## Verification culture

This branch has survived four external-agent review rounds. The bar: every firmware change
that touches the protocol runs `tools/bench/verify_fixes.py` on real hardware to exit 0;
released binaries get re-verified after flashing (boot proven by log stream + fresh uptime,
wire proven by a probe). Releases pin their source commit in `RELEASE.md` and ship
`SHA256SUMS`; flash tooling verifies artifacts before touching any device. State what was
verified and how — never claim more reproducibility or safety than was actually measured.

## Skills (step-by-step procedures)

- `.agents/skills/flash-t1000e/SKILL.md` — flashing every path + wedged-board recovery
- `.agents/skills/long-running-ops/SKILL.md` — bounded, monitored execution of anything slow
- `.agents/skills/bench-verify/SKILL.md` — running/extending the hardware regression suite
- `.agents/skills/deploy-ios/SKILL.md` — build → install on iPhone (the standing rule for iOS changes)
- `.agents/skills/firmware-release/SKILL.md` — edit → sync → build flavors → cut a release
- `.agents/skills/release-testflight/SKILL.md` — TestFlight trains, identifiable builds, What-to-Test notes
