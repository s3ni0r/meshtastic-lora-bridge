#include "configuration.h"

#ifdef GPS_TAG
#include "GnssTagSettings.h"
#include "FSCommon.h"

GnssTagSettings gnssTagSettings;

static const char *kPath = "/prefs/gnsstag.dat";

// On-disk layout: [magic][version][7-byte wire payload]
static const uint8_t kMagicByte = 0xA7;
static const uint8_t kVersion = 1;

static bool validNavMode(uint8_t m)
{
    return m == 0 || m == 1 || m == 4 || m == 5 || m == 7 || m == 9;
}

void gnssTagSettingsPack(uint8_t out[7])
{
    out[0] = gnssTagSettings.navMode;
    out[1] = gnssTagSettings.staticThrDms;
    out[2] = gnssTagSettings.minSnr;
    out[3] = gnssTagSettings.fixIntervalMs & 0xFF;
    out[4] = gnssTagSettings.fixIntervalMs >> 8;
    out[5] = gnssTagSettings.txSpacingMs & 0xFF;
    out[6] = gnssTagSettings.txSpacingMs >> 8;
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
    uint8_t buf[9] = {kMagicByte, kVersion};
    gnssTagSettingsPack(&buf[2]);
    bool ok = f.write(buf, sizeof(buf)) == sizeof(buf);
    f.close();
    return ok;
#else
    return false;
#endif
}

bool gnssTagSettingsSetFromWire(const uint8_t in[7])
{
    uint8_t navMode = in[0], thr = in[1], snr = in[2];
    uint16_t fixMs = (uint16_t)(in[3] | (in[4] << 8));
    uint16_t spacing = (uint16_t)(in[5] | (in[6] << 8));
    if (!validNavMode(navMode) || thr > 20 || snr < 9 || snr > 37 || fixMs < 100 || fixMs > 1000 ||
        spacing < 100 || spacing > 5000) {
        LOG_WARN("GnssTagSettings: REJECTED mode=%u thr=%u snr=%u fix=%u spacing=%u", navMode, thr, snr, fixMs,
                 spacing);
        return false;
    }
    gnssTagSettings.navMode = navMode;
    gnssTagSettings.staticThrDms = thr;
    gnssTagSettings.minSnr = snr;
    gnssTagSettings.fixIntervalMs = fixMs;
    gnssTagSettings.txSpacingMs = spacing;
    bool saved = save();
    LOG_INFO("GnssTagSettings: set mode=%u thr=%u dm/s snr=%u dB fix=%u ms spacing=%u ms (saved=%d)", navMode, thr,
             snr, fixMs, spacing, (int)saved);
    return true;
}

void gnssTagSettingsLoad()
{
#ifdef FSCom
    auto f = FSCom.open(kPath, FILE_O_READ);
    if (!f)
        return; // first run: compiled defaults stand
    uint8_t buf[9];
    bool ok = f.read(buf, sizeof(buf)) == sizeof(buf) && buf[0] == kMagicByte && buf[1] == kVersion;
    f.close();
    if (!ok) {
        LOG_WARN("GnssTagSettings: stored file invalid — using defaults");
        return;
    }
    // Adopt via the same validator (a corrupt-but-well-framed file can't smuggle bad values in).
    uint8_t navMode = gnssTagSettings.navMode, thr = gnssTagSettings.staticThrDms, snr = gnssTagSettings.minSnr;
    uint16_t fixMs = gnssTagSettings.fixIntervalMs, spacing = gnssTagSettings.txSpacingMs;
    if (!gnssTagSettingsSetFromWire(&buf[2])) { // note: re-saves on success (harmless)
        gnssTagSettings.navMode = navMode;
        gnssTagSettings.staticThrDms = thr;
        gnssTagSettings.minSnr = snr;
        gnssTagSettings.fixIntervalMs = fixMs;
        gnssTagSettings.txSpacingMs = spacing;
    }
#endif
}

#endif // GPS_TAG
