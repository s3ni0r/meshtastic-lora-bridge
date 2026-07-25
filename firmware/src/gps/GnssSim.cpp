#include "GnssSim.h"

#ifdef GPS_TAG
#include "FSCommon.h"
#include "GnssMotion.h"
#include "GnssTagSettings.h"
#include "main.h" // concurrency::mainDelay
#include "modules/HighRatePositionModule.h"
#include <math.h>

// Track slot on LittleFS (28 KB total internal FS shared with prefs — cap the slot well below).
static const char *kTrackPath = "/prefs/simtrack.bin";
static const uint8_t kTrackMagic = 0xA9, kTrackVer = 1;
static const uint16_t kTrackMaxRecs = 1600; // 10 B/record -> <=16 KB
static const uint8_t kTrackHdrLen = 8;      // magic, ver, count u16, crc32 u32
static const uint8_t kTrackRecLen = 10;


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

void GnssSim::publishAt(double lat, double lon, float speedKmh, float hdgDeg)
{
    g_gpsTagLat = (int32_t)(lat * 1e7);
    g_gpsTagLon = (int32_t)(lon * 1e7);
    g_gpsTagAlt = anchorAlt;
    g_gpsTagSpeed = (uint8_t)(speedKmh > 255 ? 255 : (speedKmh < 0 ? 0 : speedKmh));
    g_gpsTagHeading = (uint8_t)(hdgDeg * 256.0f / 360.0f);
    g_gpsTagHacc = 3; // pretend a good outdoor fix
    g_gpsTagTs = ++simTs; // any strictly-advancing value works as the novelty key
    g_gpsTagMs = millis();
    if (highRatePositionModule)
        highRatePositionModule->wakeFreshFix();
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
    publishAt(latDeg, lonDeg, speedKmh, headingDeg);
}

// ---- Track slot: upload -----------------------------------------------------------------

bool GnssSim::trackBegin(uint16_t count, uint32_t crc)
{
#ifdef FSCom
    if (count < 2 || count > kTrackMaxRecs)
        return false;
    if (src == TRACK)
        stop("upload replaces slot");
    FSCom.mkdir("/prefs");
    if (FSCom.exists((char *)kTrackPath))
        FSCom.remove((char *)kTrackPath);
    auto f = FSCom.open(kTrackPath, FILE_O_WRITE);
    if (!f)
        return false;
    uint8_t hdr[kTrackHdrLen] = {kTrackMagic, kTrackVer,
                                 (uint8_t)(count & 0xFF), (uint8_t)(count >> 8),
                                 (uint8_t)(crc & 0xFF), (uint8_t)((crc >> 8) & 0xFF),
                                 (uint8_t)((crc >> 16) & 0xFF), (uint8_t)((crc >> 24) & 0xFF)};
    bool ok = f.write(hdr, sizeof(hdr)) == sizeof(hdr);
    f.close();
    upActive = ok;
    upCount = count;
    upExpected = 0;
    upCrc = crc;
    LOG_INFO("GnssSim: track upload BEGIN count=%u", count);
    return ok;
#else
    return false;
#endif
}

bool GnssSim::trackChunk(uint16_t offRec, uint8_t n, const uint8_t *recBytes)
{
#ifdef FSCom
    if (!upActive || offRec != upExpected || n == 0 || (uint32_t)offRec + n > upCount)
        return false;
    auto f = FSCom.open(kTrackPath, FILE_O_WRITE); // Adafruit LittleFS: O_WRITE appends at end
    if (!f)
        return false;
    f.seek(f.size());
    bool ok = f.write(recBytes, (size_t)n * kTrackRecLen) == (size_t)n * kTrackRecLen;
    f.close();
    if (ok)
        upExpected += n;
    return ok;
#else
    return false;
#endif
}

bool GnssSim::trackCommit()
{
#ifdef FSCom
    if (!upActive || upExpected != upCount)
        return false;
    upActive = false;
    // CRC the record region against the claim — a half/corrupt upload can never play.
    auto f = FSCom.open(kTrackPath, FILE_O_READ);
    if (!f)
        return false;
    f.seek(kTrackHdrLen);
    uint32_t c = ~0UL;
    uint8_t buf[40];
    int n;
    while ((n = f.read(buf, sizeof(buf))) > 0)
        for (int i = 0; i < n; i++) {
            c ^= buf[i];
            for (int k = 0; k < 8; k++)
                c = (c >> 1) ^ (0xEDB88320UL & (-(int32_t)(c & 1)));
        }
    f.close();
    c = ~c;
    bool ok = (c == upCrc);
    LOG_INFO("GnssSim: track COMMIT %s (crc 0x%08lx vs 0x%08lx, %u recs)", ok ? "OK" : "CRC MISMATCH",
             (unsigned long)c, (unsigned long)upCrc, upCount);
    if (!ok)
        FSCom.remove((char *)kTrackPath);
    return ok;
#else
    return false;
#endif
}

