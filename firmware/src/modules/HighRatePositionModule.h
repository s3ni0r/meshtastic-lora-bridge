#pragma once
#include "SinglePortModule.h"

/**
 * HighRatePositionModule — project fork.
 *
 * Streams a position fix as a compact 12/17-byte payload on PRIVATE_APP (256), calling
 * service->sendToMesh() directly. This deliberately BYPASSES Meshtastic's PositionModule, whose
 * 5 s RUNONCE_INTERVAL, whole-second config, smart-broadcast gate, and channel-util/duty-cycle
 * checks make 2-4 Hz impossible.
 *
 * Fix source = the TAG FLAVOR (flags bits 5-7 tell the receiver which one sent the packet):
 *   -DODID_SNIFFER (src=1): BLE5/LoRa bridge — position sniffed from Dronetag Remote ID adverts.
 *   -DGPS_TAG      (src=2): self-contained tag — onboard AG3335 fixes, event-driven via GPS.cpp
 *                           (GnssRateProbe attempts >1 Hz on hardware that allows it).
 *   neither        (src=0): legacy fixed-cadence localPosition bench streamer.
 *
 * Gated behind -DHIGHRATE_POSITION_SENDER (implied by GPS_TAG) so only *tag* nodes stream; the
 * Base/receiver node runs a plain build.
 *
 * BENCH/TEST ONLY: at >2.4 Hz this exceeds the EU868 10% duty cycle. Set
 * lora.override_duty_cycle=true and device.role=TRACKER on the sender. Not for deployment.
 */
class HighRatePositionModule : public SinglePortModule, private concurrency::OSThread
{
  public:
    HighRatePositionModule();

    /// Event-driven send: called by the ODID sniffer (from the Bluefruit callback task) when a NOVEL
    /// fix lands, so runOnce fires now instead of aging the fix up to a full poll interval. Same
    /// cross-task wake pattern as NimbleBluetooth's phone API (setIntervalFromNow is a 32-bit write;
    /// a torn-write race costs at most one poll cycle, never corruption).
    void wakeFreshFix();

  protected:
    virtual int32_t runOnce() override;

  private:
    uint8_t seq = 0;
    int32_t lastLat = 0;       // for staleness detection (position that stops changing == stale)
    int32_t lastLon = 0;
    uint32_t lastChangedMs = 0;
    // Novelty dedupe + pacing (ODID_SNIFFER): what we last actually sent, and when.
    uint16_t lastSentTs = 0;
    int32_t lastSentLat = 0;
    int32_t lastSentLon = 0;
    uint32_t lastSendMs = 0;
    PacketId prevPacketId = 0; // latest-wins: cancel the previous un-sent packet before each send
};

extern HighRatePositionModule *highRatePositionModule;
