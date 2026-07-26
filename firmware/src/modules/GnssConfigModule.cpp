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
            } else if (srcReq == GnssSim::TRACK) {
                ok = gnssSim->startTrack(loopReq, ttl);
            }
            if (!ok)
                status = 1;
        } else {
            status = 2;
        }
    } else if (op == 0x05) { // TRACK upload: [sub, ...] — phone/USB-direct ONLY (enforced)
        uint8_t sub = d.payload.size >= 2 ? d.payload.bytes[1] : 0xEE;
        uint16_t echoOff = 0;
        bool ok = false;
        if (!fromPhone) {
            // R3 finding 7: TRACK is destructive (slot replacement) — a mesh peer must never
            // drive it. Reject with a NAK; only the locally-attached client may upload.
            LOG_WARN("GnssConfig: TRACK op from mesh !%08lx REJECTED", (unsigned long)mp.from);
        } else if (sub == 0x00 && d.payload.size >= 9) { // BEGIN: count u16, crc32 u32, nonce u8
            uint16_t cnt = (uint16_t)(d.payload.bytes[2] | (d.payload.bytes[3] << 8));
            uint32_t crc = (uint32_t)d.payload.bytes[4] | ((uint32_t)d.payload.bytes[5] << 8) |
                           ((uint32_t)d.payload.bytes[6] << 16) | ((uint32_t)d.payload.bytes[7] << 24);
            ok = gnssSim->trackBegin(cnt, crc, d.payload.bytes[8]);
            echoOff = cnt;
        } else if (sub == 0x01 && d.payload.size >= 5) { // CHUNK: offRec u16, n u8, n×10B
            uint16_t off = (uint16_t)(d.payload.bytes[2] | (d.payload.bytes[3] << 8));
            uint8_t n = d.payload.bytes[4];
            if (d.payload.size >= (uint16_t)(5 + n * 10))
                ok = gnssSim->trackChunk(off, n, &d.payload.bytes[5]);
            echoOff = off;
        } else if (sub == 0x02) { // COMMIT — idempotent + transactional (see GnssSim)
            ok = gnssSim->trackCommit();
        } else if (sub == 0x03) { // ABORT — discards the STAGED upload only
            gnssSim->trackAbort();
            ok = true;
        }
        // Correlated ACK (R2 f1 + R3 f3): echoes sub-op, offset AND the per-upload nonce —
        // [0x85, status, sub, offLo, offHi, nonce]. A stale ACK from a previous upload or a
        // different tag can never satisfy the current transfer (the client also validates
        // the sender's node id from the MeshPacket).
        meshtastic_MeshPacket *tr = allocDataPacket();
        if (tr) {
            tr->to = mp.from;
            tr->decoded.payload.bytes[0] = 0x85;
            tr->decoded.payload.bytes[1] = ok ? 0 : 1;
            tr->decoded.payload.bytes[2] = sub;
            tr->decoded.payload.bytes[3] = (uint8_t)(echoOff & 0xFF);
            tr->decoded.payload.bytes[4] = (uint8_t)(echoOff >> 8);
            tr->decoded.payload.bytes[5] = gnssSim->uploadNonce();
            tr->decoded.payload.size = 6;
            if (fromPhone) {
                service->sendToPhone(tr);
            } else {
                tr->want_ack = false;
                tr->hop_limit = 1;
                service->sendToMesh(tr, RX_SRC_LOCAL, false);
            }
        }
        return ProcessMessage::STOP;
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
    } else if (op != 0x00) { // GET(0)/SET(1)/MODE(2)/SIGNAL(3)/SIM(4)/TRACK(5)
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
