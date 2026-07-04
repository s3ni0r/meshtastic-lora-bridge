#pragma once
#include "configuration.h"

#ifdef GPS_TAG
#include <Arduino.h>

class TinyGPSPlus;

/**
 * GnssRateProbe — project fork (GPS_TAG flavor only).
 *
 * Attempts to raise the AG3335 fix rate to 4 Hz+ and MEASURES whether it worked, walking a list of
 * candidate command sequences at boot. The 1 Hz lock proven on unit #1 (docs/results.md "GPS rate —
 * exhaustive root-cause") was a property of that unit's GNSS firmware — every new T1000-E gets
 * re-probed, cheaply and safely, on every boot.
 *
 * Safety rails (the unit-#1 postmortem is baked in):
 *   - RAM-only commands: no $PAIR513 persist attempts tied to a rate change.
 *   - NEVER $PAIR382,1 — that "engine stop for persist" enters a VRTC-backed backup sleep that
 *     survives reboots and bricks GNSS detection (recovery = GPS_RTC_INT pulse, see GPS::createGps).
 *   - The engine-stop candidate uses plain $PAIR003/$PAIR002 power off/on instead, which the
 *     existing anti-brick preamble + RTC_INT safety net already cover.
 *
 * Ground truth is the measured fix cadence, not ACKs (unit #1 honored $PAIR062 without ever ACKing
 * $PAIR050): fix epochs = changes of the NMEA time-of-day (centisecond resolution), cross-checked
 * against the checksum-passed sentence rate so OSThread tick jitter can't alias a 10 Hz win away.
 * Driven non-blocking from GPS::runOnce() while the GPS is active; logs a verdict per candidate, a
 * WINNER (kept re-applied if the rate ever sags) or a final "locked at 1 Hz" verdict, then stays
 * resident logging the live fix rate every 10 s.
 */
class GnssRateProbe
{
  public:
    /// Call once per GPS thread pass while the GPS is powered (GPS_ACTIVE). Non-blocking.
    void tick(Stream *serial, TinyGPSPlus &reader);

  private:
    enum Phase : uint8_t {
        WAIT_FLOW,   // wait for NMEA flow (and boot to settle) before touching anything
        BASELINE,    // measure the as-shipped rate + calibrate sentences-per-fix
        SEND,        // emit the current candidate's commands, one per tick
        SETTLE,      // give the module time to apply (longer for the engine-stop candidate)
        MEASURE,     // measure the resulting fix cadence
        RESIDENT,    // probing done: monitor + 10 s rate logs (+ re-apply the winner if rate sags)
    };

    void sendCmd(Stream *serial, const char *body); // wraps $<body>*<checksum>\r\n
    void startWindow(TinyGPSPlus &reader, uint32_t nowMs);
    void sampleFixEpochs(TinyGPSPlus &reader, uint32_t nowMs);
    float windowFixHz(TinyGPSPlus &reader, uint32_t nowMs) const; // best estimate over the window

    Phase phase = WAIT_FLOW;
    uint32_t phaseStartMs = 0;
    uint32_t nextActionMs = 0;

    // Candidate walk
    int8_t candidate = -1;  // index into the candidate table
    uint8_t cmdIdx = 0;     // next command within the candidate
    int8_t winner = -1;     // candidate that reached >= GNSSPROBE_SUCCESS_HZ (-1 = none)
    uint8_t sagWindows = 0; // resident windows below the re-apply threshold
    uint32_t lastReapplyMs = 0;

    // Measurement window state
    uint32_t winStartMs = 0;
    uint32_t sentAtStart = 0;   // reader.passedChecksum() at window start
    uint32_t lastTimeVal = 0;   // last seen reader.time.value() (HHMMSSCC)
    uint16_t fixEpochs = 0;     // observed time-of-day changes in the window
    float sentPerFix = 0;       // calibrated at BASELINE (the chip is known to ship at 1 Hz)
    float baselineHz = 0;
};

extern GnssRateProbe gnssRateProbe;

#endif // GPS_TAG
