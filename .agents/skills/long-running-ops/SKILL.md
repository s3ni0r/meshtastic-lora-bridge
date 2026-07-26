---
name: long-running-ops
description: Discipline for ANY command that runs longer than a few seconds (builds, flashes, bench suites, uploads, polls) — bounded waits, streamed output, active monitoring. Use whenever starting a build/flash/test run or waiting on device state.
---

# Long-running operations — never wait blindly, never wait forever

Owner rule (2026-07-26, repeat offense): every long-running command is **bounded** and its
**output stays visible while it runs**. No unbounded foreground waits, no fire-and-forget,
no silent multi-minute polls.

## The standard shape

```bash
# 1. Start it detached, output to a LOG FILE (never a pipe — see hazard below):
<command> > /tmp/<op>.log 2>&1 &            # or the harness's background-run facility

# 2. Monitor with a BOUNDED poll that surfaces progress every 15-30 s:
t0=$(date +%s)
until <completion-check> || [ $(( $(date +%s) - t0 )) -ge <budget_s> ]; do
    sleep 15
    tail -3 /tmp/<op>.log        # progress must be SHOWN each round, not just checked
done
tail -20 /tmp/<op>.log           # the verdict, from the log — with its real exit code
```

- `<budget_s>` = 2× the expected duration. Hitting the budget = a STALL: investigate,
  never extend silently. Known durations on this bench: pio flavor build ~65 s; serial-DFU
  flash ~40 s; bench suite ~6 min pre-C sections (assume ~12 min with C1–C5, which include
  three reboots); xcodebuild ~2–4 min.
- Completion checks must read a truth signal (an `exit=` sentinel appended to the log, a
  file appearing, a port resolving) — never "it's probably done by now".
- For foreground one-shots, ALWAYS pass an explicit timeout sized to the same 2× budget.

## Hard rules (each one has burned real bench time)

1. **Never pipe a long command through `head` / `grep -m N`** — the reader exiting
   SIGPIPE-kills the producer mid-work (a flasher died this way and bricked a board).
   Redirect to a file; filter the FILE afterwards.
2. **`| tail -1` and friends mask failures** — pipeline exit codes lie. Append your own
   `echo "exit=$?"` sentinel to the log and read THAT.
3. **Silence is a signal**: no new log output for 2× the expected step duration = stall.
   Say so and investigate; do not keep sleeping.
4. **Device-state waits are polls, not sleeps**: waiting for a port/volume/reboot is a
   bounded until-loop on the actual signal (port resolves, volume mounts, uptime counter
   restarts), reporting each round, with an explicit budget and a loud timeout verdict.
5. **One wait at a time gets narrated**: before starting a long op, state what is running,
   the expected duration, and what signal ends the wait — so the operator watching the
   session always knows why nothing seems to be happening.
