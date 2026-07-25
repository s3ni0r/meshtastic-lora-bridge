#pragma once
#include "configuration.h"

#if defined(GPS_TAG) || defined(ODID_SNIFFER)
#include <Arduino.h>

/**
 * GnssMotion — tag-downlink branch. Turns the QMA6100P's 10 Hz samples (taken on the stock
 * AccelerometerThread tick — see the QMA6100PSensor.cpp patch) into two published values:
 *
 *   g_motionEnergyByte  high-passed |accel| envelope, mg/4 (0..254; 255 = no sample yet) —
 *                       shipped RAW in every stream packet (payload v4 byte 18) so session
 *                       recordings become the dataset that tunes the sea thresholds later.
 *   g_isMoving          provisional moving/still classification (stream flags bit1) with
 *                       LAND-calibrated thresholds (TODO.md findings: >50 mg sustained 0.5 s
 *                       -> moving; <20 mg for 3 s -> still; in between: hold). Orientation-
 *                       independent by construction (gravity tracked as an EMA of |a|).
 *
 * Both tag flavors sample — the bridge rides with the subject next to the Dronetag, so its
 * cell's motion IS the subject's motion.
 */
extern volatile uint8_t g_motionEnergyByte;
extern volatile bool g_isMoving;

/// Feed one accelerometer sample (units: g). Called at ~10 Hz from the sensor tick.
void gnssMotionSample(float xG, float yG, float zG, uint32_t nowMs);

#endif // GPS_TAG || ODID_SNIFFER
