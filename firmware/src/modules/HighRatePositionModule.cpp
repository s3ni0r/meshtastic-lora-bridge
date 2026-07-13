#include "HighRatePositionModule.h"
#include "GPSStatus.h"
#include "MeshService.h"
#include "NodeDB.h"
#include "PowerStatus.h" // payload v3: live battery byte in every stream packet
#include "configuration.h"
#include "main.h" // concurrency::mainDelay — woken from wakeFreshFix()
#include <string.h>

// Poll/fallback tick in ms. With an event-driven fix source (ODID_SNIFFER or GPS_TAG) the send is
// wake-on-novel-fix; this is only the safety-net poll, so a (rare) missed cross-task wake costs at
// most one tick. Without an event source it remains the fixed TX cadence (250 = 4 Hz).
#ifndef HIGHRATE_POSITION_INTERVAL_MS
#define HIGHRATE_POSITION_INTERVAL_MS 250
#endif

// Minimum spacing between event-driven sends (caps the TX rate if the fix source bursts).
// ~150 ms ≈ 6.7 Hz ceiling — above the Dronetag's ~4.5 Hz max novelty, and it would likewise clip a
// 10 Hz AG3335 probe win. EU868 note: at 10% duty use >= 500 (2 Hz) for deployment; bench setup is
// region US (no duty limit).
#ifndef HIGHRATE_MIN_SPACING_MS
#define HIGHRATE_MIN_SPACING_MS 150
#endif
#ifdef GPS_TAG
// GPS tag: spacing is a runtime setting (BLE-configurable; 500 = EU868-legal 2 Hz).
#include "gps/GnssTagSettings.h"
#define HIGHRATE_SPACING ((uint32_t)gnssTagSettings.txSpacingMs)
#else
#define HIGHRATE_SPACING ((uint32_t)HIGHRATE_MIN_SPACING_MS)
#endif

// A fix whose coordinates haven't changed within this window is reported stale (lock=0).
#ifndef HIGHRATE_FRESH_MS
#define HIGHRATE_FRESH_MS 2500
#endif

// With no fresh fix, send only a slow heartbeat instead of flooding the channel.
#ifndef HIGHRATE_HEARTBEAT_MS
#define HIGHRATE_HEARTBEAT_MS 2000
#endif

// Payload (little-endian, must match tools/m2_stream_poc.py + iOS MeshProto.swift):
//   0 lat int32 (deg*1e7) | 4 lon int32 | 8 ms uint16 | 10 seq uint8 | 11 flags uint8
//   12 alt int16 (m) | 14 speed uint8 (km/h) | 15 heading uint8 (deg*256/360) | 16 hacc uint8 (m)
//   17 battery uint8 (v3: 0-100 %, 101 = externally powered, 255 = unknown)
// flags: bit0 = lock, bit1 reserved for `moving` (QMA6100P gate, TODO.md), bits 5-7 = source type
// (SRC_*) so a receiver can tell WHICH tag flavor sent this even before looking at the LoRa `from`
// node id. Receivers key on length: 12 = position only, 17 = +telemetry, 18 = +battery (v3).
#define HIGHRATE_SRC_LEGACY 0 // pre-fork / bench counter build
#define HIGHRATE_SRC_ODID 1   // BLE5 Remote ID bridge (Dronetag is the position source)
#define HIGHRATE_SRC_GPS 2    // self-contained tag: onboard AG3335 is the position source

#if defined(ODID_SNIFFER)
#define HIGHRATE_SRC_TYPE HIGHRATE_SRC_ODID
#elif defined(GPS_TAG)
#define HIGHRATE_SRC_TYPE HIGHRATE_SRC_GPS
#else
#define HIGHRATE_SRC_TYPE HIGHRATE_SRC_LEGACY
#endif

HighRatePositionModule *highRatePositionModule;

HighRatePositionModule::HighRatePositionModule()
    : SinglePortModule("highratepos", meshtastic_PortNum_PRIVATE_APP), OSThread("HighRatePos")
{
}

void HighRatePositionModule::wakeFreshFix()
{
    setIntervalFromNow(0);              // run me on the next main-loop pass
    concurrency::mainDelay.interrupt(); // ...and end the main loop's sleep now (task-safe give)
}

