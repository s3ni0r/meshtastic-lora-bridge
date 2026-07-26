"""Fail-closed release identity for tracker firmware builds.

Meshtastic's device metadata reserves 18 bytes for ``firmware_version`` (17 visible
characters plus NUL). Development builds keep the upstream version. A release build sets
both ``TRACKER_RELEASE`` and ``TRACKER_SOURCE_SHA`` and receives
``vX.Y.<outer-sha8>`` only after this module proves both:

* the requested SHA is the clean outer repository HEAD; and
* the ignored Meshtastic build clone is exactly the tracked export + vendor patch, measured
  against the PINNED vendor commit OID (never the movable tag name); and
* every resolved library input under ``.pio/libdeps/tracker-t1000-e`` matches the tracked
  path-and-content fingerprint in ``firmware/platformio-dependencies.lock.json``; and
* every external PlatformIO input tree (platform, framework, toolchain, nrfutil, and the
  PlatformIO core venv that supplies ``pio``) matches the tracked fingerprint in
  ``firmware/platformio-toolchain.lock.json`` — after purging derived Python bytecode,
  which is executable input that cannot be content-locked (``.pyc`` embeds mtimes).

The clone check matters because PlatformIO compiles the ignored clone, not ``firmware/src``
directly; the dependency and toolchain checks close the same gap for every ignored cache
the build executes or compiles from. Every subprocess here runs the PINNED system Git —
a PATH-selected ``git`` is itself unattested input. Compiler outputs under ``.pio/build``
remain outside the source identity; release builds still validate the produced UF2/DFU
payloads separately. The toolchain lock is machine-local by design (absolute roots under
``~``): releases are cut on the bench machine, and a different machine fails closed until
it deliberately regenerates and reviews the lock.

Regenerate locks (review the diff before committing!):

    python3 -I firmware/release_identity.py write-toolchain-lock
    python3 -I firmware/release_identity.py write-dependencies-lock
"""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess


FIRMWARE_BASE_TAG = "v2.7.15.567b8ea"  # human-readable name; the OID below is authoritative
# Full immutable object id of the vendor base. Tags are movable refs — the patch, the drop-in
# overlay and every "unexpected change" diff are measured against THIS commit, so a
# re-pointed tag can never silently shift the attested baseline. Keep in sync with
# apply-fork.sh BASE_OID when bumping the vendor base.
FIRMWARE_BASE_COMMIT = "567b8ea1c2b2d100c24b0d6cbc437ec89fae0a56"
# The one Git this module will execute. /usr/bin/git is the Apple-managed CLT shim — not
# user-writable without root — whereas a bare "git" resolves through the caller's PATH,
# which is exactly the injection surface a release attestor must not have.
TRUSTED_GIT = "/usr/bin/git"
_PATCH_HEADER = re.compile(rb"^diff --git a/([^ \r\n]+) b/([^ \r\n]+)$", re.MULTILINE)
_DEPENDENCY_LOCK_ALGORITHM = "sha256-path-content-v1"
_DEPENDENCY_ENVIRONMENT = "tracker-t1000-e"
_TOOLCHAIN_LOCK_ALGORITHM = "sha256-path-content-symlink-v1"
# External executable/compiled inputs of the tracker-t1000-e build, locked by content.
# Roots are recorded with a leading ~ and expanded at attestation time.
TOOLCHAIN_TREES = {
    "platform-nordicnrf52": "~/.platformio/platforms/nordicnrf52",
    "framework-arduinoadafruitnrf52": "~/.platformio/packages/framework-arduinoadafruitnrf52",
    "toolchain-gccarmnoneeabi": "~/.platformio/packages/toolchain-gccarmnoneeabi",
    "tool-adafruit-nrfutil": "~/.platformio/packages/tool-adafruit-nrfutil",
    "platformio-core-venv": "~/.local/pipx/venvs/platformio",
}


def _git_environment():
    clean = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    clean["GIT_CONFIG_NOSYSTEM"] = "1"
    clean["GIT_CONFIG_GLOBAL"] = os.devnull
    return clean


def _git(args, **kwargs):
    """Run the pinned system Git — never a PATH-resolved one."""
    if not os.path.isfile(TRUSTED_GIT):
        raise RuntimeError("trusted git executable missing: " + TRUSTED_GIT)
    return subprocess.check_output([TRUSTED_GIT, *args], env=_git_environment(), **kwargs)


def _git_paths(build_root, args):
    raw = _git(["-C", str(build_root), *args])
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
    tracked = _git(["-C", str(repo_root), "ls-files", "-z", "--", "firmware/src"])
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


