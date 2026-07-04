#include "configuration.h"

#ifdef GPS_TAG
#include "GnssRateProbe.h"
#include "TinyGPS++.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Success = a sustained fix cadence at/above this. The dance sets 100 ms (10 Hz) — the only >1 Hz
// value this firmware lineage accepts — so a win reads ~10. LoRa TX is separately paced by
// HIGHRATE_MIN_SPACING_MS.
#ifndef GNSSPROBE_SUCCESS_HZ
#define GNSSPROBE_SUCCESS_HZ 3.5f
#endif

#define GNSSPROBE_BOOT_DELAY_MS 15000
#define GNSSPROBE_BASE_WIN_MS 5000
#define GNSSPROBE_CHAR_WIN_MS 3000
#define GNSSPROBE_WIN_MS 4000
#define GNSSPROBE_RESIDENT_WIN_MS 10000
#define GNSSPROBE_SILENT_MS 6000            // no UART bytes for this long during apply = rescue
#define GNSSPROBE_REAPPLY_COOLDOWN_MS 60000 // min gap between resident re-dances

GnssRateProbe gnssRateProbe;

// ---------------------------------------------------------------- raw UART tap

void GnssRateProbe::feedByte(int c)
{
    lastByteMs = millis();
    if (c == '\r' || c == '\n') {
        if (lineLen >= 6 && lineBuf[0] == '$' && lineBuf[1] == 'P') { // $PAIR / $PMTK traffic only
            lineBuf[lineLen] = 0;
            if (tapLogBudget) {
                tapLogBudget--;
                LOG_INFO("GnssProbe: << %s", lineBuf); // verbatim module response — the evidence
            }
            if (!strncmp(lineBuf, "$PAIR001,", 9)) {
                ackCmd = (uint16_t)atoi(lineBuf + 9);
                const char *comma = strchr(lineBuf + 9, ',');
                ackCode = comma ? (int8_t)atoi(comma + 1) : -1;
            }
        }
        lineLen = 0;
        return;
    }
    if (lineLen < sizeof(lineBuf) - 1)
        lineBuf[lineLen++] = (char)c;
    else
        lineLen = 0; // oversized line: drop
}

// ---------------------------------------------------------------- helpers

void GnssRateProbe::sendCmd(Stream *serial, const char *body, bool quiet)
{
    uint8_t ck = 0;
    for (const char *c = body; *c; ++c)
        ck ^= (uint8_t)*c;
    char line[64];
    snprintf(line, sizeof(line), "$%s*%02X\r\n", body, ck);
    serial->write(line);
    if (!quiet)
        LOG_INFO("GnssProbe: >> $%s*%02X", body, ck);
}

void GnssRateProbe::startWindow(TinyGPSPlus &reader, uint32_t nowMs)
{
    winStartMs = nowMs;
    sentAtStart = reader.passedChecksum();
    lastTimeVal = reader.time.value();
    fixEpochs = 0;
    tapLogBudget = 30;
}

void GnssRateProbe::sampleFixEpochs(TinyGPSPlus &reader, uint32_t nowMs)
{
    (void)nowMs;
    uint32_t tv = reader.time.value(); // HHMMSSCC — moves once per fix epoch, lock not required
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
    // Larger of direct epoch counting (can only under-count from tick aliasing) and the
    // sentence-rate estimate calibrated at the 1 Hz baseline (alias-immune).
    float epochHz = fixEpochs / winSec;
    float sentHz = (reader.passedChecksum() - sentAtStart) / winSec;
    float sentEstHz = (sentPerFix > 0) ? (sentHz / sentPerFix) : 0;
    return (epochHz > sentEstHz) ? epochHz : sentEstHz;
}

void GnssRateProbe::startMeasure(TinyGPSPlus &reader, uint32_t nowMs, uint8_t ctx)
{
    measureCtx = ctx;
    startWindow(reader, nowMs);
    phase = MEASURE;
}

void GnssRateProbe::hwReset()
{
#ifdef PIN_GPS_RESET
    LOG_WARN("GnssProbe: hardware reset pulse (applying the saved fix rate)");
    pinMode(PIN_GPS_RESET, OUTPUT);
    digitalWrite(PIN_GPS_RESET, GPS_RESET_MODE);
    delay(60);
    digitalWrite(PIN_GPS_RESET, !GPS_RESET_MODE);
#else
    LOG_WARN("GnssProbe: PIN_GPS_RESET not defined — cannot hardware-reset");
#endif
}

