import contextlib
import io
import plistlib
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import flash_uf2  # noqa: E402


def uf2_block(
    *,
    block_no=0,
    total=1,
    target=flash_uf2.T1000_APP_FLASH_START,
    payload_size=256,
    flags=flash_uf2.UF2_FLAG_FAMILY_ID,
    family=flash_uf2.NRF52840_FAMILY,
):
    block = bytearray(flash_uf2.UF2_BLOCK_SIZE)
    struct.pack_into(
        "<IIIIIIII",
        block,
        0,
        flash_uf2.UF2_MAGIC0,
        flash_uf2.UF2_MAGIC1,
        flags,
        target,
        payload_size,
        block_no,
        total,
        family,
    )
    block[flash_uf2.UF2_DATA_OFFSET : flash_uf2.UF2_DATA_OFFSET + payload_size] = bytes(
        [block_no & 0xFF]
    ) * payload_size
    struct.pack_into("<I", block, 508, flash_uf2.UF2_MAGIC_END)
    return bytes(block)


class Uf2ValidationTests(unittest.TestCase):
    def validate_bytes(self, data):
        with tempfile.NamedTemporaryFile(suffix=".uf2") as image:
            image.write(data)
            image.flush()
            with contextlib.redirect_stdout(io.StringIO()):
                flash_uf2.validate_uf2(image.name)

    def assert_invalid(self, data, message):
        with self.assertRaises(SystemExit) as raised:
            self.validate_bytes(data)
        self.assertIn(message, str(raised.exception))

    def test_valid_complete_image(self):
        data = b"".join(
            [
                uf2_block(
                    block_no=1,
                    total=2,
                    target=flash_uf2.T1000_APP_FLASH_START + 256,
                ),
                uf2_block(block_no=0, total=2),
            ]
        )
        self.validate_bytes(data)

    def test_accepts_payloads_on_both_application_partition_edges(self):
        data = uf2_block(block_no=0, total=2) + uf2_block(
            block_no=1,
            total=2,
            target=flash_uf2.T1000_APP_FLASH_END - 256,
        )
        self.validate_bytes(data)

    def test_shipped_v43_images_validate(self):
        images = sorted((REPO / "firmware/releases/v4.3").glob("*.uf2"))
        self.assertEqual(
            [image.name for image in images],
            [
                "base-plain.uf2",
                "bridge-tag.uf2",
                "gps-tag.uf2",
            ],
        )
        for image in images:
            with self.subTest(image=image.name), contextlib.redirect_stdout(io.StringIO()):
                flash_uf2.validate_uf2(image)

    def test_rejects_any_block_without_exact_family_flag(self):
        for flags in (0, flash_uf2.UF2_FLAG_FAMILY_ID | 0x00000001):
            with self.subTest(flags=hex(flags)):
                data = uf2_block(block_no=0, total=2) + uf2_block(
                    block_no=1,
                    total=2,
                    target=flash_uf2.T1000_APP_FLASH_START + 256,
                    flags=flags,
                    family=0xDEADBEEF,
                )
                self.assert_invalid(data, "every block must be")

    def test_rejects_mixed_family(self):
        data = uf2_block(block_no=0, total=2) + uf2_block(
            block_no=1,
            total=2,
            target=flash_uf2.T1000_APP_FLASH_START + 256,
            family=0x12345678,
        )
        self.assert_invalid(data, "wrong-target image")

    def test_rejects_truncated_image(self):
        self.assert_invalid(uf2_block()[:-1], "not a multiple")

    def test_rejects_duplicate_block_number(self):
        data = uf2_block(block_no=0, total=2) + uf2_block(
            block_no=0,
            total=2,
            target=flash_uf2.T1000_APP_FLASH_START + 256,
        )
        self.assert_invalid(data, "repeats UF2 block number")

    def test_rejects_inconsistent_or_incomplete_total(self):
        data = uf2_block(block_no=0, total=2)
        self.assert_invalid(data, "file contains 1")

    def test_rejects_payload_outside_block_bounds(self):
        for payload_size in (0, flash_uf2.UF2_MAX_PAYLOAD + 1):
            with self.subTest(payload_size=payload_size):
                self.assert_invalid(
                    uf2_block(payload_size=payload_size),
                    "payload size",
                )

    def test_rejects_targets_outside_application_partition(self):
        cases = (
            flash_uf2.T1000_APP_FLASH_START - 4,
            flash_uf2.T1000_APP_FLASH_END - 128,
        )
        for target in cases:
            with self.subTest(target=hex(target)):
                self.assert_invalid(uf2_block(target=target), "outside the T1000-E application")

    def test_rejects_target_address_overflow(self):
        self.assert_invalid(
            uf2_block(target=0xFFFFFFF0),
            "overflows the 32-bit address space",
        )

    def test_rejects_overlapping_target_ranges(self):
        data = uf2_block(block_no=0, total=2) + uf2_block(
            block_no=1,
            total=2,
            target=flash_uf2.T1000_APP_FLASH_START + 128,
        )
        self.assert_invalid(data, "overlap in flash")


