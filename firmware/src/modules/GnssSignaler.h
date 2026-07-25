#pragma once
#include "configuration.h"

#ifdef GPS_TAG
#include "concurrency/OSThread.h"
#include <Arduino.h>

/**
 * GnssSignaler — tag-downlink branch, language v2 (BEEP-FIRST, 2026-07-25 owner direction).
 * Renders operator feedback on the T1000-E's piezo (P0.25) with the green LED (P0.24)
 * mirroring every beep, commanded over portnum 260 op 0x03 (Base-relayed LoRa or direct BLE).
 *
 * The calibration language (wire ids — additions need owner sign-off):
 *   1..8  COUNTED: N short beeps (D6 1175 Hz — AutoShot's CalibrationBeeper pitch) + N blips.
 *         Convergence progress etc.: "how many" IS the message (1 = first band, 2 = second…).
 *   10    RECORDING STARTED: one long HIGH beep (G6 1568 Hz, 600 ms) + long flash — unmistakably
 *         different from any counted signal — then arms the local LED heartbeat (a low blip
 *         every 3 s, zero airtime; its absence = not recording).
 *   11    PROBLEM: LOW-tone beep (D5 587 Hz, 500 ms) + LED burn every 2 s, self-capped 120 s.
 *         Low pitch = bad news; repeats so a distracted operator can't miss it.
 *   0     CANCEL: stop everything (problem loop, heartbeat, pending beeps). Doubles as
 *         "recording stopped" — the heartbeat's silence is the signal.
 *
 * ONE signal owner: every LED/buzzer write on the tag goes through this thread. Duplicate-seq
 * commands are acknowledged but not replayed, so lossy fire-and-forget re-sends are safe.
 */
class GnssSignaler : private concurrency::OSThread
{
  public:
    GnssSignaler();

    /// Handle a SIGNAL command. False = unknown pattern id (caller replies status 1);
    /// duplicate seq returns true without replaying.
    bool play(uint8_t pattern, uint8_t seq);

  protected:
    int32_t runOnce() override;

  private:
    void ledWrite(bool on);
    void stopAll();

    // Counted beep trains (ids 1..8)
    uint8_t beepsLeft = 0;
    bool phaseOn = false;

    // One-shot record-start (id 10)
    bool recStartPending = false;

    // Looping states
    bool problemActive = false; // id 11
    uint32_t problemStartedMs = 0;
    bool heartbeatActive = false;
    uint32_t lastHeartbeatMs = 0;

    int16_t lastSeq = -1;
};

extern GnssSignaler *gnssSignaler;

#endif // GPS_TAG
