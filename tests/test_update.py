"""Offline regression checks for the download-to-reload handoff in update.sh."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
UPDATE_SCRIPT = PROJECT_ROOT / "scripts" / "update.sh"


class UpdateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="dnsmasq-update-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.conf = self.root / "data with spaces"
        self.scripts = self.root / "scripts with spaces"
        self.conf.mkdir()
        self.scripts.mkdir()
        self.cache = self.conf / "gfw.conf"
        self.active = self.conf / "servers.conf"
        self.old_cache = "server=/old.example/192.0.2.53#53\n"
        self.old_active = "server=/custom.example/203.0.113.53#53\n" + self.old_cache
        self.cache.write_text(self.old_cache)
        self.active.write_text(self.old_active)
        self.generator_log = self.root / "generator.json"
        self.reload_log = self.root / "reload.json"
        self.runtime_env = self.root / "runtime.env"
        self.runtime_env.write_text(
            "export GFW_UPSTREAM_IP=198.51.100.53\n"
            "export GFW_UPSTREAM_PORT=5300\n"
        )
        self.download = (
            "# complete downloaded list\n"
            "server=/google.com/198.51.100.53#5300\n"
            "server=/netflix.com/198.51.100.53#5300\n"
        )
        self.env = os.environ.copy()
        self.env.update(
            DNSMASQ_CONF_DIR=str(self.conf),
            DNSMASQ_SCRIPT_DIR=str(self.scripts),
            DNSMASQ_RUNTIME_ENV=str(self.runtime_env),
            # Cron must use the persisted settings rather than these stale ones.
            GFW_UPSTREAM_IP="192.0.2.99",
            GFW_UPSTREAM_PORT="9999",
            MOCK_GENERATOR_LOG=str(self.generator_log),
            MOCK_RELOAD_LOG=str(self.reload_log),
            MOCK_GENERATOR_EXIT="0",
            MOCK_RELOAD_EXIT="0",
            MOCK_GENERATOR_OUTPUT=self.download,
        )
        self._executable(
            self.scripts / "gfwlist2dnsmasq.sh",
            """import json, os, pathlib, sys
args = sys.argv[1:]
pathlib.Path(os.environ['MOCK_GENERATOR_LOG']).write_text(json.dumps(args))
output = pathlib.Path(args[args.index('-o') + 1])
output.write_text(os.environ['MOCK_GENERATOR_OUTPUT'])
sys.exit(int(os.environ.get('MOCK_GENERATOR_EXIT', '0')))
""",
        )
        self._executable(
            self.scripts / "reload.sh",
            """import json, os, pathlib, sys
args = sys.argv[1:]
staged = pathlib.Path(args[args.index('--gfw-file') + 1])
content = staged.read_text()
pathlib.Path(os.environ['MOCK_RELOAD_LOG']).write_text(
    json.dumps({'args': args, 'content': content}))
status = int(os.environ.get('MOCK_RELOAD_EXIT', '0'))
if status:
    sys.exit(status)
conf = pathlib.Path(os.environ['DNSMASQ_CONF_DIR'])
staged.replace(conf / 'gfw.conf')
(conf / 'servers.conf').write_text(content)
""",
        )

    def _executable(self, path, source):
        path.write_text("#!" + sys.executable + "\n" + source)
        path.chmod(0o755)

    def update(self, *arguments, success=True):
        result = subprocess.run(
            ["bash", str(UPDATE_SCRIPT), *arguments],
            cwd=PROJECT_ROOT,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def assert_previous_rules(self):
        self.assertEqual(self.cache.read_text(), self.old_cache)
        self.assertEqual(self.active.read_text(), self.old_active)

    def test_failed_download_never_reloads_or_publishes_partial_output(self):
        self.env["MOCK_GENERATOR_EXIT"] = "2"
        result = self.update(success=False)
        self.assertEqual(result.returncode, 2)
        self.assertTrue(self.generator_log.exists())
        self.assertFalse(self.reload_log.exists())
        self.assert_previous_rules()

    def test_empty_or_comment_only_download_does_not_replace_rules(self):
        for content in ("", "# downloaded metadata only\n"):
            with self.subTest(content=content):
                self.env["MOCK_GENERATOR_OUTPUT"] = content
                result = self.update(success=False)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(self.reload_log.exists())
                self.assert_previous_rules()

    def test_complete_gfw_list_reaches_reload_without_domain_exclusions(self):
        self.update()
        generator_args = json.loads(self.generator_log.read_text())
        self.assertNotIn("--exclude-domain-file", generator_args)
        self.assertEqual(generator_args[generator_args.index("-d") + 1], "198.51.100.53")
        self.assertEqual(generator_args[generator_args.index("-p") + 1], "5300")
        request = json.loads(self.reload_log.read_text())
        self.assertEqual(request["content"], self.download)
        self.assertIn("server=/netflix.com/", request["content"])
        self.assertEqual(self.cache.read_text(), self.download)

    def test_default_update_delegates_reload_with_staged_cache(self):
        self.update()
        args = json.loads(self.reload_log.read_text())["args"]
        self.assertEqual(args[0], "--gfw-file")
        self.assertEqual(Path(args[1]).parent, self.conf)
        self.assertEqual(len(args), 2)
        self.assertEqual(self.active.read_text(), self.download)

    def test_startup_mode_passes_no_reload_to_common_renderer(self):
        self.update("--no-reload")
        args = json.loads(self.reload_log.read_text())["args"]
        self.assertIn("--no-reload", args)
        self.assertEqual(len(args), 3)

    def test_reload_failure_is_reported_and_keeps_both_previous_files(self):
        self.env["MOCK_RELOAD_EXIT"] = "3"
        result = self.update(success=False)
        self.assertEqual(result.returncode, 3)
        self.assertTrue(self.reload_log.exists())
        self.assert_previous_rules()

    def test_invalid_arguments_fail_before_downloading(self):
        for args in (("--unknown",), ("--no-reload", "extra")):
            with self.subTest(args=args):
                result = self.update(*args, success=False)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(self.generator_log.exists())
                self.assertFalse(self.reload_log.exists())
                self.assert_previous_rules()


if __name__ == "__main__":
    unittest.main()
