"""Fail-closed release identity for tracker firmware builds.

Meshtastic's device metadata reserves 18 bytes for ``firmware_version`` (17 visible
characters plus NUL). Development builds keep the upstream version. A release build sets
both ``TRACKER_RELEASE`` and ``TRACKER_SOURCE_SHA`` and receives
``vX.Y.<outer-sha8>`` only after this module proves both:

* the requested SHA is the clean outer repository HEAD; and
* the ignored Meshtastic build clone is exactly the tracked export + vendor patch; and
* every resolved library input under ``.pio/libdeps/tracker-t1000-e`` matches the tracked
  path-and-content fingerprint in ``firmware/platformio-dependencies.lock.json``.

The second check matters because PlatformIO compiles the ignored clone, not ``firmware/src``
directly. The dependency check closes the same gap for PlatformIO's ignored library cache.
Compiler outputs under ``.pio/build`` and the external toolchain remain outside the source
identity; release builds still validate the produced UF2/DFU payloads separately.
"""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess


FIRMWARE_BASE_TAG = "v2.7.15.567b8ea"
_PATCH_HEADER = re.compile(rb"^diff --git a/([^ \r\n]+) b/([^ \r\n]+)$", re.MULTILINE)
_DEPENDENCY_LOCK_ALGORITHM = "sha256-path-content-v1"
_DEPENDENCY_ENVIRONMENT = "tracker-t1000-e"


def _git_environment():
    clean = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    clean["GIT_CONFIG_NOSYSTEM"] = "1"
    clean["GIT_CONFIG_GLOBAL"] = os.devnull
    return clean


def _git_paths(build_root, args):
    raw = subprocess.check_output(
        ["git", "-C", str(build_root), *args],
        env=_git_environment(),
    )
    return {item.decode("utf-8") for item in raw.split(b"\0") if item}


def _patch_paths(patch):
    paths = set()
    for left_raw, right_raw in _PATCH_HEADER.findall(patch):
        left = left_raw.decode("utf-8")
        right = right_raw.decode("utf-8")
        if left != right:
            raise RuntimeError("firmware vendor patch may not rename build-tree files")
        path = PurePosixPath(left)
        if path.is_absolute() or ".." in path.parts:
            raise RuntimeError("firmware vendor patch contains an unsafe path")
        paths.add(left)
    if patch.strip() and not paths:
        raise RuntimeError("firmware vendor patch has no parseable file headers")
    return paths


def _overlay_files(repo_root):
    tracked = subprocess.check_output(
        [
            "git",
            "-C",
            str(repo_root),
            "ls-files",
            "-z",
            "--",
            "firmware/src",
        ],
        env=_git_environment(),
    )
    overlays = {}
    prefix = "firmware/src/"
    for raw in tracked.split(b"\0"):
        if not raw:
            continue
        outer_path = raw.decode("utf-8")
        if not outer_path.startswith(prefix):
            raise RuntimeError("unexpected tracked firmware export path: " + outer_path)
        overlays["src/" + outer_path[len(prefix) :]] = Path(repo_root) / outer_path

    overlays["bin/readprops.py"] = (
        Path(repo_root) / "firmware/vendor/bin/readprops.py"
    )
    overlays["patch_bluefruit_ext.py"] = (
        Path(repo_root) / "firmware/patch_bluefruit_ext.py"
    )
    return overlays


def _allowed_ignored_build_output(path):
    # A directory name is not evidence that its contents are harmless: PlatformIO's
    # recursive source filter will still compile e.g. src/__pycache__/injected.cpp.
    # Dependency inputs under .pio/libdeps are admitted separately, one exact locked path
    # at a time. Python bytecode is executable input, not harmless output: a valid cached
    # readprops.pyc can run before the source attestor. Only compiler outputs are generic.
    return path.startswith(".pio/build/")


