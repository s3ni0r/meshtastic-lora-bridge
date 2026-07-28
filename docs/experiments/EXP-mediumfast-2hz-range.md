# EXP — MediumFast 2 Hz surf-range experiment (branch `exp-mediumfast-2hz-range`)

**Question:** with the worn tag fixed (T1000-E bridge + Dronetag in a watertight enclosure,
on-body under a wetsuit) and the Base at 1.5 m on the e-bike handlebars, does
**MEDIUM_FAST @ 2 Hz** close the measured surf gap (solid ≤100 m, dead 100–350 m on
SHORT_TURBO, 2026-07-28 session)?

## Why this configuration

- 2 updates/s is a hard product requirement → LONG presets are physically impossible
  (LongFast airtime 559 ms measured > the 500 ms period) and MEDIUM_SLOW has no headroom
  (~56 % channel occupancy). **MEDIUM_FAST (SF9/250 kHz) is the most sensitive preset that
  sustains 2 Hz comfortably (~28 %)** — +8 dB link budget over the tested SHORT_TURBO.
- **Region EU_868, duty override ON** (owner's deliberate experiment-scoped choice): keeps
  transmissions in the correct European ISM band (region US = 902–928 MHz overlaps the
  GSM-900 uplink — never transmit that outdoors here) while ignoring the 10 % duty limit
  for the test. The production path back to legality is the adaptive profile (2 Hz moving /
  1 Hz paddling / slow idle) — machinery already in the fork.
- Bridge TX spacing capped at **500 ms** via the settings wire (persisted).

## Radio identity (all participating nodes TOGETHER — split fleet = silent air-path loss)

| Field | Experiment | Bench baseline (restore) |
|---|---|---|
| `lora.region` | `EU_868` | `US` |
| `lora.modem_preset` | `MEDIUM_FAST` | `SHORT_TURBO` |
| `lora.override_duty_cycle` | `true` | `false` |

Tooling: `tools/bench/exp_mediumfast.py apply|verify|restore` (read-back verified, exit-coded;
also sets the bridge spacing on apply). The GPS tag, if left unflipped, is deliberately out
of the experiment — flip it before any bench regression run.

## Bench gate (before any field session)

1. `exp_mediumfast.py apply` → exit 0.
2. `exp_stress.py [duration]` → PASS: matched-id delivery ≥ 95 %, rate 1.6–2.4 Hz, median
   airtime 100–220 ms (proves the modem is really on MEDIUM_FAST), no TX-queue pileup.
   Airtime + per-packet rxSNR/rxRSSI are recorded — the same margin instrumentation the
   field session uses.

## Field protocol (surf session)

Base: L1 Pro-class node + vertical 5–6 dBi whip on the handlebars (1.5 m), phone in the bar
bag on BLE. Worn: unchanged enclosure position (deliberately — one variable at a time).
Walk/paddle marks at ~100 / 200 / 350 m; note posture (sitting vs prone) per leg. The Base
log's rxSNR per packet vs distance is the deliverable: a margin-vs-distance curve, not
impressions. Expected from the +8 dB preset step alone: solid to ~170–200 m, marginal to
350 m; with the upgraded Base antenna: the full lineup.

## Results

- **Bench stress (2026-07-28): PASS.** 30 min, live Dronetag source (~3.3 fixes/s sniffed,
  relayed at the cap): **3532/3532 matched packets = 100.00 % delivery** at 1.96 Hz
  sustained; median airtime **160 ms** (SF9/250 confirmed on the wire — duty at 2 Hz ≈ 31 %,
  slightly above the 28 % estimate); rxSNR min 11.5 / mean 13.1 dB at bench distance; TX
  queue never piled up. The 500 ms spacing cap held exactly. Two harness lessons are
  encoded in `exp_stress.py`: base RadioIf lines have no rxRSSI field, and readers must
  prove they're capturing bytes (a silent reader once mimicked 0 % delivery).
- Field session: _(pending — protocol above; margin curve from base rxSNR vs distance)_
