#include "configuration.h"

#if defined(GPS_TAG) || defined(ODID_SNIFFER)
#include "GnssTagSettings.h"
#include "FSCommon.h"
#include "modules/TagRadioState.h" // tagRadioDutyFloorMs(): region duty-cycle floor for live SETs

GnssTagSettings gnssTagSettings;
#ifdef GPS_TAG
GnssTagMode gnssTagMode; // runtime-only; deliberately NOT part of the persisted file
#endif

static const char *kPath = "/prefs/gnsstag.dat";

// On-disk layout: [magic][version][wire payload] — v1 = 7-byte wire, v2 adds elevMaskDeg (8),
// v3 adds the adaptive knobs (13), v4 adds the profile byte (14).
static const uint8_t kMagicByte = 0xA7;
static const uint8_t kVersion = 4;

static bool validNavMode(uint8_t m)
{
    return m == 0 || m == 1 || m == 4 || m == 5 || m == 7 || m == 9;
}

void gnssTagSettingsPack(uint8_t out[14])
{
    out[0] = gnssTagSettings.navMode;
    out[1] = gnssTagSettings.staticThrDms;
    out[2] = gnssTagSettings.minSnr;
    out[3] = gnssTagSettings.fixIntervalMs & 0xFF;
    out[4] = gnssTagSettings.fixIntervalMs >> 8;
    out[5] = gnssTagSettings.txSpacingMs & 0xFF;
    out[6] = gnssTagSettings.txSpacingMs >> 8;
    out[7] = gnssTagSettings.elevMaskDeg;
    out[8] = gnssTagSettings.idleSpacingMs & 0xFF;
    out[9] = gnssTagSettings.idleSpacingMs >> 8;
    out[10] = gnssTagSettings.adaptFastKmh;
    out[11] = gnssTagSettings.adaptSlowKmh;
    out[12] = gnssTagSettings.adaptSustainS;
    out[13] = gnssTagSettings.profileBits;
}

static bool save()
{
#ifdef FSCom
    FSCom.mkdir("/prefs"); // usually exists (NodeDB); harmless if it does
    if (FSCom.exists(kPath))
        FSCom.remove(kPath);
    auto f = FSCom.open(kPath, FILE_O_WRITE);
    if (!f)
        return false;
    uint8_t buf[16] = {kMagicByte, kVersion};
    gnssTagSettingsPack(&buf[2]);
    bool ok = f.write(buf, sizeof(buf)) == sizeof(buf);
    f.close();
    return ok;
#else
    return false;
#endif
}

bool gnssTagSettingsSaveProfile(uint8_t profileBits)
{
    if (profileBits & ~(TAG_PROFILE_PERMANENT | TAG_PROFILE_PERM_DEAF))
        return false;
    if ((profileBits & TAG_PROFILE_PERM_DEAF) && !(profileBits & TAG_PROFILE_PERMANENT))
        return false; // DEAF bit is only meaningful inside a PERMANENT profile
    if (profileBits == gnssTagSettings.profileBits)
        return true; // no flash wear for a no-op rewrite (idempotent RADIO-op retries)
    gnssTagSettings.profileBits = profileBits;
    bool saved = save();
    LOG_INFO("GnssTagSettings: profile bits=0x%02x (saved=%d)", profileBits, (int)saved);
    return saved;
}

