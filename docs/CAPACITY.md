# Capacity planning — presets, regions, distance, and simultaneous tags

Study guide for deploying this system worldwide, computed for **the exact data we transmit
today** (§1) on **our hardware** (T1000-E: LR1110, +22 dBm max TX, small internal antenna) with
region/preset facts read from the firmware we ship (`src/mesh/RadioInterface.cpp`).

## 1. Our current traffic profile (what every number below assumes)

| Item | Today's value |
|---|---|
| Payload | 17 B on `PRIVATE_APP(256)`: lat/lon/ms/seq/flags + alt/speed/heading/hacc |
| On-air packet | **≈40 B** = 16 B radio header + encrypted Data protobuf (~6 B) + payload |
| GPS tag (`!18e77545`) | fresh fix every 250 ms (4 Hz GNSS), TX spacing ≥150 ms, **2 s heartbeat when no fix** |
| Bridge tag (`!b4dbb54c`) | Dronetag novelty rate ~2–4.5 Hz, same payload/heartbeat |
| Base | RX only (broadcast — extra Bases/phones listen for free) |
| MAC behavior | tags are TX-only with CAD (listen-before-talk) + latest-wins queue |

Payload v3 (18 B: +moving bit, +battery — `TODO.md`) changes airtime by ≤1 symbol; every table
below still holds.

## 2. Presets: airtime and throughput for our 40 B packet

| Preset | SF/BW(kHz)/CR | Airtime | Raw msgs/s (100% ch.) | Sensitivity* |
|---|---|---|---|---|
| ShortTurbo | 7 / 500 / 4:5 | **23 ms** | 44 | −118.5 dBm |
| ShortFast | 7 / 250 / 4:5 | **45 ms** | 22 | −121.5 dBm |
| ShortSlow | 8 / 250 / 4:5 | 85 ms | 11.7 | −124 dBm |
| MediumFast | 9 / 250 / 4:5 | 160 ms | 6.2 | −126.5 dBm |
| MediumSlow | 10 / 250 / 4:5 | 300 ms | 3.3 | −129 dBm |
| LongFast | 11 / 250 / 4:5 | 559 ms | 1.8 | −131.5 dBm |
| LongModerate | 11 / 125 / **4:8** | 1.64 s | 0.61 | −134.5 dBm |
| LongSlow | 12 / 125 / **4:8** | 3.02 s | 0.33 | −137 dBm |

\* thermal estimate (−174 + 10·log₁₀BW + 6 dB NF + LoRa SNR floor); the LR1110 is within ~1 dB.

**Latency floor = airtime**: beyond MediumSlow, each packet spends 0.3–3 s on air — no longer
"live tracking", only asset-tracker cadences.

## 3. Distance — how far each preset carries our packet

Link budget: +22 dBm TX (the LR1110's max — regions allowing 27–36 dBm don't help, we can't
emit more), −3 dBi antenna each side (T1000-E internal), 10 dB fade margin. Distances by
environment (868/915 MHz, T1000-E↔T1000-E):

| Preset | Dense urban, street level | Open flat, both ~1.5 m up† | Elevated / clear LOS‡ |
|---|---|---|---|
| ShortTurbo | 0.4–0.8 km | ~1.9 km | 10–45 km |
| **ShortFast** (EU pick) | 0.6–1.0 km | **~2.3 km** | 10–60 km |
| ShortSlow | 0.7–1.1 km | ~2.7 km | 15–80 km |
| MediumFast | 0.8–1.3 km | ~3.1 km | 20–100 km |
| MediumSlow | 0.9–1.5 km | ~3.6 km | 25–100+ km |
| LongFast | 1.1–1.7 km | ~4.1 km | 30–100+ km |
| LongModerate | 1.3–2.0 km | ~4.9 km | horizon-limited |
| LongSlow | 1.5–2.3 km | ~5.6 km | horizon-limited |

† two-ray ground model (40 dB/decade): the realistic ceiling when both ends are hand/pocket
height on flat ground. Note how it compresses the preset advantage — each step down the table
buys only ~15%, because ground reflection, not sensitivity, dominates.
‡ free-space with Fresnel clearance (hill, rooftop, drone). Earth curvature caps LOS at
~4.1·(√h₁+√h₂) km (h in m): 1.5 m ↔ 10 m ends ≈ 18 km horizon; the biggest budgets only pay
off with real elevation.

Anchors: our 1 km design target closes on ShortFast at street level with margin (PLAN §1
computed ~50 dB at 1 km LOS); community T1000-E reports cluster at 1–2 km suburban ground level
on LongFast — consistent with the two-ray column given its antenna.

**Region power corrections** (device caps at +22 dBm): JP (13 dBm) → ×0.6 ground / ×0.35 LOS;
TH (16 dBm) → ×0.7 / ×0.5; CN (19 dBm) → ×0.85 / ×0.7; EU_433 (10 dBm, but 433 MHz propagates
~6 dB better) → net ×0.7 ground vs the table.

## 4. Regions (as coded in our firmware)

