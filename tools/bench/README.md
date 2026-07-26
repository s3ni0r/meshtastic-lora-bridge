# Bench regression suite (hardware-in-the-loop)

The protocol state machines (adaptive tiers, TTL dead-man, SIGNAL dedupe, TRACK
upload/commit/replay) have no host-side unit tests — their regression coverage is THIS suite,
run against real hardware: Base + GPS tag on USB, no phone app connected (single PhoneAPI
client). Run with the meshtastic pipx python, from the repo root:

    PY=~/.local/pipx/venvs/meshtastic/bin/python
    $PY tools/bench/verify_sim.py     # parametric sim drives the real adaptive cycle
    $PY tools/bench/verify_track.py   # track upload (chunks/CRC/commit) + course replay
    $PY tools/bench/verify_fixes.py   # hysteresis-band semantics + dup-chunk retry +
                                      #   partial-slot refusal (commit marker)

Each prints a final PASS/FAIL verdict; tools/downlink_latency.py adds latency measurement
(signal/rawlat/mode). Every release should re-run all of these on the bench before tagging.
