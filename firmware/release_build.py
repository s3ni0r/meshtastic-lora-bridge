#!/usr/bin/env python3
"""Trusted outer-repository entry point for release-stamped firmware builds.

PlatformIO executes build hooks from the ignored Meshtastic clone. Those hooks cannot be
their own root of trust: a modified hook could simply skip release_identity.py and forge the
expected version string. This wrapper runs the tracked attestor before PlatformIO, cleans the
object cache, attests again, builds with exact flavor flags, re-attests after the build, and
only then exports an identity-checked UF2/HEX pair.

Invoke with Python isolated mode so an untracked local module cannot shadow the standard
library before the outer repository has been checked:

    python3 -I firmware/release_build.py --release v4.4 \
      --source-sha <outer-head> --flavor gps-tag
"""

import sys

if __name__ == "__main__" and not sys.flags.isolated:
    raise SystemExit("ERROR: run release_build.py with `python3 -I` (isolated mode)")

import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess


FLAVOR_FLAGS = {
    "gps-tag": "-DGPS_TAG",
    # A1/A4: -DHIGHRATE_TX_ONLY retired — "TX-only" is the runtime DEAF state now
    # (src/modules/TagRadioState) and the bridge boots LISTENING like the GPS tag.
    "bridge-tag": (
        "-DODID_SNIFFER -DODID_PHY_EXT -DHIGHRATE_POSITION_SENDER "
        "-DHIGHRATE_POSITION_INTERVAL_MS=250"
    ),
    "base-plain": None,
}

# Fixed trusted executables — release runs never resolve these through the caller's PATH
# (a PATH-selected `git` or `pio` is unattested executable input). /usr/bin/git is the
# Apple-managed CLT shim; the pio launcher lives inside the platformio-core venv whose whole
# content is bound by firmware/platformio-toolchain.lock.json, so the launcher itself is
# covered by the attestation that runs before it is ever invoked.
TRUSTED_GIT = "/usr/bin/git"
TRUSTED_PIO = str(Path.home() / ".local/pipx/venvs/platformio/bin/pio")
# Minimal fixed PATH for the child build: system tool directories only, ahead of nothing.
RELEASE_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def _trusted_executable(path, name):
    path = Path(path)
    if not path.is_file() or not os.access(path, os.X_OK):
        raise RuntimeError(
            "trusted {} executable missing or not executable: {}".format(name, path)
        )
    return str(path)


def _git_environment(environ=None):
    inherited = os.environ if environ is None else environ
    clean = {
        key: value for key, value in inherited.items() if not key.startswith("GIT_")
    }
    clean["GIT_CONFIG_NOSYSTEM"] = "1"
    clean["GIT_CONFIG_GLOBAL"] = os.devnull
    return clean


def _execute_tracked_source(path, module_name):
    path = Path(path)
    scope = {"__file__": str(path), "__name__": module_name}
    with path.open("rb") as source:
        exec(compile(source.read(), str(path), "exec"), scope)
    return scope


def _clean_outer_head(repo_root, source_sha):
    """Establish outer HEAD/cleanliness before executing any working-tree helper."""
    requested = source_sha.lower()
    if not (7 <= len(requested) <= 40) or any(
        character not in "0123456789abcdef" for character in requested
    ):
        raise RuntimeError("source SHA must contain 7-40 hexadecimal digits")
    git = _trusted_executable(TRUSTED_GIT, "git")
    actual = subprocess.check_output(
        [git, "-C", str(repo_root), "rev-parse", "HEAD"],
        text=True,
        env=_git_environment(),
    ).strip().lower()
    if not actual.startswith(requested):
        raise RuntimeError(
            "requested source SHA {} is not outer HEAD {}".format(source_sha, actual)
        )
    status = subprocess.check_output(
        [
            git,
            "-C",
            str(repo_root),
            "status",
            "--porcelain",
            "--untracked-files=normal",
        ],
        text=True,
        env=_git_environment(),
    )
    if status.strip():
        raise RuntimeError("release wrapper requires a clean outer repository")
    return actual


def _execute_committed_source(repo_root, commit, relative_path, module_name):
    """Execute source read from the attested Git object, never a working-tree cache."""
    source = subprocess.check_output(
        [
            _trusted_executable(TRUSTED_GIT, "git"),
            "-C",
            str(repo_root),
            "show",
            "{}:{}".format(commit, relative_path),
        ],
        env=_git_environment(),
    )
    display_path = Path(repo_root) / relative_path
    scope = {"__file__": str(display_path), "__name__": module_name}
    exec(compile(source, str(display_path), "exec"), scope)
    return scope