| Region code | Band (MHz) | Power limit | Duty cycle | Notes for us |
|---|---|---|---|---|
| `US` / `BR_902` | 902–928 / 902–907.5 | 30 dBm | none | ShortTurbo legal; best playground |
| `EU_868` | 869.4–869.65 | 27 dBm ERP | **10%** | 250 kHz slot → **ShortTurbo won't fit** (firmware rejects) |
| `EU_433` / `UA_433` | 433–434 | 10 dBm | **10%** | low power; **T1000-E antenna is 862–930 MHz-tuned** → 10–20 dB mismatch/side, effectively unusable on our boards |
| `UA_868` | 868–868.6 | 14 dBm | **1%** | harshest duty here — 0.22 msg/s max on ShortFast |
| `ANZ` | 915–928 | 30 dBm | none | like US |
| `IN` / `NP_865` | 865–867 / 865–868 | 30 dBm | none | |
| `NZ_865` | 864–868 | 36 dBm | none | (device still emits 22) |
| `JP` | 920.5–923.5 | **13 dBm** | none in fw (LBT in law) | power-starved — see §3 corrections |
| `KR` | 920–923 | 23 dBm | none in fw (LBT in law) | |
| `TW` | 920–925 | 27 dBm | none | |
| `SG_923` / `TH` / `MY_919` | ~917–925 | 20 / 16 / 27 dBm | none | |
| `CN` | 470–510 | 19 dBm | none | 470 MHz propagates slightly better |
| `RU` | 868.7–869.2 | 20 dBm | none in fw | |
| `LORA_24` | **2400–2483.5** | 10 dBm | none | license-free worldwide, **but requires an SX1280-class radio — the LR1110 cannot TX at 2.4 GHz** (its 2.4 GHz block is a Wi-Fi-scan receiver). Not usable on T1000-E |

> The firmware only *enforces* this table. JP/KR add listen-before-talk in law that it doesn't
> model — verify locally before anything commercial.

## 5. Per-tag legal ceiling (duty-limited regions), our packet

Max sustained msgs/s per tag = duty% ÷ airtime:

| Preset | EU_868 / EU_433 (10%) | UA_868 (1%) | US/ANZ/IN/… (none) |
|---|---|---|---|
| ShortTurbo | *(preset unavailable)* | — | 44 (channel-limited) |
| ShortFast | **2.2 /s** | 0.22 /s | 22 |
| ShortSlow | 1.2 /s | 0.12 /s | 11.7 |
| MediumFast | 0.62 /s | 0.06 /s | 6.2 |
| MediumSlow | 0.33 /s | 0.03 /s | 3.3 |
| LongFast | 0.18 /s | 0.02 /s | 1.8 |
| LongSlow | 0.03 /s | — | 0.33 |

EU868 headline: **2 Hz per tag on ShortFast is the legal sustained maximum** (8.6% duty);
our GPS tag's 4 Hz GNSS stays, only TX spacing changes (`HIGHRATE_MIN_SPACING_MS=500`).

## 6. How many tags simultaneously?

**N ≈ 35% channel budget ÷ (per-tag rate × airtime)**, each tag also capped by §5. The 35%
budget is where CAD keeps collision loss low; hidden nodes (tags far apart, both near Base)
erode it, so round down when tags spread over km.

| Preset | @ 4 Hz/tag | @ 2 Hz/tag | @ 1 Hz/tag | @ 1 fix/5 s |
|---|---|---|---|---|
| ShortTurbo (US-class) | **3–4** | 7 | 15 | 76 |
| ShortFast | 1–2 | **3–4** | 7 | 38 |
| ShortSlow | — | 2 | 4 | 20 |
| MediumFast | — | 1 | 2 | 10 |
| MediumSlow | — | — | 1 | 5 |
| LongFast | — | — | — | 3 |
| LongModerate / LongSlow | — | — | — | 1 |

**Today's fleet, concretely:**
- Bench (US/ShortTurbo): GPS tag @4 Hz = 9% airtime, bridge @~2.3 Hz novelty = 5% → **14%
  aggregate, comfortable**; room for ~2 more moving 4 Hz tags.
- France deployment (EU_868/ShortFast): GPS tag must drop to 2 Hz (9% duty ✓), bridge capped
  the same → 2 moving tags ≈ 18% channel ✓; **fleet ceiling ≈ 4 moving tags @2 Hz** or 7 @1 Hz.
- Parked tags cost ~0.5% each (2 s heartbeats), so with motion-gated TX (`TODO.md` #3)
  "N tags" really means "N *moving* at once" — a 10-tag fleet is fine on EU868 if ≤4 move.

## 7. Worldwide recipes for this system

| Scenario | Region/preset | Config |
|---|---|---|
| **France field use** (home) | `EU_868` + ShortFast | 2 Hz TX (`MIN_SPACING 500`), ≤4 moving tags, ~0.6–1 km urban / 2 km open / far with elevation |
| EU, more tags | `EU_868` + ShortFast | 1 Hz (`MIN_SPACING 1000`), ≤7 moving tags |
| US/AU trips, max fidelity | `US`/`ANZ` + ShortTurbo | 4 Hz, ≤4 tags — today's bench config, legal there |
| Long range, few tags | LongFast | 1 fix/5 s, ≤3 tags, ~1.5 km urban / 4 km open / 10s of km elevated |
| Japan | `JP` + ShortFast | 13 dBm: plan ~0.4 km urban / 1.2 km open; keep rates modest |

## 8. Formulas (recompute for new payloads/rates)

```
symbol_time  = 2^SF / BW
payload_syms = 8 + max(ceil((8·PL − 4·SF + 44)/(4·(SF − 2·DE))) · (CR+4), 0)   # PL=40 today
airtime      = (20.25 + payload_syms) · symbol_time
per_tag_duty = rate_hz × airtime                  # ≤ region duty for legality
fleet        = 0.35 / (rate_hz × airtime)         # collision-safe simultaneous moving tags
two_ray_km   = 10^((22 − 6 − 10 + |sens| + 7)/40) / 1000   # both ends ~1.5 m, flat ground
```
(DE=1 for SF11/125, SF12/125, SF12/250; CR=5 except LongModerate/LongSlow=8.)
