#include "configuration.h"

#if defined(GPS_TAG) || defined(ODID_SNIFFER)
#include "TagRadioState.h"
#include "NodeDB.h" // config.lora.override_duty_cycle
#include "gps/GnssTagSettings.h"
#include "mesh/MeshRadio.h"         // myRegion->dutyCycle
#include "mesh/RadioLibInterface.h" // instance / isSending / startReceive

extern RadioInterface *rIf; // main.cpp global — airtime source for the duty floor

TagRadioState *tagRadioState;
volatile bool g_tagRadioMuteNow = false;

// Mute-grace after a GO-DEAF ACK: RX stays alive this long so a retry sent because OUR ACK was
// lost still lands (and re-ACKs). The app's retry budget is ~5 x 0.3 s, well inside the window.
static const uint32_t kMuteGraceMs = 2000;

// Duty floor cache: -1 = not computable yet (radio/region not up). Region/preset changes reboot
// the node (Meshtastic config semantics), so one boot-time computation covers revalidation.
static int32_t sDutyFloorMs = -1;

uint32_t tagRadioDutyFloorMs()
{
    if (sDutyFloorMs >= 0)
        return (uint32_t)sDutyFloorMs;
    if (!rIf || !myRegion)
        return 0; // unknown yet — callers treat as "no floor"; recomputed next call
    if (config.lora.override_duty_cycle || myRegion->dutyCycle >= 100.0f) {
        sDutyFloorMs = 0; // bench override (hazard: bench-only!) or unrestricted region
        return 0;
    }
    // Airtime of one stream packet: 16-byte mesh header + 20-byte v5 payload + ~8 bytes of Data
    // protobuf framing = 44 bytes on air (docs/CAPACITY.md symbol-group boundary). Sustained
    // legality: spacing >= airtime * 100 / duty%.
    uint32_t airMs = rIf->getPacketTime(44);
    if (airMs == 0)
        return 0;
    sDutyFloorMs = (int32_t)((airMs * 100.0f) / myRegion->dutyCycle + 0.5f);
    LOG_INFO("TagRadio: duty floor %ld ms (air %lu ms, duty %d%%)", (long)sDutyFloorMs, (unsigned long)airMs,
             (int)myRegion->dutyCycle);
    return (uint32_t)sDutyFloorMs;
}

TagRadioState::TagRadioState() : OSThread("TagRadioState")
{
    setInterval(60 * 1000); // idle; requestState arms fast ticks while a grace window runs
}

void TagRadioState::initFromProfile()
{
    // PERMANENT·DEAF boots muted from the radio's very first startReceive() — no grace at boot
    // (there is no ACK to protect; the profile IS the consent). HYBRID always boots LISTENING.
    if ((gnssTagSettings.profileBits & TAG_PROFILE_PERMANENT) &&
        (gnssTagSettings.profileBits & TAG_PROFILE_PERM_DEAF)) {
        g_tagRadioMuteNow = true;
        LOG_INFO("TagRadio: PERMANENT profile boots DEAF");
    }
}

void TagRadioState::kickRadio()
{
    // Make the radio re-evaluate g_tagRadioMuteNow now: startReceive() lands in STANDBY when
    // muted, stock RX otherwise. Mid-TX we skip — the TX-done path calls startReceive() itself.
    if (RadioLibInterface::instance && !RadioLibInterface::instance->isSending())
        RadioLibInterface::instance->startReceive();
}

uint8_t TagRadioState::requestState(uint8_t state)
{
    if (state != LISTENING && state != DEAF)
        return 1;

    // PERMANENT closure rule (RADIO_STATES §3): a radio-state command REWRITES the persisted
    // profile — there are no temporary states. Persist FIRST: if flash fails we NAK rather than
    // create a runtime state the next boot would contradict.
    if (gnssTagSettings.profileBits & TAG_PROFILE_PERMANENT) {
        uint8_t bits = TAG_PROFILE_PERMANENT | (state == DEAF ? TAG_PROFILE_PERM_DEAF : 0);
        if (!gnssTagSettingsSaveProfile(bits))
            return 1;
    }

    if (state == DEAF) {
        if (g_tagRadioMuteNow)
            return 0; // already deaf — idempotent re-ACK (BLE/USB path; LoRa can't reach us here)
        // ACK-before-mute: the caller sends the ACK right after this returns; RX survives the
        // grace so a lost-ACK retry still lands. A duplicate inside the grace re-arms it.
        deafPending = true;
        muteAtMs = millis() + kMuteGraceMs;
        setIntervalFromNow(50);
        LOG_INFO("TagRadio: GO-DEAF committed — mute in %lu ms (grace)", (unsigned long)kMuteGraceMs);
    } else {
        bool wasDeaf = g_tagRadioMuteNow || deafPending;
        deafPending = false;
        muteAtMs = 0;
        g_tagRadioMuteNow = false;
        if (wasDeaf) {
            kickRadio();
            LOG_INFO("TagRadio: LISTENING restored");
        }
    }
    return 0;
}

void TagRadioState::applyProfileSideEffects()
{
    if (!(gnssTagSettings.profileBits & TAG_PROFILE_PERMANENT)) {
        // HYBRID profile SET: runtime radio state is untouched (deafness, if any, stays until
        // reboot or an explicit RADIO command — the profile only governs BOOT behavior).
        return;
    }
    requestState((gnssTagSettings.profileBits & TAG_PROFILE_PERM_DEAF) ? DEAF : LISTENING);
}

uint8_t TagRadioState::statusByte()
{
    uint8_t s = 0;
    if (deafCommitted())
        s |= 0x01;
    if (gnssTagSettings.profileBits & TAG_PROFILE_PERMANENT)
        s |= 0x02;
    uint32_t floorMs = tagRadioDutyFloorMs();
    if (floorMs && ((uint32_t)gnssTagSettings.txSpacingMs < floorMs || (uint32_t)gnssTagSettings.idleSpacingMs < floorMs))
        s |= 0x04; // duty-degraded: a persisted spacing is being clamped (boot/region revalidation)
    return s;
}

uint32_t TagRadioState::effectiveSpacingMs(uint32_t configuredMs)
{
    uint32_t floorMs = tagRadioDutyFloorMs();
    if (!floorMs || configuredMs >= floorMs)
        return configuredMs;
    if (!degradedLogged) {
        degradedLogged = true;
        LOG_WARN("TagRadio: configured spacing %lu ms below duty floor %lu ms — CLAMPED (profile degraded)",
                 (unsigned long)configuredMs, (unsigned long)floorMs);
    }
    return floorMs;
}

int32_t TagRadioState::runOnce()
{
    if (deafPending) {
        int32_t left = (int32_t)(muteAtMs - millis());
        if (left > 0)
            return left < 50 ? left : 50;
        deafPending = false;
        g_tagRadioMuteNow = true;
        kickRadio();
        LOG_INFO("TagRadio: grace elapsed — radio MUTED (DEAF)");
    }
    return 60 * 1000;
}

#endif // GPS_TAG || ODID_SNIFFER
