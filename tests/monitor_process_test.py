"""Standalone tests: python3 -m unittest discover -s tests -p '*_test.py'."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "utils" / "monitor_process.py"
SPEC = importlib.util.spec_from_file_location("monitor_process", SCRIPT)
monitor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(monitor)


class MonitorTests(unittest.TestCase):
    """Cover proc parsing, identity safeguards, and the actual collector CLI."""

    def test_stat_command_with_spaces_and_parentheses(self):
        """Command names must not shift the documented proc field positions."""
        fields = ["S"] + [str(number) for number in range(4, 25)]
        stat = monitor.parse_stat("123 (a name ) with (parentheses)) " + " ".join(fields))
        self.assertEqual(stat["user_ticks"], 14)
        self.assertEqual(stat["system_ticks"], 15)
        self.assertEqual(stat["start_ticks"], 22)
        self.assertEqual(stat["resident_pages"], 24)

    def test_rates_and_identity(self):
        """Verify multicore percentages, storage rates, and reused-ID rejection."""
        previous = {"start_ticks": 10, "user_ticks": 100, "system_ticks": 50,
                    "io": {"read_bytes": 1000}}
        current = {"start_ticks": 10, "user_ticks": 400, "system_ticks": 150,
                   "io": {"read_bytes": 5000}}
        monitor.add_rates(current, previous, 2, 100)
        self.assertEqual(current["cpu_percent"], 200)
        self.assertEqual(current["io_per_second"]["read_bytes"], 2000)
        replacement = dict(current, start_ticks=11)
        monitor.add_rates(replacement, previous, 2, 100)
        self.assertIsNone(replacement["cpu_percent"])

    def test_process_identity_checks(self):
        """Do not follow a new process that inherits the monitored PID."""
        collector = monitor.Collector(os.getpid())
        with patch.object(monitor, "parse_stat", return_value={
                "start_ticks": collector.start_ticks + 1, "state": "S"}):
            with self.assertRaisesRegex(monitor.TargetEnded, "reused"):
                collector.identity()
        with patch.object(monitor, "parse_stat", return_value={
                "start_ticks": collector.start_ticks, "state": "Z"}):
            with self.assertRaisesRegex(monitor.TargetEnded, "zombie"):
                collector.identity()

    def test_permission_failure_is_explicit(self):
        """An unreadable I/O counter must never be reported as zero."""
        errors = {}
        with patch.object(monitor, "read_io", side_effect=PermissionError("denied")):
            result = monitor.optional_read(errors, "io", lambda: monitor.read_io(Path("unused")))
        self.assertIsNone(result)
        self.assertEqual(errors, {"io": "denied"})

    def test_rotation(self):
        """Keep the configured number of complete JSON Lines backup files."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "resources.jsonl"
            handler = monitor.StrictRotatingHandler(path, maxBytes=100, backupCount=2)
            logger = monitor.logging.Logger("rotation-test", level=monitor.logging.INFO)
            logger.addHandler(handler)
            try:
                for number in range(20):
                    logger.info(json.dumps({"sequence": number, "data": "x" * 40}))
            finally:
                handler.close()
            self.assertEqual(len(list(Path(directory).iterdir())), 3)
            for file in Path(directory).iterdir():
                for line in file.read_text().splitlines():
                    self.assertIn("sequence", json.loads(line))

    def test_live_samples(self):
        """Exercise real proc reads and ensure that the target is unaffected."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "resources.jsonl"
            subprocess.run([sys.executable, str(SCRIPT), str(os.getpid()),
                            "--output", str(path), "--interval", "0.02", "--count", "3"],
                           check=True, timeout=10, capture_output=True)
            records = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertEqual([record["event"] for record in records],
                             ["start", "sample", "sample", "sample", "stop"])
            self.assertIsNone(records[1]["process"]["cpu_percent"])
            self.assertIsNotNone(records[2]["process"]["cpu_percent"])
            self.assertGreater(records[1]["process"]["rss_bytes"], 0)
            self.assertIn(str(os.getpid()), records[1]["process"]["threads"])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_target_exit(self):
        """A disappearing target produces a final stop record, not a busy loop."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "resources.jsonl"
            target = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
            watcher = subprocess.Popen([sys.executable, str(SCRIPT), str(target.pid),
                                        "--output", str(path), "--interval", "0.02"])
            try:
                deadline = time.monotonic() + 5
                while not path.exists() or '"event":"sample"' not in path.read_text():
                    if time.monotonic() >= deadline:
                        self.fail("collector did not produce a sample")
                    time.sleep(0.02)
                target.terminate()
                target.wait(timeout=5)
                self.assertEqual(watcher.wait(timeout=5), 0)
                final = json.loads(path.read_text().splitlines()[-1])
                self.assertEqual(final["event"], "stop")
                self.assertIn("exited", final["reason"])
            finally:
                for process in (watcher, target):
                    if process.poll() is None:
                        process.terminate()
                    process.wait(timeout=5)

    def test_signal_interrupts_long_interval(self):
        """SIGTERM must stop the collector promptly without harming its target."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "resources.jsonl"
            watcher = subprocess.Popen([sys.executable, str(SCRIPT), str(os.getpid()),
                                        "--output", str(path), "--interval", "300"])
            try:
                deadline = time.monotonic() + 5
                while not path.exists() or '"event":"sample"' not in path.read_text():
                    if time.monotonic() >= deadline:
                        self.fail("collector did not produce a sample")
                    time.sleep(0.02)
                watcher.terminate()
                self.assertEqual(watcher.wait(timeout=5), 0)
                final = json.loads(path.read_text().splitlines()[-1])
                self.assertEqual(final["reason"], "signal")
            finally:
                if watcher.poll() is None:
                    watcher.terminate()
                watcher.wait(timeout=5)

    def test_log_write_failure_propagates(self):
        """A full or failing output filesystem must not silently discard data."""
        with tempfile.TemporaryDirectory() as directory:
            handler = monitor.StrictRotatingHandler(Path(directory) / "resources.jsonl")
            logger = monitor.logging.Logger("failure-test", level=monitor.logging.INFO)
            logger.addHandler(handler)
            try:
                with patch.object(handler, "stream") as stream:
                    stream.write.side_effect = OSError("disk full")
                    with self.assertRaisesRegex(OSError, "disk full"):
                        logger.info("test record")
            finally:
                handler.close()


if __name__ == "__main__":
    unittest.main()
