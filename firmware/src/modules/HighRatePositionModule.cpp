#include "HighRatePositionModule.h"
#include "GPSStatus.h"
#include "MeshService.h"
#include "NodeDB.h"
#include "configuration.h"
#include "main.h" // concurrency::mainDelay — woken from wakeFreshFix()
#include <string.h>

// Poll/fallback tick in ms. With ODID_SNIFFER the send is EVENT-DRIVEN (the sniffer wakes us per novel
// fix); this is only the safety-net poll, so a (rare) missed cross-task wake costs at most one tick.
// Without the sniffer it remains the fixed TX cadence (250 = 4 Hz).
#ifndef HIGHRATE_POSITION_INTERVAL_MS
#define HIGHRATE_POSITION_INTERVAL_MS 250
#endif

// Minimum spacing between event-driven sends (caps the TX rate if the fix source bursts).
// ~150 ms ≈ 6.7 Hz ceiling — above the Dronetag's ~4.5 Hz max novelty. EU868 note: at 10% duty use
// >= 500 (2 Hz) for deployment; bench setup is region US (no duty limit).
#ifndef HIGHRATE_MIN_SPACING_MS
#define HIGHRATE_MIN_SPACING_MS 150
#endif

// A fix whose coordinates haven't changed within this window is reported stale (lock=0).
#ifndef HIGHRATE_FRESH_MS
#define HIGHRATE_FRESH_MS 2500
#endif

// With no fresh fix, send only a slow heartbeat instead of flooding the channel.
#ifndef HIGHRATE_HEARTBEAT_MS
#define HIGHRATE_HEARTBEAT_MS 2000
#endif

// Position-only payload — 12 bytes, little-endian (must match tools/m2_stream_poc.py + iOS):
//   0 lat int32 (deg*1e7) | 4 lon int32 | 8 ms uint16 | 10 seq uint8 | 11 flags uint8 (bit0 = lock)

HighRatePositionModule *highRatePositionModule;

HighRatePositionModule::HighRatePositionModule()
    : SinglePortModule("highratepos", meshtastic_PortNum_PRIVATE_APP), OSThread("HighRatePos")
{
}

void HighRatePositionModule::wakeFreshFix()
{
    setIntervalFromNow(0);                // run me on the next main-loop pass
    concurrency::mainDelay.interrupt();   // ...and end the main loop's sleep now (task-safe give)
}