def _purge_bytecode(root):
    """Delete derived Python bytecode under ``root``. ``.pyc`` embeds source mtimes, so it
    cannot be content-locked — and a stale/poisoned cache is executable input, so it may not
    survive either. Deleting is safe (regenerated outside release runs) and failures here
    fail the attestation rather than being skipped."""
    root = Path(root)
    removed = 0
    for path in sorted(root.rglob("*"), reverse=True):
        try:
            if path.is_symlink():
                continue
            if path.is_file() and (path.suffix in (".pyc", ".pyo") or "__pycache__" in path.parts):
                path.unlink()
                removed += 1
            elif path.is_dir() and path.name == "__pycache__" and not any(path.iterdir()):
                path.rmdir()
        except OSError as error:
            raise RuntimeError(
                "cannot purge derived bytecode {}: {}".format(path, error)
            ) from error
    return removed


def _external_tree_fingerprint(root):
    """Path-sensitive content fingerprint for an EXTERNAL input tree (platform, framework,
    toolchain, venv). Unlike the libdeps fingerprint this must tolerate symlinks — GCC
    toolchains ship them — so a symlink is hashed as its literal target string, never
    followed (a retargeted link therefore changes the digest). ``__pycache__`` content is
    excluded because :func:`_purge_bytecode` removes it before hashing."""
    root = Path(root)
    if not root.is_dir() or root.is_symlink():
        raise RuntimeError("external input tree is missing or not a directory: " + str(root))

    digest = hashlib.sha256()
    file_count = 0
    paths = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
    for path in paths:
        relative = path.relative_to(root)
        if ".git" in relative.parts or "__pycache__" in relative.parts:
            continue
        relative_bytes = relative.as_posix().encode("utf-8")
        if path.is_symlink():
            target = os.readlink(path).encode("utf-8")
            digest.update(b"L")
            digest.update(len(relative_bytes).to_bytes(4, "big"))
            digest.update(relative_bytes)
            digest.update(len(target).to_bytes(4, "big"))
            digest.update(target)
            file_count += 1
        elif path.is_dir():
            continue
        elif path.is_file():
            content = path.read_bytes()
            digest.update(b"F")
            digest.update(len(relative_bytes).to_bytes(4, "big"))
            digest.update(relative_bytes)
            digest.update(len(content).to_bytes(8, "big"))
            digest.update(content)
            file_count += 1
        else:
            raise RuntimeError(
                "external input tree contains a non-regular file: " + relative.as_posix()
            )
    return file_count, digest.hexdigest()


def _toolchain_lock_path(repo_root):
    return Path(repo_root) / "firmware/platformio-toolchain.lock.json"


def toolchain_lock_snapshot():
    """Purge bytecode, then fingerprint every locked external tree (current machine state)."""
    trees = {}
    for name, recorded_root in sorted(TOOLCHAIN_TREES.items()):
        root = Path(os.path.expanduser(recorded_root))
        _purge_bytecode(root)
        file_count, digest = _external_tree_fingerprint(root)
        trees[name] = {"root": recorded_root, "file_count": file_count, "sha256": digest}
    return {"algorithm": _TOOLCHAIN_LOCK_ALGORITHM, "trees": trees}


def attest_toolchain(repo_root):
    """Bind the external PlatformIO input trees to the tracked toolchain lock."""
    lock_path = _toolchain_lock_path(repo_root)
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        if set(lock) != {"algorithm", "trees"}:
            raise ValueError
        if lock["algorithm"] != _TOOLCHAIN_LOCK_ALGORITHM:
            raise ValueError
        expected_trees = lock["trees"]
        if set(expected_trees) != set(TOOLCHAIN_TREES):
            raise ValueError
        for name, entry in expected_trees.items():
            if set(entry) != {"root", "file_count", "sha256"}:
                raise ValueError
            if entry["root"] != TOOLCHAIN_TREES[name]:
                raise ValueError
            if type(entry["file_count"]) is not int or entry["file_count"] < 1:
                raise ValueError
            if not isinstance(entry["sha256"], str) or not re.fullmatch(
                r"[0-9a-f]{64}", entry["sha256"]
            ):
                raise ValueError
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as error:
        raise RuntimeError(
            "tracked PlatformIO toolchain lock is missing or malformed "
            "(generate with: python3 -I firmware/release_identity.py write-toolchain-lock)"
        ) from error

    actual = toolchain_lock_snapshot()["trees"]
    for name in sorted(TOOLCHAIN_TREES):
        expected_entry = expected_trees[name]
        actual_entry = actual[name]
        if (
            actual_entry["file_count"] != expected_entry["file_count"]
            or actual_entry["sha256"] != expected_entry["sha256"]
        ):
            raise RuntimeError(
                "external input tree {} differs from tracked toolchain lock "
                "(expected {} files {}, got {} files {})".format(
                    name,
                    expected_entry["file_count"],
                    expected_entry["sha256"],
                    actual_entry["file_count"],
                    actual_entry["sha256"],
                )
            )


