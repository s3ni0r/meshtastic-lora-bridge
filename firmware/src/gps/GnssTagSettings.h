#pragma once
#include "configuration.h"

#if defined(GPS_TAG) || defined(ODID_SNIFFER)
#include <Arduino.h>

/**
 * GnssTagSettings — project fork. Runtime tuning for BOTH tag flavors, persisted in the node's
 * flash filesystem and configurable live from the phone over BLE or at LoRa range via the Base
 * (GnssConfigModule, portnum 260). Compile-time GPSTAG_* macros are only the FIRST-RUN defaults.
 * On the bridge (ODID_SNIFFER) the GNSS-chip fields are stored but INERT — its position source is
 * the external Dronetag; the capability byte in every settings reply tells clients which knob
 * groups are live (docs/DOWNLINK.md).
 *
 * Wire format (payload bytes after the op byte, little-endian):
 *   [0] navMode        $PAIR080: 0 normal / 1 fitness / 4 stationary / 5 drone / 7 swim / 9 bike
 *   [1] staticThrDms   $PAIR070: 0-20 dm/s (0 = off) — chip freezes position below this speed
 *   [2] minSnr         $PAIR058: 9-37 dB satellite SNR mask
 *   [3..4] fixIntervalMs  $PAIR050: 100-1000 ms
 *   [5..6] txSpacingMs    LoRa TX min spacing: 100-5000 ms (500 = EU868-legal 2 Hz)
 *   [7] elevMaskDeg    $PAIR072: 0-45 deg — satellites below are excluded (multipath cut)
 *  v3 (tag-downlink — the ADAPTIVE mode's knobs, phone-tunable for field tuning):
 *   [8..9] idleSpacingMs  slow-tier TX spacing: 1000-30000 ms
 *   [10] adaptFastKmh     >= this speed -> full rate immediately (2-30)
 *   [11] adaptSlowKmh     < this speed sustained -> slow tier (1..fast-1)
 *   [12] adaptSustainS    sustain window before downshift: 3-120 s
 *  v4 (A4 radio states/profiles — docs/RADIO_STATES.md):
 *   [13] profileBits      bit0 = PERMANENT profile (0 = HYBRID), bit1 = permanent radio state is
 *                         DEAF (only meaningful with bit0). Valid values: 0x00, 0x01, 0x03.
 *  Clients send 7 (v1), 8 (v2), 13 (v3) or 14 (v4) bytes; shorter writes keep current values for
 *  the missing fields. GET/SET replies append the capability, radio-status and duty-floor
 *  bytes after the 14-byte settings — total reply 20 bytes = v4 (see GnssConfigModule.h).
 */

// First-run defaults (overridable with -D at build time, as before).
#ifndef GPSTAG_FIX_INTERVAL_MS
#define GPSTAG_FIX_INTERVAL_MS 250
#endif
#ifndef GPSTAG_NAV_MODE
#define GPSTAG_NAV_MODE 1
#endif
#ifndef GPSTAG_STATIC_THR_DMS
#define GPSTAG_STATIC_THR_DMS 3
#endif
#ifndef GPSTAG_MIN_SNR
#define GPSTAG_MIN_SNR 14
#endif
#ifndef GPSTAG_TX_SPACING_MS
// 500 ms = 2 Hz = EU868-legal SUSTAINED (docs/CAPACITY.md). The bench 150 ms (6.7 Hz) profile
// is one tap away in the app — but a fresh flash must default to the legal state, because
// ADAPTIVE mode's fast tier runs at exactly this spacing whenever the tag moves (external
// review 2026-07-26: a 150 ms default contradicted the "EU-duty-safe boot default" claim).
// The bridge shares this default since A1 made its spacing runtime too.
#define GPSTAG_TX_SPACING_MS 500
#endif
#ifndef GPSTAG_ELEV_MASK_DEG
#define GPSTAG_ELEV_MASK_DEG 10
#endif

// ---- Downlink-controlled TX mode (tag-downlink branch, GPS tag only) -----------------------
// Runtime-only, NEVER persisted: a reboot or an expired TTL always lands in ADAPTIVE — the
// EU-duty-safe state. Set over portnum 260 op 0x02 (phone direct or Base-relayed LoRa).