void GnssSim::trackAbort()
{
#ifdef FSCom
    upActive = false;
    if (FSCom.exists((char *)kTrackPath))
        FSCom.remove((char *)kTrackPath);
    LOG_INFO("GnssSim: track upload ABORTED");
#endif
}

// ---- Track slot: playback ---------------------------------------------------------------

bool GnssSim::trackReadRec(uint16_t idx, TrackRec *out)
{
#ifdef FSCom
    auto f = FSCom.open(kTrackPath, FILE_O_READ);
    if (!f)
        return false;
    uint8_t b[kTrackRecLen];
    bool ok = f.seek(kTrackHdrLen + (uint32_t)idx * kTrackRecLen) && f.read(b, kTrackRecLen) == kTrackRecLen;
    f.close();
    if (!ok)
        return false;
    memcpy(&out->lat, &b[0], 4);
    memcpy(&out->lon, &b[4], 4);
    out->spd = b[8];
    out->dtDs = b[9] ? b[9] : 10; // 0 would stall playback — default to 1 s
    return true;
#else
    return false;
#endif
}

bool GnssSim::trackAdvance()
{
    tkCur = tkNxt;
    tkIdx++;
    if (tkIdx >= tkCount) {
        if (!loop)
            return false;
        tkIdx = 1; // wrap: cur stays at the last point, next = second point of the course
        TrackRec first;
        if (!trackReadRec(0, &first))
            return false;
        tkCur = first;
    }
    if (!trackReadRec(tkIdx, &tkNxt))
        return false;
    tkSpanS = tkNxt.dtDs * 0.1f;
    tkFrac = 0;
    return true;
}

bool GnssSim::startTrack(bool loopFlag, uint16_t ttlS)
{
#ifdef FSCom
    auto f = FSCom.open(kTrackPath, FILE_O_READ);
    if (!f)
        return false;
    uint8_t hdr[kTrackHdrLen];
    bool ok = f.read(hdr, kTrackHdrLen) == kTrackHdrLen && hdr[0] == kTrackMagic && hdr[1] == kTrackVer;
    uint32_t fileRecs = ok ? (uint32_t)(f.size() - kTrackHdrLen) / kTrackRecLen : 0;
    f.close();
    uint16_t count = ok ? (uint16_t)(hdr[2] | (hdr[3] << 8)) : 0;
    if (!ok || count < 2 || fileRecs < count) {
        LOG_WARN("GnssSim: no valid track slot");
        return false;
    }
    tkCount = count;
    tkIdx = 0;
    if (!trackReadRec(0, &tkCur) || !trackReadRec(1, &tkNxt))
        return false;
    tkIdx = 1;
    tkSpanS = tkNxt.dtDs * 0.1f;
    tkFrac = 0;
    loop = loopFlag;
    arm(TRACK, ttlS);
    LOG_INFO("GnssSim: TRACK replay %u records loop=%d", tkCount, (int)loop);
    return true;
#else
    return false;
#endif
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

    if (src == TRACK) {
        // Interpolate along the uploaded course at the configured fix cadence.
        tkFrac += tkSpanS > 0 ? dtS / tkSpanS : 1.0f;
        while (tkFrac >= 1.0f) {
            float remS = (tkFrac - 1.0f) * tkSpanS;
            if (!trackAdvance()) {
                stop("track finished");
                return 1000;
            }
            tkFrac = tkSpanS > 0 ? remS / tkSpanS : 0;
        }
        double la = (tkCur.lat + (double)(tkNxt.lat - tkCur.lat) * tkFrac) / 1e7;
        double lo = (tkCur.lon + (double)(tkNxt.lon - tkCur.lon) * tkFrac) / 1e7;
        float hdg = atan2f((float)(tkNxt.lon - tkCur.lon), (float)(tkNxt.lat - tkCur.lat)) * 180.0f / (float)M_PI;
        if (hdg < 0)
            hdg += 360.0f;
        publishAt(la, lo, tkNxt.spd, hdg);
        return gnssTagSettings.fixIntervalMs;
    }

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