bool gnssTagSettingsSetFromWire(const uint8_t *in, uint8_t len, bool enforceDutyFloor)
{
    if (len < 7)
        return false;
    uint8_t navMode = in[0], thr = in[1], snr = in[2];
    uint16_t fixMs = (uint16_t)(in[3] | (in[4] << 8));
    uint16_t spacing = (uint16_t)(in[5] | (in[6] << 8));
    uint8_t elev = (len >= 8) ? in[7] : gnssTagSettings.elevMaskDeg; // v1 clients keep current mask
    // v2 clients keep the current adaptive knobs
    uint16_t idle = gnssTagSettings.idleSpacingMs;
    uint8_t fast = gnssTagSettings.adaptFastKmh, slow = gnssTagSettings.adaptSlowKmh;
    uint8_t sustain = gnssTagSettings.adaptSustainS;
    if (len >= 13) {
        idle = (uint16_t)(in[8] | (in[9] << 8));
        fast = in[10];
        slow = in[11];
        sustain = in[12];
    }
    // v3 clients keep the current profile
    uint8_t profile = gnssTagSettings.profileBits;
    if (len >= 14)
        profile = in[13];
    bool profileValid = (profile & ~(TAG_PROFILE_PERMANENT | TAG_PROFILE_PERM_DEAF)) == 0 &&
                        (!(profile & TAG_PROFILE_PERM_DEAF) || (profile & TAG_PROFILE_PERMANENT));
    if (!validNavMode(navMode) || thr > 20 || snr < 9 || snr > 37 || fixMs < 100 || fixMs > 1000 ||
        spacing < 100 || spacing > 5000 || elev > 45 || idle < 1000 || idle > 30000 || fast < 2 ||
        fast > 30 || slow < 1 || slow >= fast || sustain < 3 || sustain > 120 || !profileValid) {
        LOG_WARN("GnssTagSettings: REJECTED mode=%u thr=%u snr=%u fix=%u spacing=%u elev=%u idle=%u fast=%u slow=%u sus=%u prof=0x%02x",
                 navMode, thr, snr, fixMs, spacing, elev, idle, fast, slow, sustain, profile);
        return false;
    }
    // Duty legality at SET time (docs/RADIO_STATES.md §3): a live SET must not persist a sustained
    // spacing the configured region forbids. Boot-time loads skip this (floor unknown pre-radio;
    // stored values are clamped at use with the "degraded" flag instead) — and
    // lora.override_duty_cycle (bench-only) zeroes the floor inside tagRadioDutyFloorMs().
    if (enforceDutyFloor) {
        uint32_t floorMs = tagRadioDutyFloorMs();
        if (floorMs && spacing < floorMs) {
            LOG_WARN("GnssTagSettings: REJECTED spacing=%u < duty floor %lu ms (region duty-cycle)", spacing,
                     (unsigned long)floorMs);
            return false;
        }
    }
    gnssTagSettings.navMode = navMode;
    gnssTagSettings.staticThrDms = thr;
    gnssTagSettings.minSnr = snr;
    gnssTagSettings.fixIntervalMs = fixMs;
    gnssTagSettings.txSpacingMs = spacing;
    gnssTagSettings.elevMaskDeg = elev;
    gnssTagSettings.idleSpacingMs = idle;
    gnssTagSettings.adaptFastKmh = fast;
    gnssTagSettings.adaptSlowKmh = slow;
    gnssTagSettings.adaptSustainS = sustain;
    gnssTagSettings.profileBits = profile;
    bool saved = save();
    LOG_INFO("GnssTagSettings: set mode=%u thr=%u snr=%u fix=%u spacing=%u elev=%u idle=%u fast=%u slow=%u sus=%u prof=0x%02x (saved=%d)",
             navMode, thr, snr, fixMs, spacing, elev, idle, fast, slow, sustain, profile, (int)saved);
    return true;
}

void gnssTagSettingsLoad()
{
#ifdef FSCom
    auto f = FSCom.open(kPath, FILE_O_READ);
    if (!f)
        return; // first run: compiled defaults stand
    uint8_t buf[16];
    int n = f.read(buf, sizeof(buf));
    f.close();
    // v1 file = 9 bytes (7-byte wire), v2 = 10 (8-byte), v3 = 15 (13-byte), v4 = 16 (14-byte).
    bool ok = n >= 9 && buf[0] == kMagicByte && (buf[1] >= 1 && buf[1] <= kVersion);
    if (!ok) {
        LOG_WARN("GnssTagSettings: stored file invalid — using defaults");
        return;
    }
    // Adopt via the same validator (a corrupt-but-well-framed file can't smuggle bad values in).
    // enforceDutyFloor=false: at this point the radio/region aren't up, and a stored spacing that
    // became illegal (region change) must CLAMP at use, not silently revert the whole file.
    uint8_t navMode = gnssTagSettings.navMode, thr = gnssTagSettings.staticThrDms, snr = gnssTagSettings.minSnr;
    uint16_t fixMs = gnssTagSettings.fixIntervalMs, spacing = gnssTagSettings.txSpacingMs;
    uint8_t elevKeep = gnssTagSettings.elevMaskDeg;
    if (!gnssTagSettingsSetFromWire(&buf[2], (uint8_t)(n - 2), false)) { // note: re-saves on success (harmless)
        gnssTagSettings.navMode = navMode;
        gnssTagSettings.staticThrDms = thr;
        gnssTagSettings.minSnr = snr;
        gnssTagSettings.fixIntervalMs = fixMs;
        gnssTagSettings.txSpacingMs = spacing;
        gnssTagSettings.elevMaskDeg = elevKeep;
    }
#endif
}

#endif // GPS_TAG || ODID_SNIFFER
