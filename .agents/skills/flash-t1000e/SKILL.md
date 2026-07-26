---
name: flash-t1000e
description: Flash firmware onto a Seeed T1000-E (release or dev build), verify it booted, and recover a board wedged in its bootloader. Use for any "flash the tag/base/bridge", "update firmware on device", or "board not responding after flash" task.
---

# Flashing a T1000-E (and recovering one)

## THE RULE (owner, 2026-07-26 — enforced by `tools/tests/test_flash_policy.py`)

**`tools/flash_t1000e.sh` is the ONE flasher — hands-free, no operator action needed.**
Release flavors and dev builds both go through it. Never invoke `adafruit-nrfutil` yourself:
its `--touch 1200` reopens the SAME `/dev` path right after its own touch, loses the macOS
re-enumeration race ("Device not configured"), and strands the board in its bootloader —
this exact mistake wedged boards four times. The script wins because of its dance:

1. preflights artifacts + the complete DFU toolchain BEFORE anything hazardous;
2. pins the target by **hardware serial** (never a `/dev` path);
3. performs its own 1200-baud touch (open → DTR low → close, port never reused);
4. **re-finds the same silicon by serial, waiting out re-enumeration (up to 12 s)**;
5. runs the nrfutil upload **without `--touch`** on the refound port.

## Ground truth (measured on this fleet — trust it over intuition)

- The **1200-baud touch opens a serial-DFU CDC on the SAME `/dev` path — no UF2 disk ever
  mounts**. A UF2 disk exists only after a button **double-tap**.
- A DFU session left unspoken-to goes **permanently mute** (ignores touches and handshakes).
  Only a power-cycle or double-tap recovers it. Never open a healthy board's port at
  1200 baud "to check something".
- USB product/VID **cannot** identify app-vs-bootloader (stale descriptors + two bootloader
  generations: `T1000-E-BOOT`/0x239A and Seeed 0.9.1 `T1000-E`/0x2886). Proof of app mode =
  log stream at 115200; proof of reboot = the log uptime token (`??:??:?? <secs>`) near 0.
- **Never pipe flasher output through `head`/`grep -m`** — SIGPIPE kills nrfutil mid-upload
  and leaves an invalid app. Redirect to a file, tail after.

## Flash — released firmware (hands-free, the default)

```bash
tools/flash_t1000e.sh gps-tag gpstag          # <flavor> <role|port|serial>; latest release
VERSION=v4.3 tools/flash_t1000e.sh base-plain base
```
Fail-closed: manifest checksums → hardware-serial pin → touch → re-find same silicon →
upload. Flavors: `gps-tag`, `bridge-tag`, `base-plain`. Roles resolve via `tools/nodes.py`;
an unregistered board requires an explicit `/dev` path or 16-hex serial.

## Flash — dev build (hands-free, same dance)

```bash
# Build the flavor you mean to flash IMMEDIATELY before (all three share one .pio output):
tools/flash_t1000e.sh dev gpstag
```
Packages the current `.pio/build/tracker-t1000-e/firmware.hex` fresh, then runs the exact
same pinned/refound serial-DFU path. Run it per the long-running-ops discipline
(`.agents/skills/long-running-ops/SKILL.md`): bounded timeout, output to a log file,
tail while it runs.

## Recovery path — UF2 volume (needs the operator)

Only when a board is already wedged (invalid app, mute bootloader): ask the operator to
**double-tap the button** → a `T1000-E` disk mounts → then:

```bash
/Users/s3ni0r/.local/pipx/venvs/meshtastic/bin/python tools/flash_uf2.py gpstag \
  firmware/releases/v4.3/gps-tag.uf2      # or the dev firmware.uf2
```
Validates every UF2 block (magics, nRF52840 family, payload bounds, complete numbering,
T1000-E application range `0x27000..<0xED000`), requires a T1000-identified volume, and pins
it to the owner's USB serial via the IORegistry parent walk. `cp` errors like "Device not
configured" mid-copy are NORMAL; the truth signal is the volume unmounting (image accepted).

## Always verify the boot (any path)

```bash
/Users/s3ni0r/.local/pipx/venvs/platformio/bin/python - <<'EOF'
import serial, time, re
time.sleep(15)
s = serial.Serial("/dev/cu.usbmodemXXXX", 115200, timeout=1)
t0 = time.time(); d = b""
while time.time() - t0 < 10 and len(d) < 1000: d += s.read(256)
s.close()
secs = [int(m) for m in re.findall(rb"\?\?:\?\?:\?\? (\d+) ", d)]
print("log bytes:", len(d), "| uptime:", max(secs) if secs else None)  # logs + small uptime = booted
EOF
```
Silence ≠ bootloader necessarily: a BLE-connected phone app also silences USB (single
PhoneAPI client). Disconnect the app, or verify via the OTHER node hearing its LoRa stream.

## Recovery decision tree (board unresponsive / LED solid on)

Solid LED = bootloader waiting. 1) Ask the user to power-cycle (hold button ~8 s off, ~3 s
on) — a valid app boots. 2) Still solid → user double-taps → UF2 disk mounts → recovery
path above. 3) Full fleet rollback to validated v3.0: `firmware/known-good/restore.sh`.