#ifndef GPSTAG_IDLE_SPACING_MS
#define GPSTAG_IDLE_SPACING_MS 3000 // adaptive slow tier: 1 packet / 3 s while quasi-stationary
#endif
#ifndef GPSTAG_ADAPT_FAST_KMH
#define GPSTAG_ADAPT_FAST_KMH 5 // >= this speed -> full rate immediately (eager upshift)
#endif
#ifndef GPSTAG_ADAPT_SLOW_KMH
#define GPSTAG_ADAPT_SLOW_KMH 3 // < this speed, sustained, -> slow tier (skeptical downshift)
#endif
#ifndef GPSTAG_ADAPT_SLOW_SUSTAIN_MS
#define GPSTAG_ADAPT_SLOW_SUSTAIN_MS 15000
#endif
#ifndef GPSTAG_CALIB_TTL_DEFAULT_S
#define GPSTAG_CALIB_TTL_DEFAULT_S 90 // dead-man: calibration mode reverts unless the app refreshes
#endif

// v4 profile bits (persisted; docs/RADIO_STATES.md §3). HYBRID = 0: boot always lands in
// LISTENING (+ ADAPTIVE on the GPS tag) and deafness is runtime-only. PERMANENT: fixed spacing
// (no adaptive tiers, no CALIBRATION TTL choreography) AND a fixed boot radio state; radio-state
// commands REWRITE the persisted bits instead of creating temporary states.
#define TAG_PROFILE_PERMANENT 0x01
#define TAG_PROFILE_PERM_DEAF 0x02

struct GnssTagSettings {
    uint8_t navMode = GPSTAG_NAV_MODE;
    uint8_t staticThrDms = GPSTAG_STATIC_THR_DMS;
    uint8_t minSnr = GPSTAG_MIN_SNR;
    uint16_t fixIntervalMs = GPSTAG_FIX_INTERVAL_MS;
    uint16_t txSpacingMs = GPSTAG_TX_SPACING_MS;
    uint8_t elevMaskDeg = GPSTAG_ELEV_MASK_DEG;
    // v3 — adaptive-mode knobs, phone-tunable (defaults from the macros above)
    uint16_t idleSpacingMs = GPSTAG_IDLE_SPACING_MS;
    uint8_t adaptFastKmh = GPSTAG_ADAPT_FAST_KMH;
    uint8_t adaptSlowKmh = GPSTAG_ADAPT_SLOW_KMH;
    uint8_t adaptSustainS = GPSTAG_ADAPT_SLOW_SUSTAIN_MS / 1000;
    // v4 — persisted profile (TAG_PROFILE_*); 0 = HYBRID, the shipped default
    uint8_t profileBits = 0;
};

extern GnssTagSettings gnssTagSettings;

#ifdef GPS_TAG
struct GnssTagMode {
    static constexpr uint8_t CALIBRATION = 0; // fixed max rate (settings.txSpacingMs), TTL-guarded
    static constexpr uint8_t ADAPTIVE = 1;    // speed-gated: fast tier = settings, slow tier = idle spacing

    uint8_t mode = ADAPTIVE;      // boot default IS the safe state
    uint32_t calibDeadlineMs = 0; // millis() deadline while mode == CALIBRATION
    bool slowTier = false;        // adaptive state (echoed in stream flags bit3)
    uint32_t belowSinceMs = 0;    // when speed first dropped under the slow threshold (0 = it hasn't)
};

extern GnssTagMode gnssTagMode;
#endif // GPS_TAG

/// Load from flash (no-op if the file is absent/invalid — defaults stay). Call once, early —
/// BEFORE radio init, so a PERMANENT·DEAF profile can mute the radio from the first boot moment.
void gnssTagSettingsLoad();
/// Pack the current settings into the 14-byte v4 wire format.
void gnssTagSettingsPack(uint8_t out[14]);
/// Validate a 7/8/13 (v1-v3) / 14-byte (v4) wire payload; on success adopt + persist.
/// enforceDutyFloor: live SETs reject a sustained spacing below the region's duty-cycle floor
/// (TagRadioState); the boot-time load passes false — stored values are CLAMPED at use instead
/// (clamp + "degraded" flag, never a silent fallback to defaults). See docs/RADIO_STATES.md §3.
bool gnssTagSettingsSetFromWire(const uint8_t *in, uint8_t len, bool enforceDutyFloor = true);
/// Persist ONLY the profile bits (RADIO-op rewrite in PERMANENT). No-op if unchanged.
bool gnssTagSettingsSaveProfile(uint8_t profileBits);

#endif // GPS_TAG || ODID_SNIFFER
