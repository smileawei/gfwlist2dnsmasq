"""Offline integration tests for the real renderer and dnsmasq syntax checker."""

import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RELOAD_SCRIPT = PROJECT_ROOT / "scripts" / "reload.sh"
GFW_DNS = "198.51.100.53#5300"
MANUAL_DNS = "203.0.113.53#5353"


class ReloadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="dnsmasq-reload-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.conf = self.root / "data with spaces"
        self.upstreams = self.root / "upstreams with spaces"
        self.conf.mkdir()
        self.upstreams.mkdir()
        self.cache = self.conf / "gfw.conf"
        self.active = self.conf / "servers.conf"
        self.complete_cache = (
            "# complete GFW cache\n"
            f"server=/example.com/{GFW_DNS}\n"
            f"server=/sub.example.com/{GFW_DNS}\n"
            f"server=/notexample.com/{GFW_DNS}\n"
            f"server=/other.example/{GFW_DNS}\n"
        )
        self.cache.write_text(self.complete_cache)
        self.previous_active = "server=/previous.example/192.0.2.53#53\n"
        self.active.write_text(self.previous_active)
        self.custom = self.upstreams / "work DNS.conf"
        self.pid_file = self.root / "dnsmasq.pid"
        self.runtime_env = self.root / "runtime.env"
        self.runtime_env.write_text("")
        self.env = os.environ.copy()
        self.env.update(
            DNSMASQ_CONF_DIR=str(self.conf),
            DNSMASQ_RUNTIME_ENV=str(self.runtime_env),
            UPSTREAM_RULES_DIR=str(self.upstreams),
            DNSMASQ_PID_FILE=str(self.pid_file),
        )

    def reload(self, *arguments, success=True):
        result = subprocess.run(
            ["bash", "-c", 'umask 077; exec bash "$@"', "reload-test",
             str(RELOAD_SCRIPT), *arguments],
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

    def test_manual_rule_replaces_gfw_domain_and_children_with_boundaries(self):
        self.custom.write_text(f"server=/example.com/{MANUAL_DNS}\n")
        self.reload("--no-reload")
        rendered = self.active.read_text()
        self.assertIn(f"server=/example.com/{MANUAL_DNS}\n", rendered)
        self.assertNotIn(f"server=/example.com/{GFW_DNS}\n", rendered)
        self.assertNotIn(f"server=/sub.example.com/{GFW_DNS}\n", rendered)
        self.assertIn(f"server=/notexample.com/{GFW_DNS}\n", rendered)
        self.assertEqual(self.cache.read_text(), self.complete_cache)

    def test_changed_upstream_is_published_without_changing_gfw_cache(self):
        self.custom.write_text(f"server=/example.com/{MANUAL_DNS}\n")
        self.reload("--no-reload")
        self.custom.write_text("server=/example.com/192.0.2.54#5400\n")
        self.reload("--no-reload")
        self.assertIn("server=/example.com/192.0.2.54#5400\n", self.active.read_text())
        self.assertNotIn(MANUAL_DNS, self.active.read_text())
        self.assertEqual(self.cache.read_text(), self.complete_cache)

    def test_deleted_override_restores_complete_gfw_routes_offline(self):
        self.custom.write_text(f"server=/example.com/{MANUAL_DNS}\n")
        self.reload("--no-reload")
        self.custom.unlink()
        self.reload("--no-reload")
        rendered = self.active.read_text()
        self.assertIn(f"server=/example.com/{GFW_DNS}\n", rendered)
        self.assertIn(f"server=/sub.example.com/{GFW_DNS}\n", rendered)
        self.assertNotIn(MANUAL_DNS, rendered)
        self.assertEqual(self.cache.read_text(), self.complete_cache)

    def test_empty_manual_directory_and_empty_gfw_cache_are_valid(self):
        self.reload("--no-reload")
        self.assertIn(f"server=/example.com/{GFW_DNS}\n", self.active.read_text())
        self.cache.write_text("")
        self.reload("--no-reload")
        self.assertFalse(any(line.startswith("server=")
                             for line in self.active.read_text().splitlines()))

    def test_unsupported_manual_directives_preserve_cache_and_active_rules(self):
        staged = self.root / "new GFW.conf"
        staged.write_text("server=/new.example/192.0.2.55#53\n")
        for directive in ("address=/example.com/192.0.2.1\n", "cache-size=2000\n"):
            with self.subTest(directive=directive):
                self.custom.write_text(directive)
                result = self.reload("--no-reload", "--gfw-file", str(staged), success=False)
                self.assertIn("only server= and rev-server=", result.stderr)
                self.assertEqual(self.cache.read_text(), self.complete_cache)
                self.assertEqual(self.active.read_text(), self.previous_active)

    def test_invalid_native_server_syntax_is_rejected_before_publication(self):
        self.custom.write_text("server=/example.com/203.0.113.53#notaport\n")
        staged = self.root / "new GFW.conf"
        staged.write_text("server=/new.example/192.0.2.55#53\n")
        self.reload("--no-reload", "--gfw-file", str(staged), success=False)
        self.assertEqual(self.cache.read_text(), self.complete_cache)
        self.assertEqual(self.active.read_text(), self.previous_active)

    def test_invalid_staged_gfw_does_not_replace_cache_or_active_rules(self):
        staged = self.root / "new GFW.conf"
        for content in ("address=/example.com/192.0.2.1\n", "cache-size=2000\n",
                        "server=/example.com/192.0.2.53#notaport\n"):
            with self.subTest(content=content):
                staged.write_text(content)
                self.reload("--no-reload", "--gfw-file", str(staged), success=False)
                self.assertEqual(self.cache.read_text(), self.complete_cache)
                self.assertEqual(self.active.read_text(), self.previous_active)

    def test_complete_new_cache_is_saved_while_combined_rules_use_manual_upstream(self):
        self.custom.write_text(f"server=/example.com/{MANUAL_DNS}\n")
        staged = self.root / "new GFW.conf"
        complete = self.complete_cache + "server=/new.example/192.0.2.55#53\n"
        staged.write_text(complete)
        self.reload("--no-reload", "--gfw-file", str(staged))
        self.assertEqual(self.cache.read_text(), complete)
        self.assertIn(f"server=/example.com/{MANUAL_DNS}\n", self.active.read_text())
        self.assertNotIn(f"server=/sub.example.com/{GFW_DNS}\n", self.active.read_text())
        self.assertIn("server=/new.example/192.0.2.55#53\n", self.active.read_text())
        self.assertEqual(stat.S_IMODE(self.cache.stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(self.active.stat().st_mode), 0o644)

    def test_native_quotes_crlf_multiple_domains_and_reverse_rules(self):
        self.custom.write_bytes(
            ('  # comments and CRLF are accepted\r\n'
             f'  server = "/Example.COM/extra.example/{MANUAL_DNS}"\r\n'
             'rev-server=192.0.2.0/24,203.0.113.53\r\n').encode()
        )
        self.reload("--no-reload")
        rendered = self.active.read_text()
        self.assertIn(f'server = "/Example.COM/extra.example/{MANUAL_DNS}"', rendered)
        self.assertIn("rev-server=192.0.2.0/24,203.0.113.53", rendered)
        self.assertNotIn(f"server=/sub.example.com/{GFW_DNS}\n", rendered)
        self.assertEqual(stat.S_IMODE(self.active.stat().st_mode), 0o644)

    def test_only_visible_top_level_conf_files_are_loaded(self):
        self.custom.write_text(f"server=/example.com/{MANUAL_DNS}\n")
        for name in ("notes.txt", ".hidden.conf", "disabled.conf.bak"):
            (self.upstreams / name).write_text("cache-size=bad-value\n")
        nested = self.upstreams / "nested.conf"
        nested.mkdir()
        (nested / "nested.conf").write_text("cache-size=bad-value\n")
        self.reload("--no-reload")
        self.assertIn(f"server=/example.com/{MANUAL_DNS}\n", self.active.read_text())

    def signal_target(self):
        received = self.root / "received-signals"
        process = subprocess.Popen(
            [sys.executable, "-u", "-c", """
import ctypes, pathlib, signal, sys
ctypes.CDLL(None).prctl(15, b'dnsmasq', 0, 0, 0)
received = pathlib.Path(sys.argv[1])
def on_hup(*_):
    with received.open('a') as output:
        output.write('HUP\\n')
signal.signal(signal.SIGHUP, on_hup)
print('ready', flush=True)
while True:
    signal.pause()
""", str(received)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )

        def stop():
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=5)

        self.addCleanup(stop)
        self.assertNotEqual(process.pid, 1)
        self.assertEqual(process.stdout.readline().strip(), "ready")
        self.pid_file.write_text(str(process.pid) + "\n")
        return received

    @unittest.skipUnless(sys.platform == "linux", "requires Linux process names")
    def test_no_reload_does_not_signal_a_running_process(self):
        received = self.signal_target()
        self.reload("--no-reload")
        self.assertFalse(received.exists())

    @unittest.skipUnless(sys.platform == "linux", "requires Linux process names")
    def test_reload_sends_hup_to_the_controlled_dnsmasq_process(self):
        received = self.signal_target()
        result = self.reload()
        deadline = time.monotonic() + 2
        while not received.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(received.read_text(), "HUP\n")
        self.assertIn("sent SIGHUP", result.stdout)


if __name__ == "__main__":
    unittest.main()