int32_t HighRatePositionModule::runOnce()
{
    uint32_t nowMs = millis();
#if defined(ODID_SNIFFER) || defined(GPS_TAG)
#if defined(ODID_SNIFFER)
    // Position source: sniffed Dronetag Remote ID fix (NRF52Bluetooth.cpp), bypassing the onboard
    // AG3335. Fresh while RID adverts keep arriving.
    extern volatile int32_t g_odidLat;
    extern volatile int32_t g_odidLon;
    extern volatile int16_t g_odidAlt;
    extern volatile uint8_t g_odidSpeed;
    extern volatile uint8_t g_odidHeading;
    extern volatile uint8_t g_odidHacc;
    extern volatile uint32_t g_odidMs;
    extern volatile uint16_t g_odidTs;
    int32_t lat = g_odidLat;
    int32_t lon = g_odidLon;
    int16_t extAlt = g_odidAlt;
    uint8_t extSpeed = g_odidSpeed;
    uint8_t extHeading = g_odidHeading;
    uint8_t extHacc = g_odidHacc;
    uint16_t fixTs = g_odidTs;
    uint32_t fixMs = g_odidMs;
#else // GPS_TAG
    // Position source: the onboard AG3335, stashed per published fix by GPS.cpp (which also wakes
    // us — same cross-task pattern as the sniffer). GnssRateProbe tries to push it past 1 Hz.
    extern volatile int32_t g_gpsTagLat;
    extern volatile int32_t g_gpsTagLon;
    extern volatile int16_t g_gpsTagAlt;
    extern volatile uint8_t g_gpsTagSpeed;
    extern volatile uint8_t g_gpsTagHeading;
    extern volatile uint8_t g_gpsTagHacc;
    extern volatile uint32_t g_gpsTagMs;
    extern volatile uint16_t g_gpsTagTs;
    int32_t lat = g_gpsTagLat;
    int32_t lon = g_gpsTagLon;
    int16_t extAlt = g_gpsTagAlt;
    uint8_t extSpeed = g_gpsTagSpeed;
    uint8_t extHeading = g_gpsTagHeading;
    uint8_t extHacc = g_gpsTagHacc;
    uint16_t fixTs = g_gpsTagTs;
    uint32_t fixMs = g_gpsTagMs;
#endif
    bool hasLock = (fixMs != 0) && (nowMs - fixMs) < HIGHRATE_FRESH_MS && (lat != 0 || lon != 0);

    // Event-driven TX: send when the fix is NOVEL (the source wakes us per new fix), spacing-guarded;
    // otherwise just a slow heartbeat. Duplicate fixes never burn airtime, and a fresh fix goes out
    // in ~ms instead of aging up to a full poll interval.
    bool novel = hasLock && (fixTs != lastSentTs || lat != lastSentLat || lon != lastSentLon);
    uint32_t sinceSend = nowMs - lastSendMs;
    if (lastSendMs != 0) {
        if (novel) {
            if (sinceSend < HIGHRATE_SPACING)
                return HIGHRATE_SPACING - sinceSend; // re-run exactly when spacing allows
        } else {
            if (sinceSend < HIGHRATE_HEARTBEAT_MS) { // nothing new — sleep toward the heartbeat...
                uint32_t wait = HIGHRATE_HEARTBEAT_MS - sinceSend;
                // ...capped at one poll tick so a missed cross-task wake degrades to old behavior
                return wait < HIGHRATE_POSITION_INTERVAL_MS ? wait : HIGHRATE_POSITION_INTERVAL_MS;
            }
        }
    }
#else
    // Legacy bench path (HIGHRATE_POSITION_SENDER alone): fixed-cadence stream of localPosition.
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
    uint8_t flags = (hasLock ? 0x01 : 0x00) | (uint8_t)(HIGHRATE_SRC_TYPE << 5);

    uint8_t buf[18];
    memcpy(&buf[0], &lat, 4);
    memcpy(&buf[4], &lon, 4);
    memcpy(&buf[8], &offsetMs, 2);
    buf[10] = seq;
    buf[11] = flags;
    uint8_t len = 12;
#if defined(ODID_SNIFFER) || defined(GPS_TAG)
    // Extended telemetry: alt(i16,m) speed(u8,km/h) heading(u8,*256/360) hacc(u8,m). Receivers
    // decode these when payload >= 17; 12-byte clients still get position.
    memcpy(&buf[12], &extAlt, 2);
    buf[14] = extSpeed;
    buf[15] = extHeading;
    buf[16] = extHacc;
    // v3: this unit's OWN battery in every packet — real-time gauge with zero extra airtime
    // packets (one byte at ShortFast doesn't change the symbol count in practice). Same 101
    // "externally powered" magic as stock DeviceTelemetry so all consumers read one convention.
    uint8_t batt = 255; // unknown — power status not sampled yet (first seconds after boot)
    if (powerStatus && powerStatus->getHasBattery())
        batt = powerStatus->getIsCharging() ? 101 : powerStatus->getBatteryChargePercent();
    else if (powerStatus)
        batt = 101; // no cell detected = running on USB
    buf[17] = batt;
    len = 18;
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
    // ccToPhone: copy every position to the phone queue too, so a phone connected DIRECTLY to
    // this tag's BLE gets the stream without any Base alive (harmless when no phone: the queue
    // just recycles). LoRa behavior unchanged.
    service->sendToMesh(p, RX_SRC_LOCAL, true);
    lastSendMs = nowMs;
#if defined(ODID_SNIFFER) || defined(GPS_TAG)
    lastSentTs = fixTs;
    lastSentLat = lat;
    lastSentLon = lon;
    if ((seq % 20) == 0) // dec2send = fix-decode -> LoRa-enqueue latency (the P1 metric)
        LOG_INFO("HighRate: src=%d seq=%u lat=%d lon=%d lock=%d dec2send=%lums", HIGHRATE_SRC_TYPE, seq, lat, lon,
                 hasLock, (unsigned long)(fixMs ? (nowMs - fixMs) : 0));
#else
    if ((seq % 20) == 0)
        LOG_INFO("HighRate: seq=%u lat=%d lon=%d lock=%d", seq, lat, lon, hasLock);
#endif
    seq++;
    return hasLock ? HIGHRATE_POSITION_INTERVAL_MS : HIGHRATE_HEARTBEAT_MS;
}
