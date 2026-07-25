#include "GnssMotion.h"

#if defined(GPS_TAG) || defined(ODID_SNIFFER)
#include <math.h>

volatile uint8_t g_motionEnergyByte = 255; // 255 = accel never sampled (thread absent / init failed)
volatile bool g_isMoving = false;

// Provisional LAND thresholds — the sea profile is tuned later from recorded session data
// (which is the whole point of shipping the raw energy byte).
#ifndef GPSTAG_MOTION_MOVE_MG
#define GPSTAG_MOTION_MOVE_MG 50
#endif
#ifndef GPSTAG_MOTION_STILL_MG
#define GPSTAG_MOTION_STILL_MG 20
#endif
#ifndef GPSTAG_MOTION_MOVE_SUSTAIN_MS
#define GPSTAG_MOTION_MOVE_SUSTAIN_MS 500
#endif
#ifndef GPSTAG_MOTION_STILL_SUSTAIN_MS
#define GPSTAG_MOTION_STILL_SUSTAIN_MS 3000
#endif

void gnssMotionSample(float xG, float yG, float zG, uint32_t nowMs)
{
    static float gravityEma = 1.0f; // |a| settles to 1 g at rest regardless of orientation
    static float energyEma = 0.0f;
    static uint32_t aboveSinceMs = 0, belowSinceMs = 0;

    float mag = sqrtf(xG * xG + yG * yG + zG * zG);
    gravityEma += 0.05f * (mag - gravityEma); // slow (~2 s @10 Hz): absorbs tilt/bias drift
    float devMg = fabsf(mag - gravityEma) * 1000.0f;
    energyEma += 0.3f * (devMg - energyEma); // fast envelope (~0.3 s): what the packet carries

    float e4 = energyEma / 4.0f;
    g_motionEnergyByte = e4 >= 254.0f ? 254 : (uint8_t)e4;

    if (energyEma >= GPSTAG_MOTION_MOVE_MG) { // eager up
        belowSinceMs = 0;
        if (aboveSinceMs == 0)
            aboveSinceMs = nowMs;
        else if (!g_isMoving && nowMs - aboveSinceMs >= GPSTAG_MOTION_MOVE_SUSTAIN_MS)
            g_isMoving = true;
    } else if (energyEma < GPSTAG_MOTION_STILL_MG) { // skeptical down
        aboveSinceMs = 0;
        if (belowSinceMs == 0)
            belowSinceMs = nowMs;
        else if (g_isMoving && nowMs - belowSinceMs >= GPSTAG_MOTION_STILL_SUSTAIN_MS)
            g_isMoving = false;
    } else { // hysteresis band: hold the current state, restart both clocks
        aboveSinceMs = 0;
        belowSinceMs = 0;
    }
}

#endif // GPS_TAG || ODID_SNIFFER
