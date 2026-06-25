#include "HighRatePositionModule.h"
#include "GPSStatus.h"
#include "MeshService.h"
#include "NodeDB.h"
#include "configuration.h"
#include <string.h>

// TX cadence in ms. 250 = 4 Hz, 500 = 2 Hz. Overridable at build time:
//   PLATFORMIO_BUILD_FLAGS="-DHIGHRATE_POSITION_SENDER -DHIGHRATE_POSITION_INTERVAL_MS=250"
// NOTE: this is the SEND rate, independent of the GNSS fix rate. For genuine position novelty at
// this cadence the AG3335 must be set to a matching fix rate ($PAIR050, applied in GPS.cpp).
#ifndef HIGHRATE_POSITION_INTERVAL_MS
#define HIGHRATE_POSITION_INTERVAL_MS 250
#endif

HighRatePositionModule *highRatePositionModule;

HighRatePositionModule::HighRatePositionModule()
    : SinglePortModule("highratepos", meshtastic_PortNum_PRIVATE_APP), OSThread("HighRatePos")
{
}

int32_t HighRatePositionModule::runOnce()
{
    // Best-available position: prefer the freshest live GPS fix (localPosition, updated every fix),
    // else fall back to the node's stored / fixed position (lets us bench-test without a sky view,
    // and supports Phase 2 where position is injected rather than locally acquired).
    bool hasLock = gpsStatus && gpsStatus->getHasLock();
    int32_t lat = localPosition.latitude_i;
    int32_t lon = localPosition.longitude_i;
    if (lat == 0 && lon == 0) {
        meshtastic_NodeInfoLite *node = nodeDB->getMeshNode(nodeDB->getNodeNum());
        if (node && node->has_position) {
            lat = node->position.latitude_i;
            lon = node->position.longitude_i;
        }
    }
    if (lat == 0 && lon == 0)
        return HIGHRATE_POSITION_INTERVAL_MS; // no position available yet

    uint16_t offsetMs = (uint16_t)(millis() % 1000); // sub-second tick for jitter/latency
    uint8_t flags = hasLock ? 0x01 : 0x00;           // bit0: live GPS lock (vs fixed/last-known)

    // 12-byte fixed little-endian payload: lat(i32) lon(i32) offsetMs(u16) seq(u8) flags(u8).
    // Matches tools/m2_stream_poc.py and the iOS client. Far under DATA_PAYLOAD_LEN (233).
    uint8_t buf[12];
    memcpy(&buf[0], &lat, 4);
    memcpy(&buf[4], &lon, 4);
    memcpy(&buf[8], &offsetMs, 2);
    buf[10] = seq;
    buf[11] = flags;

    meshtastic_MeshPacket *p = allocDataPacket(); // stamps decoded.portnum = PRIVATE_APP, to = BROADCAST
    if (!p)
        return HIGHRATE_POSITION_INTERVAL_MS;         // pool exhausted; skip this tick
    p->want_ack = false;                              // fire-and-forget; ACKs would double airtime
    p->hop_limit = 1;                                 // direct 2-node link, no rebroadcast
    p->decoded.payload.size = sizeof(buf);
    memcpy(p->decoded.payload.bytes, buf, sizeof(buf));
    service->sendToMesh(p); // consumes p

    if ((seq % 20) == 0)
        LOG_INFO("HighRate: sent seq=%u lat=%d lon=%d lock=%d", seq, lat, lon, hasLock);
    seq++;
    return HIGHRATE_POSITION_INTERVAL_MS;
}
