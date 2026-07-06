# TODO — sensor fusion roadmap (QMA6100P + battery)

Findings from the 2026-07-04 brainstorm on exploiting the T1000-E's remaining sensors for better
tag tracking. Context: GPS tag streams onboard AG3335 fixes at 4 Hz (see `firmware/FORK.md` §9);
payload is 17 bytes on `PRIVATE_APP(256)`, flags bits 1–4 still free.

## Findings (the physics that shaped the plan)

**QMA6100P accelerometer** (3-axis, 14-bit @ ±2 g ≈ 0.24 mg/LSB, ~1–3 mg RMS noise, HW
any-motion/no-motion engines at µA cost, INT on P1.02, driver `src/motion/QMA6100PSensor.cpp`):

- **Dead reckoning is physically impossible with this part** — ±20–50 mg temperature-drifting
  bias double-integrates to ~10 m error in 10 s, ~350 m in 60 s; and with no gyro/magnetometer,
  every degree of unknown tilt leaks ~170 mg of gravity into the horizontal axes (100× signal).
  Do NOT attempt INS-style integration between fixes.
- **Motion classification is where it's near-perfect**: stationary-vs-moving from acceleration
  variance (hysteresis: >~50 mg for 0.5 s → moving; <~20 mg for ~3 s → parked) is orientation-
  independent and rock-solid. GPS is blind exactly here: a parked tag's fixes wander 1–5 m
  (70 m measured in bad multipath) and render as fake movement.
- GPS speed lags reality ~0.5–1 s; the accel detects start/stop instantly (polish for the
  phone-side interpolation, minor at 4 Hz).
- ~~Impact/free-fall bit~~ — dropped, not useful for this project.

**Battery**: valuable, trivial — percent already available in firmware power status; 1 byte.

## Roadmap (priority order)

### 1. Payload v3: `moving` bit + battery byte  [firmware + iOS + tools]
- [ ] Firmware: motion state machine on QMA6100P (variance + hysteresis as above), publish
      **flags bit1 = moving**; append **byte 17 = battery %** → 18-byte payload.
- [ ] iOS: decode both; show battery per tag (list row + metric tile), "parked/moving" state.
- [ ] tools/m2_stream_poc.py: parse v3 (graceful for 17/12-byte).
- Risk to test on-device: QMA I²C init timing/contention was flagged as risky in earlier work —
  validate boot stability before shipping.

### 2. Parked-position handling in the app (ZUPT display fusion)  [iOS only]
- [ ] While `moving == 0`: freeze the marker (stop trail growth), average incoming fixes
      (√N gain, realistically 2–3×), force speed 0, hold heading, show "parked".
- [ ] While moving: reject fixes implying physically impossible jumps for the motion class
      (multipath spikes), e.g. >8 m step between 250 ms fixes while accel energy says walking.

### 3. Motion-gated TX  [firmware]
- [ ] Full 4 Hz stream while `moving`, drop to the 2 s heartbeat while parked (keep the
      any-motion interrupt path so the first fix after departure goes out in ~ms).
- [ ] Biggest battery lever available (700 mAh cell); also frees channel airtime at rest.
- [ ] Measure: %/hour parked and moving, before/after (DeviceMetrics logging).

### 3.5 GNSS field-quality follow-ups (from the 2026-07-06 outdoor test)
- [x] Motion-tuning ACKs verified on-device ($PAIR080/070/058 all ACK 0; mode 7 Swimming
      rejected ACK 4 on this unit). Accuracy pack shipped in v1.2: GST-backed hacc ($PAIR062,8,1
      ACK 0), elevation-mask knob ($PAIR072 ACK 0), AIC confirmed on, jamming events enabled.
      EASY ($PAIR490) is UNSUPPORTED on this build (ACK 3) — TTFF path is EPO injection only.
- [ ] Outdoor check: GST-based ± accuracy vs the Dronetag; elevation-mask A/B (10° vs 5°).
- [ ] Walk test: fitness mode + 0.3 m/s static threshold + SNR 14 vs the Dronetag reference.
- [ ] TTFF: main lever is AGNSS/EPO ephemeris injection (Airoha EPO file over UART at boot —
      needs a download path via phone/BLE or USB; Dronetag gets assistance from its app, which
      is why it fixes faster). Design sketch first; non-trivial.
- [ ] Consider nav mode 5 (Drone) + SBAS for airborne use (fitness kills EGNOS; drone mode
      keeps it) — flag-only change: -DGPSTAG_NAV_MODE=5.

### 4. Experiments (cheap, uncertain gain — try when idle)
- [ ] **Base-as-reference differential**: Base is static with an idle GPS; its wander is the
      local common-mode GPS error (same sats/iono, EGNOS residuals). Subtract Base's
      deviation-from-average from tag fixes on the phone. Expect 20–40% on smooth error,
      nothing on multipath spikes — measure before adopting.
- [ ] **Orientation vs RSSI diagnostics**: quasi-static gravity vector → coarse tilt; log
      against per-packet RSSI to see if link dips correlate with antenna orientation.

## Out of scope (decided)
- Inertial dead reckoning / EKF tight coupling (unsupported by hardware — see findings).
- Impact / free-fall event bit (user decision 2026-07-04).
- Temperature + lux telemetry (available in `T1000xSensor.cpp` if ever wanted; not valuable here).
