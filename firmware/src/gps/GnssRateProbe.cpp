#include "configuration.h"

#ifdef GPS_TAG
#include "GnssRateProbe.h"
#include "TinyGPS++.h"
#include <stdio.h>

// Success = a sustained fix cadence at/above this. 3.5 accepts a true 4 Hz with margin; a 10 Hz win
// simply sails past it. The LoRa TX side is separately paced by HIGHRATE_MIN_SPACING_MS.
#ifndef GNSSPROBE_SUCCESS_HZ
#define GNSSPROBE_SUCCESS_HZ 3.5f
#endif

#define GNSSPROBE_BOOT_DELAY_MS 15000       // let boot + GPS::setup + anti-brick preamble finish first
#define GNSSPROBE_BASE_WIN_MS 5000          // baseline (as-shipped rate) measurement window
#define GNSSPROBE_WIN_MS 4000               // per-candidate measurement window
#define GNSSPROBE_RESIDENT_WIN_MS 10000     // resident rate-log window
#define GNSSPROBE_REAPPLY_COOLDOWN_MS 60000 // min gap between winner re-applies

// Candidate command sequences, walked in order until one measures >= GNSSPROBE_SUCCESS_HZ.
// Bodies are checksummed at runtime (no hand-XOR bugs). ALL RAM-only. $PAIR382 is BANNED (see .h).
struct GnssProbeCandidate {
    const char *desc;
    const char *cmds[3];   // nullptr-terminated (unused slots nullptr)
    uint16_t interCmdMs;   // spacing between the sequence's commands
    uint16_t settleMs;     // wait after the last command before measuring
};

static const GnssProbeCandidate kCandidates[] = {
    // Unit #1 refused these — a different GNSS firmware on a new unit may not.
    {"$PAIR050,250 (Airoha 4 Hz)", {"PAIR050,250", nullptr, nullptr}, 150, 600},
    {"$PAIR050,100 (Airoha 10 Hz — some fw only accept 100)", {"PAIR050,100", nullptr, nullptr}, 150, 600},
    // Some Airoha builds gate the fix rate behind the navigation mode — try fitness mode first.
    {"$PAIR080,1 fitness nav-mode + $PAIR050,250", {"PAIR080,1", "PAIR050,250", nullptr}, 250, 800},
    // MediaTek-family fallback (AG3335 cores answer PMTK on some vendor firmwares).
    {"$PMTK220,250 + $PMTK300,250 (MediaTek 4 Hz)", {"PMTK220,250", "PMTK300,250,0,0,0,0", nullptr}, 150, 600},
    // Engine-stop sandwich: some firmwares only latch a rate while the engine is stopped. Uses the
    // plain power off/on pair — NOT $PAIR382,1 (the VRTC backup-sleep brick from unit #1). Longer
    // settle so the hot restart re-acquires before we measure.
    {"engine-stop sandwich $PAIR003 > rate > $PAIR002", {"PAIR003", "PAIR050,250", "PAIR002"}, 400, 3000},
};
static const int8_t kNumCandidates = sizeof(kCandidates) / sizeof(kCandidates[0]);

GnssRateProbe gnssRateProbe;

void GnssRateProbe::sendCmd(Stream *serial, const char *body)
{
    uint8_t ck = 0;
    for (const char *c = body; *c; ++c)
        ck ^= (uint8_t)*c;
    char line[64];
    snprintf(line, sizeof(line), "$%s*%02X\r\n", body, ck);
    serial->write(line);
    LOG_INFO("GnssProbe: >> $%s*%02X", body, ck);
}

void GnssRateProbe::startWindow(TinyGPSPlus &reader, uint32_t nowMs)
{
    winStartMs = nowMs;
    sentAtStart = reader.passedChecksum();
    lastTimeVal = reader.time.value();
    fixEpochs = 0;
}

void GnssRateProbe::sampleFixEpochs(TinyGPSPlus &reader, uint32_t nowMs)
{
    (void)nowMs;
    // A fix epoch = the NMEA time-of-day (HHMMSSCC, centisecond resolution) moving. Works even
    // before a position lock, as soon as the module knows time.
    uint32_t tv = reader.time.value();
    if (tv != lastTimeVal) {
        lastTimeVal = tv;
        if (winStartMs != 0)
            fixEpochs++;
    }
}

float GnssRateProbe::windowFixHz(TinyGPSPlus &reader, uint32_t nowMs) const
{
    float winSec = (nowMs - winStartMs) / 1000.0f;
    if (winSec <= 0.5f)
        return 0;
    // Two estimators, take the larger: direct epoch counting is exact up to ~1/(2*tick) and can
    // only UNDER-count (tick jitter aliasing at 10 Hz); the sentence-rate estimate (calibrated at
    // the known 1 Hz baseline) is immune to tick aliasing but assumes the sentence mix is stable.
    float epochHz = fixEpochs / winSec;
    float sentHz = (reader.passedChecksum() - sentAtStart) / winSec;
    float sentEstHz = (sentPerFix > 0) ? (sentHz / sentPerFix) : 0;
    return (epochHz > sentEstHz) ? epochHz : sentEstHz;
}

