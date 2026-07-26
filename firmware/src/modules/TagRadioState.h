#pragma once
#include "configuration.h"

#if defined(GPS_TAG) || defined(ODID_SNIFFER)
#include "concurrency/OSThread.h"
#include <Arduino.h>

/**
 * TagRadioState — A4 radio states (docs/RADIO_STATES.md), ONE generic module compiled into both
 * tag flavors. "TX-only" stopped being a build flag (-DHIGHRATE_TX_ONLY, retired) and became a
 * runtime radio state:
 *
 *   LISTENING — LoRa RX between transmissions: portnum-260 commands work at range.
 *   DEAF      — radio idles in STANDBY between TX (uA vs RX mA, and a foreign RX-in-progress can
 *               never defer our TX). LoRa-unreachable; BLE/USB commands still work (phone-injected
 *               packets are delivered locally and never touch the radio).
 *
 * Profiles (persisted, GnssTagSettings v4 profileBits):
 *   HYBRID (default)  — boot ALWAYS lands in LISTENING; deafness is runtime-only, NEVER persists.
 *   PERMANENT         — boots straight into its fixed radio state; a RADIO command REWRITES the
 *                       persisted bits (no temporary states — RADIO_STATES §3 closure rules).
 *
 * GO-DEAF discipline (§4, two-layer confirmation): the correlated ACK goes out FIRST, then a
 * ~2 s mute-grace holds RX so lost-ACK retries still land (duplicates re-ACK and extend the
 * grace); only then does the radio mute. The stream's v5 status byte reports DEAF from the ACK
 * moment — even if every ACK is lost, the next stream packet proves the transition.
 *
 * Duty legality (§3): tagRadioDutyFloorMs() derives the minimum sustained TX spacing from the
 * configured region's duty-cycle % and the measured 20-byte-payload airtime. Live SETs below the
 * floor are rejected (GnssTagSettings); values persisted BEFORE a region change are clamped at
 * use via effectiveSpacingMs() and flagged "degraded" in the status byte — the tag never
 * silently transmits illegally. lora.override_duty_cycle (bench-only) disables the floor.
 */

/// THE radio-facing switch, read by LR11x0Interface::startReceive() (vendor patch): true = idle
/// in STANDBY (deaf NOW — grace elapsed or PERMANENT·DEAF boot), false = stock RX.
extern volatile bool g_tagRadioMuteNow;

/// Region duty-cycle floor for the sustained TX spacing, ms. 0 = no limit (region without duty
/// restriction, bench override, or radio/region not up yet).
uint32_t tagRadioDutyFloorMs();

class TagRadioState : private concurrency::OSThread
{
  public:
    static constexpr uint8_t LISTENING = 0;
    static constexpr uint8_t DEAF = 1;

    TagRadioState();

    /// Call BEFORE radio init (Modules.cpp, right after gnssTagSettingsLoad): a PERMANENT·DEAF
    /// profile must mute the radio from its very first startReceive().
    static void initFromProfile();

    /// RADIO op (260/0x06) semantics. Returns the ACK status: 0 = ok (including idempotent
    /// duplicates — the caller ACKs BEFORE any mute happens), 1 = rejected. In PERMANENT the
    /// persisted profile is rewritten (RADIO_STATES §3); in HYBRID the transition is runtime-only.
    uint8_t requestState(uint8_t state);

    /// After a successful settings SET: a PERMANENT profile forces its persisted radio state
    /// (with the same ACK-first + grace discipline when that means going deaf). HYBRID leaves
    /// the runtime state untouched.
    void applyProfileSideEffects();

    /// True from the moment a GO-DEAF is ACKed (grace may still be running) — this is what the
    /// stream status byte and settings replies report, closing the lost-ACK race.
    bool deafCommitted() const { return deafPending || g_tagRadioMuteNow; }

    /// Status byte, shared by payload v5 byte 19 and settings-reply byte 17:
    /// bit0 = DEAF (committed), bit1 = PERMANENT profile, bit2 = duty-degraded (a persisted
    /// spacing is being clamped to the region floor). Bits 3-7 reserved, 0.
    uint8_t statusByte();

    /// Clamp a configured spacing to the region duty floor (0 floor = passthrough). Logs once
    /// when a clamp first engages (the boot/region-change revalidation evidence).
    uint32_t effectiveSpacingMs(uint32_t configuredMs);

  protected:
    int32_t runOnce() override;

  private:
    void kickRadio(); // make LR11x0 re-evaluate g_tagRadioMuteNow (unless a TX is in flight)

    bool deafPending = false; // GO-DEAF ACKed, mute-grace running
    uint32_t muteAtMs = 0;    // grace deadline while deafPending
    bool degradedLogged = false;
};

extern TagRadioState *tagRadioState;

#endif // GPS_TAG || ODID_SNIFFER
