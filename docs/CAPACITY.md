# Capacity planning — presets, regions, range, and simultaneous tags

Study guide for deploying this system worldwide: how fast each modem preset can carry our
position packets, what each region legally allows, how far each preset reaches, and how many
tags can stream at once. All numbers are for **our actual packet** and **our firmware**
(v2.7.15 base + fork; region/preset facts read from `src/mesh/RadioInterface.cpp`).

## Assumptions (recompute if these change)

- **On-air packet ≈ 40 bytes**: 16 B Meshtastic radio header + encrypted Data protobuf
  (~6 B overhead + 17 B payload). Payload v3 (18 B, `TODO.md`) adds ≤1 symbol — negligible.
- Airtime = (20.25 preamble symbols + payload symbols) × 2^SF / BW, CRC on, explicit header,
  Meshtastic's 16-symbol preamble, low-data-rate-optimize where the symbol time ≥ 16.4 ms.
- Tags are TX-only with CAD (listen-before-talk) and latest-wins queues; Base only receives.
  Broadcast = any number of Bases/phones listen for free.
- **Channel budget for multi-tag planning: ~35% aggregate airtime.** CAD keeps collisions low
  up to roughly that load; beyond it, loss climbs fast (pure-ALOHA collapses ~18%; CAD buys
  headroom but hidden nodes between spread-out tags erode it).

## 1. Presets: airtime, throughput, sensitivity, range

For the 40 B packet (SF/BW/CR as configured by our firmware, non-wideLora regions):

| Preset | SF/BW(kHz)/CR | Airtime | Raw msgs/s (100% ch.) | Sensitivity* | Range vs ShortFast** |
|---|---|---|---|---|---|
| ShortTurbo | 7 / 500 / 4:5 | **23 ms** | 44 | −118.5 dBm | 0.7× |
| ShortFast | 7 / 250 / 4:5 | **45 ms** | 22 | −121.5 dBm | 1.0× |
| ShortSlow | 8 / 250 / 4:5 | 85 ms | 11.7 | −124 dBm | 1.3× |
| MediumFast | 9 / 250 / 4:5 | 160 ms | 6.2 | −126.5 dBm | 1.8× |
| MediumSlow | 10 / 250 / 4:5 | 300 ms | 3.3 | −129 dBm | 2.4× |
| LongFast | 11 / 250 / 4:5 | 559 ms | 1.8 | −131.5 dBm | 3.2× |
| LongModerate | 11 / 125 / 4:8 | 1.64 s | 0.61 | −134.5 dBm | 4.5× |
| LongSlow | 12 / 125 / 4:8 | 3.02 s | 0.33 | −137 dBm | 6.0× |

\* thermal-limit estimate (−174 + 10·log₁₀BW + 6 dB NF + LoRa SNR floor) — real LR1110 is within ~1 dB.
\** free-space ratio from sensitivity delta (6 dB ≈ 2× range). Real terrain compresses these ratios.

Practical T1000-E↔T1000-E guidance (small internal antenna, ~1–2 m height): ShortFast covers the
1 km design target with ~50 dB margin line-of-sight (PLAN §1); expect 0.5–2 km ground-level
urban, 5 km+ elevated LOS. Long presets trade rate for reach — LongFast is the classic
"tens of km LOS" Meshtastic preset, but its 559 ms airtime makes even 1 Hz impossible.

**Latency floor = airtime.** For live tracking, anything slower than MediumSlow stops feeling
"real-time" (0.3–3 s per message just on air).

## 2. Regions (as coded in our firmware)

| Region code | Band (MHz) | Power limit | Duty cycle | Notes for us |
|---|---|---|---|---|
| `US` / `BR_902` | 902–928 / 902–907.5 | 30 dBm | none | ShortTurbo legal; best playground |
| `EU_868` | 869.4–869.65 | 27 dBm ERP | **10%** | 250 kHz slot → **ShortTurbo won't fit** (firmware rejects); duty is per-device |
| `EU_433` / `UA_433` | 433–434 | 10 dBm | **10%** | low power → short range |
| `UA_868` | 868–868.6 | 14 dBm | **1%** | harshest duty in the table — 0.22 msg/s max on ShortFast |
| `ANZ` | 915–928 | 30 dBm | none | like US |
| `IN` / `NP_865` | 865–867 / 865–868 | 30 dBm | none | |
| `NZ_865` | 864–868 | 36 dBm | none | highest power in table |
| `JP` | 920.5–923.5 | **13 dBm** | none in fw (LBT applies in law) | power-starved: expect ~⅕ the range of US at same preset |
| `KR` | 920–923 | 23 dBm | none in fw (LBT in law) | |
| `TW` | 920–925 | 27 dBm | none | |
| `SG_923` / `TH` / `MY_919` | ~917–925 | 20 / 16 / 27 dBm | none | |
| `CN` | 470–510 | 19 dBm | none | 470 MHz propagates a bit better |
| `RU` | 868.7–869.2 | 20 dBm | none in fw | |
| `LORA_24` | **2400–2483.5** | 10 dBm | none | **license-free worldwide**, wideLora presets (ShortTurbo @1625 kHz); short range, but one config for any country |

