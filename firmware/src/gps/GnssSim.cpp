#include "GnssSim.h"

#ifdef GPS_TAG
#include "GnssMotion.h"
#include "GnssTagSettings.h"
#include "main.h" // concurrency::mainDelay
#include "modules/HighRatePositionModule.h"
#include <math.h>

// The same stash globals GPS.cpp fills from real fixes (see GPS.cpp GPS_TAG block).
extern volatile int32_t g_gpsTagLat;
extern volatile int32_t g_gpsTagLon;
extern volatile int16_t g_gpsTagAlt;
extern volatile uint8_t g_gpsTagSpeed;
extern volatile uint8_t g_gpsTagHeading;
extern volatile uint8_t g_gpsTagHacc;
extern volatile uint32_t g_gpsTagMs;
extern volatile uint16_t g_gpsTagTs;

GnssSim *gnssSim;
volatile bool g_gnssSimActive = false;

#ifndef GPSTAG_SIM_TTL_DEFAULT_S
#define GPSTAG_SIM_TTL_DEFAULT_S 600
#endif
// Anchor fallback when the tag has never had a real fix (0,0 would read as a heartbeat).
#ifndef GPSTAG_SIM_FALLBACK_LAT
#define GPSTAG_SIM_FALLBACK_LAT 43.4832 // Côte des Basques — any recognizable, non-zero spot
#endif
#ifndef GPSTAG_SIM_FALLBACK_LON
#define GPSTAG_SIM_FALLBACK_LON -1.5586
#endif

GnssSim::GnssSim() : OSThread("GnssSim")
{
    setInterval(1000);
}

void GnssSim::arm(uint8_t newSrc, uint16_t ttlS)
{
    // Anchor at the last REAL fix if one exists (sim gates future stashes, so this is stable).
    if (g_gpsTagLat != 0 || g_gpsTagLon != 0) {
        latDeg = g_gpsTagLat / 1e7;
        lonDeg = g_gpsTagLon / 1e7;
        anchorAlt = g_gpsTagAlt;
    } else {
        latDeg = GPSTAG_SIM_FALLBACK_LAT;
        lonDeg = GPSTAG_SIM_FALLBACK_LON;
        anchorAlt = 5;
    }
    src = newSrc;
    ttlDeadlineMs = millis() + (ttlS ? ttlS : GPSTAG_SIM_TTL_DEFAULT_S) * 1000UL;
    g_gnssSimActive = true;
    segIdx = 0;
    segElapsedS = 0;
    accelSpeed = 0;
    LOG_INFO("GnssSim: START src=%u ttl=%us anchor=%.5f,%.5f", src, ttlS ? ttlS : GPSTAG_SIM_TTL_DEFAULT_S,
             latDeg, lonDeg);
    setIntervalFromNow(0);
    concurrency::mainDelay.interrupt();
}

bool GnssSim::startProgram(const uint8_t *segBytes, uint8_t n, bool loopFlag, uint16_t ttlS)
{
    if (n < 1 || n > 8)
        return false;
    for (uint8_t i = 0; i < n; i++) {
        segs[i].speedKmh = segBytes[2 * i];
        segs[i].durS = segBytes[2 * i + 1];
        if (segs[i].durS == 0)
            return false;
    }
    nSegs = n;
    loop = loopFlag;
    arm(PROGRAM, ttlS);
    return true;
}

bool GnssSim::startAccel(uint16_t ttlS)
{
    arm(ACCEL, ttlS);
    return true;
}

bool GnssSim::refreshTtl(uint16_t ttlS)
{
    if (src == OFF)
        return false;
    ttlDeadlineMs = millis() + (ttlS ? ttlS : GPSTAG_SIM_TTL_DEFAULT_S) * 1000UL;
    return true;
}

void GnssSim::stop(const char *why)
{
    if (src != OFF)
        LOG_INFO("GnssSim: STOP (%s)", why);
    src = OFF;
    g_gnssSimActive = false;
    // Age the stash out so the stream honestly drops lock instead of freezing on a fake fix.
    g_gpsTagMs = 0;
}

void GnssSim::publish(float speedKmh, float dtS)
{
    // Lazy constant turn: believable wandering course, ~2.4 min per circle.
    headingDeg += 2.5f * dtS;
    if (headingDeg >= 360.0f)
        headingDeg -= 360.0f;
    float dM = speedKmh / 3.6f * dtS;
    float hRad = headingDeg * (float)M_PI / 180.0f;
    latDeg += (dM * cosf(hRad)) / 111320.0;
    lonDeg += (dM * sinf(hRad)) / (111320.0 * cos(latDeg * M_PI / 180.0));

    g_gpsTagLat = (int32_t)(latDeg * 1e7);
    g_gpsTagLon = (int32_t)(lonDeg * 1e7);
    g_gpsTagAlt = anchorAlt;
    g_gpsTagSpeed = (uint8_t)(speedKmh > 255 ? 255 : (speedKmh < 0 ? 0 : speedKmh));
    g_gpsTagHeading = (uint8_t)(headingDeg * 256.0f / 360.0f);
    g_gpsTagHacc = 3; // pretend a good outdoor fix
    g_gpsTagTs = ++simTs; // any strictly-advancing value works as the novelty key
    g_gpsTagMs = millis();
    if (highRatePositionModule)
        highRatePositionModule->wakeFreshFix();
}

int32_t GnssSim::runOnce()
{
    if (src == OFF)
        return 1000;
    uint32_t now = millis();
    if ((int32_t)(now - ttlDeadlineMs) >= 0) {
        stop("TTL dead-man"); // a forgotten sim always dies on its own
        return 1000;
    }

    float dtS = gnssTagSettings.fixIntervalMs / 1000.0f;
    float sp = 0;

    if (src == PROGRAM) {
        segElapsedS += dtS;
        if (segElapsedS >= segs[segIdx].durS) {
            segElapsedS = 0;
            segIdx++;
            if (segIdx >= nSegs) {
                if (!loop) {
                    stop("program finished");
                    return 1000;
                }
                segIdx = 0;
            }
            LOG_INFO("GnssSim: segment %u -> %u km/h for %u s", segIdx, segs[segIdx].speedKmh, segs[segIdx].durS);
        }
        sp = segs[segIdx].speedKmh;
    } else if (src == ACCEL) {
        // Shake-to-move: live motion energy (mg) -> speed, smoothed. ~80 mg of handling reads
        // ~5 km/h; a vigorous shake saturates around 25 km/h.
        uint8_t e = g_motionEnergyByte;
        float energyMg = (e == 255) ? 0.0f : e * 4.0f;
        float target = energyMg / 16.0f;
        if (target > 25.0f)
            target = 25.0f;
        accelSpeed += 0.15f * (target - accelSpeed);
        sp = accelSpeed;
    }

    publish(sp, dtS);
    return gnssTagSettings.fixIntervalMs;
}

#endif // GPS_TAG
