#include "GnssSim.h"

#ifdef GPS_TAG
#include "FSCommon.h"
#include "GnssMotion.h"
#include "GnssTagSettings.h"
#include "main.h" // concurrency::mainDelay
#include "modules/HighRatePositionModule.h"
#include <math.h>

// Track storage: A/B generation slots on LittleFS (R4 finding 2). Each slot is a standalone
// file whose 16-byte header carries its own commit state: generation 0 = staged/incomplete
// (never playable), generation N>0 = committed at epoch N. The upload stages into the slot
// that is NOT currently active; the active slot is never opened for writing, so power loss,
// a torn write or a CRC failure at ANY point leaves the previous committed track untouched
// and selectable (highest valid generation wins). No marker/selector file exists to tear.
//
// Capacity honesty (R4 finding 6): the internal FS is 28 KiB shared with all prefs. Both
// slots at the 800-record cap total 2 x (16 + 8000) = 16,032 B, leaving ~12 KiB for prefs.
// An abandoned staged slot occupies only its own pre-budgeted slot file and is reused by the
// next BEGIN.
static const char *kSlotAPath = "/prefs/simtrk.a";
static const char *kSlotBPath = "/prefs/simtrk.b";
// Legacy v1 layout (single slot + marker + tmp) — removed on first track op after upgrade.
static const char *kLegacyBin = "/prefs/simtrack.bin";
static const char *kLegacyTmp = "/prefs/simtrack.tmp";
static const char *kLegacyMark = "/prefs/simtrack.ok";
static const uint8_t kTrackMagic = 0xAA, kTrackVer = 2;
static const uint16_t kTrackMaxRecs = 800; // 10 B/record -> 8,016 B/slot, 2 slots budgeted
static const uint8_t kTrackHdrLen = 16;    // magic, ver, count u16, crc u32, gen u32, tid u32
static const uint8_t kTrackRecLen = 10;

struct TrackSlotHdr {
    uint16_t count;
    uint32_t crc, gen, tid;
};

static void packU32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

static uint32_t unpackU32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void trackHdrBytes(uint8_t *out, const TrackSlotHdr &h)
{
    out[0] = kTrackMagic;
    out[1] = kTrackVer;
    out[2] = (uint8_t)(h.count & 0xFF);
    out[3] = (uint8_t)(h.count >> 8);
    packU32(&out[4], h.crc);
    packU32(&out[8], h.gen);
    packU32(&out[12], h.tid);
}

/// Parse a slot header + shape check (magic, version, count bounds, exact file size).
/// CRC of the record region is verified separately (it is the expensive part).
static bool trackSlotHdr(const char *path, TrackSlotHdr *out)
{
#ifdef FSCom
    auto f = FSCom.open(path, FILE_O_READ);
    if (!f)
        return false;
    uint8_t hdr[kTrackHdrLen];
    bool ok = f.read(hdr, kTrackHdrLen) == kTrackHdrLen && hdr[0] == kTrackMagic && hdr[1] == kTrackVer;
    uint32_t fsize = f.size();
    f.close();
    if (!ok)
        return false;
    out->count = (uint16_t)(hdr[2] | (hdr[3] << 8));
    out->crc = unpackU32(&hdr[4]);
    out->gen = unpackU32(&hdr[8]);
    out->tid = unpackU32(&hdr[12]);
    return out->count >= 2 && out->count <= kTrackMaxRecs &&
           fsize == (uint32_t)kTrackHdrLen + (uint32_t)out->count * kTrackRecLen;
#else
    return false;
#endif
}

/// CRC the stored record region against the header's claim (CRC value 0 is legal — validity
/// is a separate boolean, review R3 low-priority finding).
static bool trackSlotCrcValid(const char *path)
{
#ifdef FSCom
    TrackSlotHdr h;
    if (!trackSlotHdr(path, &h))
        return false;
    auto f = FSCom.open(path, FILE_O_READ);
    if (!f)
        return false;
    if (!f.seek(kTrackHdrLen)) {
        f.close();
        return false;
    }
    uint32_t c = ~0UL, bytes = 0;
    uint8_t buf[40];
    int n;
    while ((n = f.read(buf, sizeof(buf))) > 0) {
        bytes += n;
        for (int i = 0; i < n; i++) {
            c ^= buf[i];
            for (int k = 0; k < 8; k++)
                c = (c >> 1) ^ (0xEDB88320UL & (-(int32_t)(c & 1)));
        }
    }
    f.close();
    return bytes == (uint32_t)h.count * kTrackRecLen && ~c == h.crc;
#else
    return false;
#endif
}

