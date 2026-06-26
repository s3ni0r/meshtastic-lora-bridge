#include "HighRatePositionModule.h"
#include "GPSStatus.h"
#include "MeshService.h"
#include "NodeDB.h"
#include "configuration.h"
#include <string.h>

// TX cadence in ms. 250 = 4 Hz. Overridable at build time. This is the SEND rate; the GNSS fix rate
// is set separately by $PAIR050 in GPS.cpp.
#ifndef HIGHRATE_POSITION_INTERVAL_MS
#define HIGHRATE_POSITION_INTERVAL_MS 250
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

int32_t HighRatePositionModule::runOnce()
{
    uint32_t nowMs = millis();
#ifdef ODID_SNIFFER
    // Position source is the sniffed Dronetag Remote ID fix (NRF52Bluetooth.cpp), bypassing the
    // onboard AG3335 (which is firmware-locked at 1 Hz). Fresh while RID adverts keep arriving.
    extern volatile int32_t g_odidLat;
    extern volatile int32_t g_odidLon;
    extern volatile uint32_t g_odidMs;
    int32_t lat = g_odidLat;
    int32_t lon = g_odidLon;
    bool hasLock = (g_odidMs != 0) && (nowMs - g_odidMs) < HIGHRATE_FRESH_MS && (lat != 0 || lon != 0);
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

    meshtastic_MeshPacket *p = allocDataPacket(); // stamps decoded.portnum = PRIVATE_APP, to = BROADCAST
    if (!p)
        return HIGHRATE_POSITION_INTERVAL_MS;
    p->want_ack = false;
    p->hop_limit = 1;
    p->decoded.payload.size = len;
    memcpy(p->decoded.payload.bytes, buf, len);
    service->sendToMesh(p);

    if ((seq % 20) == 0)
        LOG_INFO("HighRate: seq=%u lat=%d lon=%d lock=%d", seq, lat, lon, hasLock);
    seq++;
    return hasLock ? HIGHRATE_POSITION_INTERVAL_MS : HIGHRATE_HEARTBEAT_MS;
}