def preflight_release(repo_root, release, source_sha):
    """Run the tracked source attestor without importing anything from the ignored clone."""
    repo_root = Path(repo_root).resolve()
    actual = _clean_outer_head(repo_root, source_sha)
    helper = _execute_committed_source(
        repo_root,
        actual,
        "firmware/release_identity.py",
        "tracker_release_identity_preflight",
    )
    identity = helper["tracker_release_version"](
        str(repo_root),
        {
            "TRACKER_RELEASE": release,
            "TRACKER_SOURCE_SHA": source_sha,
        },
        build_root=repo_root / "firmware/meshtastic-firmware",
    )
    expected = "{}.{}".format(release, actual[:8])
    if identity != expected:
        raise RuntimeError(
            "release preflight returned {!r}, expected {!r}".format(identity, expected)
        )
    return identity


def _validated_uf2_contains_identity(repo_root, uf2_path, identity):
    flash = _execute_tracked_source(
        Path(repo_root) / "tools/flash_uf2.py",
        "tracker_release_flash_uf2",
    )
    flash["validate_uf2"](uf2_path)

    chunks = []
    raw = Path(uf2_path).read_bytes()
    block_size = flash["UF2_BLOCK_SIZE"]
    data_offset = flash["UF2_DATA_OFFSET"]
    for offset in range(0, len(raw), block_size):
        block = raw[offset : offset + block_size]
        target, size = struct.unpack_from("<II", block, 12)
        chunks.append((target, block[data_offset : data_offset + size]))

    runs = []
    run_end = None
    for target, payload in sorted(chunks):
        if target != run_end:
            runs.append(bytearray())
        runs[-1].extend(payload)
        run_end = target + len(payload)
    if not any(identity.encode("ascii") in run for run in runs):
        raise RuntimeError(
            "{} does not contain release identity {}".format(uf2_path, identity)
        )


def _release_environment(release, source_sha, flavor, environ=None):
    """Return a minimal inherited environment with all PlatformIO overrides removed."""
    inherited = os.environ if environ is None else environ
    child_env = {
        key: value
        for key, value in inherited.items()
        if not key.startswith(("PLATFORMIO_", "PYTHON", "SCONS", "GIT_"))
    }
    # Fixed PATH: the caller's PATH must not be able to place a different compiler, git, or
    # helper ahead of the attested toolchain (whose tools PlatformIO invokes by absolute
    # package path anyway).
    child_env["PATH"] = RELEASE_PATH
    child_env["PYTHONDONTWRITEBYTECODE"] = "1"
    child_env["TRACKER_RELEASE"] = release
    child_env["TRACKER_SOURCE_SHA"] = source_sha
    flags = FLAVOR_FLAGS[flavor]
    if flags is not None:
        child_env["PLATFORMIO_BUILD_FLAGS"] = flags
    return child_env


def build_release_flavor(repo_root, release, source_sha, flavor):
    """Clean-build and export one flavor after trusted pre/post attestation."""
    if flavor not in FLAVOR_FLAGS:
        raise ValueError("unknown firmware flavor: " + flavor)
    repo_root = Path(repo_root).resolve()
    build_root = repo_root / "firmware/meshtastic-firmware"
    identity = preflight_release(repo_root, release, source_sha)

    # Fixed trusted launcher — never PATH-resolved. Its bytes are covered by the toolchain
    # lock (platformio-core-venv tree), which preflight_release just attested.
    pio = _trusted_executable(TRUSTED_PIO, "pio")
    child_env = _release_environment(release, source_sha, flavor)

    command = [pio, "run", "-e", "tracker-t1000-e"]
    subprocess.run(command + ["-t", "clean"], cwd=build_root, env=child_env, check=True)
    preflight_release(repo_root, release, source_sha)
    subprocess.run(command, cwd=build_root, env=child_env, check=True)
    preflight_release(repo_root, release, source_sha)

    product_dir = build_root / ".pio/build/tracker-t1000-e"
    uf2 = product_dir / "firmware.uf2"
    hex_file = product_dir / "firmware.hex"
    if not hex_file.is_file() or hex_file.stat().st_size == 0:
        raise RuntimeError("release build did not produce firmware.hex")
    _validated_uf2_contains_identity(repo_root, uf2, identity)

    output_dir = repo_root / "firmware/build-out"
    output_dir.mkdir(parents=True, exist_ok=True)
    output_uf2 = output_dir / "{}.uf2".format(flavor)
    output_hex = output_dir / "{}.hex".format(flavor)
    shutil.copy2(uf2, output_uf2)
    shutil.copy2(hex_file, output_hex)
    print("{}: {} -> {}".format(flavor, identity, output_uf2))
    return output_uf2, output_hex


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--release", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--flavor", required=True, choices=sorted(FLAVOR_FLAGS))
    args = parser.parse_args(argv)
    repo_root = Path(__file__).resolve().parents[1]
    build_release_flavor(repo_root, args.release, args.source_sha, args.flavor)


if __name__ == "__main__":
    main()
