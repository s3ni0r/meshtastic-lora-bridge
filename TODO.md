# TODO — pending work (sensor fusion + GNSS follow-ups)

Pending items only. Shipped milestones live in [docs/HISTORY.md](docs/HISTORY.md) (battery →
payload v3 2026-07-13; motion energy + `moving` bit → payload v4, speed-gated ADAPTIVE TX,
downlink/signals/simulator → tag-downlink 2026-07-26, firmware v4.3). Physics findings that
shaped this list (why dead reckoning is impossible with the QMA6100P, why motion
classification is near-perfect): see the findings section preserved in git history
(`git log --follow TODO.md`) — short version: ±20–50 mg drifting bias double-integrates to
~350 m/min, but stationary-vs-moving from acceleration variance is orientation-independent
and rock-solid, exactly where GPS is blind (parked fixes wander 1–5 m, 70 m measured in bad
multipath).

Current payload: **19 B v4** on `PRIVATE_APP(256)` — byte 17 battery, byte 18 motion energy,
flags bit1 `moving` (see `docs/BATTERY_INTEGRATION.md`).

## 1. Sea/surf threshold tuning → accel-gated TX  [data, then firmware]

- [ ] Tune the sea/surf motion thresholds from recorded surf-session `me` data (sessions
      carry per-packet motion energy since v4 — the instrument exists; needs real sessions
      at sea). Provisional land thresholds shipped: >50 mg 0.5 s up / <20 mg 3 s down.
- [ ] Accel-gated refinement of ADAPTIVE TX: use the `moving` classifier (flags bit1) as a
      second gate next to speed — instant upshift on the pop-up instead of waiting ~1 s for
      GPS speed. AFTER the sea thresholds are tuned.
- [ ] Measure the battery win: %/hour parked vs moving, before/after (sessions carry
      per-packet `bt` since v3 — one long parked + one long moving session gives both
      slopes). Biggest battery lever available (700 mAh cell); also frees channel airtime.

## 2. Parked-position handling in the app (ZUPT display fusion)  [iOS only]

- [ ] While `moving == 0`: freeze the marker (stop trail growth), average incoming fixes
      (√N gain, realistically 2–3×), force speed 0, hold heading, show "parked".
- [ ] While moving: reject fixes implying physically impossible jumps for the motion class
      (multipath spikes), e.g. >8 m step between 250 ms fixes while accel energy says walking.

## 3. GNSS follow-ups

- [ ] TTFF: the main lever is AGNSS/EPO ephemeris injection (Airoha EPO file over UART at
      boot — needs a download path via phone/BLE or USB; Dronetag gets assistance from its
      app, which is why it fixes faster). EASY is genuinely unsupported on this unit
      (ACK 3). Design sketch first; non-trivial.
- [ ] Consider nav mode 5 (Drone) + SBAS for airborne use (fitness kills EGNOS; drone mode
      keeps it) — flag-only change: `-DGPSTAG_NAV_MODE=5`.

## 4. Experiments (cheap, uncertain gain — try when idle)

- [ ] **Base-as-reference differential**: the Base is static with an idle GPS; its wander is
      the local common-mode GPS error (same sats/iono, EGNOS residuals). Subtract the Base's
      deviation-from-average from tag fixes on the phone. Expect 20–40% on smooth error,
      nothing on multipath spikes — measure before adopting.
- [ ] **Orientation vs RSSI diagnostics**: quasi-static gravity vector → coarse tilt; log
      against per-packet RSSI to see if link dips correlate with antenna orientation.

## Engineering debt (acknowledged, deliberately deferred — from the external reviews)

- [ ] Bit-exact / hermetic firmware builds (current releases are source-mapped, not
      bit-exact — deps float, dates embedded, global framework hook).
- [ ] Recorder file I/O is synchronous on the main queue (measurement app, acceptable; would
      matter at much higher packet rates).
- [ ] Map keeps a 10 Hz UI timer while idle.
- [ ] Host-side CI / test target (protocol coverage is the hardware bench suite only).
- [ ] `MeshTrackerWatch` target is dormant and drifting.

## Out of scope (decided)

- Inertial dead reckoning / EKF tight coupling (unsupported by hardware — see findings).
- Impact / free-fall event bit (user decision 2026-07-04).
- Temperature + lux telemetry (available in `T1000xSensor.cpp` if ever wanted; not valuable
  here).
