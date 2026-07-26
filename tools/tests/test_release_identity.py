import json
import os
import py_compile
import subprocess
import tempfile
import unittest
from pathlib import Path
import sys


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "firmware"))
import release_identity  # noqa: E402
from release_identity import (  # noqa: E402
    _dependency_tree_fingerprint,
    toolchain_lock_snapshot,
    tracker_release_version,
)
from release_build import _release_environment, preflight_release  # noqa: E402
import release_build  # noqa: E402


class ReleaseIdentityTests(unittest.TestCase):
    # The toolchain lock fingerprints the REAL machine's PlatformIO trees; snapshot once for
    # the whole suite (it also purges derived bytecode, which is idempotent).
    TOOLCHAIN_SNAPSHOT = None

    @classmethod
    def setUpClass(cls):
        cls.TOOLCHAIN_SNAPSHOT = json.dumps(toolchain_lock_snapshot()) + "\n"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name)
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(
            ["git", "-C", str(self.repo), "config", "user.email", "test@example.invalid"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(self.repo), "config", "user.name", "Release Test"],
            check=True,
        )

        # Model the real two-tree layout: the outer repository tracks a patch and
        # project-owned overlays, while PlatformIO compiles an ignored inner checkout.
        firmware = self.repo / "firmware"
        self.build = firmware / "meshtastic-firmware"
        (firmware / "src").mkdir(parents=True)
        (firmware / "vendor/bin").mkdir(parents=True)
        (self.build / "src").mkdir(parents=True)
        (self.build / "bin").mkdir()
        subprocess.run(["git", "init", "-q", str(self.build)], check=True)
        subprocess.run(
            ["git", "-C", str(self.build), "config", "user.email", "test@example.invalid"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(self.build), "config", "user.name", "Build Test"],
            check=True,
        )
        (self.build / "src/vendor.cpp").write_text("vendor base\n")
        (self.build / "bin/platformio-custom.py").write_text("vendor bootstrap\n")
        (self.build / ".gitignore").write_text(".pio/\n")
        subprocess.run(
            [
                "git",
                "-C",
                str(self.build),
                "add",
                ".gitignore",
                "bin/platformio-custom.py",
                "src/vendor.cpp",
            ],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(self.build), "commit", "-qm", "vendor base"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(self.build), "tag", "v2.7.15.567b8ea"],
            check=True,
        )

        (self.build / "src/vendor.cpp").write_text("tracked vendor fork\n")
        patch = subprocess.check_output(
            [
                "git",
                "-C",
                str(self.build),
                "diff",
                "--no-ext-diff",
                "--binary",
                "--no-renames",
                "v2.7.15.567b8ea",
                "--",
                "src/vendor.cpp",
            ]
        )
        (firmware / "meshtastic-fork.patch").write_bytes(patch)

        # The fixture vendor repo has its own history: point the pinned base OID at ITS tag
        # target — both in the imported module (direct calls) and in the copies committed to
        # the fixture repo (preflight executes those via `git show`).
        self.vendor_oid = subprocess.check_output(
            ["git", "-C", str(self.build), "rev-parse", "v2.7.15.567b8ea^{commit}"],
            text=True,
        ).strip().lower()
        self._real_base_oid = release_identity.FIRMWARE_BASE_COMMIT
        release_identity.FIRMWARE_BASE_COMMIT = self.vendor_oid

        (firmware / "src/demo.cpp").write_text("tracked overlay\n")
        (firmware / "vendor/bin/readprops.py").write_text("# tracked readprops\n")
        (firmware / "patch_bluefruit_ext.py").write_text("# tracked hook\n")
        (firmware / "release_identity.py").write_bytes(
            (REPO / "firmware/release_identity.py")
            .read_bytes()
            .replace(self._real_base_oid.encode(), self.vendor_oid.encode())
        )
        (firmware / "release_build.py").write_bytes(
            (REPO / "firmware/release_build.py").read_bytes()
        )
        (firmware / "platformio-toolchain.lock.json").write_text(self.TOOLCHAIN_SNAPSHOT)
        (self.build / "src/demo.cpp").write_text("tracked overlay\n")
        (self.build / "bin/readprops.py").write_text("# tracked readprops\n")
        (self.build / "patch_bluefruit_ext.py").write_text("# tracked hook\n")

        self.dependencies = (
            self.build / ".pio/libdeps/tracker-t1000-e/Example/src"
        )
        self.dependencies.mkdir(parents=True)
        (self.dependencies / "dependency.cpp").write_text("void dependency() {}\n")
        count, digest, _ = _dependency_tree_fingerprint(
            self.build / ".pio/libdeps/tracker-t1000-e"
        )
        (firmware / "platformio-dependencies.lock.json").write_text(
            json.dumps(
                {
                    "algorithm": "sha256-path-content-v1",
                    "environments": {
                        "tracker-t1000-e": {
                            "file_count": count,
                            "sha256": digest,
                        }
                    },
                }
            )
            + "\n"
        )

        (self.repo / ".gitignore").write_text("firmware/meshtastic-firmware/\n")
        (self.repo / "source.txt").write_text("source\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(self.repo), "commit", "-qm", "source"], check=True
        )
        self.sha = subprocess.check_output(
            ["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True
        ).strip()

    def tearDown(self):
        release_identity.FIRMWARE_BASE_COMMIT = self._real_base_oid
        self.temp.cleanup()

    def test_development_build_has_no_override(self):
        self.assertIsNone(tracker_release_version(self.repo, {}))

    def test_clean_outer_head_is_stamped(self):
        identity = tracker_release_version(
            self.repo,
            {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": self.sha[:8]},
        )
        self.assertEqual(identity, "v4.4." + self.sha[:8])
        self.assertLessEqual(len(identity), 17)

    def test_inputs_are_paired_and_validated(self):
        with self.assertRaisesRegex(RuntimeError, "set together"):
            tracker_release_version(self.repo, {"TRACKER_RELEASE": "v4.4"})
        with self.assertRaisesRegex(RuntimeError, "look like"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "release-4", "TRACKER_SOURCE_SHA": self.sha[:8]},
            )
        with self.assertRaisesRegex(RuntimeError, "Git SHA"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": "not-a-sha"},
            )

    def test_wrong_or_dirty_source_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "not outer repository HEAD"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": "deadbee"},
            )
        (self.repo / "source.txt").write_text("dirty\n")
        with self.assertRaisesRegex(RuntimeError, "clean outer repository"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": self.sha},
            )

    def test_untracked_source_is_rejected(self):
        (self.repo / "untracked-source.txt").write_text("not committed\n")
        with self.assertRaisesRegex(RuntimeError, "clean outer repository"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": self.sha},
            )

    def test_unexpected_compilable_source_in_ignored_clone_is_rejected(self):
        (self.build / "src/injected.cpp").write_text("void injected() {}\n")
        with self.assertRaisesRegex(RuntimeError, "outside the tracked fork"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": self.sha},
            )

    def test_compilable_source_hidden_in_ignored_cache_dir_is_rejected(self):
        # PlatformIO recursively compiles .cpp files even when an upstream ignore rule hides
        # their directory from normal Git status. The attestor must inspect ignored files by
        # type rather than trusting the __pycache__ directory name.
        (self.build / ".git/info/exclude").write_text("__pycache__/\n")
        hidden = self.build / "src/__pycache__/injected.cpp"
        hidden.parent.mkdir(parents=True)
        hidden.write_text("void hidden_in_cache() {}\n")
        with self.assertRaisesRegex(RuntimeError, "unexpected ignored files"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": self.sha},
            )

    def test_compilable_source_in_dependency_cache_is_rejected(self):
        (self.dependencies / "injected.cpp").write_text("void injected_dependency() {}\n")
        with self.assertRaisesRegex(RuntimeError, "dependency tree differs"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": self.sha},
            )

    def test_trusted_outer_preflight_rejects_tampered_clone_bootstrap(self):
        self.assertEqual(
            preflight_release(self.repo, "v4.4", self.sha),
            "v4.4." + self.sha[:8],
        )

        bootstrap = self.build / "bin/platformio-custom.py"
        bootstrap.write_text("forged bootstrap skips attestation\n")
        with self.assertRaisesRegex(RuntimeError, "outside the tracked fork"):
            preflight_release(self.repo, "v4.4", self.sha)

        bootstrap.write_text("vendor bootstrap\n")
        readprops = self.build / "bin/readprops.py"
        readprops.write_text("# forged release identity\n")
        with self.assertRaisesRegex(RuntimeError, "differs from tracked source"):
            preflight_release(self.repo, "v4.4", self.sha)

    def test_release_environment_rejects_platformio_path_redirects(self):
        poisoned = {
            "PATH": "/usr/bin",
            "PLATFORMIO_SRC_DIR": "/tmp/forged-src",
            "PLATFORMIO_LIBDEPS_DIR": "/tmp/forged-libs",
            "PLATFORMIO_BUILD_DIR": "/tmp/stale-output",
            "PLATFORMIO_EXTRA_SCRIPTS": "/tmp/skip-attestation.py",
            "PLATFORMIO_BUILD_FLAGS": "-DEVIL",
            "PYTHONPATH": "/tmp/import-poison",
            "PYTHONPYCACHEPREFIX": "/tmp/cache-poison",
            "SCONSFLAGS": "--site-dir=/tmp/evil",
            "GIT_DIR": "/tmp/forged-repository",
        }
        gps = _release_environment("v4.4", self.sha, "gps-tag", poisoned)
        # The caller's PATH is never inherited — release children get the fixed system PATH.
        self.assertEqual(gps["PATH"], release_build.RELEASE_PATH)
        self.assertEqual(gps["PLATFORMIO_BUILD_FLAGS"], "-DGPS_TAG")
        self.assertFalse(
            any(
                key.startswith("PLATFORMIO_")
                for key in gps
                if key != "PLATFORMIO_BUILD_FLAGS"
            )
        )
        self.assertEqual(
            {key for key in gps if key.startswith("PYTHON")},
            {"PYTHONDONTWRITEBYTECODE"},
        )
        self.assertFalse(any(key.startswith("SCONS") for key in gps))
        self.assertFalse(any(key.startswith("GIT_") for key in gps))

        base = _release_environment("v4.4", self.sha, "base-plain", poisoned)
        self.assertFalse(any(key.startswith("PLATFORMIO_") for key in base))

    def test_valid_malicious_python_bytecode_cache_is_rejected(self):
        (self.build / ".git/info/exclude").write_text("__pycache__/\n")
        source = self.build / "bin/readprops.py"
        malicious = "raise SystemExit(7)\n"
        self.assertEqual(len(malicious.encode()), source.stat().st_size)
        cache = (
            source.parent
            / "__pycache__"
            / "{}.{}.pyc".format(source.stem, sys.implementation.cache_tag)
        )
        cache.parent.mkdir(parents=True)
        with tempfile.TemporaryDirectory() as scratch:
            malicious_source = Path(scratch) / "readprops.py"
            malicious_source.write_text(malicious)
            source_stat = source.stat()
            os.utime(
                malicious_source,
                ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns),
            )
            py_compile.compile(
                str(malicious_source),
                cfile=str(cache),
                doraise=True,
                invalidation_mode=py_compile.PycInvalidationMode.TIMESTAMP,
            )

        # Prove this is executable cache poison, not inert bytes: normal import accepts it.
        poisoned = subprocess.run(
            [sys.executable, "-X", "pycache_prefix=", "-c", "import readprops"],
            cwd=source.parent,
            check=False,
        )
        self.assertEqual(poisoned.returncode, 7)
        with self.assertRaisesRegex(RuntimeError, "unexpected ignored files"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": self.sha},
            )

    def test_clone_overlay_or_vendor_patch_drift_is_rejected(self):
        (self.build / "src/demo.cpp").write_text("different overlay\n")
        with self.assertRaisesRegex(RuntimeError, "differs from tracked source"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": self.sha},
            )

        (self.build / "src/demo.cpp").write_text("tracked overlay\n")
        (self.build / "src/vendor.cpp").write_text("different vendor fork\n")
        with self.assertRaisesRegex(RuntimeError, "do not match"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": self.sha},
            )

    def test_moved_base_tag_is_rejected(self):
        # A movable tag may not redefine the vendor base: re-point the fixture tag at a new
        # commit while the pinned OID stays where it was.
        (self.build / "src/vendor.cpp").write_text("tracked vendor fork\n")
        subprocess.run(
            ["git", "-C", str(self.build), "commit", "-aqm", "moved base"], check=True
        )
        subprocess.run(
            ["git", "-C", str(self.build), "tag", "-f", "v2.7.15.567b8ea"], check=True
        )
        with self.assertRaisesRegex(RuntimeError, "movable tag may not redefine"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": self.sha},
            )

    def _commit_fixture_change(self, message):
        subprocess.run(["git", "-C", str(self.repo), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", message], check=True)
        self.sha = subprocess.check_output(
            ["git", "-C", str(self.repo), "rev-parse", "HEAD"], text=True
        ).strip()

    def test_missing_or_drifted_toolchain_lock_is_rejected(self):
        # Mutations are COMMITTED so the clean-tree gate passes and the toolchain gate is
        # what actually fires.
        lock_path = self.repo / "firmware/platformio-toolchain.lock.json"
        lock_path.unlink()
        self._commit_fixture_change("drop toolchain lock")
        with self.assertRaisesRegex(RuntimeError, "toolchain lock is missing or malformed"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": self.sha},
            )
        drifted = json.loads(self.TOOLCHAIN_SNAPSHOT)
        drifted["trees"]["toolchain-gccarmnoneeabi"]["sha256"] = "0" * 64
        lock_path.write_text(json.dumps(drifted) + "\n")
        self._commit_fixture_change("drifted toolchain lock")
        with self.assertRaisesRegex(RuntimeError, "differs from tracked toolchain lock"):
            tracker_release_version(
                self.repo,
                {"TRACKER_RELEASE": "v4.4", "TRACKER_SOURCE_SHA": self.sha},
            )

    def test_metadata_field_limit_is_enforced(self):
        with self.assertRaisesRegex(RuntimeError, "17-character limit"):
            tracker_release_version(
                self.repo,
                {
                    "TRACKER_RELEASE": "v123456789.123456789",
                    "TRACKER_SOURCE_SHA": self.sha,
                },
            )


if __name__ == "__main__":
    unittest.main()
