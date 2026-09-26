#!/usr/bin/env python3
"""Regression coverage for CI timeout, exit status, and process cleanup."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


RUNNER = Path(__file__).with_name("run_test_diagnostics.py")


class TestDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def command(self, source, timeout=30):
        return [sys.executable, str(RUNNER), "--label", "fixture", "--output-dir",
                str(self.root), "--timeout-seconds", str(timeout), "--",
                sys.executable, "-c", source]

    def assert_stopped(self, pid):
        result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                                capture_output=True, text=True)
        self.assertTrue(result.returncode != 0 or result.stdout.strip().startswith("Z"),
                        f"PID {pid} survived cleanup")

    def test_preserves_output_and_exit_status(self):
        for status in (0, 7):
            with self.subTest(status=status):
                message = f"test exit {status}"
                result = subprocess.run(
                    self.command(f"print({message!r}); raise SystemExit({status})"),
                    capture_output=True, text=True, timeout=15,
                )
                self.assertEqual(result.returncode, status)
                self.assertIn(message, result.stdout)
                self.assertTrue(any(message in path.read_text()
                                    for path in self.root.glob("*/console.log")))

    def test_timeout_samples_and_kills_host_after_output_closes(self):
        # EOF must not disable the deadline while the test host is still alive.
        source = """import os, signal, time
print(os.getpid(), flush=True)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
os.close(1)
os.close(2)
time.sleep(60)
"""
        result = subprocess.run(self.command(source, timeout=0.5),
                                capture_output=True, text=True, timeout=25)
        self.assertEqual(result.returncode, 124, result.stdout)
        directory = next(self.root.iterdir())
        pid = int((directory / "console.log").read_text().strip())
        self.assert_stopped(pid)
        self.assertIn(str(pid), (directory / "processes.txt").read_text())
        self.assertTrue(list(directory.glob("*.sample.txt")))

    def test_cancellation_kills_child_even_after_launcher_exits(self):
        ready = self.root / "child-pid"
        child = ("import os, signal, time; "
                 "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                 f"open({str(ready)!r}, 'w').write(str(os.getpid())); time.sleep(60)")
        source = f"import subprocess, sys; subprocess.Popen([sys.executable, '-c', {child!r}])"
        with subprocess.Popen(self.command(source), stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, text=True) as process:
            try:
                deadline = time.monotonic() + 10
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready.exists(), "child did not start")
                process.send_signal(signal.SIGTERM)
                output, _ = process.communicate(timeout=15)
                self.assertEqual(process.returncode, 143, output)
                self.assert_stopped(int(ready.read_text()))
            finally:
                if process.poll() is None:
                    process.kill()
                if ready.exists():
                    try:
                        os.kill(int(ready.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