void GnssRateProbe::rtcIntRescue()
{
    LOG_WARN("GnssProbe: module silent — GPS_RTC_INT wake pulse + reset (rescue %u)", (unsigned)(rescues + 1));
#ifdef GPS_RTC_INT
    pinMode(GPS_RTC_INT, OUTPUT);
    digitalWrite(GPS_RTC_INT, HIGH);
    delay(300);
#endif
    hwReset();
#ifdef GPS_RTC_INT
    delay(300);
    digitalWrite(GPS_RTC_INT, LOW);
#endif
}

// ---------------------------------------------------------------- sequence engine

void GnssRateProbe::startSeq(const Step *steps, uint8_t count, Phase runPhase)
{
    seq = steps;
    seqLen = count;
    seqIdx = 0;
    seqTry = 0;
    seqWaitingAck = false;
    seqFailed = false;
    phase = runPhase;
    nextActionMs = 0;
}

bool GnssRateProbe::runSeq(Stream *serial, uint32_t nowMs)
{
    if (!seq)
        return false;
    if (seqIdx >= seqLen) {
        seq = nullptr;
        return false;
    }
    const Step &st = seq[seqIdx];
    if ((int32_t)(nowMs - nextActionMs) < 0)
        return true;

    if (!seqWaitingAck) {
        sendCmd(serial, st.body);
        seqTry++;
        if (st.ackId == 0) { // fire and forget
            seqIdx++;
            seqTry = 0;
            nextActionMs = nowMs + st.postMs;
            return true;
        }
        ackCmd = 0xFFFF; // arm the ACK latch
        ackCode = -1;
        seqWaitingAck = true;
        seqDeadline = nowMs + st.timeoutMs;
        return true;
    }

    if (ackCmd == st.ackId) {
        if (ackCode == 1) { // "in process" — keep waiting for the final code
            ackCmd = 0xFFFF;
            seqDeadline = nowMs + st.timeoutMs;
            return true;
        }
        LOG_INFO("GnssProbe: '%s' -> ACK code %d%s", st.body, ackCode,
                 ackCode == 0   ? " (ok)"
                 : ackCode == 3 ? " (UNSUPPORTED)"
                 : ackCode == 4 ? " (param error)"
                 : ackCode == 5 ? " (busy)"
                                : "");
        // Evidence capture for the verdict
        if (!strcmp(st.body, "PAIR050,250"))
            ack250 = ackCode;
        else if (!strcmp(st.body, "PAIR050,100"))
            (phase == DANCE ? danceAck050 : ack100) = ackCode;
        else if (!strcmp(st.body, "PAIR513") && ackCode == 0 && !restoring)
            danceSaved = true;

        seqWaitingAck = false;
        if (ackCode == 0) {
            seqIdx++;
            seqTry = 0;
            nextActionMs = nowMs + st.postMs;
            return true;
        }
        if (seqTry >= st.tries) {
            if (st.abortOnFail) {
                seqFailed = true;
                seq = nullptr;
                return false;
            }
            seqIdx++;
            seqTry = 0;
        }
        nextActionMs = nowMs + 250;
        return true;
    }

    if ((int32_t)(nowMs - seqDeadline) >= 0) { // ACK timeout
        LOG_WARN("GnssProbe: '%s' -> NO ACK (try %u/%u)", st.body, (unsigned)seqTry, (unsigned)st.tries);
        seqWaitingAck = false;
        if (seqTry >= st.tries) {
            if (st.abortOnFail) {
                seqFailed = true;
                seq = nullptr;
                return false;
            }
            seqIdx++;
            seqTry = 0;
        }
        nextActionMs = nowMs + 250;
    }
    return true;
}

// ---------------------------------------------------------------- verdicts

void GnssRateProbe::winner(const char *how, float hz)
{
    raised = true;
    sagWindows = 0;
    LOG_INFO("GnssProbe: *** WINNER (%s) — GNSS running at %.2f fix/s%s ***", how, hz,
             danceSaved ? "; rate SAVED to flash (persists across power cycles)" : " (RAM only)");
}