def _dependency_tree_fingerprint(root):
    """Return a path-sensitive content fingerprint and the exact admitted file set."""
    root = Path(root)
    if not root.is_dir() or root.is_symlink():
        raise RuntimeError("PlatformIO dependency tree is missing or is not a directory")

    digest = hashlib.sha256()
    relative_files = []
    paths = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
    for path in paths:
        relative = path.relative_to(root)
        # A dependency installed from Git may retain repository metadata. Git internals are
        # not compiler inputs; every file outside that directory remains locked below.
        if ".git" in relative.parts:
            continue
        if path.is_symlink():
            raise RuntimeError(
                "PlatformIO dependency tree contains a symlink: " + relative.as_posix()
            )
        if path.is_dir():
            continue
        if not path.is_file():
            raise RuntimeError(
                "PlatformIO dependency tree contains a non-regular file: "
                + relative.as_posix()
            )
        relative_bytes = relative.as_posix().encode("utf-8")
        content = path.read_bytes()
        digest.update(len(relative_bytes).to_bytes(4, "big"))
        digest.update(relative_bytes)
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
        relative_files.append(relative.as_posix())
    return len(relative_files), digest.hexdigest(), relative_files


def _attest_dependencies(repo_root, build_root):
    """Bind every resolved PlatformIO library file to the tracked dependency lock."""
    lock_path = Path(repo_root) / "firmware/platformio-dependencies.lock.json"
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        if set(lock) != {"algorithm", "environments"}:
            raise ValueError
        if lock["algorithm"] != _DEPENDENCY_LOCK_ALGORITHM:
            raise ValueError
        environments = lock["environments"]
        if set(environments) != {_DEPENDENCY_ENVIRONMENT}:
            raise ValueError
        expected = environments[_DEPENDENCY_ENVIRONMENT]
        if set(expected) != {"file_count", "sha256"}:
            raise ValueError
        expected_count = expected["file_count"]
        expected_digest = expected["sha256"]
        if (
            type(expected_count) is not int
            or expected_count < 1
            or not isinstance(expected_digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", expected_digest)
        ):
            raise ValueError
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as error:
        raise RuntimeError("tracked PlatformIO dependency lock is missing or malformed") from error

    dependency_root = (
        Path(build_root) / ".pio/libdeps" / _DEPENDENCY_ENVIRONMENT
    )
    actual_count, actual_digest, relative_files = _dependency_tree_fingerprint(
        dependency_root
    )
    if actual_count != expected_count or actual_digest != expected_digest:
        raise RuntimeError(
            "PlatformIO dependency tree differs from tracked lock "
            "(expected {} files {}, got {} files {})".format(
                expected_count,
                expected_digest,
                actual_count,
                actual_digest,
            )
        )
    prefix = ".pio/libdeps/" + _DEPENDENCY_ENVIRONMENT + "/"
    admitted = {prefix + relative for relative in relative_files}
    # `git ls-files --others --ignored` reports a nested Git dependency as one directory
    # entry instead of enumerating its files. Admit only parent directories proven to contain
    # locked files; an added dependency or file still changes the fingerprint above.
    for relative in relative_files:
        for parent in PurePosixPath(relative).parents:
            if parent != PurePosixPath("."):
                admitted.add(prefix + parent.as_posix() + "/")
    return admitted


def attest_build_tree(repo_root, build_root):
    """Prove the ignored clone is exactly the tracked fork representation."""
    repo_root = Path(repo_root).resolve()
    build_root = Path(build_root).resolve()
    if not (build_root / ".git").exists():
        raise RuntimeError("firmware build clone is missing or is not a Git checkout")

    try:
        subprocess.check_output(
            [
                "git",
                "-C",
                str(build_root),
                "rev-parse",
                "--verify",
                FIRMWARE_BASE_TAG + "^{commit}",
            ],
            env=_git_environment(),
        )
    except subprocess.CalledProcessError as error:
        raise RuntimeError(
            "firmware build clone is missing base tag " + FIRMWARE_BASE_TAG
        ) from error

    patch_path = repo_root / "firmware/meshtastic-fork.patch"
    try:
        expected_patch = patch_path.read_bytes()
    except OSError as error:
        raise RuntimeError("tracked firmware vendor patch is missing") from error
    vendor_paths = _patch_paths(expected_patch)
    if vendor_paths:
        actual_patch = subprocess.check_output(
            [
                "git",
                "-C",
                str(build_root),
                "diff",
                "--no-ext-diff",
                "--binary",
                "--no-renames",
                FIRMWARE_BASE_TAG,
                "--",
                *sorted(vendor_paths),
            ],
            env=_git_environment(),
        )
    else:
        actual_patch = b""
    if actual_patch != expected_patch:
        raise RuntimeError(
            "firmware build clone vendor edits do not match meshtastic-fork.patch"
        )

    overlays = _overlay_files(repo_root)
    for relative, expected in overlays.items():
        actual = build_root / relative
        if (
            not expected.is_file()
            or expected.is_symlink()
            or not actual.is_file()
            or actual.is_symlink()
        ):
            raise RuntimeError(
                "firmware build clone export is missing or not a regular file: "
                + relative
            )
        if actual.read_bytes() != expected.read_bytes():
            raise RuntimeError(
                "firmware build clone export differs from tracked source: " + relative
            )

    allowed = vendor_paths | set(overlays)
    changed = _git_paths(
        build_root,
        [
            "diff",
            "--name-only",
            "--no-renames",
            "-z",
            FIRMWARE_BASE_TAG,
            "--",
        ],
    )
    untracked = _git_paths(
        build_root, ["ls-files", "--others", "--exclude-standard", "-z"]
    )
    unexpected = sorted((changed | untracked) - allowed)
    if unexpected:
        raise RuntimeError(
            "firmware build clone has changes outside the tracked fork: "
            + ", ".join(unexpected[:8])
        )

    dependency_files = _attest_dependencies(repo_root, build_root)
    ignored = _git_paths(
        build_root,
        ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"],
    )
    unexpected_ignored = sorted(
        path
        for path in ignored
        if path not in dependency_files and not _allowed_ignored_build_output(path)
    )
    if unexpected_ignored:
        raise RuntimeError(
            "firmware build clone has unexpected ignored files: "
            + ", ".join(unexpected_ignored[:8])
        )


def tracker_release_version(repo_root, environ=None, build_root=None):
    """Return a source-attested release identity, or ``None`` for a development build."""
    env = os.environ if environ is None else environ
    release = env.get("TRACKER_RELEASE")
    source = env.get("TRACKER_SOURCE_SHA")
    if not release and not source:
        return None
    if not release or not source:
        raise RuntimeError("TRACKER_RELEASE and TRACKER_SOURCE_SHA must be set together")
    if not re.fullmatch(r"v[0-9]+\.[0-9]+(?:\.[0-9]+)?", release):
        raise RuntimeError("TRACKER_RELEASE must look like v4.4")
    if not re.fullmatch(r"[0-9a-fA-F]{7,40}", source):
        raise RuntimeError("TRACKER_SOURCE_SHA must be a 7-40 digit Git SHA")

    actual = subprocess.check_output(
        ["git", "-C", repo_root, "rev-parse", "HEAD"],
        text=True,
        env=_git_environment(),
    ).strip().lower()
    if not actual.startswith(source.lower()):
        raise RuntimeError(
            "TRACKER_SOURCE_SHA {} is not outer repository HEAD {}".format(source, actual)
        )
    status = subprocess.check_output(
        [
            "git",
            "-C",
            repo_root,
            "status",
            "--porcelain",
            "--untracked-files=normal",
        ],
        text=True,
        env=_git_environment(),
    )
    if status.strip():
        raise RuntimeError("tracker release builds require a clean outer repository")

    if build_root is None:
        build_root = Path(repo_root) / "firmware/meshtastic-firmware"
    attest_build_tree(repo_root, build_root)

    identity = "{}.{}".format(release, actual[:8])
    if len(identity) > 17:
        raise RuntimeError(
            "tracker release identity {!r} exceeds firmware_version's "
            "17-character limit".format(identity)
        )
    return identity
