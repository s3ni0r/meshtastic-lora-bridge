# AG3335 10 Hz unlock — root cause and the fix (2026-07-04)

**Outcome: the T1000-E's AG3335 now runs at a measured, sustained 10 Hz fix rate.**
`GnssProbe: GNSS rate 10.02 fix/s (20.0 sent/s) (raised)` — reproducible on every boot.

## The misdiagnosis we inherited

Two units, exhaustively probed (see `results.md` "GPS rate — exhaustive root-cause"), both read as
"firmware-locked at 1 Hz": `$PAIR050` "got no ACK and no effect" via RAM, save+reboot and
save+RESETB, while `$PAIR062` sentence config "worked" — so the rate command specifically looked
disabled. The persist dance (`$PAIR382,1` → `$PAIR003` → …) left a unit unresponsive and was
written off as a brick trap, with `$PAIR382,1` blamed.

**Every one of those observations was an artifact of one unmodeled behavior:** this Seeed/Airoha
firmware's **command CPU auto-sleeps a few seconds after boot**. NMEA keeps streaming (the DSP/PE
side stays up), but incoming UART commands are silently ignored — no execution, no ACK.

- The `$PAIR062`s that "worked" were sent by Meshtastic's own init *inside the boot window*.
- Every `$PAIR050` we ever sent (v1 probe at t+15 s, unit #1's debug path) landed *after* the CPU
  had gone to sleep — never heard, never ACKed, never refused.
- `$PAIR021` detection succeeds at boot for the same reason (it's early), which made the interface
  look "fine" while later commands looked "filtered".
- The "brick": `$PAIR003`/`$PAIR650`-class power-downs without a *confirmed* `$PAIR382,1` latch
  leave the module deaf (per the LC29H spec, PAIR003 note 1: without the latch ACK "any other
  commands will not be received"). Recovery is the `GPS_RTC_INT` HIGH pulse — exactly what Seeed's
  own driver does at every scan start (`gnss_scan_start`, `t1000_e/peripherals/src/ag3335.c`).

The tell, in retrospect, sat in Seeed's driver all along: it blasts **`$PAIR382,1` twenty-five
times at scan start**. `$PAIR382,<n>` is "lock system sleep" — `1` = **keep the module awake**
(not "enter backup sleep" as we had it). Seeed spams it blind precisely because only sends that
land in an awake window count.

## The unlock (now automated in GnssRateProbe v2)

1. **Latch the sleep lock inside the boot window** — `probe()`'s GPS_TAG preamble sends
   `$PAIR382,1` ×6 right at GNSS power-on, and the probe re-sends it as its opening step.
   `$PAIR001,382,0` back = the command interface stays alive indefinitely.
2. **Set the rate** — `$PAIR050,100` → `$PAIR001,050,1` (in process) then `$PAIR001,050,0` (ok);
   effective **immediately** (no reboot, no persist dance, no constellation changes needed).
   `$PAIR050,250` is also accepted (ACK 0) — this firmware is not CSA4-restricted to 100/1000.
3. RAM-only by design: the setting resets on a GNSS power cycle, and the probe re-applies it on
   every boot (plus a resident sag-detector re-applies if the rate ever drops). With
   `position.gps_update_interval=1` the GPS never power-cycles mid-session.

Measured on unit #2 (node !18e77545, factory Meshtastic 2.6.11 base): baseline 0.99 fix/s →
**10.0 fix/s sustained** (20 sentences/s = GGA+RMC per fix), stable across 2+ minutes and across
reboots, indoors (no position lock required — rate is visible in the NMEA time-of-day cadence).

## Evidence log (fresh boot, abridged)

```
GnssProbe: << $PAIR001,062,0*3F        <- boot-window ACKs for Meshtastic's own init (never seen before v2's tap)
GnssProbe: >> $PAIR382,1*2E
GnssProbe: << $PAIR001,382,0*32        <- sleep lock LATCHED
GnssProbe: << $PAIR051,1000*13         <- fix interval query answers: 1000 ms
GnssProbe: >> $PAIR050,250*24
GnssProbe: << $PAIR001,050,0*3E        <- 4 Hz accepted (ACK 0)
GnssProbe: >> $PAIR050,100*22
GnssProbe: << $PAIR001,050,0*3E        <- 10 Hz accepted
GnssProbe: RAM-set immediate effect: 9.93 fix/s (ack 250=0, 100=0)
GnssProbe: *** WINNER (RAM set took effect immediately) — GNSS running at 9.93 fix/s (RAM only) ***
GnssProbe: GNSS rate 10.02 fix/s (20.0 sent/s) (raised)
```

## Why v1 (and unit #1's investigation) couldn't see it

v1 measured cadence but had no raw-response tap, started 15+ s after boot (CPU already asleep),
and treated silence as refusal. v2 added: a byte-level `$PAIR` tap in `GPS::whileActive()` (ACK
codes + verbatim replies), the boot-window latch, exact `$PAIR001` code decoding (0 ok / 3
unsupported / 4 param error), an echo test to distinguish deaf-vs-mute, and a reset+latch-spam
fallback to re-open the window. The latch made all of it moot — but those diagnostics are what
finally produced *evidence* instead of inference, and they stay in the firmware for the next unit.

Unit #1 (the bridge tag) was almost certainly never locked either; its GPS is unused in the
bridge role, so we haven't re-verified.

## References

- `Quectel_LC29H_LC79H_GNSS_Protocol_Specification_V1.1.pdf` (this directory; extracted text in
  `spec.txt`): $PAIR001 result codes §2.3.1, $PAIR050/051 §2.3.9-10, $PAIR382 §2.3.37 + PAIR003
  note 1 (the latch-before-power-off rule), $PAIR511/513 >1 Hz save rule, $PAIR650 backup mode.
- Seeed's AG3335 driver: `Seeed-Tracker-T1000-E-for-LoRaWAN-dev-board`,
  `t1000_e/peripherals/src/ag3335.c` (382,1 ×25 at scan start; RTC_INT wake pulse; 650,0 sleep).
- LC29H lineage notes (context, turned out not to apply): CSA2 removed $PAIR050; CSA4 restored it
  as 100/1000-only + reboot-to-apply.

## Knock-on settings

- GPS tag build now uses `-DHIGHRATE_MIN_SPACING_MS=100` (LoRa TX up to 10 Hz to match the GNSS;
  bench/US only — EU868 duty rules still cap sustained deployment ~2 Hz).
- `GPS_THREAD_INTERVAL=100` (already the GPS_TAG default) keeps parse latency ≤1 fix period.
