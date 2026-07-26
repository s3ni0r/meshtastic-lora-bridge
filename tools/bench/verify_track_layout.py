"""Host-only TRACK slot-format and exact LittleFS-capacity regression gate.

No hardware is touched. The format checks exercise the v3 immutable-header + appended-footer
contract, including every possible truncated footer length and metadata-proof corruption. The
capacity fixture compiles against PlatformIO's exact bundled LittleFS v1 with the T1000-E's
224 x 128-byte InternalFS geometry.
"""
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HEADER_LEN, FOOTER_LEN, RECORD_LEN, MAX_RECORDS = 16, 16, 10, 800
TRACK_MAGIC, TRACK_VERSION = 0xAA, 3
COMMIT_MAGIC = 0x54494D43  # LE bytes "CMIT"


def committed_slot(records, tid, generation):
    crc = zlib.crc32(records) & 0xFFFFFFFF
    count = len(records) // RECORD_LEN
    header = struct.pack("<BBHIII", TRACK_MAGIC, TRACK_VERSION, count, crc, 0, tid)
    footer_prefix = struct.pack("<III", COMMIT_MAGIC, generation, tid)
    proof = zlib.crc32(header + footer_prefix) & 0xFFFFFFFF
    return header + records + footer_prefix + struct.pack("<I", proof)


def valid_committed_slot(blob):
    if len(blob) < HEADER_LEN + FOOTER_LEN:
        return False
    magic, version, count, crc, reserved, tid = struct.unpack_from("<BBHIII", blob)
    if magic != TRACK_MAGIC or version != TRACK_VERSION or not (2 <= count <= MAX_RECORDS):
        return False
    if reserved != 0 or tid == 0:
        return False
    record_end = HEADER_LEN + count * RECORD_LEN
    if len(blob) != record_end + FOOTER_LEN:
        return False
    records = blob[HEADER_LEN:record_end]
    if zlib.crc32(records) & 0xFFFFFFFF != crc:
        return False
    commit_magic, generation, footer_tid, proof = struct.unpack_from("<IIII", blob, record_end)
    if commit_magic != COMMIT_MAGIC or generation == 0 or footer_tid != tid:
        return False
    expected = zlib.crc32(blob[:HEADER_LEN] + blob[record_end:record_end + 12]) & 0xFFFFFFFF
    return proof == expected


def check_format():
    records = bytes((i * 17 + 3) & 0xFF for i in range(MAX_RECORDS * RECORD_LEN))
    slot = committed_slot(records, 0xC0FFEE01, 7)
    assert len(slot) == 8032
    assert valid_committed_slot(slot)

    staging = slot[:-FOOTER_LEN]
    assert len(staging) == 8016 and not valid_committed_slot(staging)
    for footer_bytes in range(FOOTER_LEN):
        assert not valid_committed_slot(staging + slot[-FOOTER_LEN:][:footer_bytes])

    for i in range(FOOTER_LEN):
        damaged = bytearray(slot)
        damaged[-FOOTER_LEN + i] ^= 0x01
        assert not valid_committed_slot(damaged), f"footer corruption at byte {i} was accepted"

    damaged_record = bytearray(slot)
    damaged_record[HEADER_LEN + 123] ^= 0x01
    assert not valid_committed_slot(damaged_record)
    print("PASS: v3 slot/footer shape, proof CRC, torn-footer, and record CRC invariants")


def check_source_contract():
    source = (ROOT / "firmware/src/gps/GnssSim.cpp").read_text()
    header = (ROOT / "firmware/src/gps/GnssSim.h").read_text()
    handler = (ROOT / "firmware/src/modules/GnssConfigModule.cpp").read_text()
    required = [
        "kTrackLegacyVer = 2, kTrackVer = 3",
        "packU32(&out[12], trackFooterProof(h))",
        "f.write(footer, sizeof(footer))",
        "return trackActiveSlot(&act) != nullptr && act.tid == tid",
    ]
    for snippet in required:
        assert snippet in source, f"firmware source lost layout invariant: {snippet}"
    assert "seek(0)" not in source, "COMMIT regressed to an offset-zero LittleFS rewrite"
    assert "trackChunk(uint32_t tid" in header
    assert "trackChunk(tid, off, n" in handler
    print("PASS: tracked firmware source uses footer append and pre-mutation CHUNK tid ownership")


def check_exact_littlefs_capacity():
    lfs_dir = (Path.home() / ".platformio/packages/framework-arduinoadafruitnrf52/"
               "libraries/Adafruit_LittleFS/src/littlefs")
    required = [lfs_dir / "lfs.c", lfs_dir / "lfs_util.c", lfs_dir / "lfs.h"]
    if not all(path.is_file() for path in required):
        raise RuntimeError("PlatformIO Adafruit LittleFS package is missing; run the GPS firmware build first")
    compiler = shutil.which("cc")
    if not compiler:
        raise RuntimeError("host C compiler `cc` is unavailable")

    fixture = ROOT / "tools/bench/lfs_track_capacity.c"
    with tempfile.TemporaryDirectory(prefix="meshtastic-lfs-layout-") as tmp:
        binary = Path(tmp) / "lfs_track_capacity"
        compile_result = subprocess.run(
            [compiler, "-std=c99", "-O2", "-I", str(lfs_dir), str(fixture),
             str(lfs_dir / "lfs.c"), str(lfs_dir / "lfs_util.c"), "-o", str(binary)],
            capture_output=True, text=True)
        if compile_result.returncode:
            raise RuntimeError(f"capacity fixture compile failed:\n{compile_result.stderr}")
        run_result = subprocess.run([str(binary)], capture_output=True, text=True)
        if run_result.returncode:
            raise RuntimeError(f"capacity fixture failed:\n{run_result.stdout}{run_result.stderr}")
        print(run_result.stdout.strip())


try:
    check_format()
    check_source_contract()
    check_exact_littlefs_capacity()
except Exception as exc:
    print(f"OVERALL: FAIL — {exc}")
    sys.exit(1)

print("OVERALL: PASS")
sys.exit(0)
