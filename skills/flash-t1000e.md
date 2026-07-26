# Flashing a T1000-E (and recovering one)

> **Use when:** Flash firmware onto a Seeed T1000-E (release or dev build), verify it booted, and recover a board wedged in its bootloader. Use for any "flash the tag/base/bridge", "update firmware on device", or "board not responding after flash" task.
>
> Agent-neutral procedure (standing rule C1: anything written for agents lives
> vendor-neutrally; `skills/flash-t1000e.md` is only the Claude Code shim).


Ground truth measured on this fleet 2026-07-26 — trust it over intuition:
- The **1200-baud touch opens a serial-DFU CDC on the SAME `/dev` path — no UF2 disk ever
  mounts**. A UF2 disk exists only after a button **double-tap**.
- A DFU session left unspoken-to goes **permanently mute** (ignores touches and handshakes).
  Only a power-cycle or double-tap recovers it. Therefore: never open a healthy board's port
  at 1200 baud "to check something".
- USB product/VID **cannot** identify app-vs-bootloader (stale descriptors + two bootloader
  generations: `T1000-E-BOOT`/0x239A and Seeed 0.9.1 `T1000-E`/0x2886). Proof of app mode =
  log stream at 115200; proof of reboot = the log uptime token (`??:??:?? <secs>`) near 0.
- **Never pipe flasher output through `head`/`grep -m`** — SIGPIPE kills nrfutil mid-upload
  and leaves an invalid app. Redirect to a file, tail after.

## Path 1 — released firmware, hands-free (default)

```bash
tools/flash_t1000e.sh gps-tag gpstag          # <flavor> <role|port|serial>; latest release
VERSION=v4.3 tools/flash_t1000e.sh base-plain base
```
Does everything fail-closed: manifest checksums → hardware-serial pin → 1200 touch →
re-find same silicon → `adafruit-nrfutil dfu serial` upload. Flavors: `gps-tag`,
`bridge-tag`, `base-plain`. Roles resolve via `tools/nodes.py`; omitted-target autodetection
considers only registry-known serials across both measured VIDs (0x239A/0x2886). An
unregistered board requires an explicit `/dev` path or 16-hex serial. The script validates
the serial, VID and complete nrfutil toolchain before the hazardous 1200-baud touch.

## Path 2 — dev build, hands-free

```bash
# 1. Package the fresh hex (adafruit-nrfutil lives in the PlatformIO tool package):
NRF="$HOME/.platformio/packages/tool-adafruit-nrfutil"
PY="$HOME/.local/pipx/venvs/platformio/bin/python"
(cd "$NRF" && PYTHONPATH=site-packages "$PY" adafruit-nrfutil.py dfu genpkg \
  --dev-type 0x0052 --sd-req 0x0123 \
  --application <repo>/firmware/meshtastic-firmware/.pio/build/tracker-t1000-e/firmware.hex \
  /tmp/dev-dfu.zip)
# 2. Upload — let nrfutil own the touch timing (most reliable form):
(cd "$NRF" && PYTHONPATH=site-packages "$PY" adafruit-nrfutil.py dfu serial --touch 1200 \
  --package /tmp/dev-dfu.zip -p /dev/cu.usbmodemXXXX -b 115200 --singlebank) > /tmp/flash.log 2>&1
tail -3 /tmp/flash.log   # expect "Device programmed."
```

## Path 3 — UF2 disk (explicit; also THE recovery path)

Requires the user to **double-tap the button** → a `T1000-E` disk mounts. Then:

```bash
/Users/s3ni0r/.local/pipx/venvs/meshtastic/bin/python tools/flash_uf2.py gpstag \
  firmware/releases/v4.3/gps-tag.uf2
```
Validates every UF2 block (magics, only the family-ID flag, nRF52840 family, payload bounds,
complete/unique numbering, no overlapping targets, and the T1000-E linker-script application
range `0x27000..<0xED000`), requires a T1000-identified volume, and walks the structured
IORegistry parent tree from that volume's exact BSD node to its nearest USB device. A sibling
or parent hub serial can never satisfy the role pin. `cp` errors like "Device not configured"
mid-copy are NORMAL; the truth signal is the volume unmounting (image accepted).

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
on) — a valid app boots. 2) Still solid → user double-taps → UF2 disk mounts → Path 3.
3) Full fleet rollback to validated v3.0: `firmware/known-good/restore.sh`.
