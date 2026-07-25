#include "configuration.h"

#ifdef GPS_TAG
#include "GnssTagSettings.h"
#include "FSCommon.h"

GnssTagSettings gnssTagSettings;
GnssTagMode gnssTagMode; // runtime-only; deliberately NOT part of the persisted file

static const char *kPath = "/prefs/gnsstag.dat";

// On-disk layout: [magic][version][wire payload] — v1 = 7-byte wire, v2 adds elevMaskDeg (8),
// v3 adds the adaptive knobs (13).
static const uint8_t kMagicByte = 0xA7;
static const uint8_t kVersion = 3;

static bool validNavMode(uint8_t m)
{
    return m == 0 || m == 1 || m == 4 || m == 5 || m == 7 || m == 9;
}

void gnssTagSettingsPack(uint8_t out[13])
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
    uint8_t buf[15] = {kMagicByte, kVersion};
    gnssTagSettingsPack(&buf[2]);
    bool ok = f.write(buf, sizeof(buf)) == sizeof(buf);
    f.close();
    return ok;
#else
    return false;
#endif
}

bool gnssTagSettingsSetFromWire(const uint8_t *in, uint8_t len)
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
    if (!validNavMode(navMode) || thr > 20 || snr < 9 || snr > 37 || fixMs < 100 || fixMs > 1000 ||
        spacing < 100 || spacing > 5000 || elev > 45 || idle < 1000 || idle > 30000 || fast < 2 ||
        fast > 30 || slow < 1 || slow >= fast || sustain < 3 || sustain > 120) {
        LOG_WARN("GnssTagSettings: REJECTED mode=%u thr=%u snr=%u fix=%u spacing=%u elev=%u idle=%u fast=%u slow=%u sus=%u",
                 navMode, thr, snr, fixMs, spacing, elev, idle, fast, slow, sustain);
        return false;
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
    bool saved = save();
    LOG_INFO("GnssTagSettings: set mode=%u thr=%u snr=%u fix=%u spacing=%u elev=%u idle=%u fast=%u slow=%u sus=%u (saved=%d)",
             navMode, thr, snr, fixMs, spacing, elev, idle, fast, slow, sustain, (int)saved);
    return true;
}

void gnssTagSettingsLoad()
{
#ifdef FSCom
    auto f = FSCom.open(kPath, FILE_O_READ);
    if (!f)
        return; // first run: compiled defaults stand
    uint8_t buf[15];
    int n = f.read(buf, sizeof(buf));
    f.close();
    // v1 file = 9 bytes (7-byte wire), v2 = 10 (8-byte wire), v3 = 15 (13-byte) — all accepted.
    bool ok = n >= 9 && buf[0] == kMagicByte && (buf[1] >= 1 && buf[1] <= kVersion);
    if (!ok) {
        LOG_WARN("GnssTagSettings: stored file invalid — using defaults");
        return;
    }
    // Adopt via the same validator (a corrupt-but-well-framed file can't smuggle bad values in).
    uint8_t navMode = gnssTagSettings.navMode, thr = gnssTagSettings.staticThrDms, snr = gnssTagSettings.minSnr;
    uint16_t fixMs = gnssTagSettings.fixIntervalMs, spacing = gnssTagSettings.txSpacingMs;
    uint8_t elevKeep = gnssTagSettings.elevMaskDeg;
    if (!gnssTagSettingsSetFromWire(&buf[2], (uint8_t)(n - 2))) { // note: re-saves on success (harmless)
        gnssTagSettings.navMode = navMode;
        gnssTagSettings.staticThrDms = thr;
        gnssTagSettings.minSnr = snr;
        gnssTagSettings.fixIntervalMs = fixMs;
        gnssTagSettings.txSpacingMs = spacing;
        gnssTagSettings.elevMaskDeg = elevKeep;
    }
#endif
}

#endif // GPS_TAG