def registry_fixture(target_serial=None, parent_hub_serial=None):
    target = {
        "IOObjectClass": "IOUSBHostDevice",
        "IORegistryEntryName": "T1000-E",
        "IORegistryEntryChildren": [
            {
                "IOObjectClass": "IOUSBMassStorageInterfaceNub",
                "IORegistryEntryChildren": [
                    {
                        "IOObjectClass": "IOMedia",
                        "BSD Name": "disk9s1",
                    }
                ],
            }
        ],
    }
    if target_serial:
        target["USB Serial Number"] = target_serial
    root_children = [
        {
            "IOObjectClass": "IOUSBHostDevice",
            "IORegistryEntryName": "Unrelated sibling",
            "USB Serial Number": "AAAAAAAAAAAAAAAA",
            "IORegistryEntryChildren": [
                {"IOObjectClass": "IOMedia", "BSD Name": "disk8s1"}
            ],
        },
        target,
    ]
    root = {
        "IOObjectClass": "IOPlatformExpertDevice",
        "IORegistryEntryChildren": root_children,
    }
    if parent_hub_serial:
        root = {
            "IOObjectClass": "IOUSBHostDevice",
            "USB Serial Number": parent_hub_serial,
            "IORegistryEntryChildren": [root],
        }
    return [root]


class IoregOwnerTests(unittest.TestCase):
    def test_returns_serial_from_nearest_usb_device_ancestor(self):
        serial = flash_uf2._owner_serial_from_ioreg(
            registry_fixture(target_serial="bbbbbbbbbbbbbbbb"),
            "disk9s1",
        )
        self.assertEqual(serial, "BBBBBBBBBBBBBBBB")

    def test_sibling_serial_never_authorizes_serial_less_target(self):
        serial = flash_uf2._owner_serial_from_ioreg(
            registry_fixture(),
            "disk9s1",
        )
        self.assertIsNone(serial)

    def test_parent_hub_serial_never_replaces_missing_target_serial(self):
        serial = flash_uf2._owner_serial_from_ioreg(
            registry_fixture(parent_hub_serial="CCCCCCCCCCCCCCCC"),
            "disk9s1",
        )
        self.assertIsNone(serial)

    def test_volume_owner_uses_structured_diskutil_and_ioreg_plists(self):
        disk = plistlib.dumps({"DeviceIdentifier": "disk9s1"})
        registry = plistlib.dumps(registry_fixture(target_serial="BBBBBBBBBBBBBBBB"))
        results = [
            SimpleNamespace(returncode=0, stdout=disk),
            SimpleNamespace(returncode=0, stdout=registry),
        ]
        with mock.patch.object(flash_uf2.subprocess, "run", side_effect=results) as run:
            self.assertEqual(
                flash_uf2.volume_owner_serial("/Volumes/T1000-E"),
                "BBBBBBBBBBBBBBBB",
            )
        self.assertEqual(run.call_args_list[0].args[0][1:3], ["info", "-plist"])
        self.assertIn("-a", run.call_args_list[1].args[0])


class ShellUf2DelegationTests(unittest.TestCase):
    def test_explicit_shell_mode_uses_the_strict_uf2_implementation(self):
        script = (REPO / "tools/flash_t1000e.sh").read_text()
        self.assertIn(
            'exec "$PY" "$REPO/tools/flash_uf2.py" - "$UF2"',
            script,
        )
        self.assertNotIn('cp "$UF2" "$v/"', script)


if __name__ == "__main__":
    unittest.main()
