# Project history — dated milestones (newest first)

The detailed narrative that used to live in the README. Raw measurements: `results.md`.

## 2026-07-26 — branch `tag-downlink`: bidirectional tag, adaptive TX, simulator, v4.3

Full contract in [DOWNLINK.md](DOWNLINK.md); all bench-validated on hardware.

- **Four external-review rounds absorbed; firmware release v4.3 current** (supersedes
  v4.0–v4.2 — WIRE CHANGE on TRACK: u32 transfer id in every sub-op, 9-byte ACK). Track
  storage is A/B generation slots (cap 800 records): the committed track is never opened
  for writing; a failed COMMIT keeps NAKing on retry. Hardware regression suite
  ([../tools/bench/](../tools/bench/README.md)) 22/22, exit 0, against the RELEASED
  gps-tag binary. Agent onboarding added: [../AGENTS.md](../AGENTS.md) + `.claude/skills/`.
- **The GPS tag listens now** (RX enabled; CLIENT_MUTE still bars rebroadcast): mode
  switching, signals and the simulator ride portnum 260 through the Base at LoRa range or
  a direct link. Command latency phone→tag ≈ **0.2–0.35 s** (Base fast-lane + API-poll
  fixes, measured).
- **Adaptive TX** (boot default, EU-duty-safe): full rate above 5 km/h instantly,
  1 pkt/3 s when quasi-stationary (15 s sustain) — all four knobs phone-tunable (settings
  wire v3), mode/tier echoed in every packet's flags. **CALIBRATION mode** (fixed max rate
  for AutoShot) is TTL-dead-man guarded: forgotten = auto-revert, reboot = adaptive.
- **Beep-first operator signals** (AutoShot's grammar): 1–8 counted beeps = progress, long
  high beep = recording started (+ silent LED heartbeat), low repeating beep = problem,
  0 = cancel. Test panel in the app.
- **Payload v4 (19 B)**: byte 18 = raw QMA6100P motion-energy envelope + flags bit1
  `moving` — zero added airtime; sessions record it (the dataset that will tune the surf
  thresholds).
- **Indoor simulator ON the tag**: parametric speed programs, accel-coupled "shake to
  move", and GPX / recorded-session track replay (upload once over direct BLE, replay
  anywhere) — synthetic fixes drive the *real* firmware path and self-declare via flags
  bit4.

## 2026-07-13 — payload v3: live battery everywhere (firmware v3.0)

Every stream packet carries the sending tag's own cell % (byte 17; 101 = USB-powered), so
tag battery updates at the position rate; the Base — which never streams — pushes stock
DeviceMetrics over BLE every 15 s (fork tweak) and the app decodes portnum 67 (also the
fallback for pre-v3 tags). Badges in the status capsule, tag rows and Tag Setup; recorded
per point in sessions (`bt`) for %/hour drain analysis. ShortFast airtime 45 → 48 ms
(EU 2 Hz = 9.5% duty, still legal — CAPACITY.md recomputed). v3.0 is the **known-good
rollback state**: `firmware/known-good/restore.sh`.

## 2026-07-07 — v2.0 baseline: the outdoor-validated release

Field-approved GNSS profile shipped as default: Fitness nav mode (the mode that actually
ran during the approval test — this unit rejects Swimming, ACK 4), 0.3 m/s static freeze,
14 dB SNR mask, 10° elevation mask, 4 Hz GNSS, 150 ms TX spacing (~6.7 Hz cap; the EU868
2 Hz profile is one tap in the app for legal sustained use in France).

- **AG3335 GNSS unlocked to 10 Hz** — the historical "1 Hz firmware lock" was a
  misdiagnosis (the command CPU auto-sleeps post-boot; the fix is a boot-window
  `$PAIR382,1` latch + `$PAIR050`). Deployed at a 4 Hz target, steered per boot by
  `GnssRateProbe`, France/Europe GNSS preset (GPS+GLONASS+Galileo+BDS, EGNOS SBAS verified
  active). Full story: [gnss/UNLOCK_NOTES.md](gnss/UNLOCK_NOTES.md).
- **Live GNSS tuning from the phone** (no reflash): nav mode, static freeze, SNR mask,
  elevation mask, fix rate, TX spacing, one-tap profiles — persisted on the tag
  (`/prefs/gnsstag.dat`), applied live via `GnssConfigModule` (portnum 260).
- **Direct-to-tag mode**: no Base alive? The app falls back to the tag's own BLE within
  ~6 s and receives the stream directly; the settings sheet rides the same link.
- **Honest accuracy**: the payload's ±m carries the receiver's own GST 1-σ estimate (HDOP
  heuristic fallback). Boot diagnostics verified: AIC on, jamming-detect on, EASY
  genuinely unsupported on this build (TTFF assist = future EPO injection, see TODO).
- **Session recording & analysis** (measurement-grade): verbatim crash-safe capture,
  sessions library, full-resolution multi-session projection, moment explorer, GPX + CSV
  exports. Details: [IOS_APP.md](IOS_APP.md).
- **iOS app v2**: per-tag colored trails + heading arrows, favorites, per-tag show/hide,
  pin/follow focus, map styles, fit-all, metric tiles, CSV logging, app icon.
- **GPS tag runs `role=CLIENT_MUTE`** (RX enabled later by tag-downlink); the bridge tag
  remains TX-only.

## 2026-06/07 — phase 1: two tag flavors, first releases (v1.0–v1.2)

Two interchangeable tag firmwares over the same `PRIVATE_APP(256)` payload: the BLE5/LoRa
**bridge** (sniffs Dronetag Remote ID advertisements, retransmits over LoRa — the original
>1 Hz solution) and the self-contained **GPS tag** (onboard AG3335). Flags bits 5–7
identify the source on top of the LoRa `from` id. Versioned, checksummed releases +
`tools/flash_t1000e.sh`. Bench validation on US/ShortTurbo (devices' as-found config);
milestones and raw numbers: [results.md](results.md), plan and constraints:
[../PLAN.md](../PLAN.md).
