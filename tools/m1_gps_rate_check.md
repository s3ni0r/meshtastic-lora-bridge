# M1 — Validate the AG3335 honors a fast fix rate (`$PAIR050`)

**Goal:** confirm *your specific* T1000-E's GNSS firmware accepts a sub-second fix rate before
we commit any firmware change. This is the single biggest unknown in the whole project — some
AG3335/LC29H revisions only accept 100 ms or 1000 ms and reject 250 ms; a few don't support
`$PAIR050` at all.

## Commands (NMEA, XOR checksum between `$` and `*`)

| Interval | Rate | Command |
|---|---|---|
| 1000 ms | 1 Hz | `$PAIR050,1000*12` |
| 500 ms | 2 Hz | `$PAIR050,500*26` |
| 250 ms | 4 Hz | `$PAIR050,250*24` |
| 200 ms | 5 Hz | `$PAIR050,200*21` |
| 100 ms | 10 Hz | `$PAIR050,100*22` |

Save after setting: `$PAIR513*3D`.

## What success looks like

1. Module replies `$PAIR001,050,0` — the `0` = command accepted. (`$PAIR001,050,1` or `,2` = bad
   parameter / not supported → fall back.)
2. `$GxRMC` / `$GxGGA` timestamps then advance at the requested cadence (e.g. 4 fixes/sec for 250 ms).

## How to talk to the GPS UART

The AG3335 is on an internal UART, not the USB CDC that Meshtastic uses. Options, easiest first:

- **Bench fork (recommended):** add a one-shot debug path in a local `GPS.cpp` build that writes
  the `$PAIR050,250*24` string to `_serial_gps` at boot and logs the raw GPS bytes back over the
  Meshtastic serial console. This tests the exact UART/baud the production code will use (115200).
- **Direct probe:** if you can reach the module's TX/RX test pads, a USB-UART adapter at 115200
  + a serial terminal lets you send the commands and watch the ACK + RMC cadence directly.

## Decision

- **ACK `,0` + cadence advances at 250 ms** → use `$PAIR050,250*24` (4 Hz) in the fork (M4).
- **250 ms rejected, 100 ms accepted** → use `$PAIR050,100*22` (10 Hz hardware) and **decimate**
  in firmware to the 2 Hz TX cadence.
- **`$PAIR050` unsupported entirely** → GNSS is capped at 1 Hz; the onboard-GPS path tops out at
  ~1 Hz and Phase 2 (Apple Watch / external GPS injection) becomes the route to higher rates.

Record the outcome here once tested.
