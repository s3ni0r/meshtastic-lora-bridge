#include "GnssSignaler.h"

#ifdef GPS_TAG

// Timing — AutoShot's torch grammar, transplanted (docs/feedback-signals.md):
static const uint32_t kBlipOnMs = 120;
static const uint32_t kBlipGapMs = 200;
static const uint32_t kBurnMs = 2000;         // failure burns: 2 s ON / 2 s OFF
static const uint32_t kBurnsCapMs = 120000;   // same 120 s hard cap as the torch
static const uint32_t kHeartbeatPeriodMs = 3000;
static const uint16_t kBeepHz = 1175;         // D6 — the exact pitch of AutoShot's CalibrationBeeper

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

void GnssSignaler::beep(uint16_t ms)
{
#ifdef PIN_BUZZER
    tone(PIN_BUZZER, kBeepHz, ms);
#endif
}

void GnssSignaler::stopAll()
{
    blipsLeft = 0;
    blipWithBeep = false;
    burnsActive = false;
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

    switch (pattern) {
    case 1: // resection ack
    case 2: // band converged
    case 3: // recording started
        stopAll();
        blipsLeft = pattern; // 1/2/3 blips — the id IS the count, like the torch signatures
        blipWithBeep = (pattern == 3);
        if (pattern == 3)
            heartbeatActive = true; // armed; starts pulsing after the blip train finishes
        break;
    case 4: // calibration failed — burn loop
        stopAll();
        burnsActive = true;
        burnsStartedMs = millis();
        break;
    case 5: // cancel everything (also = "recording stopped": the heartbeat's absence is the signal)
        stopAll();
        break;
    default:
        return false;
    }
    lastSeq = seq;
    LOG_INFO("Signaler: pattern=%u seq=%u t=%lums", pattern, seq, (unsigned long)millis());
    setIntervalFromNow(0);
    concurrency::mainDelay.interrupt(); // render the first edge now, not at the next lazy tick
    return true;
}

int32_t GnssSignaler::runOnce()
{
    uint32_t now = millis();

    // 1) One-shot blip trains preempt everything else visually.
    if (blipsLeft > 0) {
        if (!phaseOn) {
            phaseOn = true;
            ledWrite(true);
            if (blipWithBeep)
                beep(kBlipOnMs + 40); // beep rides each blip: triple-blip == triple-beep
            return kBlipOnMs;
        }
        phaseOn = false;
        ledWrite(false);
        blipsLeft--;
        return blipsLeft > 0 ? kBlipGapMs : 1; // fall through to loops on the next pass
    }

    // 2) Failure burns: 2 s ON / 2 s OFF until cancelled or the 120 s cap.
    if (burnsActive) {
        if (now - burnsStartedMs >= kBurnsCapMs) {
            burnsActive = false;
            phaseOn = false;
            ledWrite(false);
            LOG_INFO("Signaler: burns capped at 120 s");
            return 1000;
        }
        phaseOn = !phaseOn;
        ledWrite(phaseOn);
        return kBurnMs;
    }

    // 3) Recording heartbeat: one low blip every 3 s, generated locally (zero airtime).
    if (heartbeatActive) {
        if (phaseOn) {
            phaseOn = false;
            ledWrite(false);
            return kHeartbeatPeriodMs - kBlipOnMs;
        }
        if (now - lastHeartbeatMs >= kHeartbeatPeriodMs - kBlipOnMs) {
            phaseOn = true;
            lastHeartbeatMs = now;
            ledWrite(true);
            return kBlipOnMs;
        }
        return 250;
    }

    ledWrite(false);
    return 1000; // idle
}

#endif // GPS_TAG
