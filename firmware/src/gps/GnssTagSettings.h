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
#define GPSTAG_TX_SPACING_MS 150
#endif
#ifndef GPSTAG_ELEV_MASK_DEG
#define GPSTAG_ELEV_MASK_DEG 10
#endif

struct GnssTagSettings {
    uint8_t navMode = GPSTAG_NAV_MODE;
    uint8_t staticThrDms = GPSTAG_STATIC_THR_DMS;
    uint8_t minSnr = GPSTAG_MIN_SNR;
    uint16_t fixIntervalMs = GPSTAG_FIX_INTERVAL_MS;
    uint16_t txSpacingMs = GPSTAG_TX_SPACING_MS;
    uint8_t elevMaskDeg = GPSTAG_ELEV_MASK_DEG;
};

extern GnssTagSettings gnssTagSettings;

/// Load from flash (no-op if the file is absent/invalid — defaults stay). Call once, early.
void gnssTagSettingsLoad();
/// Pack the current settings into the 8-byte wire format.
void gnssTagSettingsPack(uint8_t out[8]);
/// Validate a 7- (legacy) or 8-byte wire payload; on success adopt + persist and return true.
bool gnssTagSettingsSetFromWire(const uint8_t *in, uint8_t len);

#endif // GPS_TAG