/// A slot is COMMITTED iff its header parses, generation > 0, and the content CRC verifies.
static bool trackSlotCommitted(const char *path, TrackSlotHdr *out)
{
    if (!trackSlotHdr(path, out) || out->gen == 0)
        return false;
    return trackSlotCrcValid(path);
}

/// The playable slot: the committed slot with the highest generation (nullptr if none).
static const char *trackActiveSlot(TrackSlotHdr *out)
{
    TrackSlotHdr a, b;
    bool va = trackSlotCommitted(kSlotAPath, &a);
    bool vb = trackSlotCommitted(kSlotBPath, &b);
    if (va && vb) {
        *out = (a.gen >= b.gen) ? a : b;
        return (a.gen >= b.gen) ? kSlotAPath : kSlotBPath;
    }
    if (va) {
        *out = a;
        return kSlotAPath;
    }
    if (vb) {
        *out = b;
        return kSlotBPath;
    }
    return nullptr;
}

/// One-time cleanup of the pre-R4 single-slot layout (bin + tmp + marker files).
static void trackMaintenance()
{
#ifdef FSCom
    static bool done = false;
    if (done)
        return;
    done = true;
    const char *legacy[] = {kLegacyBin, kLegacyTmp, kLegacyMark};
    for (auto p : legacy)
        if (FSCom.exists((char *)p)) {
            FSCom.remove((char *)p);
            LOG_INFO("GnssSim: removed legacy track file %s", p);
        }
#endif
}


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

bool GnssSim::trackBegin(uint16_t count, uint32_t crc, uint32_t tid)
{
#ifdef FSCom
    if (count < 2 || count > kTrackMaxRecs || tid == 0)
        return false;
    // Playback pins its slot file (tkPath); staging targets the OTHER slot. A second commit
    // during one long playback would have to stage into the pinned file — refuse instead of
    // splicing playback state into fresh data (R4 finding 2). Stop the sim first.
    if (src == TRACK) {
        LOG_WARN("GnssSim: BEGIN rejected — track playback active");
        return false;
    }
    trackMaintenance();
    FSCom.mkdir("/prefs");
    // Stage into the inactive slot: the active (highest-generation committed) slot is never
    // opened for writing by any path in this file.
    TrackSlotHdr act;
    const char *activePath = trackActiveSlot(&act);
    upPath = (activePath == kSlotAPath) ? kSlotBPath : kSlotAPath;
    if (FSCom.exists((char *)upPath))
        FSCom.remove((char *)upPath);
    auto f = FSCom.open(upPath, FILE_O_WRITE);
    if (!f)
        return false;
    uint8_t hdr[kTrackHdrLen];
    trackHdrBytes(hdr, TrackSlotHdr{count, crc, 0 /* gen 0 = staged, unplayable */, tid});
    bool ok = f.write(hdr, sizeof(hdr)) == sizeof(hdr);
    f.close();
    upActive = ok;
    upCount = count;
    upExpected = 0;
    upCrc = crc;
    upTid = tid;
    lastChunkOff = 0;
    lastChunkN = 0;
    LOG_INFO("GnssSim: track upload BEGIN count=%u tid=%08lx -> %s (staged)", count, (unsigned long)tid, upPath);
    return ok;
#else
    return false;
#endif
}

bool GnssSim::trackChunk(uint16_t offRec, uint8_t n, const uint8_t *recBytes)
{
#ifdef FSCom
    if (!upActive || n == 0)
        return false;
    // Retry-safe: ONLY an exact re-send of the previous chunk (same offset AND length — its
    // REPLY was lost, not the data) is acknowledged without rewriting.
    if (lastChunkN > 0 && offRec == lastChunkOff && n == lastChunkN)
        return true;
    if (offRec != upExpected || (uint32_t)offRec + n > upCount)
        return false;
    auto f = FSCom.open(upPath, FILE_O_WRITE); // Adafruit LittleFS: O_WRITE appends at end
    if (!f)
        return false;
    f.seek(f.size());
    bool ok = f.write(recBytes, (size_t)n * kTrackRecLen) == (size_t)n * kTrackRecLen;
    f.close();
    if (ok) {
        upExpected += n;
        lastChunkOff = offRec;
        lastChunkN = n;
    }
    return ok;
#else
    return false;
#endif
}

