#pragma once
#include "configuration.h"

#ifdef GPS_TAG
#include <Arduino.h>

class TinyGPSPlus;

/**
 * GnssRateProbe v2 — project fork (GPS_TAG flavor only).
 *
 * Attempts to raise the AG3335 fix rate to 10 Hz and MEASURES whether it worked. v1 sent RAM-only
 * candidates and measured; both units read 1 Hz. The Quectel LC29H spec (same AG3335 core; saved
 * under docs/gnss/) explains why that was inconclusive for this firmware lineage:
 *   - $PAIR050 accepts ONLY 100 or 1000 ms on CSA4-like builds (250 = param error), and the new
 *     rate "takes effect after you reboot the module" — a RAM-only set shows nothing immediately.
 *   - Saving a >1 Hz rate ($PAIR513) is only valid while the GNSS engine is POWERED OFF, i.e.
 *     after $PAIR382,1 (keep-command-interface-alive latch) then $PAIR003 (subsystem off).
 *   - $PAIR382,1 MUST be ACKed ($PAIR001,382,0) before $PAIR003, otherwise the module stops
 *     receiving commands entirely (that was the unit-#1 "brick"; wake = GPS_RTC_INT pulse, which
 *     createGps() now performs on every boot as a safety net).
 *   - On CSA2-like builds $PAIR050 was REMOVED ($PAIR001,050,3 or silence) — then no UART sequence
 *     can help and only a GNSS firmware update remains.
 *
 * v2 therefore:
 *   1. taps the raw UART RX (feedByte from GPS::whileActive) so every $PAIR response — $PAIR001
 *      ACK codes, the full $PAIR021 version string, the $PAIR051 fix-interval reply — is logged
 *      verbatim (the missing evidence in every earlier attempt);
 *   2. characterizes $PAIR050,250 vs $PAIR050,100 ACK codes (0 ok / 1 in-process / 2 send fail /
 *      3 unsupported / 4 param error / 5 busy);
 *   3. runs the spec-exact ACK-GATED dance 382,1 -> 003 -> 050,<target> -> 513 -> 002 (aborts before
 *      003 if the 382 latch is never ACKed — the deaf-module trap);
 *   4. applies the reboot requirement: $PAIR004 hot start, then a PIN_GPS_RESET hardware reset;
 *   5. rescues a silent module (GPS_RTC_INT pulse + reset) and RESTOREs 1000 ms if a saved rate
 *      never takes effect, so the module is never left in a half-configured state.
 */
class GnssRateProbe
{
  public:
    /// Call once per GPS thread pass while the GPS is powered (GPS_ACTIVE). Non-blocking.
    void tick(Stream *serial, TinyGPSPlus &reader);
    /// Raw UART RX tap (called per byte from GPS::whileActive — same thread as tick()).
    void feedByte(int c);
    /// Settings changed (GnssConfigModule): re-run tuning + rate steering live, when idle.
    void requestApply();

  private:
    enum Phase : uint8_t {
        WAIT_FLOW,  // wait for NMEA flow + boot settle
        IDENT,      // $PAIR021 (version string) + $PAIR051 (current fix interval) — via seq engine
        BASELINE,   // as-shipped rate + sentences-per-fix calibration
        CHAR_RAM,   // seq: $PAIR050,250 then $PAIR050,100 — capture ACK codes + immediate effect
        DANCE,      // seq: ACK-gated 382,1 -> 003 -> 050,100 -> 513 -> 002
        APPLY_WAIT, // hot-start seq, or plain wait after a hardware reset
        MEASURE,    // measure cadence, then escalate per measureCtx
        ECHO_TEST,  // seq: $PAIR062,3,1 (GSV ON) — do commands EXECUTE even though nothing ACKs?
        RESETLATCH, // hw reset, then spam the 382,1 latch inside the module's boot window
        RESTORE,    // seq: put 1000 ms back (reverse dance) after a failed apply
        RESIDENT,   // done: 10 s rate logs (+ re-dance if a raised rate sags)
    };
    // What the current MEASURE window is evaluating (escalation ladder position).
    enum MeasureCtx : uint8_t { CTX_CHAR, CTX_DANCE, CTX_HOT, CTX_RESET, CTX_RESTORE, CTX_ECHO };

    // --- sequence engine: one command per tick, optionally gated on its $PAIR001 ACK ---
    struct Step {
        const char *body;   // NMEA body without $/checksum
        uint16_t ackId;     // $PAIR001 command id to wait for (0 = fire and forget)
        uint16_t timeoutMs; // per-attempt ACK wait
        uint8_t tries;      // total attempts
        bool abortOnFail;   // abort the whole sequence if never ACKed with code 0
        uint16_t postMs;    // delay after the step completes
    };
    void startSeq(const Step *steps, uint8_t count, Phase runPhase);
    bool runSeq(Stream *serial, uint32_t nowMs); // true = still running
    void onSeqDone(TinyGPSPlus &reader, uint32_t nowMs);

    void sendCmd(Stream *serial, const char *body, bool quiet = false);
    void startWindow(TinyGPSPlus &reader, uint32_t nowMs);
    void sampleFixEpochs(TinyGPSPlus &reader, uint32_t nowMs);
    float windowFixHz(TinyGPSPlus &reader, uint32_t nowMs) const;
    void startMeasure(TinyGPSPlus &reader, uint32_t nowMs, uint8_t ctx);
    void winner(const char *how, float hz);
    void finalVerdict(float hz);
    void hwReset();      // PIN_GPS_RESET pulse (the "reboot" that applies a saved rate)
    void rtcIntRescue(); // GPS_RTC_INT wake pulse + reset (deaf-module recovery)

    Phase phase = WAIT_FLOW;
    uint32_t nextActionMs = 0;

    // sequence engine state
    const Step *seq = nullptr;
    uint8_t seqLen = 0, seqIdx = 0, seqTry = 0;
    bool seqWaitingAck = false;
    uint32_t seqDeadline = 0;
    bool seqFailed = false;

    // evidence + escalation state
    uint8_t measureCtx = CTX_CHAR;
    int8_t ack100 = -100;      // rate-command ACK code, RAM characterization (-100 = no ACK seen)
    int8_t danceAck050 = -100; // rate-command ACK code inside the dance
    bool danceSaved = false;   // $PAIR513 ACKed code 0 inside the dance
    bool danceRan = false;
    bool restoring = false;
    bool echoPositive = false; // $PAIR062,3,1 turned GSV on -> commands execute without ACKs
    uint32_t resetMs = 0;      // RESETLATCH: when the hw reset was pulsed
    uint16_t latchSends = 0;   // RESETLATCH: 382,1 spam counter
    bool raised = false; // a winner is active
    bool settingsLoaded = false;
    bool pendingApply = false;
    Step applySeq[5]; // runtime-built live-apply sequence (nav/thr/snr/elev/rate)
    uint8_t rescues = 0;
    uint8_t sagWindows = 0;
    uint32_t lastReapplyMs = 0;

    // raw-line tap state
    char lineBuf[120];
    uint8_t lineLen = 0;
    uint16_t ackCmd = 0xFFFF; // last $PAIR001 <cmd>
    int8_t ackCode = -1;      // last $PAIR001 <code>
    uint32_t lastByteMs = 0;
    uint8_t tapLogBudget = 30;

    // measurement window
    uint32_t winStartMs = 0;
    uint32_t sentAtStart = 0;
    uint32_t lastTimeVal = 0;
    uint16_t fixEpochs = 0;
    float sentPerFix = 0;
    float baselineHz = 0;
};

extern GnssRateProbe gnssRateProbe;

#endif // GPS_TAG