def attest_build_tree(repo_root, build_root):
    """Prove the ignored clone is exactly the tracked fork representation."""
    repo_root = Path(repo_root).resolve()
    build_root = Path(build_root).resolve()
    if not (build_root / ".git").exists():
        raise RuntimeError("firmware build clone is missing or is not a Git checkout")

    # The pinned OID must exist as a commit object; the tag NAME is checked only so a moved
    # tag is noticed, never trusted for measurement (every diff below uses the OID).
    try:
        object_type = _git(
            ["-C", str(build_root), "cat-file", "-t", FIRMWARE_BASE_COMMIT],
            text=True,
        ).strip()
    except subprocess.CalledProcessError as error:
        raise RuntimeError(
            "firmware build clone is missing pinned base commit " + FIRMWARE_BASE_COMMIT
        ) from error
    if object_type != "commit":
        raise RuntimeError(
            "pinned base {} is a {}, not a commit".format(FIRMWARE_BASE_COMMIT, object_type)
        )
    try:
        tag_target = _git(
            ["-C", str(build_root), "rev-parse", "--verify", FIRMWARE_BASE_TAG + "^{commit}"],
            text=True,
        ).strip().lower()
    except subprocess.CalledProcessError as error:
        raise RuntimeError(
            "firmware build clone is missing base tag " + FIRMWARE_BASE_TAG
        ) from error
    if tag_target != FIRMWARE_BASE_COMMIT:
        raise RuntimeError(
            "base tag {} points at {}, not the pinned OID {} — a movable tag may not "
            "redefine the vendor base".format(FIRMWARE_BASE_TAG, tag_target, FIRMWARE_BASE_COMMIT)
        )

    patch_path = repo_root / "firmware/meshtastic-fork.patch"
    try:
        expected_patch = patch_path.read_bytes()
    except OSError as error:
        raise RuntimeError("tracked firmware vendor patch is missing") from error
    vendor_paths = _patch_paths(expected_patch)
    if vendor_paths:
        actual_patch = _git(
            [
                "-C",
                str(build_root),
                "diff",
                "--no-ext-diff",
                "--binary",
                "--no-renames",
                FIRMWARE_BASE_COMMIT,
                "--",
                *sorted(vendor_paths),
            ]
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
            FIRMWARE_BASE_COMMIT,
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

    actual = _git(["-C", str(repo_root), "rev-parse", "HEAD"], text=True).strip().lower()
    if not actual.startswith(source.lower()):
        raise RuntimeError(
            "TRACKER_SOURCE_SHA {} is not outer repository HEAD {}".format(source, actual)
        )
    status = _git(
        ["-C", str(repo_root), "status", "--porcelain", "--untracked-files=normal"],
        text=True,
    )
    if status.strip():
        raise RuntimeError("tracker release builds require a clean outer repository")

    if build_root is None:
        build_root = Path(repo_root) / "firmware/meshtastic-firmware"
    attest_build_tree(repo_root, build_root)
    attest_toolchain(repo_root)

    identity = "{}.{}".format(release, actual[:8])
    if len(identity) > 17:
        raise RuntimeError(
            "tracker release identity {!r} exceeds firmware_version's "
            "17-character limit".format(identity)
        )
    return identity


def _write_lock(path, payload):
    path = Path(path)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("wrote", path)


def main(argv):
    """Lock (re)generation only — attestation runs through tracker_release_version()."""
    repo_root = Path(__file__).resolve().parents[1]
    if argv == ["write-toolchain-lock"]:
        _write_lock(_toolchain_lock_path(repo_root), toolchain_lock_snapshot())
        return 0
    if argv == ["write-dependencies-lock"]:
        dependency_root = (
            repo_root / "firmware/meshtastic-firmware/.pio/libdeps" / _DEPENDENCY_ENVIRONMENT
        )
        count, digest, _ = _dependency_tree_fingerprint(dependency_root)
        _write_lock(
            repo_root / "firmware/platformio-dependencies.lock.json",
            {
                "algorithm": _DEPENDENCY_LOCK_ALGORITHM,
                "environments": {
                    _DEPENDENCY_ENVIRONMENT: {"file_count": count, "sha256": digest}
                },
            },
        )
        return 0
    print(
        "usage: python3 -I firmware/release_identity.py "
        "{write-toolchain-lock | write-dependencies-lock}",
    )
    return 2


if __name__ == "__main__":
    import sys

    if not sys.flags.isolated:
        raise SystemExit("ERROR: run release_identity.py with `python3 -I` (isolated mode)")
    raise SystemExit(main(sys.argv[1:]))
