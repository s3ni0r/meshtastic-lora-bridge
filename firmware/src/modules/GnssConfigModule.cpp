#include "configuration.h"

#ifdef GPS_TAG
#include "GnssConfigModule.h"
#include "MeshService.h"
#include "gps/GnssRateProbe.h"
#include "gps/GnssTagSettings.h"

GnssConfigModule *gnssConfigModule;

ProcessMessage GnssConfigModule::handleReceived(const meshtastic_MeshPacket &mp)
{
    const auto &d = mp.decoded;
    if (d.payload.size < 1)
        return ProcessMessage::STOP;

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
    } else if (op != 0x00) { // only GET(0)/SET(1) exist
        status = 2;
    }

    // Reply with the (possibly updated) current settings — the phone's positive confirmation.
    meshtastic_MeshPacket *r = allocDataPacket();
    if (!r)
        return ProcessMessage::STOP;
    r->to = mp.from;
    r->decoded.payload.bytes[0] = 0x80 | op;
    r->decoded.payload.bytes[1] = status;
    gnssTagSettingsPack(&r->decoded.payload.bytes[2]);
    r->decoded.payload.size = 10;
    service->sendToPhone(r); // straight to the BLE/USB client; never queued for LoRa
    LOG_INFO("GnssConfig: op=%u status=%u (reply sent to phone)", op, status);
    return ProcessMessage::STOP;
}

#endif // GPS_TAG
