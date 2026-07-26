# Hardware bench verification

> **Use when:** Run (or extend) the hardware-in-the-loop regression suite that gates every firmware protocol change — adaptive TX semantics, TRACK upload/commit/reboot durability. Use before shipping firmware, after flashing, or when asked to "verify on hardware".
>
> Agent-neutral procedure (standing rule C1: anything written for agents lives
> vendor-neutrally; `skills/bench-verify.md` is only the Claude Code shim).


The suite is the shipping gate: **exit 0 or it does not ship.** It asserts on real hardware
(GPS tag on USB): adaptive hysteresis band semantics, consumed-once correlated TRACK ACKs
(sender+tid+sub+offset), wrong-tid NAKs, idempotent COMMIT retry, failed-commit retry
KEEPS NAKing, stray BEGIN/ABORT survival, BEGIN-while-playing NAK, and reboot durability
with generation proof (distinct staged coordinates + uptime-verified reboot).

## Preconditions

- GPS tag on USB, resolvable: `nodes.resolve("gpstag")` (registry in `tools/nodes.py`).
- **No phone app connected to the tag over BLE** — a BLE client locks out the USB PhoneAPI
  (single-client rule) and every connect will time out. If `SerialInterface` times out on a
  node that streams logs fine, this is why.
- Run from the **repo root** with the pipx python.

## Run the host-only layout gate first

```bash
cd <repo-root>
python3 tools/bench/verify_track_layout.py
```

This exercises the immutable-header/appended-footer format (including every torn-footer
length), source invariants, and both full 800-record slots on the exact bundled LittleFS
implementation and T1000-E geometry. `OVERALL: PASS` + exit 0 is mandatory, and no board is
touched.

## Run it (foreground, fully streamed — never wait blindly)

```bash
cd <repo-root>
set -o pipefail
/Users/s3ni0r/.local/pipx/venvs/meshtastic/bin/python -u tools/bench/verify_fixes.py \
  2>&1 | tee /tmp/bench.log
```
`pipefail` preserves the Python failure status; never append a filtering `grep` that can turn
a traceback or `[FAIL]` into pipeline exit 0. Takes ~6 minutes (75 s band test + uploads + a
real reboot with ~45 s of waits). Keep the complete phase/PASS output visible; if there is no
output for 2× the expected phase duration, treat it as a stall and investigate.

Companion scripts: `verify_track.py` (upload+replay walkthrough), `verify_sim.py`
(parametric simulator), `tools/downlink_latency.py` (signal/mode latency legs).

## Reading results

- `OVERALL: PASS` + exit 0 is the only green. Any `[FAIL]` line names the exact assertion.
- A FAIL can indict the TEST, not the firmware (it happened: an unreliable "port dropped"
  reboot check on macOS). Judge the assertion's evidence before touching firmware — but
  remember the suite has also caught real firmware bugs twice; never weaken an assertion
  just to pass.

## Extending it (conventions that keep it honest)

- New wire ops: every TRACK frame is `[0x05, sub, tid u32 LE, ...]`; ACK `[0x85, status,
  sub, offLo, offHi, tid u32]` (9 B). Send via `cmd(...)` which returns the pre-send ack
  index; match with `await_ack(mark, sub, off, tid)` — ACKs are consumed-once (an ACK
  emitted before your send can never credit your frame). Keep it that way.
- Prove state transitions with EVIDENCE, not absence: reboot = log uptime counter restarts
  (`??:??:?? <secs>` < 90), never "the port disappeared" (macOS keeps `/dev` paths across
  re-enumeration). Which-data-played = geographically distinct fixtures + coordinate
  assertions on the simulated stream (flags bit4).
- Accumulate failures in `FAILURES`, print `OVERALL`, `sys.exit(0/1)`. No soft verdicts.