bool GnssSim::trackCommit(uint32_t tid)
{
#ifdef FSCom
    if (tid == 0)
        return false;
    if (!upActive) {
        // Idempotent RETRY only: succeed iff THIS transfer already committed — same tid AND
        // the active slot is that transfer's data (tid + CRC in its header). A retry after a
        // failed commit can never be credited by an older surviving track (R4 finding 1).
        TrackSlotHdr act;
        return tid == lastCommitTid && trackActiveSlot(&act) != nullptr && act.tid == tid &&
               act.crc == lastCommitCrc;
    }
    if (tid != upTid)
        return false; // a COMMIT for some other transfer never touches this staging
    if (upExpected != upCount)
        return false; // incomplete — staging stays open, remaining chunks may still arrive
    upActive = false;
    // Verify the STAGED slot in place (shape + content CRC against both the header claim and
    // the BEGIN's declared CRC). The active slot is not involved at all.
    TrackSlotHdr staged;
    if (!trackSlotHdr(upPath, &staged) || staged.tid != upTid || staged.crc != upCrc ||
        staged.count != upCount || !trackSlotCrcValid(upPath)) {
        LOG_INFO("GnssSim: track COMMIT FAILED (staged verify) — active slot untouched");
        FSCom.remove((char *)upPath);
        return false;
    }
    // Promote: stamp generation = active+1 in the staged header. This is the ONLY mutation;
    // if it tears or power drops, the staged slot stays at gen 0 (unplayable) and the old
    // active slot still wins. Nothing ever deletes or rewrites the previous track.
    TrackSlotHdr act;
    const char *activePath = trackActiveSlot(&act);
    uint32_t newGen = activePath ? act.gen + 1 : 1;
    bool ok = false;
    {
        auto f = FSCom.open(upPath, FILE_O_WRITE);
        if (f) {
            uint8_t hdr[kTrackHdrLen];
            trackHdrBytes(hdr, TrackSlotHdr{upCount, upCrc, newGen, upTid});
            ok = f.seek(0) && f.write(hdr, kTrackHdrLen) == kTrackHdrLen;
            f.close();
        }
    }
    ok = ok && trackSlotCommitted(upPath, &staged) && staged.gen == newGen;
    if (ok) {
        lastCommitTid = upTid;
        lastCommitCrc = upCrc;
    } else {
        FSCom.remove((char *)upPath); // failed promotion is discarded; old track still active
    }
    LOG_INFO("GnssSim: track COMMIT %s (%u recs gen=%lu tid=%08lx)", ok ? "OK" : "FAILED", upCount,
             (unsigned long)newGen, (unsigned long)upTid);
    return ok;
#else
    return false;
#endif
}

bool GnssSim::trackAbort(uint32_t tid)
{
#ifdef FSCom
    // Abort discards ONLY the staged upload it names — the committed track survives, and an
    // abort for a stale transfer id cannot kill someone else's in-flight staging.
    if (!upActive)
        return true; // nothing staged: the named transfer is certainly not staged — idempotent
    if (tid != upTid)
        return false;
    upActive = false;
    if (upPath && FSCom.exists((char *)upPath))
        FSCom.remove((char *)upPath);
    LOG_INFO("GnssSim: track upload ABORTED tid=%08lx (staged slot discarded)", (unsigned long)tid);
    return true;
#else
    return false;
#endif
}

// ---- Track slot: playback ---------------------------------------------------------------

bool GnssSim::trackReadRec(uint16_t idx, TrackRec *out)
{
#ifdef FSCom
    if (!tkPath)
        return false;
    auto f = FSCom.open(tkPath, FILE_O_READ);
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
    // NOTE: an in-progress upload does NOT block playback — staging lives in the OTHER slot.
    // (Own bench caught the earlier over-broad guard: a stray/abandoned BEGIN must never
    // disable a valid committed track.) The slot is pinned here for the whole playback: a
    // COMMIT that lands mid-play promotes the other slot and never touches this file.
    trackMaintenance();
    TrackSlotHdr act;
    const char *path = trackActiveSlot(&act); // committed (gen>0) + shape + content CRC
    if (!path) {
        LOG_WARN("GnssSim: no committed track slot");
        return false;
    }
    tkPath = path;
    tkCount = act.count;
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
