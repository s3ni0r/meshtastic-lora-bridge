#pragma once
#include "configuration.h"

#if defined(GPS_TAG) || defined(ODID_SNIFFER)
#include "SinglePortModule.h"

/**
 * GnssConfigModule — project fork, the portnum-260 command channel. Compiled into BOTH tag
 * flavors since A1 (bridge parity); the capability byte in every settings reply advertises which
 * knob groups this flavor actually serves. Commands arrive over the tag's own BLE/USB (PhoneAPI —
 * works in every radio state) or over LoRa via the Base while the tag is LISTENING
 * (docs/RADIO_STATES.md; the wire contract is docs/DOWNLINK.md).
 *
 * Ops (first payload byte); portnum 260 = PRIVATE_APP+4 (257 is taken by ATAK_FORWARDER):
 *   0x00 GET      — reply with current settings
 *   0x01 SET      — 7/8/13/14-byte settings (v4 adds the profile byte; see GnssTagSettings.h)
 *   0x02 MODE     — GPS tag only, HYBRID only: CALIBRATION (TTL dead-man) / ADAPTIVE
 *   0x03 SIGNAL   — v5: [pattern u8][sid u32 LE] -> correlated 7-byte ACK; legacy 3-byte form kept
 *   0x04 SIM      — GPS tag only: indoor simulator programs
 *   0x05 TRACK    — GPS tag only, phone/USB only: track upload (u32 tid discipline, 9-byte ACKs)
 *   0x06 RADIO    — [state u8: 0 LISTENING / 1 DEAF][rid u32 LE] -> 7-byte ACK, ACK-BEFORE-MUTE
 *
 * Replies:
 *   settings echo (GET/SET/MODE/legacy-SIGNAL): [0x80|op][status][14B v4 settings][capability]
 *     [radio-status][dutyFloorMs u16 LE] = 20 bytes — the length tells the app the tag speaks
 *     v4 (15 = v3 firmware). The duty floor is the tag's own region-law number (0 = no limit);
 *     clients must never re-derive it from modem-preset assumptions.
 *   SIGNAL v5 ACK:  [0x83][status][pattern][sid u32 LE]  (7 B; status 0 covers duplicates)
 *   RADIO ACK:      [0x86][status][state][rid u32 LE]    (7 B; sent BEFORE any mute happens)
 *   TRACK ACK:      [0x85][status][sub][offLo][offHi][tid u32 LE] (9 B, unchanged)
 *   status: 0 = ok/applied, 1 = rejected/unsupported, 2 = malformed request
 *
 * Capability byte (bit set = knob group live on this flavor):
 *   bit0 GNSS chip knobs · bit1 TX modes (MODE op + adaptive) · bit2 simulator/TRACK
 *   bit3 signals · bit4 radio-state op · bit5 profiles
 *   GPS tag = 0x3F; bridge = 0x38 (signals + radio + profiles; spacing is in the base settings).
 */
class GnssConfigModule : public SinglePortModule
{
  public:
    GnssConfigModule() : SinglePortModule("gnsscfg", (meshtastic_PortNum)260) {}

  protected:
    virtual ProcessMessage handleReceived(const meshtastic_MeshPacket &mp) override;

  private:
    /// Correlated 7-byte ACK shared by SIGNAL (0x83) and RADIO (0x86): [ackOp][status][echo]
    /// [id u32 LE] — the echoed byte + the request's own u32 id make the ACK satisfiable ONLY
    /// by the frame that asked (TRACK keeps its 9-byte offset-bearing form).
    void sendSmallAck(const meshtastic_MeshPacket &mp, bool fromPhone, uint8_t ackOp, uint8_t status, uint8_t echo,
                      uint32_t id);
};

// Knob-group capability bits (settings reply byte 16).
#define TAG_CAP_GNSS 0x01
#define TAG_CAP_MODES 0x02
#define TAG_CAP_SIM_TRACK 0x04
#define TAG_CAP_SIGNALS 0x08
#define TAG_CAP_RADIO 0x10
#define TAG_CAP_PROFILES 0x20

#ifdef GPS_TAG
#define TAG_CAPABILITIES (TAG_CAP_GNSS | TAG_CAP_MODES | TAG_CAP_SIM_TRACK | TAG_CAP_SIGNALS | TAG_CAP_RADIO | TAG_CAP_PROFILES)
#else // bridge: position source is the Dronetag — no GNSS knobs, no TX modes, no simulator
#define TAG_CAPABILITIES (TAG_CAP_SIGNALS | TAG_CAP_RADIO | TAG_CAP_PROFILES)
#endif

extern GnssConfigModule *gnssConfigModule;

#endif // GPS_TAG || ODID_SNIFFER
