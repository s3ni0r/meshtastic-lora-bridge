#pragma once
#include "SinglePortModule.h"

/**
 * HighRatePositionModule — project fork.
 *
 * Streams the local GPS fix as a compact 12-byte payload on PRIVATE_APP (256) at a fixed
 * sub-second cadence, calling service->sendToMesh() directly. This deliberately BYPASSES
 * Meshtastic's PositionModule, whose 5 s RUNONCE_INTERVAL, whole-second config, smart-broadcast
 * gate, and channel-util/duty-cycle checks make 2-4 Hz impossible.
 *
 * Gated behind -DHIGHRATE_POSITION_SENDER so only the *moving* (sender) node streams; the
 * receiver node runs a normal build.
 *
 * BENCH/TEST ONLY: at >2.4 Hz this exceeds the EU868 10% duty cycle. Set
 * lora.override_duty_cycle=true and device.role=TRACKER on the sender. Not for deployment.
 */
class HighRatePositionModule : public SinglePortModule, private concurrency::OSThread
{
  public:
    HighRatePositionModule();

  protected:
    virtual int32_t runOnce() override;

  private:
    uint8_t seq = 0;
    int32_t lastLat = 0;       // for staleness detection (position that stops changing == stale)
    int32_t lastLon = 0;
    uint32_t lastChangedMs = 0;
};

extern HighRatePositionModule *highRatePositionModule;
