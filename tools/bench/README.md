# Bench regression suite (hardware-in-the-loop)

The protocol state machines (adaptive tiers, TTL dead-man, SIGNAL dedupe, TRACK
upload/commit/replay) have no host-side unit tests — their regression coverage is THIS suite,
run against real hardware: GPS tag on USB, **no phone app connected** (single PhoneAPI
client — a BLE-held node times out every serial connect). Run with the meshtastic pipx
python, from the repo root:

    PY=~/.local/pipx/venvs/meshtastic/bin/python
    $PY tools/bench/verify_sim.py     # parametric sim drives the real adaptive cycle
    $PY tools/bench/verify_track.py   # track upload (tid wire, chunks/CRC/commit) + replay
    $PY tools/bench/verify_fixes.py   # THE shipping gate — 28 hard assertions, exit 0 or bust

`verify_fixes.py` (R4-rigorous, all assertions consumed-once — an ACK emitted before a
request was sent can never credit it) generates fresh transfer ids and a distinct committed
course on every invocation, so an earlier run's active tid/data cannot credit a rerun:

- **A** adaptive hysteresis: the band (slow < v < fast) never counts toward the downshift.
  The SIM start must first receive this tag's exact post-send success reply; a lost command
  is retried instead of wasting the observation window and masquerading as a tier failure.
- **B1** upload correlation: every 0x85 ACK matched on sender + u32 tid + sub + offset;
  wrong-tid CHUNK/COMMIT NAK, changed-byte duplicate NAK, exact duplicate ACK, active-tid
  BEGIN refusal, and COMMIT retry idempotence are all asserted; the committed course actually
  plays (coordinate-checked).
- **B2** A/B slot safety: stray BEGIN/ABORT never destroy the committed slot; BEGIN during
  playback is refused (splice guard).
- **B3** failed-commit honesty: a transfer whose declared CRC mismatches its data NAKs at
  COMMIT and KEEPS NAKing on retry — the surviving older track can never credit it.
- **B4** reboot durability with PROOF: geographically distinct staged data + a reboot
  verified by the device's restarted log-uptime counter (never "the port dropped" — macOS
  keeps /dev paths across re-enumeration) → the COMMITTED course plays afterwards, not the
  staged one; the original successful COMMIT retry remains idempotent from on-disk proof.

Each script exits 0 only on full PASS; `tools/downlink_latency.py` adds latency measurement
(signal/rawlat/mode). Every release re-runs `verify_fixes.py` on the bench before tagging —
ideally against the RELEASED artifact after flashing it (done for v4.3's historical suite:
22/22). The current post-v4.3 suite passed **28/28** on the physical GPS tag on 2026-07-26,
including confirmed reboot/re-enumeration, committed-generation coordinate proof, and
post-reboot COMMIT retry. That result validates the working-tree build, not the immutable
v4.3 release artifacts. The suite has caught real firmware bugs; never weaken an assertion
to make it pass.