void GnssRateProbe::finalVerdict(float hz)
{
    LOG_WARN("GnssProbe: VERDICT — still ~%.2f fix/s. Evidence: PAIR050,250 ack=%d; PAIR050,100 ack=%d (RAM) / %d "
             "(in dance); 513 save=%d. Codes: -100 none, 0 ok, 3 unsupported, 4 param error.",
             hz, ack250, ack100, danceAck050, (int)danceSaved);
    LOG_WARN("GnssProbe: echo test %s; rescues=%u", echoPositive ? "POSITIVE (mute but commands execute)" : "negative/not run",
             (unsigned)rescues);
    if (ack250 == -100 && ack100 == -100 && danceAck050 == -100) {
        LOG_WARN("GnssProbe: no $PAIR001 ever seen for PAIR050 -> command REMOVED from this firmware "
                 "(CSA2-like lineage). UART cannot unlock it; a GNSS firmware update is the only path.");
    } else if (danceAck050 == 0 || ack100 == 0) {
        LOG_WARN("GnssProbe: PAIR050,100 was ACCEPTED but never took effect -> lineage quirk beyond the "
                 "documented reboot rule; capture this log for docs/gnss/UNLOCK_NOTES.md.");
    }
}

// ---------------------------------------------------------------- main state machine

void GnssRateProbe::tick(Stream *serial, TinyGPSPlus &reader)
{
    if (!serial)
        return;
    uint32_t nowMs = millis();
    sampleFixEpochs(reader, nowMs);

    // A running command sequence owns the tick.
    if (seq) {
        if (runSeq(serial, nowMs))
            return;
        onSeqDone(reader, nowMs);
        return;
    }

    switch (phase) {
    case WAIT_FLOW: {
        // Start at the FIRST sign of NMEA flow — the command CPU auto-sleeps a few seconds after
        // boot (the historical "no ACK" artifact), so every second matters. The $PAIR382,1 sleep
        // lock is the opening move: if even one lands while the CPU is awake, the interface stays
        // alive for the whole session (Seeed's driver does exactly this, 25x blind).
        if (reader.passedChecksum() < 2)
            return;
        LOG_INFO("GnssProbe v2: NMEA up at %lums — latching $PAIR382,1 sleep lock + identity queries",
                 (unsigned long)nowMs);
        static const Step kWakeIdent[] = {
            {"PAIR382,1", 382, 700, 6, false, 150}, // keep-awake latch: ACK here = interface alive
            {"PAIR021", 0, 0, 1, false, 1200},      // full version string — logged verbatim by the tap
            {"PAIR051", 0, 0, 1, false, 1200},      // current fix interval — reply logged by the tap
        };
        startSeq(kWakeIdent, 3, IDENT);
        return;
    }

    case IDENT: // only reached if seq ended without transition (defensive)
        startWindow(reader, nowMs);
        phase = BASELINE;
        return;

    case BASELINE: {
        if (winStartMs == 0) {
            startWindow(reader, nowMs);
            return;
        }
        if (nowMs - winStartMs < GNSSPROBE_BASE_WIN_MS)
            return;
        float winSec = (nowMs - winStartMs) / 1000.0f;
        uint32_t sentDelta = reader.passedChecksum() - sentAtStart;
        baselineHz = fixEpochs / winSec;
        sentPerFix = (fixEpochs > 0) ? ((float)sentDelta / fixEpochs) : ((float)sentDelta / winSec);
        if (sentPerFix < 1.0f)
            sentPerFix = 1.0f;
        LOG_INFO("GnssProbe: baseline %.2f fix/s, %.1f sentences/fix", baselineHz, sentPerFix);
        if (baselineHz >= GNSSPROBE_SUCCESS_HZ) {
            winner("already raised — saved rate persisted from a previous run", baselineHz);
            startWindow(reader, nowMs);
            phase = RESIDENT;
            return;
        }
        // Characterize the RAM-set path first: exact ACK codes for 250 vs 100.
        static const Step kChar[] = {
            {"PAIR050,250", 50, 1500, 1, false, 400},
            {"PAIR050,100", 50, 1500, 1, false, 400},
        };
        startSeq(kChar, 2, CHAR_RAM);
        return;
    }

    case APPLY_WAIT: // plain wait after a hardware reset (no seq running)
        if ((int32_t)(nowMs - nextActionMs) < 0) {
            if (nowMs - lastByteMs > GNSSPROBE_SILENT_MS && rescues < 2) {
                rtcIntRescue();
                rescues++;
                nextActionMs = nowMs + 3500;
            }
            return;
        }
        startMeasure(reader, nowMs, CTX_RESET);
        return;

    case MEASURE: {
        // Rescue a module that went deaf mid-apply (the historical failure mode).
        if (measureCtx != CTX_CHAR && nowMs - lastByteMs > GNSSPROBE_SILENT_MS) {
            if (rescues < 2) {
                rtcIntRescue();
                rescues++;
                startWindow(reader, nowMs); // restart the window after the rescue
                return;
            }
            LOG_WARN("GnssProbe: module stayed silent after 2 rescues — giving up this cycle");
            finalVerdict(0);
            startWindow(reader, nowMs);
            phase = RESIDENT;
            return;
        }
        uint32_t winMs = (measureCtx == CTX_CHAR) ? GNSSPROBE_CHAR_WIN_MS : GNSSPROBE_WIN_MS;
        if (nowMs - winStartMs < winMs)
            return;
        float hz = windowFixHz(reader, nowMs);

        switch (measureCtx) {
        case CTX_CHAR: {
            LOG_INFO("GnssProbe: RAM-set immediate effect: %.2f fix/s (ack 250=%d, 100=%d)", hz, ack250, ack100);
            if (hz >= GNSSPROBE_SUCCESS_HZ) {
                winner("RAM set took effect immediately", hz);
                startWindow(reader, nowMs);
                phase = RESIDENT;
                return;
            }
            if (ack250 == -100 && ack100 == -100) {
                // Nothing ACKs post-boot. Discriminate DEAF (commands unheard) from MUTE (commands
                // execute, ACK generation disabled): turn GSV back on and watch the sentence mix.
                LOG_INFO("GnssProbe: zero ACKs — echo test: $PAIR062,3,1 (GSV ON), watching the sentence mix");
                static const Step kEchoOn[] = {{"PAIR062,3,1", 0, 0, 1, false, 400}};
                startSeq(kEchoOn, 1, ECHO_TEST);
                return;
            }
            LOG_INFO("GnssProbe: starting the ACK-gated dance: 382,1 -> 003 -> 050,100 -> 513 -> 002");
            static const Step kDance[] = {
                {"PAIR382,1", 382, 1500, 3, true, 150}, // keep-alive latch — ABORT if never ACKed
                {"PAIR003", 3, 1500, 2, false, 400},    // engine off (commands stay alive via the latch)
                {"PAIR050,100", 50, 1500, 2, false, 150},
                {"PAIR513", 513, 2000, 2, false, 300},  // save — only valid while powered off
                {"PAIR002", 2, 2500, 2, false, 1200},   // engine back on
            };
            danceRan = true;
            startSeq(kDance, 5, DANCE);
            return;
        }
        case CTX_DANCE:
            if (hz >= GNSSPROBE_SUCCESS_HZ) {
                winner("dance applied without reboot", hz);
                startWindow(reader, nowMs);
                phase = RESIDENT;
                return;
            }
            LOG_INFO("GnssProbe: post-dance still %.2f fix/s — trying $PAIR004 hot start (reboot-to-apply)", hz);
            {
                static const Step kHot[] = {{"PAIR004", 4, 2500, 1, false, 2500}};
                startSeq(kHot, 1, APPLY_WAIT);
            }
            return;
        case CTX_HOT:
            if (hz >= GNSSPROBE_SUCCESS_HZ) {
                winner("applied after $PAIR004 hot start", hz);
                startWindow(reader, nowMs);
                phase = RESIDENT;
                return;
            }
            LOG_INFO("GnssProbe: hot start didn't apply it (%.2f fix/s) — escalating to hardware reset", hz);
            hwReset();
            phase = APPLY_WAIT;
            nextActionMs = nowMs + 3500;
            return;
        case CTX_RESET:
            if (hz >= GNSSPROBE_SUCCESS_HZ) {
                winner("applied after hardware reset", hz);
                startWindow(reader, nowMs);
                phase = RESIDENT;
                return;
            }
            if (danceSaved) {
                LOG_WARN("GnssProbe: saved rate never took effect — restoring 1000 ms so the module is "
                         "left in a clean state");
                static const Step kRestore[] = {
                    {"PAIR382,1", 382, 1500, 2, false, 150},
                    {"PAIR003", 3, 1500, 1, false, 400},
                    {"PAIR050,1000", 50, 1500, 1, false, 150},
                    {"PAIR513", 513, 2000, 1, false, 300},
                    {"PAIR002", 2, 2500, 1, false, 1000},
                    {"PAIR004", 0, 0, 1, false, 1500},
                };
                restoring = true;
                startSeq(kRestore, 6, RESTORE);
                return;
            }
            finalVerdict(hz);
            startWindow(reader, nowMs);
            phase = RESIDENT;
            return;
        case CTX_ECHO: {
            float sentHz = (reader.passedChecksum() - sentAtStart) / ((nowMs - winStartMs) / 1000.0f);
            echoPositive = sentHz >= 3.2f; // GSV adds several sentences per fix epoch vs the 2.0 baseline
            LOG_INFO("GnssProbe: echo test %s — %.1f sent/s (baseline ~2.0)",
                     echoPositive ? "POSITIVE: commands EXECUTE, ACKs are just disabled" : "NEGATIVE: module deaf to late commands",
                     sentHz);
            sendCmd(serial, "PAIR062,3,0"); // restore GSV off either way
            if (echoPositive) {
                LOG_INFO("GnssProbe: running the dance BLIND (Seeed-style repeats, no ACK gating)");
                static const Step kBlind[] = {
                    {"PAIR382,1", 0, 0, 1, false, 80},  {"PAIR382,1", 0, 0, 1, false, 80},
                    {"PAIR382,1", 0, 0, 1, false, 80},  {"PAIR382,1", 0, 0, 1, false, 80},
                    {"PAIR382,1", 0, 0, 1, false, 80},  {"PAIR382,1", 0, 0, 1, false, 120},
                    {"PAIR003", 0, 0, 1, false, 250},   {"PAIR003", 0, 0, 1, false, 250},
                    {"PAIR003", 0, 0, 1, false, 350},
                    {"PAIR050,100", 0, 0, 1, false, 150}, {"PAIR050,100", 0, 0, 1, false, 150},
                    {"PAIR050,100", 0, 0, 1, false, 200},
                    {"PAIR513", 0, 0, 1, false, 250},   {"PAIR513", 0, 0, 1, false, 250},
                    {"PAIR513", 0, 0, 1, false, 350},
                    {"PAIR002", 0, 0, 1, false, 600},   {"PAIR002", 0, 0, 1, false, 600},
                    {"PAIR002", 0, 0, 1, false, 1200},
                };
                danceRan = true;
                danceSaved = true; // blind: assume the save landed so the failure path restores 1000 ms
                startSeq(kBlind, sizeof(kBlind) / sizeof(kBlind[0]), DANCE);
                return;
            }
            LOG_INFO("GnssProbe: escalating — hardware reset, then latch-spam inside the module's boot window");
            hwReset();
            resetMs = nowMs;
            latchSends = 0;
            ackCmd = 0xFFFF;
            phase = RESETLATCH;
            nextActionMs = nowMs + 400;
            return;
        }
        case CTX_RESTORE:
        default:
            LOG_INFO("GnssProbe: post-restore rate %.2f fix/s", hz);
            restoring = false;
            finalVerdict(hz);
            startWindow(reader, nowMs);
            phase = RESIDENT;
            return;
        }
    }

    case RESETLATCH: {
        if ((int32_t)(nowMs - nextActionMs) < 0)
            return;
        if (ackCmd == 382 && ackCode == 0) {
            LOG_INFO("GnssProbe: *** $PAIR382,1 ACKed %lums after reset — command window FOUND; gated dance now ***",
                     (unsigned long)(nowMs - resetMs));
            static const Step kDanceW[] = {
                {"PAIR382,1", 382, 1500, 3, true, 150},
                {"PAIR003", 3, 1500, 2, false, 400},
                {"PAIR050,100", 50, 1500, 2, false, 150},
                {"PAIR513", 513, 2000, 2, false, 300},
                {"PAIR002", 2, 2500, 2, false, 1200},
            };
            danceRan = true;
            startSeq(kDanceW, 5, DANCE);
            return;
        }
        if (nowMs - resetMs > 5000 && rescues == 0) {
            rtcIntRescue(); // maybe the wake pin, not RESET, opens the window
            rescues++;
            resetMs = nowMs;
            latchSends = 0;
            nextActionMs = nowMs + 400;
            return;
        }
        if (nowMs - resetMs > 8000) {
            LOG_WARN("GnssProbe: latch never ACKed even straight after reset — interface is mute AND deaf post-boot");
            finalVerdict(windowFixHz(reader, nowMs));
            startWindow(reader, nowMs);
            phase = RESIDENT;
            return;
        }
        sendCmd(serial, "PAIR382,1", true); // quiet spam — one send per tick
        latchSends++;
        if ((latchSends % 8) == 0)
            LOG_INFO("GnssProbe: latch spam x%u (t+%lums after reset)", (unsigned)latchSends,
                     (unsigned long)(nowMs - resetMs));
        nextActionMs = nowMs + 120;
        return;
    }

    case RESIDENT: {
        if (nowMs - winStartMs < GNSSPROBE_RESIDENT_WIN_MS)
            return;
        float hz = windowFixHz(reader, nowMs);
        float sentHz = (reader.passedChecksum() - sentAtStart) / ((nowMs - winStartMs) / 1000.0f);
        LOG_INFO("GnssProbe: GNSS rate %.2f fix/s (%.1f sent/s)%s", hz, sentHz, raised ? " (raised)" : "");
        if (raised && hz < GNSSPROBE_SUCCESS_HZ * 0.6f) {
            if (++sagWindows >= 2 && (nowMs - lastReapplyMs) > GNSSPROBE_REAPPLY_COOLDOWN_MS && rescues < 2) {
                LOG_WARN("GnssProbe: raised rate sagged to %.2f fix/s — re-running the dance", hz);
                lastReapplyMs = nowMs;
                sagWindows = 0;
                static const Step kDance2[] = {
                    {"PAIR382,1", 382, 1500, 3, true, 150},
                    {"PAIR003", 3, 1500, 2, false, 400},
                    {"PAIR050,100", 50, 1500, 2, false, 150},
                    {"PAIR513", 513, 2000, 2, false, 300},
                    {"PAIR002", 2, 2500, 2, false, 1200},
                };
                startSeq(kDance2, 5, DANCE);
                return;
            }
        } else {
            sagWindows = 0;
        }
        startWindow(reader, nowMs);
        return;
    }

    default:
        return;
    }
}

void GnssRateProbe::onSeqDone(TinyGPSPlus &reader, uint32_t nowMs)
{
    switch (phase) {
    case IDENT:
        startWindow(reader, nowMs);
        phase = BASELINE;
        return;
    case CHAR_RAM:
        startMeasure(reader, nowMs, CTX_CHAR);
        return;
    case DANCE:
        if (seqFailed) {
            LOG_WARN("GnssProbe: $PAIR382,1 latch never ACKed — DANCE ABORTED before $PAIR003 (protects "
                     "against the deaf-module state). This firmware likely filters PAIR commands.");
            finalVerdict(windowFixHz(reader, nowMs));
            startWindow(reader, nowMs);
            phase = RESIDENT;
            return;
        }
        startMeasure(reader, nowMs, CTX_DANCE);
        return;
    case APPLY_WAIT: // hot-start sequence finished
        startMeasure(reader, nowMs, CTX_HOT);
        return;
    case ECHO_TEST:
        startMeasure(reader, nowMs, CTX_ECHO);
        return;
    case RESTORE:
        startMeasure(reader, nowMs, CTX_RESTORE);
        return;
    default:
        startWindow(reader, nowMs);
        phase = RESIDENT;
        return;
    }
}

#endif // GPS_TAG
