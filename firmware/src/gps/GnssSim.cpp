#include "GnssSim.h"

#ifdef GPS_TAG
#include "FSCommon.h"
#include "GnssMotion.h"
#include "GnssTagSettings.h"
#include "main.h" // concurrency::mainDelay
#include "modules/HighRatePositionModule.h"
#include <math.h>

// Track storage: A/B generation slots on LittleFS. Each current-format slot is a standalone
// file with a 16-byte immutable header and, only after COMMIT, a 16-byte commit footer:
//
//   header | count x 10-byte records | footer
//
// Staging has no footer and is therefore never playable. COMMIT verifies the staged records,
// then APPENDS the footer. This detail is essential: rewriting the header at offset zero makes
// this LittleFS version COW-copy the entire 8 KiB file before its metadata swap, temporarily
// requiring three slot images and making the advertised 800-record cap fail on a normal prefs
// filesystem. Appending only COW-copies the tail block and, if the footer crosses a boundary,
// allocates one additional block. Under the LittleFS block model, an incomplete footer fails the
// exact-size/magic/tid/crc checks below, so the previous committed slot remains selectable. The
// board adapter erases 4 KiB physical pages, however: preservation across a power cut during that
// operation still needs device fault injection and is not claimed by the host or orderly-reboot
// gates. No marker/selector file exists to tear.
//
// Capacity honesty: the internal FS is 224 x 128 B (28 KiB), shared with prefs. The exact
// bundled-LittleFS host gate in tools/bench/verify_track_layout.py measures the real CTZ and
// metadata cost: two 800-record slots can promote by footer append with an 8,192-byte single
// prefs-filler file present, ending at 209/224 live blocks (15 blocks still free). That measured
// block margin—not a logical-size subtraction—is the capacity guarantee; extra per-file metadata
// also consumes it. An abandoned staged slot occupies only its own pre-budgeted slot file and is
// reused by the next BEGIN.
static const char *kSlotAPath = "/prefs/simtrk.a";
static const char *kSlotBPath = "/prefs/simtrk.b";
// Legacy v1 layout (single slot + marker + tmp) — removed on first track op after upgrade.
static const char *kLegacyBin = "/prefs/simtrack.bin";
static const char *kLegacyTmp = "/prefs/simtrack.tmp";
static const char *kLegacyMark = "/prefs/simtrack.ok";
static const uint8_t kTrackMagic = 0xAA, kTrackLegacyVer = 2, kTrackVer = 3;
static const uint32_t kTrackCommitMagic = 0x54494D43UL; // LE bytes "CMIT"
static const uint16_t kTrackMaxRecs = 800;
static const uint8_t kTrackHdrLen = 16;    // magic, ver, count u16, crc u32, reserved=0 u32, tid u32
static const uint8_t kTrackFooterLen = 16; // "CMIT" u32, gen u32, tid u32, metadata-proof CRC32
static const uint8_t kTrackRecLen = 10;

