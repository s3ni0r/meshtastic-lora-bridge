# Bench regression suite (hardware-in-the-loop)

The protocol state machines (adaptive tiers, TTL dead-man, SIGNAL dedupe, TRACK
upload/commit/replay) have no host-side unit tests — their regression coverage is THIS suite,
run against real hardware: GPS tag on USB, **no phone app connected** (single PhoneAPI
client — a BLE-held node times out every serial connect). Run with the meshtastic pipx
python, from the repo root:

    PY=~/.local/pipx/venvs/meshtastic/bin/python
    $PY tools/bench/verify_sim.py     # parametric sim drives the real adaptive cycle
    $PY tools/bench/verify_track.py   # track upload (tid wire, chunks/CRC/commit) + replay
    $PY tools/bench/verify_fixes.py   # THE shipping gate — 22 hard assertions, exit 0 or bust

`verify_fixes.py` (R4-rigorous, all assertions consumed-once — an ACK emitted before a
request was sent can never credit it):

- **A** adaptive hysteresis: the band (slow < v < fast) never counts toward the downshift.
- **B1** upload correlation: every 0x85 ACK matched on sender + u32 tid + sub + offset,
  including a deliberate duplicate chunk; COMMIT with a WRONG tid NAKs; COMMIT + same-tid
  retry are idempotent; the committed course actually plays (coordinate-checked).
- **B2** A/B slot safety: stray BEGIN/ABORT never destroy the committed slot; BEGIN during
  playback is refused (splice guard).
- **B3** failed-commit honesty: a transfer whose declared CRC mismatches its data NAKs at
  COMMIT and KEEPS NAKing on retry — the surviving older track can never credit it.
- **B4** reboot durability with PROOF: geographically distinct staged data + a reboot
  verified by the device's restarted log-uptime counter (never "the port dropped" — macOS
  keeps /dev paths across re-enumeration) → the COMMITTED course plays afterwards, not the
  staged one.

Each script exits 0 only on full PASS; `tools/downlink_latency.py` adds latency measurement
(signal/rawlat/mode). Every release re-runs `verify_fixes.py` on the bench before tagging —
ideally against the RELEASED artifact after flashing it (done for v4.3: 22/22). The suite
has caught two real firmware bugs so far; never weaken an assertion to make it pass.