> The firmware only *enforces* what's in this table (duty %, power, band fit). Local law can add
> LBT or channel plans it doesn't model (JP/KR) — verify before a commercial deployment.

## 3. Per-tag legal ceiling (duty-cycle regions)

Max sustained msgs/s **per tag** = duty% ÷ airtime. Only the duty-limited regions constrain this:

| Preset | EU_868 / EU_433 (10%) | UA_868 (1%) | US/ANZ/IN/… (none) |
|---|---|---|---|
| ShortTurbo | *(not available)* | — | 44 (channel-limited) |
| ShortFast | **2.2 /s** | 0.22 /s | 22 |
| ShortSlow | 1.2 /s | 0.12 /s | 11.7 |
| MediumFast | 0.62 /s | 0.06 /s | 6.2 |
| MediumSlow | 0.33 /s | 0.03 /s | 3.3 |
| LongFast | 0.18 /s | 0.02 /s | 1.8 |
| LongSlow | 0.03 /s | — | 0.33 |

So in EU868 the familiar result: **2 Hz per tag on ShortFast is the legal sustained maximum**
(8.6% duty). 4 Hz is bench/burst only. `lora.override_duty_cycle` bypasses the firmware check
but not the law.

## 4. How many tags simultaneously?

**N ≈ 35% channel budget ÷ (per-tag rate × airtime)** — then cap each tag by §3's duty limit.

| Preset | @ 4 Hz/tag | @ 2 Hz/tag | @ 1 Hz/tag | @ 1/5 s/tag |
|---|---|---|---|---|
| ShortTurbo (US-class only) | **3–4** | 7 | 15 | 76 |
| ShortFast | 1–2 | **3–4** | 7 | 38 |
| ShortSlow | — | 2 | 4 | 20 |
| MediumFast | — | 1 | 2 | 10 |
| MediumSlow | — | — | 1 | 5 |
| LongFast | — | — | — | 3 |
| LongModerate | — | — | — | 1 |
| LongSlow | — | — | — | 1 (10 s cadence) |

Reading it with regions:

- **US/ANZ-class (no duty):** ShortTurbo @4 Hz supports **3–4 live tags** (our current bench
  config); halve the rate to double the fleet.
- **EU_868:** per-tag cap of 2.2/s *and* the channel budget both bite: **2 Hz × 3–4 tags** on
  ShortFast is the realistic ceiling; **1 Hz × 7 tags**; drop to 0.5 Hz for ~15.
- Long-range presets are effectively **single-tag, slow-cadence** links — an asset tracker
  pattern (fix every 5–30 s), not live tracking.

Refinements that raise effective capacity:
- **Motion-gated TX** (`TODO.md` #3): parked tags cost ~0.5% airtime (2 s heartbeats), so
  "N simultaneous" really means "N *moving* at once" — a 10-tag fleet works on EU868/2 Hz if
  ≤4 move at any moment.
- Novelty-driven senders already skip duplicate fixes; real-world rates sit below the nominal.
- Stagger is automatic (CAD defers), but hidden nodes (two tags far apart, both near Base)
  reduce CAD's benefit — budget conservatively when tags spread over km.

## 5. Worldwide deployment recipes

| Scenario | Region/preset | Config |
|---|---|---|
| **France/EU field use** (current home) | `EU_868` + ShortFast | 2 Hz/tag (`HIGHRATE_MIN_SPACING_MS=500`), ≤4 moving tags, `override_duty_cycle=false` |
| EU, more tags | `EU_868` + ShortFast | 1 Hz/tag (`MIN_SPACING 1000`), ≤7 moving tags |
| US/AU trips, max fidelity | `US`/`ANZ` + ShortTurbo | 4 Hz/tag, ≤4 tags (today's bench config, legal there) |
| Long range, few tags | LongFast (any region) | 1 fix/5 s, ≤3 tags, multi-km reach |
| Any-country demo without reconfig | `LORA_24` | wideLora presets, short range, zero regulatory homework |
| Japan | `JP` + ShortFast | 13 dBm hurts range — plan ~⅓–⅕ the distances; keep rates modest |

## 6. Formulas (to recompute for new payloads/rates)

```
symbol_time  = 2^SF / BW
payload_syms = 8 + max(ceil((8·PL − 4·SF + 44 − 20·DE_adj)/(4·(SF − 2·DE))) · (CR+4), 0)
airtime      = (20.25 + payload_syms) · symbol_time        # PL=40 today, 41 for payload v3
per_tag_duty = rate_hz × airtime                            # ≤ region duty for legality
fleet        = 0.35 / (rate_hz × airtime)                   # ≈ collision-safe simultaneous tags
```
(DE=1 for SF11/125, SF12/125, SF12/250; CR is 5 except LongModerate/LongSlow = 8.)