struct TrackSlotHdr {
    uint16_t count;
    uint32_t crc, gen, tid;
    uint8_t version;
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

static void trackCrc32Add(uint32_t *crc, const uint8_t *bytes, uint32_t length)
{
    for (uint32_t i = 0; i < length; i++) {
        *crc ^= bytes[i];
        for (int k = 0; k < 8; k++)
            *crc = (*crc >> 1) ^ (0xEDB88320UL & (-(int32_t)(*crc & 1)));
    }
}

static void trackHdrBytes(uint8_t *out, const TrackSlotHdr &h)
{
    out[0] = kTrackMagic;
    out[1] = h.version;
    out[2] = (uint8_t)(h.count & 0xFF);
    out[3] = (uint8_t)(h.count >> 8);
    packU32(&out[4], h.crc);
    packU32(&out[8], 0); // immutable current-format header; generation lives in the footer
    packU32(&out[12], h.tid);
}

static uint32_t trackFooterProof(const TrackSlotHdr &h)
{
    uint8_t proofBytes[kTrackHdrLen + 12];
    trackHdrBytes(proofBytes, h);
    packU32(&proofBytes[kTrackHdrLen], kTrackCommitMagic);
    packU32(&proofBytes[kTrackHdrLen + 4], h.gen);
    packU32(&proofBytes[kTrackHdrLen + 8], h.tid);
    uint32_t crc = ~0UL;
    trackCrc32Add(&crc, proofBytes, sizeof(proofBytes));
    return ~crc;
}

static void trackFooterBytes(uint8_t *out, const TrackSlotHdr &h)
{
    packU32(&out[0], kTrackCommitMagic);
    packU32(&out[4], h.gen);
    packU32(&out[8], h.tid);
    packU32(&out[12], trackFooterProof(h));
}

static uint32_t trackRecordEnd(const TrackSlotHdr &h)
{
    return (uint32_t)kTrackHdrLen + (uint32_t)h.count * kTrackRecLen;
}

/// Parse the immutable header and accept only one of the two complete shapes: current staging
/// (header+records) or current committed (header+records+footer). v2 header-generation slots
/// remain readable so an already-deployed v4.3 track survives this storage-format upgrade.
static bool trackSlotHdr(const char *path, TrackSlotHdr *out, uint32_t *outSize = nullptr)
{
#ifdef FSCom
    auto f = FSCom.open(path, FILE_O_READ);
    if (!f)
        return false;
    uint8_t hdr[kTrackHdrLen];
    bool ok = f.read(hdr, kTrackHdrLen) == kTrackHdrLen && hdr[0] == kTrackMagic &&
              (hdr[1] == kTrackLegacyVer || hdr[1] == kTrackVer);
    uint32_t fsize = f.size();
    f.close();
    if (!ok)
        return false;
    out->count = (uint16_t)(hdr[2] | (hdr[3] << 8));
    out->crc = unpackU32(&hdr[4]);
    out->gen = unpackU32(&hdr[8]);
    out->tid = unpackU32(&hdr[12]);
    out->version = hdr[1];
    if (out->count < 2 || out->count > kTrackMaxRecs || out->tid == 0)
        return false;
    uint32_t recordEnd = trackRecordEnd(*out);
    bool shapeOK = out->version == kTrackLegacyVer
                       ? fsize == recordEnd
                       : out->gen == 0 && (fsize == recordEnd || fsize == recordEnd + kTrackFooterLen);
    if (shapeOK && outSize)
        *outSize = fsize;
    return shapeOK;
#else
    return false;
#endif
}

/// CRC exactly the record region (never a current-format footer) against the header's claim.
/// CRC value 0 is legal; validity is a separate boolean.
static bool trackSlotCrcValid(const char *path, const TrackSlotHdr &h)
{
#ifdef FSCom
    auto f = FSCom.open(path, FILE_O_READ);
    if (!f)
        return false;
    if (!f.seek(kTrackHdrLen)) {
        f.close();
        return false;
    }
    uint32_t c = ~0UL;
    uint32_t remaining = (uint32_t)h.count * kTrackRecLen;
    uint8_t buf[40];
    while (remaining > 0) {
        uint16_t want = (uint16_t)(remaining < sizeof(buf) ? remaining : sizeof(buf));
        int n = f.read(buf, want);
        if (n != want) {
            f.close();
            return false;
        }
        trackCrc32Add(&c, buf, n);
        remaining -= n;
    }
    f.close();
    return ~c == h.crc;
#else
    return false;
#endif
}

/// Current-format staging is exact header+records (no footer) with a verified record CRC.
static bool trackSlotStaged(const char *path, TrackSlotHdr *out)
{
    uint32_t fsize = 0;
    if (!trackSlotHdr(path, out, &fsize) || out->version != kTrackVer ||
        fsize != trackRecordEnd(*out))
        return false;
    return trackSlotCrcValid(path, *out);
}

/// A slot is COMMITTED iff its complete on-disk commit proof and content CRC verify. Current
/// v3 proof is the appended footer; legacy v2 generation headers are accepted read-only.
static bool trackSlotCommitted(const char *path, TrackSlotHdr *out)
{
    uint32_t fsize = 0;
    if (!trackSlotHdr(path, out, &fsize))
        return false;
    if (out->version == kTrackLegacyVer)
        return out->gen > 0 && trackSlotCrcValid(path, *out);
    if (fsize != trackRecordEnd(*out) + kTrackFooterLen)
        return false;
#ifdef FSCom
    auto f = FSCom.open(path, FILE_O_READ);
    if (!f)
        return false;
    uint8_t footer[kTrackFooterLen];
    bool ok = f.seek(trackRecordEnd(*out)) && f.read(footer, sizeof(footer)) == sizeof(footer);
    f.close();
    if (!ok || unpackU32(&footer[0]) != kTrackCommitMagic)
        return false;
    uint32_t gen = unpackU32(&footer[4]);
    if (gen == 0 || unpackU32(&footer[8]) != out->tid)
        return false;
    out->gen = gen;
    if (unpackU32(&footer[12]) != trackFooterProof(*out))
        return false;
    return trackSlotCrcValid(path, *out);
#else
    return false;
#endif
}

/// The playable slot: the committed slot with the highest generation (nullptr if none).
static bool trackGenNewer(uint32_t a, uint32_t b)
{
    return (int32_t)(a - b) > 0; // serial-number arithmetic; generation zero is reserved
}

static const char *trackActiveSlot(TrackSlotHdr *out)
{
    TrackSlotHdr a, b;
    bool va = trackSlotCommitted(kSlotAPath, &a);
    bool vb = trackSlotCommitted(kSlotBPath, &b);
    if (va && vb) {
        bool chooseA = a.gen == b.gen || trackGenNewer(a.gen, b.gen);
        *out = chooseA ? a : b;
        return chooseA ? kSlotAPath : kSlotBPath;
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
    // Prime a valid synthetic stash before the command handler returns. Otherwise the
    // high-rate module can observe g_gnssSimActive during the arm->first-run gap and emit
    // one stale/zero heartbeat carrying the simulated flag.
    publishAt(latDeg, lonDeg, segs[0].speedKmh, headingDeg);
    return true;
}

bool GnssSim::startAccel(uint16_t ttlS)
{
    arm(ACCEL, ttlS);
    publishAt(latDeg, lonDeg, 0, headingDeg);
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

static bool trackBytesEqual(const char *path, uint32_t offset, const uint8_t *expected, uint32_t length)
{
#ifdef FSCom
    auto f = FSCom.open(path, FILE_O_READ);
    if (!f)
        return false;
    if (!f.seek(offset)) {
        f.close();
        return false;
    }
    uint8_t buf[40];
    uint32_t compared = 0;
    while (compared < length) {
        uint16_t want = (uint16_t)((length - compared) < sizeof(buf) ? (length - compared) : sizeof(buf));
        int n = f.read(buf, want);
        if (n != want || memcmp(buf, expected + compared, want) != 0) {
            f.close();
            return false;
        }
        compared += want;
    }
    f.close();
    return true;
#else
    return false;
#endif
}

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
    // The disk footer is the reboot-stable COMMIT-retry proof. Reusing its tid for a new
    // replacement would make a later failed attempt indistinguishable from that older success,
    // so active tids are single-use until a different transfer supersedes the slot.
    if (activePath && act.tid == tid) {
        LOG_WARN("GnssSim: BEGIN rejected — tid %08lx is the active committed transfer", (unsigned long)tid);
        return false;
    }
    upPath = (activePath == kSlotAPath) ? kSlotBPath : kSlotAPath;
    upActive = false; // replacement BEGIN owns the old staging only after every check above
    if (FSCom.exists((char *)upPath) && !FSCom.remove((char *)upPath))
        return false;
    auto f = FSCom.open(upPath, FILE_O_WRITE);
    if (!f)
        return false;
    uint8_t hdr[kTrackHdrLen];
    trackHdrBytes(hdr, TrackSlotHdr{count, crc, 0, tid, kTrackVer});
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

bool GnssSim::trackChunk(uint32_t tid, uint16_t offRec, uint8_t n, const uint8_t *recBytes)
{
#ifdef FSCom
    // Ownership is checked before duplicate reads or append opens: another transfer cannot
    // mutate, advance, or receive a success ACK for this staging slot.
    if (!upActive || tid != upTid || n == 0)
        return false;
    // Retry-safe: same range is a duplicate only if every stored byte also matches. A changed
    // payload is NAKed rather than falsely credited and left to fail much later at COMMIT.
    if (lastChunkN > 0 && offRec == lastChunkOff && n == lastChunkN) {
        uint32_t byteOffset = (uint32_t)kTrackHdrLen + (uint32_t)offRec * kTrackRecLen;
        return trackBytesEqual(upPath, byteOffset, recBytes, (uint32_t)n * kTrackRecLen);
    }
    if (offRec != upExpected || (uint32_t)offRec + n > upCount)
        return false;
    auto f = FSCom.open(upPath, FILE_O_WRITE); // Adafruit LittleFS: O_WRITE appends at end
    if (!f)
        return false;
    uint32_t expectedSize = (uint32_t)kTrackHdrLen + (uint32_t)upExpected * kTrackRecLen;
    bool ok = f.size() == expectedSize && f.position() == expectedSize &&
              f.write(recBytes, (size_t)n * kTrackRecLen) == (size_t)n * kTrackRecLen;
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
        // Reboot-stable idempotence: the fully validated active slot footer is the proof. BEGIN
        // refuses reuse of this tid, so an older active slot cannot credit a failed replacement.
        TrackSlotHdr act;
        return trackActiveSlot(&act) != nullptr && act.tid == tid;
    }
    if (tid != upTid)
        return false; // a COMMIT for some other transfer never touches this staging
    if (upExpected != upCount)
        return false; // incomplete — staging stays open, remaining chunks may still arrive
    upActive = false;
    // Verify the STAGED slot in place (shape + content CRC against both the header claim and
    // the BEGIN's declared CRC). The active slot is not involved at all.
    TrackSlotHdr staged;
    if (!trackSlotStaged(upPath, &staged) || staged.tid != upTid || staged.crc != upCrc ||
        staged.count != upCount) {
        LOG_INFO("GnssSim: track COMMIT FAILED (staged verify) — active slot untouched");
        FSCom.remove((char *)upPath);
        return false;
    }
    // Promote by appending the commit footer. Never seek backwards: an offset-zero update makes
    // this LittleFS COW-copy the entire staged file before close. A missing/partial/bad footer
    // remains unplayable, while the previous active slot is never opened or deleted.
    TrackSlotHdr act;
    const char *activePath = trackActiveSlot(&act);
    uint32_t newGen = activePath ? act.gen + 1 : 1;
    if (newGen == 0)
        newGen = 1; // generation zero is the uncommitted sentinel; serial comparison handles wrap
    staged.gen = newGen;
    bool ok = false;
    {
        auto f = FSCom.open(upPath, FILE_O_WRITE);
        if (f) {
            uint8_t footer[kTrackFooterLen];
            trackFooterBytes(footer, staged);
            uint32_t expectedEnd = trackRecordEnd(staged);
            ok = f.size() == expectedEnd && f.position() == expectedEnd &&
                 f.write(footer, sizeof(footer)) == sizeof(footer);
            f.close();
        }
    }
    ok = ok && trackSlotCommitted(upPath, &staged) && staged.gen == newGen;
    if (!ok) {
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
    float hdg = atan2f((float)(tkNxt.lon - tkCur.lon), (float)(tkNxt.lat - tkCur.lat)) * 180.0f / (float)M_PI;
    if (hdg < 0)
        hdg += 360.0f;
    publishAt(tkCur.lat / 1e7, tkCur.lon / 1e7, tkCur.spd, hdg);
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
