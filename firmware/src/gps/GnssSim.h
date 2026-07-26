#pragma once
#include "configuration.h"

#ifdef GPS_TAG
#include "concurrency/OSThread.h"
#include <Arduino.h>

/**
 * GnssSim — tag-downlink branch. Synthetic-fix generator for indoor testing: fabricates GPS
 * fixes INSIDE the tag, feeding the exact same stash + wake path real AG3335 fixes use, so
 * everything downstream (novelty dedup, TX spacing, the adaptive speed gate, mode echo, the
 * app) is the genuine machinery under test — not a mock.
 *
 * Sources (portnum 260 op 0x04):
 *   PROGRAM  up to 8 segments of (speed km/h, duration s), optional loop — fits ONE packet,
 *            works over the LoRa downlink at range.
 *   ACCEL    "shake to move": speed derives from the live QMA6100P energy byte — rehearses
 *            the whole paddle/still story on a couch.
 *   TRACK    (phase 2) replay of an uploaded track slot.
 *
 * Safety rails (same philosophy as CALIBRATION mode):
 *   - every simulated packet self-declares: stream flags bit4 = simulated;
 *   - dead-man TTL (default 600 s) — a forgotten sim always dies on its own;
 *   - never persisted: reboot = real GPS;
 *   - while active, real-fix stashes are gated off (g_gnssSimActive) so the two sources
 *     can't interleave; position anchors at the last real fix when one exists.
 */
struct GnssSimSeg {
    uint8_t speedKmh;
    uint8_t durS;
};

class GnssSim : private concurrency::OSThread
{
  public:
    static constexpr uint8_t OFF = 0, PROGRAM = 1, ACCEL = 2, TRACK = 3;

    GnssSim();
    bool startProgram(const uint8_t *segBytes, uint8_t n, bool loopFlag, uint16_t ttlS);
    bool startAccel(uint16_t ttlS);
    bool startTrack(bool loopFlag, uint16_t ttlS); // phase 2: replay the uploaded slot
    bool refreshTtl(uint16_t ttlS); // sub-op 0xFF: extend the dead-man without disturbing playback
    void stop(const char *why);
    uint8_t source() const { return src; }

    // Track-slot upload (op 0x05, phone/USB-direct ONLY — mesh-relayed ops are rejected; see
    // DOWNLINK.md). Uploads stage into simtrack.tmp — the committed live slot survives until
    // the replacement verifies (transactional swap at COMMIT). Records are 10 B:
    // lat i32 | lon i32 | speed u8 (km/h) | dt u8 (0.1 s units from the PREVIOUS point).
    bool trackBegin(uint16_t count, uint32_t crc32, uint8_t nonce);
    bool trackChunk(uint16_t offRec, uint8_t n, const uint8_t *recBytes);
    bool trackCommit();
    void trackAbort();
    uint8_t uploadNonce() const { return upNonce; } // echoed in every 0x85 ACK (R3 finding 3)

  protected:
    int32_t runOnce() override;

  private:
    struct TrackRec {
        int32_t lat, lon;
        uint8_t spd, dtDs;
    };

    void arm(uint8_t newSrc, uint16_t ttlS);
    void publish(float speedKmh, float dtS);                                  // parametric walker
    void publishAt(double lat, double lon, float speedKmh, float headingDeg); // explicit (track)
    bool trackReadRec(uint16_t idx, TrackRec *out);
    bool trackAdvance(); // cur <- nxt, load the following record (handles loop/end)

    uint8_t src = OFF;
    bool loop = false;
    uint32_t ttlDeadlineMs = 0;
    GnssSimSeg segs[8];
    uint8_t nSegs = 0, segIdx = 0;
    float segElapsedS = 0;
    double latDeg = 0, lonDeg = 0;
    float headingDeg = 45.0f, accelSpeed = 0;
    int16_t anchorAlt = 0;
    uint16_t simTs = 0;

    // Track upload state
    bool upActive = false;
    uint16_t upCount = 0, upExpected = 0;
    uint32_t upCrc = 0;
    uint8_t upNonce = 0;
    uint16_t lastChunkOff = 0;
    uint8_t lastChunkN = 0; // exact-duplicate detection (R3 low-priority: any-range was too lax)
    // Track playback state
    uint16_t tkCount = 0, tkIdx = 0;
    TrackRec tkCur{}, tkNxt{};
    float tkFrac = 0, tkSpanS = 0.1f;
};

extern GnssSim *gnssSim;
extern volatile bool g_gnssSimActive; // read by GPS.cpp (stash gate) + HighRate (flags bit4)

#endif // GPS_TAG
