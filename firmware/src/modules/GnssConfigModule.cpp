#include "configuration.h"

#if defined(GPS_TAG) || defined(ODID_SNIFFER)
#include "GnssConfigModule.h"
#include "GnssSignaler.h"
#include "MeshService.h"
#include "NodeDB.h"
#include "TagRadioState.h"
#include "gps/GnssTagSettings.h"
#ifdef GPS_TAG
#include "gps/GnssRateProbe.h"
#include "gps/GnssSim.h"
#endif

GnssConfigModule *gnssConfigModule;

void GnssConfigModule::sendSmallAck(const meshtastic_MeshPacket &mp, bool fromPhone, uint8_t ackOp, uint8_t status,
                                    uint8_t echo, uint32_t id)
{
    meshtastic_MeshPacket *a = allocDataPacket();
    if (!a)
        return;
    a->to = mp.from;
    a->decoded.payload.bytes[0] = ackOp;
    a->decoded.payload.bytes[1] = status;
    a->decoded.payload.bytes[2] = echo;
    a->decoded.payload.bytes[3] = (uint8_t)(id & 0xFF);
    a->decoded.payload.bytes[4] = (uint8_t)((id >> 8) & 0xFF);
    a->decoded.payload.bytes[5] = (uint8_t)((id >> 16) & 0xFF);
    a->decoded.payload.bytes[6] = (uint8_t)((id >> 24) & 0xFF);
    a->decoded.payload.size = 7;
    if (fromPhone) {
        service->sendToPhone(a);
    } else {
        a->want_ack = false;
        a->hop_limit = 1;
        service->sendToMesh(a, RX_SRC_LOCAL, false);
    }
}