void GnssRateProbe::tick(Stream *serial, TinyGPSPlus &reader)
{
    if (!serial)
        return;
    uint32_t nowMs = millis();
    sampleFixEpochs(reader, nowMs);

    switch (phase) {
    case WAIT_FLOW:
        if (nowMs < GNSSPROBE_BOOT_DELAY_MS || reader.passedChecksum() < 8)
            return;
        LOG_INFO("GnssProbe: NMEA flow up (%lu sentences) — measuring the as-shipped rate for %d s",
                 (unsigned long)reader.passedChecksum(), GNSSPROBE_BASE_WIN_MS / 1000);
        startWindow(reader, nowMs);
        phase = BASELINE;
        return;

    case BASELINE: {
        if (nowMs - winStartMs < GNSSPROBE_BASE_WIN_MS)
            return;
        float winSec = (nowMs - winStartMs) / 1000.0f;
        uint32_t sentDelta = reader.passedChecksum() - sentAtStart;
        baselineHz = fixEpochs / winSec;
        // Calibrate sentences-per-fix at the known-1 Hz baseline so later windows can estimate the
        // fix rate from the sentence rate (immune to tick-sampling aliasing at 10 Hz).
        sentPerFix = (fixEpochs > 0) ? ((float)sentDelta / fixEpochs) : ((float)sentDelta / winSec);
        if (sentPerFix < 1.0f)
            sentPerFix = 1.0f;
        LOG_INFO("GnssProbe: baseline %.2f fix/s, %.1f sentences/fix — walking %d candidates", baselineHz, sentPerFix,
                 (int)kNumCandidates);
        candidate = 0;
        cmdIdx = 0;
        nextActionMs = nowMs;
        phase = SEND;
        return;
    }

    case SEND: {
        const GnssProbeCandidate &c = kCandidates[candidate];
        if ((int32_t)(nowMs - nextActionMs) < 0)
            return;
        if (cmdIdx < 3 && c.cmds[cmdIdx]) {
            sendCmd(serial, c.cmds[cmdIdx]);
            cmdIdx++;
            nextActionMs = nowMs + c.interCmdMs;
            return; // one command per GPS-thread pass
        }
        phaseStartMs = nowMs;
        phase = SETTLE;
        return;
    }

    case SETTLE:
        if (nowMs - phaseStartMs < kCandidates[candidate].settleMs)
            return;
        startWindow(reader, nowMs);
        phase = MEASURE;
        return;

    case MEASURE: {
        if (nowMs - winStartMs < GNSSPROBE_WIN_MS)
            return;
        float hz = windowFixHz(reader, nowMs);
        LOG_INFO("GnssProbe: [%d/%d] %s -> %.2f fix/s", (int)candidate + 1, (int)kNumCandidates,
                 kCandidates[candidate].desc, hz);
        if (hz >= GNSSPROBE_SUCCESS_HZ) {
            winner = candidate;
            sagWindows = 0;
            LOG_INFO("GnssProbe: *** WINNER '%s' — GNSS raised to %.2f fix/s (>= %.1f). RAM-only setting; "
                     "it is re-applied automatically if the rate ever sags. ***",
                     kCandidates[winner].desc, hz, (double)GNSSPROBE_SUCCESS_HZ);
            startWindow(reader, nowMs);
            phase = RESIDENT;
            return;
        }
        candidate++;
        if (candidate >= kNumCandidates) {
            sendCmd(serial, "PAIR050,1000"); // restore the known-good default (harmless if ignored)
            LOG_WARN("GnssProbe: VERDICT — all %d candidates refused; this AG3335 stays at ~%.2f fix/s "
                     "(same lock as unit #1). Stream rides fix novelty; use client-side interpolation.",
                     (int)kNumCandidates, baselineHz);
            winner = -1;
            startWindow(reader, nowMs);
            phase = RESIDENT;
            return;
        }
        cmdIdx = 0;
        nextActionMs = nowMs;
        phase = SEND;
        return;
    }

    case RESIDENT: {
        if (nowMs - winStartMs < GNSSPROBE_RESIDENT_WIN_MS)
            return;
        float hz = windowFixHz(reader, nowMs);
        LOG_INFO("GnssProbe: GNSS rate %.2f fix/s%s", hz, (winner >= 0) ? " (raised)" : "");
        if (winner >= 0) {
            if (hz < GNSSPROBE_SUCCESS_HZ * 0.6f) {
                // Two sagged windows + cooldown -> re-send the winning sequence (a GPS power event
                // would reset the RAM-only rate). Re-enters SEND/MEASURE, so if the winner stopped
                // working the remaining candidates get another chance too.
                if (++sagWindows >= 2 && (nowMs - lastReapplyMs) > GNSSPROBE_REAPPLY_COOLDOWN_MS) {
                    LOG_WARN("GnssProbe: rate sagged to %.2f fix/s — re-applying '%s'", hz, kCandidates[winner].desc);
                    candidate = winner;
                    cmdIdx = 0;
                    nextActionMs = nowMs;
                    lastReapplyMs = nowMs;
                    sagWindows = 0;
                    phase = SEND;
                    return;
                }
            } else {
                sagWindows = 0;
            }
        }
        startWindow(reader, nowMs);
        return;
    }
    }
}

#endif // GPS_TAG