int32_t HighRatePositionModule::runOnce()
{
    uint32_t nowMs = millis();
#ifdef ODID_SNIFFER
    // Position source is the sniffed Dronetag Remote ID fix (NRF52Bluetooth.cpp), bypassing the
    // onboard AG3335 (which is firmware-locked at 1 Hz). Fresh while RID adverts keep arriving.
    extern volatile int32_t g_odidLat;
    extern volatile int32_t g_odidLon;
    extern volatile uint32_t g_odidMs;
    extern volatile uint16_t g_odidTs;
    int32_t lat = g_odidLat;
    int32_t lon = g_odidLon;
    uint16_t fixTs = g_odidTs;
    uint32_t fixMs = g_odidMs;
    bool hasLock = (fixMs != 0) && (nowMs - fixMs) < HIGHRATE_FRESH_MS && (lat != 0 || lon != 0);

    // Event-driven TX: send when the fix is NOVEL (the sniffer wakes us per new fix), spacing-guarded;
    // otherwise just a slow heartbeat. Duplicate re-adverts (~5 Hz) no longer burn airtime, and a fresh
    // fix goes out in ~ms instead of aging up to a full poll interval.
    bool novel = hasLock && (fixTs != lastSentTs || lat != lastSentLat || lon != lastSentLon);
    uint32_t sinceSend = nowMs - lastSendMs;
    if (lastSendMs != 0) {
        if (novel) {
            if (sinceSend < HIGHRATE_MIN_SPACING_MS)
                return HIGHRATE_MIN_SPACING_MS - sinceSend; // re-run exactly when spacing allows
        } else {
            if (sinceSend < HIGHRATE_HEARTBEAT_MS) { // nothing new — sleep toward the heartbeat...
                uint32_t wait = HIGHRATE_HEARTBEAT_MS - sinceSend;
                // ...capped at one poll tick so a missed cross-task wake degrades to old behavior
                return wait < HIGHRATE_POSITION_INTERVAL_MS ? wait : HIGHRATE_POSITION_INTERVAL_MS;
            }
        }
    }
#else
    int32_t lat = localPosition.latitude_i;
    int32_t lon = localPosition.longitude_i;
    if (lat == 0 && lon == 0) {
        meshtastic_NodeInfoLite *node = nodeDB->getMeshNode(nodeDB->getNodeNum());
        if (node && node->has_position) {
            lat = node->position.latitude_i;
            lon = node->position.longitude_i;
        }
    }

    // Freshness gate: coordinates that stop changing mean a stalled/lost GPS — report lock=0.
    if (lat != lastLat || lon != lastLon) {
        lastLat = lat;
        lastLon = lon;
        lastChangedMs = nowMs;
    }
    bool hasLock = (gpsStatus && gpsStatus->getHasLock()) && lastChangedMs != 0 &&
                   (nowMs - lastChangedMs) < HIGHRATE_FRESH_MS;
#endif

    uint16_t offsetMs = (uint16_t)(nowMs % 1000);
    uint8_t flags = hasLock ? 0x01 : 0x00;

    uint8_t buf[17];
    memcpy(&buf[0], &lat, 4);
    memcpy(&buf[4], &lon, 4);
    memcpy(&buf[8], &offsetMs, 2);
    buf[10] = seq;
    buf[11] = flags;
    uint8_t len = 12;
#ifdef ODID_SNIFFER
    // Extended telemetry from the Dronetag ODID Location: alt(i16,m) speed(u8,km/h)
    // heading(u8,*256/360) hacc(u8,m). Receivers decode these when payload >= 17; 12-byte clients
    // still get position.
    extern volatile int16_t g_odidAlt;
    extern volatile uint8_t g_odidSpeed;
    extern volatile uint8_t g_odidHeading;
    extern volatile uint8_t g_odidHacc;
    int16_t alt = g_odidAlt;
    memcpy(&buf[12], &alt, 2);
    buf[14] = g_odidSpeed;
    buf[15] = g_odidHeading;
    buf[16] = g_odidHacc;
    len = 17;
#endif

    // Latest-wins (stock PositionModule pattern): if the previous position is still queued (channel
    // was busy), drop it — a stale fix must not transmit ahead of this one.
    if (prevPacketId)
        service->cancelSending(prevPacketId);

    meshtastic_MeshPacket *p = allocDataPacket(); // stamps decoded.portnum = PRIVATE_APP, to = BROADCAST
    if (!p)
        return HIGHRATE_POSITION_INTERVAL_MS;
    p->want_ack = false;
    p->hop_limit = 1;
    p->decoded.payload.size = len;
    memcpy(p->decoded.payload.bytes, buf, len);
    prevPacketId = p->id;
    service->sendToMesh(p);
    lastSendMs = nowMs;
#ifdef ODID_SNIFFER
    lastSentTs = fixTs;
    lastSentLat = lat;
    lastSentLon = lon;
    if ((seq % 20) == 0) // dec2send = sniffer-decode -> LoRa-enqueue latency (the P1 metric)
        LOG_INFO("HighRate: seq=%u lat=%d lon=%d lock=%d dec2send=%lums", seq, lat, lon, hasLock,
                 (unsigned long)(fixMs ? (nowMs - fixMs) : 0));
#else
    if ((seq % 20) == 0)
        LOG_INFO("HighRate: seq=%u lat=%d lon=%d lock=%d", seq, lat, lon, hasLock);
#endif
    seq++;
    return hasLock ? HIGHRATE_POSITION_INTERVAL_MS : HIGHRATE_HEARTBEAT_MS;
}
