"""Offline startup checks using the real update, renderer and dnsmasq parser."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ENTRYPOINT = PROJECT_ROOT / "scripts" / "entrypoint.sh"


class EntrypointTests(unittest.TestCase):
    def setUp(self):
        self.dnsmasq = shutil.which("dnsmasq")
        self.mkdir = shutil.which("mkdir")
        if not self.dnsmasq:
            self.skipTest("dnsmasq is required for startup validation")
        temporary = tempfile.TemporaryDirectory(prefix="dnsmasq-entrypoint-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.conf = self.root / "data with spaces"
        self.upstreams = self.root / "upstreams with spaces"
        self.scripts = self.root / "scripts with spaces"
        self.bin = self.root / "bin"
        for directory in (self.conf, self.upstreams, self.scripts, self.bin):
            directory.mkdir()
        self.cache = self.conf / "gfw.conf"
        self.active = self.conf / "servers.conf"
        self.custom = self.upstreams / "custom.conf"
        self.generator_log = self.root / "downloads.log"
        self.guard_log = self.root / "unexpected-startup.log"
        for name in ("update.sh", "reload.sh"):
            (self.scripts / name).symlink_to(PROJECT_ROOT / "scripts" / name)
        self.env = os.environ.copy()
        self.env.update(
            DNSMASQ_CONF_DIR=str(self.conf),
            DNSMASQ_SCRIPT_DIR=str(self.scripts),
            DNSMASQ_RUNTIME_ENV=str(self.root / "runtime.env"),
            DNSMASQ_PID_FILE=str(self.root / "dnsmasq.pid"),
            UPSTREAM_RULES_DIR=str(self.upstreams),
            GFW_UPSTREAM_IP="198.51.100.53",
            GFW_UPSTREAM_PORT="53",
            DEFAULT_UPSTREAM="192.0.2.53",
            PATH=str(self.bin) + os.pathsep + os.environ.get("PATH", os.defpath),
            TEST_ROOT=str(self.root),
            TEST_GENERATOR_LOG=str(self.generator_log),
            TEST_GUARD_LOG=str(self.guard_log),
            TEST_REAL_DNSMASQ=self.dnsmasq,
            TEST_REAL_MKDIR=self.mkdir,
        )
        self._executable(
            self.scripts / "gfwlist2dnsmasq.sh",
            """import os, pathlib, sys
with pathlib.Path(os.environ['TEST_GENERATOR_LOG']).open('a') as log:
    log.write('download\\n')
args = sys.argv[1:]
pathlib.Path(args[args.index('-o') + 1]).write_text(
    'server=/downloaded.example/198.51.100.53#53\\n')
""",
        )
        # A regression must never progress into the host's cron or daemon setup.
        # These guards also make an unexpected successful validation fail the test.
        self._executable(
            self.scripts / "watch-upstreams.sh",
            """import os, pathlib
with pathlib.Path(os.environ['TEST_GUARD_LOG']).open('a') as log:
    log.write('watcher started\\n')
raise SystemExit(97)
""",
        )
        self._executable(
            self.bin / "mkdir",
            """import os, pathlib, subprocess, sys
root = pathlib.Path(os.environ['TEST_ROOT']).resolve()
try:
    for argument in sys.argv[1:]:
        if argument.startswith('-'):
            continue
        pathlib.Path(argument).resolve().relative_to(root)
except ValueError:
    with pathlib.Path(os.environ['TEST_GUARD_LOG']).open('a') as log:
        log.write('mkdir outside fixture: ' + repr(sys.argv[1:]) + '\\n')
    raise SystemExit(97)
raise SystemExit(subprocess.run(
    [os.environ['TEST_REAL_MKDIR'], *sys.argv[1:]]).returncode)
""",
        )
        self._executable(
            self.bin / "dnsmasq",
            """import os, pathlib, subprocess, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ['TEST_ROOT']).resolve()
try:
    assert '--test' in args
    configs = [arg.split('=', 1)[1] for arg in args
               if arg.startswith('--conf-file=')]
    assert configs
    for config in configs:
        pathlib.Path(config).resolve().relative_to(root)
except (AssertionError, ValueError):
    with pathlib.Path(os.environ['TEST_GUARD_LOG']).open('a') as log:
        log.write('unexpected dnsmasq invocation: ' + repr(args) + '\\n')
    raise SystemExit(97)
raise SystemExit(subprocess.run(
    [os.environ['TEST_REAL_DNSMASQ'], *args]).returncode)
""",
        )

    def _executable(self, path, source):
        path.write_text("#!" + sys.executable + "\n" + source)
        path.chmod(0o755)

    def _assert_two_failed_starts_without_download(self, expected_error):
        results = []
        for _ in range(2):
            result = subprocess.run(
                ["bash", str(ENTRYPOINT)],
                cwd=PROJECT_ROOT,
                env=self.env,
                capture_output=True,
                text=True,
                timeout=10,
            )
            output = result.stdout + result.stderr
            results.append(output)
            self.assertNotEqual(result.returncode, 0, output)
            self.assertNotEqual(result.returncode, 97, output)
            self.assertIn(expected_error, output)
            self.assertFalse(self.guard_log.exists(), output)
        downloads = (
            len(self.generator_log.read_text().splitlines())
            if self.generator_log.exists() else 0
        )
        self.assertEqual(
            downloads, 0,
            f"Invalid startup downloaded {downloads} times across two starts:\n"
            + "\n".join(results),
        )
        self.assertFalse(self.active.exists())

    def _reset_cache(self, initial_cache):
        self.cache.unlink(missing_ok=True)
        self.generator_log.unlink(missing_ok=True)
        if initial_cache == "empty":
            self.cache.touch()

    def test_unsupported_initial_manual_rules_do_not_download_on_restarts(self):
        self.custom.write_text("address=/example.com/192.0.2.1\n")
        for initial_cache in ("missing", "empty"):
            with self.subTest(initial_cache=initial_cache):
                self._reset_cache(initial_cache)
                self._assert_two_failed_starts_without_download(
                    "only server= and rev-server= are supported")

    def test_invalid_initial_server_syntax_does_not_download_on_restarts(self):
        self.custom.write_text("server=/example.com/203.0.113.53#notaport\n")
        for initial_cache in ("missing", "empty"):
            with self.subTest(initial_cache=initial_cache):
                self._reset_cache(initial_cache)
                self._assert_two_failed_starts_without_download("bad port")

    def test_missing_initial_manual_directory_does_not_download_on_restarts(self):
        self.upstreams.rmdir()
        for initial_cache in ("missing", "empty"):
            with self.subTest(initial_cache=initial_cache):
                self._reset_cache(initial_cache)
                self._assert_two_failed_starts_without_download(
                    "upstream rules directory is missing")

    def test_invalid_manual_rules_preserve_existing_cache_without_download(self):
        original = "server=/cached.example/198.51.100.53#53\n"
        self.cache.write_text(original)
        self.custom.write_text("cache-size=2000\n")
        self._assert_two_failed_starts_without_download(
            "only server= and rev-server= are supported")
        self.assertEqual(self.cache.read_text(), original)


if __name__ == "__main__":
    unittest.main()
