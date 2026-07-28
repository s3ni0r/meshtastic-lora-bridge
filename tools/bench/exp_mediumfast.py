#!/usr/bin/env python
"""EXP-mediumfast-2hz-range — fleet radio config for the range experiment.

Applies / verifies / restores the experiment radio identity on every connected
fleet node it can resolve (bridge 'tag' + 'base' minimum; 'gpstag' if present):

  apply    EU_868 + MEDIUM_FAST + override_duty_cycle=True   (+ bridge spacing 500 ms)
  restore  US    + SHORT_TURBO  + override_duty_cycle=False  (bench baseline)
  verify   read-back only (no writes)

Rules encoded here (learned the hard way, see AGENTS.md invariants + bench C5):
  - Region and preset change TOGETHER on every participating node — a split fleet
    silently loses the air path.
  - Every write is VERIFIED by read-back after the node's config reboot.
  - override_duty_cycle is a deliberate, experiment-scoped choice (owner's call);
    'restore' always turns it back off.

Run from the repo root with the pipx python. Exit 0 = every resolved node verified.
"""
import sys
import time

sys.path.insert(0, "tools")
import nodes
import meshtastic.serial_interface
from meshtastic.protobuf import config_pb2

LORA = config_pb2.Config.LoRaConfig
EXPERIMENT = {"region": LORA.RegionCode.EU_868, "preset": LORA.ModemPreset.MEDIUM_FAST,
              "override": True, "label": "EU_868 + MEDIUM_FAST + duty override"}
BASELINE = {"region": LORA.RegionCode.US, "preset": LORA.ModemPreset.SHORT_TURBO,
            "override": False, "label": "US + SHORT_TURBO (bench baseline)"}
BRIDGE_NUM = 0xB4DBB54C
BRIDGE_SPACING_MS = 500  # 2 Hz cap for the experiment

ROLES = ["tag", "base", "gpstag"]


def stamp(msg):
    print(f"[exp] {msg}", flush=True)


def open_iface(role, tries=6):
    for _ in range(tries):
        port = nodes.resolve(role)
        if port:
            try:
                return meshtastic.serial_interface.SerialInterface(devPath=port)
            except Exception as e:
                stamp(f"{role}: open failed ({e!r}), retrying")
        time.sleep(5)
    return None


def read_lora(iface):
    lc = iface.localNode.localConfig.lora
    return {"region": lc.region, "preset": lc.modem_preset, "override": lc.override_duty_cycle}


def matches(state, want):
    return (state["region"] == want["region"] and state["preset"] == want["preset"]
            and state["override"] == want["override"])


def apply_target(role, want):
    iface = open_iface(role)
    if iface is None:
        return None  # not connected — caller decides if that's fatal
    try:
        before = read_lora(iface)
        if matches(before, want):
            stamp(f"{role}: already at {want['label']}")
            return True
        node = iface.localNode
        node.localConfig.lora.region = want["region"]
        node.localConfig.lora.modem_preset = want["preset"]
        node.localConfig.lora.override_duty_cycle = want["override"]
        node.writeConfig("lora")  # node reboots itself to apply
        stamp(f"{role}: wrote {want['label']} — waiting for config reboot")
    finally:
        try:
            iface.close()
        except Exception:
            pass
    time.sleep(12)
    return verify_target(role, want)


def verify_target(role, want):
    iface = open_iface(role)
    if iface is None:
        return None
    try:
        state = read_lora(iface)
        ok = matches(state, want)
        stamp(f"{role}: region={LORA.RegionCode.Name(state['region'])} "
              f"preset={LORA.ModemPreset.Name(state['preset'])} "
              f"override={state['override']} -> {'OK' if ok else 'MISMATCH'}")
        return ok
    finally:
        try:
            iface.close()
        except Exception:
            pass


def set_bridge_spacing(ms):
    """2 Hz cap via the v4 settings wire (SET spacing u16 at settings[5:7])."""
    from meshtastic import mesh_pb2
    from pubsub import pub

    replies = []

    def on_rx(packet=None, interface=None):
        d = packet.get("decoded", {}) if packet else {}
        if d.get("portnum") in (260, "PRIVATE_APP") and packet.get("from") == BRIDGE_NUM:
            pl = bytes(d.get("payload", b""))
            if len(pl) == 20 and 0x80 <= pl[0] <= 0x86:
                replies.append(pl)

    iface = open_iface("tag")
    if iface is None:
        return None
    pub.subscribe(on_rx, "meshtastic.receive")
    try:
        time.sleep(1.5)

        def send(payload):
            p = mesh_pb2.MeshPacket()
            p.to = BRIDGE_NUM
            p.decoded.portnum = 260
            p.decoded.payload = bytes(payload)
            p.id = iface._generatePacketId()
            iface._sendPacket(p)

        def wait_reply(mark, op, timeout=3.0):
            t0 = time.monotonic()
            while time.monotonic() - t0 < timeout:
                for r in replies[mark:]:
                    if (r[0] & 0x7F) == op:
                        return r
                time.sleep(0.05)
            return None

        got = None
        for _ in range(3):
            mark = len(replies)
            send([0x00])
            got = wait_reply(mark, 0x00)
            if got:
                break
        if not got:
            stamp("bridge: no v4 GET reply — firmware without the settings wire? spacing NOT set")
            return False
        settings = bytearray(got[2:16])
        old = int.from_bytes(settings[5:7], "little")
        settings[5:7] = int(ms).to_bytes(2, "little")
        got = None
        for _ in range(3):
            mark = len(replies)
            send([0x01] + list(settings))
            got = wait_reply(mark, 0x01)
            if got:
                break
        if not got or got[1] != 0:
            stamp(f"bridge: SET spacing {ms} ms REJECTED "
                  f"(status={got[1] if got else 'no reply'}) — check duty floor bytes 18-19")
            return False
        echoed = int.from_bytes(got[7:9], "little")
        stamp(f"bridge: spacing {old} -> {echoed} ms (persisted)")
        return echoed == ms
    finally:
        pub.unsubscribe(on_rx, "meshtastic.receive")
        try:
            iface.close()
        except Exception:
            pass


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "verify"
    if mode not in ("apply", "restore", "verify"):
        print(__doc__)
        sys.exit(2)
    want = {"apply": EXPERIMENT, "restore": BASELINE, "verify": None}[mode]

    failed, applied, absent = [], [], []
    for role in ROLES:
        target = want or EXPERIMENT  # verify defaults to checking the experiment identity
        result = (verify_target if mode == "verify" else apply_target)(role, target)
        if result is None:
            absent.append(role)
        elif result:
            applied.append(role)
        else:
            failed.append(role)

    if mode == "apply" and "tag" in applied:
        if set_bridge_spacing(BRIDGE_SPACING_MS) is not True:
            failed.append("tag-spacing")

    stamp(f"done: ok={applied} absent={absent} failed={failed}")
    if failed or ("tag" in absent or "base" in absent):
        stamp("RESULT: FAIL (experiment needs at least bridge + base, all verified)")
        sys.exit(1)
    if absent:
        stamp(f"NOTE: {absent} not connected — flip them with this script before any bench "
              f"regression run, or the fleet is split (C5 trap).")
    stamp("RESULT: OK")
    sys.exit(0)


if __name__ == "__main__":
    main()
