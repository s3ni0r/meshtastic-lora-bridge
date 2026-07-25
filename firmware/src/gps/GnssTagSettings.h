#pragma once
#include "configuration.h"

#ifdef GPS_TAG
#include <Arduino.h>

/**
 * GnssTagSettings — project fork. Runtime GNSS/TX tuning for the GPS tag, persisted in the
 * node's flash filesystem and configurable live from the phone over BLE (GnssConfigModule,
 * portnum 260). Compile-time GPSTAG_* macros are only the FIRST-RUN defaults now.
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
 *  Clients send 7 (v1), 8 (v2) or 13 (v3) bytes; shorter writes keep current values for the
 *  missing fields. GET replies are always 13 — reply length tells the app the tag speaks v3.
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
#define GPSTAG_TX_SPACING_MS 500
#endif
#ifndef GPSTAG_ELEV_MASK_DEG
#define GPSTAG_ELEV_MASK_DEG 10
#endif

// ---- Downlink-controlled TX mode (tag-downlink branch) -------------------------------------
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
};

extern GnssTagSettings gnssTagSettings;

struct GnssTagMode {
    static constexpr uint8_t CALIBRATION = 0; // fixed max rate (settings.txSpacingMs), TTL-guarded
    static constexpr uint8_t ADAPTIVE = 1;    // speed-gated: fast tier = settings, slow tier = idle spacing

    uint8_t mode = ADAPTIVE;      // boot default IS the safe state
    uint32_t calibDeadlineMs = 0; // millis() deadline while mode == CALIBRATION
    bool slowTier = false;        // adaptive state (echoed in stream flags bit3)
    uint32_t belowSinceMs = 0;    // when speed first dropped under the slow threshold (0 = it hasn't)
};

extern GnssTagMode gnssTagMode;

/// Load from flash (no-op if the file is absent/invalid — defaults stay). Call once, early.
void gnssTagSettingsLoad();
/// Pack the current settings into the 13-byte v3 wire format.
void gnssTagSettingsPack(uint8_t out[13]);
/// Validate a 7- (v1) / 8- (v2) / 13-byte (v3) wire payload; on success adopt + persist.
bool gnssTagSettingsSetFromWire(const uint8_t *in, uint8_t len);

#endif // GPS_TAG
