#pragma once
#include "configuration.h"

#ifdef GPS_TAG
#include "concurrency/OSThread.h"
#include <Arduino.h>

/**
 * GnssSignaler — tag-downlink branch. Renders operator feedback patterns on the T1000-E's
 * green LED (P0.24) and piezo buzzer (P0.25), commanded over portnum 260 op 0x03 (Base-relayed
 * LoRa or direct BLE). The vocabulary is AutoShot's torch grammar verbatim (autoshot
 * docs/feedback-signals.md): blip = 0.12 s ON, blips spaced 0.2 s; burn = 2 s ON / 2 s OFF.
 *
 * Patterns (wire ids — FROZEN, additions need the same sign-off as AutoShot torch signatures):
 *   1  single blip                        resection ack (lock / window / spot / walk started)
 *   2  double blip                        band converged (2nd occurrence of the walk = stop)
 *   3  triple blip + triple beep (D6)     RECORDING STARTED — also arms the local heartbeat
 *   4  failure burns (2 s ON/OFF loop)    calibration failed, come back — hard-capped 120 s
 *   5  cancel                             stop everything (burns, heartbeat, pending blips)
 *
 * Heartbeat: after pattern 3, one low blip every 3 s, locally generated (zero airtime),
 * until pattern 5 — its absence means "recording stopped", exactly like AutoShot's torch.
 *
 * ONE signal owner: every LED/buzzer write on the tag goes through this thread (the
 * TorchSignaler rule). Duplicate-seq commands are acknowledged but not replayed, so the
 * app can re-send lossy fire-and-forget signals safely.
 */
class GnssSignaler : private concurrency::OSThread
{
  public:
    GnssSignaler();

    /// Handle a SIGNAL command. Returns false for an unknown pattern id (caller reports
    /// status 1); a duplicate seq returns true without replaying (idempotent re-send).
    bool play(uint8_t pattern, uint8_t seq);

  protected:
    int32_t runOnce() override;

  private:
    void ledWrite(bool on);
    void beep(uint16_t ms);
    void stopAll();

    // One-shot blip trains
    uint8_t blipsLeft = 0;
    bool blipWithBeep = false;
    bool phaseOn = false;

    // Looping states
    bool burnsActive = false;
    uint32_t burnsStartedMs = 0;
    bool heartbeatActive = false;
    uint32_t lastHeartbeatMs = 0;

    int16_t lastSeq = -1;
};

extern GnssSignaler *gnssSignaler;

#endif // GPS_TAG
