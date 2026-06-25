#include "HighRatePositionModule.h"
#include "GPSStatus.h"
#include "MeshService.h"
#include "NodeDB.h"
#include "PowerStatus.h"
#include "configuration.h"
#include <string.h>

// TX cadence in ms. 250 = 4 Hz, 500 = 2 Hz. Overridable at build time:
//   PLATFORMIO_BUILD_FLAGS="-DHIGHRATE_POSITION_SENDER -DHIGHRATE_POSITION_INTERVAL_MS=250"
// This is the SEND rate, independent of the GNSS fix rate ($PAIR050, applied in GPS.cpp).
#ifndef HIGHRATE_POSITION_INTERVAL_MS
#define HIGHRATE_POSITION_INTERVAL_MS 250
#endif

// Payload v2 — 18 bytes, little-endian (must match tools/m2_stream_poc.py + ios MeshProto.swift):
//   0  lat      int32  deg*1e7
//   4  lon      int32  deg*1e7
//   8  ms       uint16 millis()%1000
//   10 seq      uint8
//   11 flags    uint8  bit0=GPS lock, bit1=moving, bit2=charging
//   12 alt      int16  metres
//   14 speed    uint8  km/h (clamped)
//   15 heading  uint8  degrees * 256/360
//   16 sats     uint8  satellites in view
//   17 battery  uint8  percent (0-100, 101=unknown)
#define HIGHRATE_PAYLOAD_LEN 18

HighRatePositionModule *highRatePositionModule;

HighRatePositionModule::HighRatePositionModule()
    : SinglePortModule("highratepos", meshtastic_PortNum_PRIVATE_APP), OSThread("HighRatePos")
{
}

int32_t HighRatePositionModule::runOnce()
{
    // Best-available position: freshest live GPS fix, else the node's stored / fixed position.
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

    // --- extra metrics (cheap; sourced from existing Meshtastic state) ---
    int32_t alt = localPosition.altitude;             // metres
    uint32_t spd = localPosition.ground_speed;        // km/h
    uint32_t trk = localPosition.ground_track;        // degrees * 1e5
    uint32_t sats = localPosition.sats_in_view;
    uint8_t batt = powerStatus ? powerStatus->getBatteryChargePercent() : 101;
    bool charging = powerStatus && powerStatus->getIsCharging();
    bool moving = spd > 2; // km/h

    uint16_t offsetMs = (uint16_t)(millis() % 1000);
    uint8_t flags = (hasLock ? 0x01 : 0) | (moving ? 0x02 : 0) | (charging ? 0x04 : 0);
    int16_t altM = alt > 32767 ? 32767 : (alt < -32768 ? -32768 : (int16_t)alt);
    uint8_t spdK = spd > 255 ? 255 : (uint8_t)spd;
    uint16_t deg = (uint16_t)(trk / 100000UL);                  // 0..359
    uint8_t hdg = (uint8_t)((deg * 256UL) / 360UL);             // degrees -> byte
    uint8_t satN = sats > 255 ? 255 : (uint8_t)sats;

    uint8_t buf[HIGHRATE_PAYLOAD_LEN];
    memcpy(&buf[0], &lat, 4);
    memcpy(&buf[4], &lon, 4);
    memcpy(&buf[8], &offsetMs, 2);
    buf[10] = seq;
    buf[11] = flags;
    memcpy(&buf[12], &altM, 2);
    buf[14] = spdK;
    buf[15] = hdg;
    buf[16] = satN;
    buf[17] = batt;

    meshtastic_MeshPacket *p = allocDataPacket(); // stamps decoded.portnum = PRIVATE_APP, to = BROADCAST
    if (!p)
        return HIGHRATE_POSITION_INTERVAL_MS; // pool exhausted; skip this tick
    p->want_ack = false;
    p->hop_limit = 1;
    p->decoded.payload.size = sizeof(buf);
    memcpy(p->decoded.payload.bytes, buf, sizeof(buf));
    service->sendToMesh(p); // consumes p

    if ((seq % 20) == 0)
        LOG_INFO("HighRate: seq=%u lat=%d lon=%d spd=%ukmh hdg=%u sats=%u batt=%u lock=%d",
                 seq, lat, lon, spdK, deg, satN, batt, hasLock);
    seq++;
    return HIGHRATE_POSITION_INTERVAL_MS;
}
