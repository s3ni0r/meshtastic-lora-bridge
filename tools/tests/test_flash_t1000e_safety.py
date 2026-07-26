import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SCRIPT = (REPO / "tools/flash_t1000e.sh").read_text()


class SerialFlashSafetyTests(unittest.TestCase):
    def test_all_fail_closed_preflights_precede_the_hazardous_touch(self):
        touch = SCRIPT.index('echo "   1200-baud touch on $TARGET"')
        required_before_touch = (
            'if ! [[ "$HWSER" =~ ^[0-9A-F]{16}$ ]]',
            'case "$TARGET_VID" in',
            '[ -d "$NRFUTIL_DIR" ]',
            '[ -f "$NRFUTIL_DIR/adafruit-nrfutil.py" ]',
            "adafruit-nrfutil.py version",
        )
        for gate in required_before_touch:
            with self.subTest(gate=gate):
                self.assertLess(SCRIPT.index(gate), touch)

    def test_autodetect_requires_a_registry_known_serial(self):
        self.assertIn("p.vid in (0x239A, 0x2886)", SCRIPT)
        self.assertIn('(p.serial_number or "").upper() in nodes.NODES', SCRIPT)

    def test_unknown_board_requires_an_explicit_target(self):
        self.assertIn("UNREGISTERED — explicit port or 16-hex serial required", SCRIPT)
        self.assertIn("Unregistered boards are never auto-selected", SCRIPT)


if __name__ == "__main__":
    unittest.main()
