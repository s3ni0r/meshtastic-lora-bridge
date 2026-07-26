"""Enforce the bench flash policy (owner rule, 2026-07-26 — after the 4th serial-DFU wedge).

Root cause of every wedge: DIY serial-DFU. Raw `adafruit-nrfutil --touch 1200` performs its
own touch and immediately reopens the SAME /dev path — losing the macOS re-enumeration race
("Device not configured") and stranding the board in its bootloader until physical recovery.

Policy, hands-free and fail-closed:

  `tools/flash_t1000e.sh` is the ONE flasher (release flavors AND the `dev` build). Its
  proven dance: preflight the full DFU toolchain -> pin the target by HARDWARE SERIAL ->
  its own 1200-baud touch -> RE-FIND THE SAME SILICON by serial (up to 12 s) -> nrfutil
  upload WITHOUT --touch on the refound port. The UF2 volume path (tools/flash_uf2.py,
  double-tap) is the RECOVERY route, not the default.

This test keeps the mechanism (and the docs that describe it) from silently eroding.
"""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FLASH_SH = REPO / "tools/flash_t1000e.sh"
SKILL = REPO / ".agents/skills/flash-t1000e/SKILL.md"
AGENTS = REPO / "AGENTS.md"


class FlashPolicyTests(unittest.TestCase):
    def test_the_script_keeps_its_proven_dance(self):
        text = FLASH_SH.read_text(encoding="utf-8")
        self.assertIn("Re-find the SAME hardware after re-enumeration", text,
                      "the serial re-find loop is the mechanism that makes serial-DFU reliable")
        # The upload must run on the REFOUND port, never with nrfutil's own racy touch:
        # inspect executable lines only (the policy comment legitimately names --touch).
        code_lines = [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]
        upload_lines = [ln for ln in code_lines if "dfu serial" in ln]
        self.assertTrue(upload_lines, "expected the nrfutil upload invocation")
        self.assertFalse([ln for ln in code_lines if "--touch" in ln],
                         "flash_t1000e.sh must never delegate the touch to nrfutil (re-enum race)")
        self.assertIn('"dev" ]', text, "the dev-build mode must exist so nobody bypasses the script")

    def test_no_diy_serial_dfu_anywhere_else(self):
        # Only flash_t1000e.sh may touch at 1200 baud or drive a serial-DFU upload. Prose
        # mentions are fine; invocation forms anywhere else are the exact mistake that wedged
        # boards four times.
        offenders = []
        for path in (REPO / "tools").rglob("*"):
            if not path.is_file() or path.suffix == ".pyc" or path.name == "flash_t1000e.sh":
                continue
            if path.name == Path(__file__).name:
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, OSError):
                continue
            if re.search(r"--touch\s+1200|adafruit-nrfutil\.py\s+dfu\s+serial", text):
                offenders.append(str(path.relative_to(REPO)))
        self.assertEqual(offenders, [], f"DIY serial-DFU outside the flasher: {offenders}")

    def test_docs_state_the_enforced_policy(self):
        for doc, needle in ((SKILL, "flash_t1000e.sh"), (AGENTS, "flash_t1000e.sh")):
            text = doc.read_text(encoding="utf-8")
            self.assertIn(needle, text, f"{doc.name} must present the script as THE flash path")
            self.assertNotIn("ALLOW_SERIAL_DFU", text,
                             f"{doc.name} still references the retired approval gate")


if __name__ == "__main__":
    unittest.main()
