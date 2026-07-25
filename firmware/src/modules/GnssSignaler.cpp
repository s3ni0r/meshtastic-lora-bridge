#include "GnssSignaler.h"

#ifdef GPS_TAG
#include "main.h" // concurrency::mainDelay

// Language v2 timing/pitch (see GnssSignaler.h for the vocabulary):
static const uint32_t kBeepOnMs = 160;  // counted short beep + its LED blip
static const uint32_t kBeepGapMs = 240; // gap between counted beeps (rhythm must be countable)
static const uint16_t kCountHz = 1175;  // D6 — AutoShot CalibrationBeeper pitch
static const uint32_t kRecOnMs = 600;   // recording-start long beep + flash
static const uint16_t kRecHz = 1568;    // G6 — higher = "go"
static const uint32_t kProblemPeriodMs = 2000;
static const uint32_t kProblemOnMs = 500;
static const uint16_t kProblemHz = 587; // D5 — low = "bad news"
static const uint32_t kProblemCapMs = 120000;
static const uint32_t kHeartbeatPeriodMs = 3000;
static const uint32_t kHeartbeatOnMs = 120; // LED only — the sea heartbeat stays silent

GnssSignaler *gnssSignaler;

GnssSignaler::GnssSignaler() : OSThread("GnssSignaler")
{
    pinMode(LED_PIN, OUTPUT);
    ledWrite(false);
#ifdef PIN_BUZZER
    pinMode(PIN_BUZZER, OUTPUT);
#endif
    setInterval(1000);
}

void GnssSignaler::ledWrite(bool on)
{
    digitalWrite(LED_PIN, on ? LED_STATE_ON : !LED_STATE_ON);
}

static void buzz(uint16_t hz, uint16_t ms)
{
#ifdef PIN_BUZZER
    tone(PIN_BUZZER, hz, ms);
#endif
}

void GnssSignaler::stopAll()
{
    beepsLeft = 0;
    recStartPending = false;
    problemActive = false;
    heartbeatActive = false;
    phaseOn = false;
    ledWrite(false);
#ifdef PIN_BUZZER
    noTone(PIN_BUZZER);
#endif
}

bool GnssSignaler::play(uint8_t pattern, uint8_t seq)
{
    if (seq == lastSeq) {
        LOG_INFO("Signaler: dup seq=%u ignored", seq);
        return true; // idempotent re-send — acknowledged, not replayed
    }

    if (pattern >= 1 && pattern <= 8) { // counted: N beeps + N blips
        stopAll();
        beepsLeft = pattern;
    } else if (pattern == 10) { // recording started
        stopAll();
        recStartPending = true;
        heartbeatActive = true; // armed; pulses after the long beep
    } else if (pattern == 11) { // problem loop
        stopAll();
        problemActive = true;
        problemStartedMs = millis();
    } else if (pattern == 0) { // cancel / recording stopped
        stopAll();
    } else {
        return false;
    }
    lastSeq = seq;
    LOG_INFO("Signaler: pattern=%u seq=%u t=%lums", pattern, seq, (unsigned long)millis());
    setIntervalFromNow(0);
    concurrency::mainDelay.interrupt(); // render the first edge now
    return true;
}

int32_t GnssSignaler::runOnce()
{
    uint32_t now = millis();

    // 1) Counted beep trains preempt loops.
    if (beepsLeft > 0) {
        if (!phaseOn) {
            phaseOn = true;
            ledWrite(true);
            buzz(kCountHz, kBeepOnMs);
            return kBeepOnMs;
        }
        phaseOn = false;
        ledWrite(false);
        beepsLeft--;
        return beepsLeft > 0 ? kBeepGapMs : 1;
    }

    // 2) Recording-start long beep, then fall into the heartbeat.
    if (recStartPending) {
        if (!phaseOn) {
            phaseOn = true;
            ledWrite(true);
            buzz(kRecHz, kRecOnMs);
            return kRecOnMs;
        }
        phaseOn = false;
        recStartPending = false;
        ledWrite(false);
        lastHeartbeatMs = now;
        return kHeartbeatPeriodMs;
    }

    // 3) Problem loop: low beep + LED burn every 2 s until cancel or the 120 s cap.
    if (problemActive) {
        if (now - problemStartedMs >= kProblemCapMs) {
            problemActive = false;
            phaseOn = false;
            ledWrite(false);
            LOG_INFO("Signaler: problem loop capped at 120 s");
            return 1000;
        }
        if (!phaseOn) {
            phaseOn = true;
            ledWrite(true);
            buzz(kProblemHz, kProblemOnMs);
            return kProblemOnMs;
        }
        phaseOn = false;
        ledWrite(false);
        return kProblemPeriodMs - kProblemOnMs;
    }

    // 4) Recording heartbeat: LED-only low blip every 3 s (locally generated, zero airtime).
    if (heartbeatActive) {
        if (phaseOn) {
            phaseOn = false;
            ledWrite(false);
            return kHeartbeatPeriodMs - kHeartbeatOnMs;
        }
        if (now - lastHeartbeatMs >= kHeartbeatPeriodMs - kHeartbeatOnMs) {
            phaseOn = true;
            lastHeartbeatMs = now;
            ledWrite(true);
            return kHeartbeatOnMs;
        }
        return 250;
    }

    ledWrite(false);
    return 1000; // idle
}

#endif // GPS_TAG