ProcessMessage GnssConfigModule::handleReceived(const meshtastic_MeshPacket &mp)
{
    uint32_t rxMs = millis(); // stamp FIRST — the downlink-latency reference point
    const auto &d = mp.decoded;
    if (d.payload.size < 1)
        return ProcessMessage::STOP;

    // Origin: phone-injected packets carry our own node id (or 0); anything else arrived over
    // LoRa via the Base (tag-downlink branch — the radio listens while LISTENING).
    bool fromPhone = (mp.from == 0) || (mp.from == nodeDB->getNodeNum());

    uint8_t op = d.payload.bytes[0];
    uint8_t status = 0;

    if (op == 0x01) { // SET (accepts 7/8/13-byte legacy or 14-byte v4 settings after the op byte)
        if (d.payload.size >= 8) {
            if (gnssTagSettingsSetFromWire(&d.payload.bytes[1], (uint8_t)(d.payload.size - 1))) {
#ifdef GPS_TAG
                gnssRateProbe.requestApply(); // live re-tune (no reboot)
#endif
                // PERMANENT profile forces its persisted radio state (ACK-first + grace when
                // that means going deaf — the reply below leaves before any mute).
                if (tagRadioState)
                    tagRadioState->applyProfileSideEffects();
            } else {
                status = 1; // out-of-range / invalid mode / duty floor
            }
        } else {
            status = 2; // malformed
        }
    } else if (op == 0x02) { // MODE: [mode u8, ttl_s u16 LE (CALIBRATION only; 0 = default)]
#ifdef GPS_TAG
        if (gnssTagSettings.profileBits & TAG_PROFILE_PERMANENT) {
            status = 1; // PERMANENT has no temporary states (docs/RADIO_STATES.md §3)
        } else if (d.payload.size >= 2 && d.payload.bytes[1] <= GnssTagMode::ADAPTIVE) {
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
#else
        status = 1; // bridge has NO TX modes (RADIO_STATES §2) — capability byte says so
#endif
    } else if (op == 0x04) { // SIM: [src, flags(bit0 loop), ttl_s u16 LE, nSeg, nSeg×(speed,dur)]
#ifdef GPS_TAG
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
#else
        status = 1; // no simulator on the bridge (its position source is the Dronetag)
#endif
    } else if (op == 0x05) { // TRACK upload: [sub, tid u32 LE, ...] — phone/USB-direct ONLY
#ifdef GPS_TAG
        // Every sub-op carries the client-chosen u32 transfer id (R4 finding 7): CHUNK/COMMIT/
        // ABORT for a different transfer can never mutate the active staging, and the ACK
        // echoes the REQUEST's tid so correlation is exact, not probabilistic.
        uint8_t sub = 0xEE;
        uint32_t tid = 0;
        uint16_t echoOff = 0;
        bool ok = false;
        if (d.payload.size >= 6) {
            sub = d.payload.bytes[1];
            tid = (uint32_t)d.payload.bytes[2] | ((uint32_t)d.payload.bytes[3] << 8) |
                  ((uint32_t)d.payload.bytes[4] << 16) | ((uint32_t)d.payload.bytes[5] << 24);
        }
        if (!fromPhone) {
            // R3 finding 7: TRACK is destructive (slot replacement) — a mesh peer must never
            // drive it. Reject with a NAK; only the locally-attached client may upload.
            LOG_WARN("GnssConfig: TRACK op from mesh !%08lx REJECTED", (unsigned long)mp.from);
        } else if (tid == 0) {
            // malformed / missing transfer id — NAK (ok stays false)
        } else if (sub == 0x00 && d.payload.size >= 12) { // BEGIN: tid, count u16, crc32 u32
            uint16_t cnt = (uint16_t)(d.payload.bytes[6] | (d.payload.bytes[7] << 8));
            uint32_t crc = (uint32_t)d.payload.bytes[8] | ((uint32_t)d.payload.bytes[9] << 8) |
                           ((uint32_t)d.payload.bytes[10] << 16) | ((uint32_t)d.payload.bytes[11] << 24);
            ok = gnssSim->trackBegin(cnt, crc, tid);
            echoOff = cnt;
        } else if (sub == 0x01 && d.payload.size >= 9) { // CHUNK: tid, offRec u16, n u8, n×10B
            uint16_t off = (uint16_t)(d.payload.bytes[6] | (d.payload.bytes[7] << 8));
            uint8_t n = d.payload.bytes[8];
            if (d.payload.size >= (uint16_t)(9 + n * 10))
                ok = gnssSim->trackChunk(tid, off, n, &d.payload.bytes[9]);
            echoOff = off;
        } else if (sub == 0x02) { // COMMIT — idempotent RETRY only for the SAME (tid, crc)
            ok = gnssSim->trackCommit(tid);
        } else if (sub == 0x03) { // ABORT — discards only the staging this tid owns
            ok = gnssSim->trackAbort(tid);
        }
        // Correlated ACK: [0x85, status, sub, offLo, offHi, tid u32 LE] (9 bytes). The tid is
        // the one from the REQUEST — a stale ACK from any previous transfer or another tag
        // can never satisfy the current frame (the client also validates the sender node).
        meshtastic_MeshPacket *tr = allocDataPacket();
        if (tr) {
            tr->to = mp.from;
            tr->decoded.payload.bytes[0] = 0x85;
            tr->decoded.payload.bytes[1] = ok ? 0 : 1;
            tr->decoded.payload.bytes[2] = sub;
            tr->decoded.payload.bytes[3] = (uint8_t)(echoOff & 0xFF);
            tr->decoded.payload.bytes[4] = (uint8_t)(echoOff >> 8);
            tr->decoded.payload.bytes[5] = (uint8_t)(tid & 0xFF);
            tr->decoded.payload.bytes[6] = (uint8_t)((tid >> 8) & 0xFF);
            tr->decoded.payload.bytes[7] = (uint8_t)((tid >> 16) & 0xFF);
            tr->decoded.payload.bytes[8] = (uint8_t)((tid >> 24) & 0xFF);
            tr->decoded.payload.size = 9;
            if (fromPhone) {
                service->sendToPhone(tr);
            } else {
                tr->want_ack = false;
                tr->hop_limit = 1;
                service->sendToMesh(tr, RX_SRC_LOCAL, false);
            }
        }
        return ProcessMessage::STOP;
#else
        status = 1; // no track storage on the bridge
#endif
    } else if (op == 0x03 && d.payload.size >= 6) { // SIGNAL v5: [pattern u8][sid u32 LE]
        uint8_t pattern = d.payload.bytes[1];
        uint32_t sid = (uint32_t)d.payload.bytes[2] | ((uint32_t)d.payload.bytes[3] << 8) |
                       ((uint32_t)d.payload.bytes[4] << 16) | ((uint32_t)d.payload.bytes[5] << 24);
        // The latency-measurement line: host timestamps its send, this stamps the arrival.
        LOG_INFO("GnssConfig: SIGRX pattern=%u sid=%lu t=%lums", pattern, (unsigned long)sid, (unsigned long)rxMs);
        GnssSignaler::Result res =
            gnssSignaler ? gnssSignaler->play(pattern, sid) : GnssSignaler::Result::UNKNOWN;
        // ACK = accepted + playback scheduled (or an exact duplicate of one that was). A sid
        // carrying a different pattern, or an unknown pattern, NAKs — never a silent swallow.
        uint8_t st = (res == GnssSignaler::Result::PLAYED || res == GnssSignaler::Result::DUPLICATE) ? 0 : 1;
        sendSmallAck(mp, fromPhone, 0x83, st, pattern, sid);
        LOG_INFO("GnssConfig: op=3 status=%u sid=%lu (ack via %s)", st, (unsigned long)sid,
                 fromPhone ? "phone" : "mesh");
        return ProcessMessage::STOP;
    } else if (op == 0x03) { // SIGNAL legacy: [pattern u8, seq u8] — pre-v5 clients
        if (d.payload.size >= 3) {
            LOG_INFO("GnssConfig: SIGRX pattern=%u seq=%u t=%lums", d.payload.bytes[1], d.payload.bytes[2],
                     (unsigned long)rxMs);
            // Namespace the u8 seq into the sid history so legacy re-sends still dedupe.
            uint32_t sid = 0xFFFFFF00UL | d.payload.bytes[2];
            GnssSignaler::Result res =
                gnssSignaler ? gnssSignaler->play(d.payload.bytes[1], sid) : GnssSignaler::Result::UNKNOWN;
            if (res == GnssSignaler::Result::UNKNOWN || res == GnssSignaler::Result::SID_CONFLICT)
                status = 1; // unknown pattern id (legacy semantics; reply is the settings echo)
        } else {
            status = 2;
        }
    } else if (op == 0x06) { // RADIO: [state u8: 0 LISTENING / 1 DEAF][rid u32 LE]
        uint8_t state = 0xFF;
        uint32_t rid = 0;
        uint8_t st = 2; // malformed until proven otherwise
        if (d.payload.size >= 6) {
            state = d.payload.bytes[1];
            rid = (uint32_t)d.payload.bytes[2] | ((uint32_t)d.payload.bytes[3] << 8) |
                  ((uint32_t)d.payload.bytes[4] << 16) | ((uint32_t)d.payload.bytes[5] << 24);
            st = tagRadioState ? tagRadioState->requestState(state) : 1;
        }
        // ACK-BEFORE-MUTE: requestState never mutes synchronously — a GO-DEAF arms the ~2 s
        // grace, so this ACK (and re-ACKs for duplicates inside the grace) always leaves first.
        sendSmallAck(mp, fromPhone, 0x86, st, state, rid);
        LOG_INFO("GnssConfig: RADIO state=%u status=%u rid=%lu t=%lums (ack via %s)", state, st, (unsigned long)rid,
                 (unsigned long)rxMs, fromPhone ? "phone" : "mesh");
        return ProcessMessage::STOP;
    } else if (op != 0x00) { // GET(0)/SET(1)/MODE(2)/SIGNAL(3)/SIM(4)/TRACK(5)/RADIO(6)
        status = 2;
    }

    // Reply with the current settings — the requester's positive confirmation. Phone requests
    // reply on the phone queue (as always); LoRa requests reply over the air to the requester,
    // cheap and single-hop (mode/tier/radio-state are ALSO echoed in every stream packet).
    // 20 bytes = v4: [0x80|op][status][14B settings][capability][radio-status][dutyFloor u16 LE].
    // The duty floor is the tag's OWN number (region duty % × measured airtime for the active
    // modem preset) — clients must never re-derive it from preset assumptions (the bench once
    // assumed ShortFast while the fleet ran LongFast). 0 = no duty limit / bench override.
    meshtastic_MeshPacket *r = allocDataPacket();
    if (!r)
        return ProcessMessage::STOP;
    r->to = mp.from;
    r->decoded.payload.bytes[0] = 0x80 | op;
    r->decoded.payload.bytes[1] = status;
    gnssTagSettingsPack(&r->decoded.payload.bytes[2]);
    r->decoded.payload.bytes[16] = TAG_CAPABILITIES;
    r->decoded.payload.bytes[17] = tagRadioState ? tagRadioState->statusByte() : 0;
    uint32_t floorMs = tagRadioDutyFloorMs();
    if (floorMs > 0xFFFF)
        floorMs = 0xFFFF;
    r->decoded.payload.bytes[18] = (uint8_t)(floorMs & 0xFF);
    r->decoded.payload.bytes[19] = (uint8_t)(floorMs >> 8);
    r->decoded.payload.size = 20;
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

#endif // GPS_TAG || ODID_SNIFFER
