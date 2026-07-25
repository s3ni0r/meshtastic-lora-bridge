#include "configuration.h"

#ifdef GPS_TAG
#include "GnssConfigModule.h"
#include "GnssSignaler.h"
#include "MeshService.h"
#include "NodeDB.h"
#include "gps/GnssRateProbe.h"
#include "gps/GnssSim.h"
#include "gps/GnssTagSettings.h"

GnssConfigModule *gnssConfigModule;

ProcessMessage GnssConfigModule::handleReceived(const meshtastic_MeshPacket &mp)
{
    uint32_t rxMs = millis(); // stamp FIRST — the downlink-latency reference point
    const auto &d = mp.decoded;
    if (d.payload.size < 1)
        return ProcessMessage::STOP;

    // Origin: phone-injected packets carry our own node id (or 0); anything else arrived over
    // LoRa via the Base (tag-downlink branch — the radio listens now).
    bool fromPhone = (mp.from == 0) || (mp.from == nodeDB->getNodeNum());

    uint8_t op = d.payload.bytes[0];
    uint8_t status = 0;

    if (op == 0x01) { // SET (accepts 7-byte legacy or 8-byte v2 settings after the op byte)
        if (d.payload.size >= 8) {
            if (gnssTagSettingsSetFromWire(&d.payload.bytes[1], (uint8_t)(d.payload.size - 1))) {
                gnssRateProbe.requestApply(); // live re-tune (no reboot)
            } else {
                status = 1; // out-of-range / invalid mode
            }
        } else {
            status = 2; // malformed
        }
    } else if (op == 0x02) { // MODE: [mode u8, ttl_s u16 LE (CALIBRATION only; 0 = default)]
        if (d.payload.size >= 2 && d.payload.bytes[1] <= GnssTagMode::ADAPTIVE) {
            gnssTagMode.mode = d.payload.bytes[1];
            if (gnssTagMode.mode == GnssTagMode::CALIBRATION) {
                uint32_t ttlS = GPSTAG_CALIB_TTL_DEFAULT_S;
                if (d.payload.size >= 4) {
                    uint32_t w = (uint32_t)d.payload.bytes[2] | ((uint32_t)d.payload.bytes[3] << 8);
                    if (w)
                        ttlS = w;
                }
                gnssTagMode.calibDeadlineMs = rxMs + ttlS * 1000UL;
                LOG_INFO("GnssConfig: MODE=CALIBRATION ttl=%lus t=%lums", (unsigned long)ttlS, (unsigned long)rxMs);
            } else {
                gnssTagMode.slowTier = false; // re-evaluate from scratch
                gnssTagMode.belowSinceMs = 0;
                LOG_INFO("GnssConfig: MODE=ADAPTIVE t=%lums", (unsigned long)rxMs);
            }
        } else {
            status = d.payload.size >= 2 ? 1 : 2;
        }
    } else if (op == 0x04) { // SIM: [src, flags(bit0 loop), ttl_s u16 LE, nSeg, nSeg×(speed,dur)]
        // src 0 = off, 1 = program, 2 = accel-coupled, 3 = track replay (phase 2),
        // 0xFF = TTL keep-alive only (doesn't disturb playback).
        if (d.payload.size >= 2 && d.payload.bytes[1] == 0x00) {
            gnssSim->stop("app command");
        } else if (d.payload.size >= 5) {
            uint16_t ttl = (uint16_t)(d.payload.bytes[3] | (d.payload.bytes[4] << 8));
            uint8_t srcReq = d.payload.bytes[1];
            bool loopReq = d.payload.bytes[2] & 1;
            bool ok = false;
            if (srcReq == 0xFF) {
                ok = gnssSim->refreshTtl(ttl);
            } else if (srcReq == GnssSim::PROGRAM && d.payload.size >= 6) {
                uint8_t n = d.payload.bytes[5];
                if (d.payload.size >= (uint16_t)(6 + 2 * n))
                    ok = gnssSim->startProgram(&d.payload.bytes[6], n, loopReq, ttl);
            } else if (srcReq == GnssSim::ACCEL) {
                ok = gnssSim->startAccel(ttl);
            }
            if (!ok)
                status = 1;
        } else {
            status = 2;
        }
    } else if (op == 0x03) { // SIGNAL: [pattern u8, seq u8] — LED/buzzer, AutoShot grammar
        if (d.payload.size >= 3) {
            // The latency-measurement line: host timestamps its send, this stamps the arrival.
            LOG_INFO("GnssConfig: SIGRX pattern=%u seq=%u t=%lums", d.payload.bytes[1], d.payload.bytes[2],
                     (unsigned long)rxMs);
            if (!gnssSignaler || !gnssSignaler->play(d.payload.bytes[1], d.payload.bytes[2]))
                status = 1; // unknown pattern id
        } else {
            status = 2;
        }
    } else if (op != 0x00) { // GET(0)/SET(1)/MODE(2)/SIGNAL(3)/SIM(4)
        status = 2;
    }

    // Reply with the current settings — the requester's positive confirmation. Phone requests
    // reply on the phone queue (as always); LoRa requests reply over the air to the requester,
    // cheap and single-hop (the mode/tier is ALSO echoed in every stream packet's flags).
    meshtastic_MeshPacket *r = allocDataPacket();
    if (!r)
        return ProcessMessage::STOP;
    r->to = mp.from;
    r->decoded.payload.bytes[0] = 0x80 | op;
    r->decoded.payload.bytes[1] = status;
    gnssTagSettingsPack(&r->decoded.payload.bytes[2]);
    r->decoded.payload.size = 15; // 13-byte v3 settings — the length tells the app the tag speaks v3
    if (fromPhone) {
        service->sendToPhone(r); // straight to the BLE/USB client; never queued for LoRa
    } else {
        r->want_ack = false;
        r->hop_limit = 1;
        service->sendToMesh(r, RX_SRC_LOCAL, false);
    }
    LOG_INFO("GnssConfig: op=%u status=%u (reply via %s)", op, status, fromPhone ? "phone" : "mesh");
    return ProcessMessage::STOP;
}

#endif // GPS_TAG
