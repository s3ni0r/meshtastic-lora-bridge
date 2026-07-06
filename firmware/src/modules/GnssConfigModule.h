#pragma once
#include "configuration.h"

#ifdef GPS_TAG
#include "SinglePortModule.h"

/**
 * GnssConfigModule — project fork (GPS_TAG only). Live GNSS/TX tuning over the tag's own BLE.
 *
 * The tag is deliberately deaf on LoRa (HIGHRATE_TX_ONLY), but its PhoneAPI still works over
 * BLE/USB: a packet the phone addresses to the node itself is delivered locally to modules and
 * never touches the radio. This module listens on portnum 260 (PRIVATE_APP+4; 257 is taken by
 * ATAK_FORWARDER upstream):
 *
 *   phone -> tag:  [0x00]                      GET current settings
 *                  [0x01][7-byte settings]     SET (see GnssTagSettings.h wire format)
 *   tag -> phone:  [0x80|op][status][7-byte current settings]
 *                  status: 0 = ok/applied, 1 = validation rejected, 2 = malformed request
 *
 * A successful SET persists to flash and asks GnssRateProbe to re-run its tuning + rate-steering
 * sequence live — the new mode is on the GNSS within seconds, no reboot.
 */
class GnssConfigModule : public SinglePortModule
{
  public:
    GnssConfigModule() : SinglePortModule("gnsscfg", (meshtastic_PortNum)260) {}

  protected:
    virtual ProcessMessage handleReceived(const meshtastic_MeshPacket &mp) override;
};

extern GnssConfigModule *gnssConfigModule;

#endif // GPS_TAG
