#pragma once
#include "configuration.h"

#if defined(GPS_TAG) || defined(ODID_SNIFFER)
#include "concurrency/OSThread.h"
#include <Arduino.h>

/**
 * GnssSignaler — tag-downlink branch, language v2 (BEEP-FIRST, 2026-07-25 owner direction).
 * Renders operator feedback on the T1000-E's piezo (P0.25) with the green LED (P0.24)
 * mirroring every beep, commanded over portnum 260 op 0x03 (Base-relayed LoRa or direct BLE).
 * Compiled into BOTH tag flavors since A1 — the bridge has the same buzzer/LED and plays the
 * same calibration role; it only lacks GNSS knobs.
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
 * Delivery discipline (A4, design review 2026-07-26): at-least-once delivery, AT-MOST-ONCE
 * PLAYBACK per signal id. The client picks a u32 sid (TRACK-tid discipline) and retransmits the
 * SAME {sid, pattern} until the correlated ACK arrives. Dedupe remembers the last
 * kSidHistory {sid, pattern} pairs: an exact re-send re-ACKs without replaying (even if newer
 * signals played in between), while the SAME sid with a DIFFERENT pattern is a client bug and
 * NAKs instead of being silently swallowed. The dedupe is RAM-only — a reboot inside the
 * seconds-long retry window can replay one signal (documented residual, harmless vocabulary).
 *
 * ONE signal owner: every LED/buzzer write on the tag goes through this thread.
 */
class GnssSignaler : private concurrency::OSThread
{
  public:
    /// play() outcome — the config module maps this to the correlated ACK/NAK status.
    enum class Result : uint8_t {
        PLAYED = 0,      // accepted + playback scheduled (starts within one scheduler tick)
        DUPLICATE = 1,   // exact {sid, pattern} re-send: re-ACK, NOT replayed
        SID_CONFLICT = 2, // known sid, DIFFERENT pattern: NAK (client bug — never guess)
        UNKNOWN = 3,     // unknown pattern id: NAK
    };

    GnssSignaler();

    /// Handle a SIGNAL command (sid = client-chosen u32; legacy u8-seq requests are namespaced
    /// into the same history by the caller).
    Result play(uint8_t pattern, uint32_t sid);

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

    // {sid, pattern} dedupe ring — big enough that every sid inside any realistic retry window
    // is still remembered (retry budget ~5; signals are seconds apart in the choreography).
    static constexpr uint8_t kSidHistory = 8;
    uint32_t sidRing[kSidHistory] = {0};
    uint8_t patternRing[kSidHistory] = {0};
    bool ringUsed[kSidHistory] = {false};
    uint8_t ringNext = 0;
};

extern GnssSignaler *gnssSignaler;

#endif // GPS_TAG || ODID_SNIFFER
