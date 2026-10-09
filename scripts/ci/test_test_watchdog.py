"""Self-tests for scripts/ci/test-watchdog.py (#183, b9 and Codex on #188).

Each case runs the watchdog on a small command and checks its exit status,
what it reports, and that nothing the command started is left running.
Run: python3 -m unittest scripts/ci/test_test_watchdog.py
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

WATCHDOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "test-watchdog.py")


def alive(marker):
    return subprocess.run(["pgrep", "-f", marker], capture_output=True).returncode == 0


class WatchdogTests(unittest.TestCase):
    def run_watchdog(self, command, stall=20, timeout=90, env=None):
        out = tempfile.mkdtemp(prefix="watchdog-test-")
        started = time.monotonic()
        r = subprocess.run([sys.executable, WATCHDOG, "--stall", str(stall), "--out", out, "--", *command],
                           capture_output=True, text=True, timeout=timeout, env=dict(os.environ, **(env or {})))
        return r.returncode, r.stdout + r.stderr, time.monotonic() - started, out

    def test_returns_the_commands_own_status(self):
        code, _, _, _ = self.run_watchdog(["sh", "-c", "echo hi; exit 3"])
        self.assertEqual(code, 3)

    def test_a_stall_lists_the_unfinished_test_and_fails(self):
        code, log, _, out = self.run_watchdog(
            [sys.executable, "-c",
             'import threading; print("◇ Test stuck() started."); print("◇ Test done() started."); '
             'print("✔ Test done() passed after 0.1 seconds."); l=threading.Lock(); l.acquire(); l.acquire()'],
            stall=3)
        self.assertEqual(code, 124)
        self.assertIn("still running: stuck()", log)
        self.assertNotIn("still running: done()", log)
        self.assertTrue(any(f.startswith("sample-") for f in os.listdir(out)))

    def test_a_background_process_in_a_new_session_is_caught_and_stopped(self):
        marker = f"sleep 10{uuid.uuid4().int % 1000:03d}"
        secs = marker.split()[1]
        code, log, took, _ = self.run_watchdog(
            [sys.executable, "-c", f'import subprocess; subprocess.Popen(["sleep", "{secs}"], start_new_session=True)'])
        self.assertEqual(code, 124)
        self.assertIn(marker, log)
        self.assertLess(took, 30)
        self.assertFalse(alive(marker))

    def test_a_new_session_that_left_the_terminal_is_caught_by_what_was_seen(self):
        marker = f"sleep 20{uuid.uuid4().int % 1000:03d}"
        secs = marker.split()[1]
        code, log, _, _ = self.run_watchdog(
            [sys.executable, "-c",
             f'import subprocess, time; subprocess.Popen(["sleep", "{secs}"], start_new_session=True, '
             'stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(1)'])
        self.assertEqual(code, 124)
        self.assertIn(marker, log)
        self.assertFalse(alive(marker))

    def test_a_leftover_that_keeps_writing_does_not_hide_the_exit(self):
        tag = f"tick-{uuid.uuid4().hex[:8]}"
        code, _, took, _ = self.run_watchdog(
            ["sh", "-c", f"(while :; do echo {tag}; sleep 1; done) & echo started; exit 0"])
        self.assertEqual(code, 124)
        self.assertLess(took, 30)
        self.assertFalse(alive(tag))

    def test_a_detached_child_whose_parent_exits_at_once_is_found_by_the_marker(self):
        # Codex on #188: setsid, every stream redirected, the parent gone at
        # once; no snapshot can see it, the environment marker does. A
        # non-platform binary (this Python) so the environment is readable
        # without root, as it is for the engine's own processes.
        tag = f"detached-{uuid.uuid4().hex[:8]}"
        code, log, _, _ = self.run_watchdog(
            [sys.executable, "-c",
             "import subprocess, sys; subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60) # "
             + tag + "'], start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, "
             "stderr=subprocess.DEVNULL)"])
        self.assertEqual(code, 124)
        self.assertIn(tag, log)
        self.assertFalse(alive(tag))

    def test_an_unrelated_process_is_never_stopped(self):
        tag = f"unrelated-{uuid.uuid4().hex[:8]}"
        bystander = subprocess.Popen([sys.executable, "-c", f"import time; time.sleep(60) # {tag}"],
                                     start_new_session=True)
        try:
            code, log, _, _ = self.run_watchdog(["sh", "-c", "(sleep 30 &) ; exit 0"])
            self.assertEqual(code, 124)
            self.assertNotIn(tag, log)
            self.assertIsNone(bystander.poll(), "an unrelated process was stopped")
        finally:
            bystander.kill()
            bystander.wait()

    def test_a_failing_sampler_keeps_the_rest_of_the_evidence(self):
        code, log, _, out = self.run_watchdog(
            [sys.executable, "-c", 'import threading; print("◇ Test stuck() started."); '
             'l=threading.Lock(); l.acquire(); l.acquire()'],
            stall=3, env={"WATCHDOG_SAMPLE": "/nonexistent/sample"})
        self.assertEqual(code, 124)
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        self.assertEqual(report["trigger"], "output stalled")
        self.assertEqual(report["tests_unfinished"], ["stuck()"])
        self.assertTrue(any(s["step"].startswith("sample") and s["status"] == "failed" for s in report["steps"]))
        incomplete = next(line for line in log.splitlines() if "incomplete steps:" in line)
        self.assertIn("sample", incomplete)
        self.assertTrue(os.path.exists(os.path.join(out, "unfinished-tests.txt")))

    def test_a_hanging_sampler_is_cut_off_and_reported(self):
        hang = os.path.join(tempfile.mkdtemp(prefix="watchdog-hang-"), "sample")
        with open(hang, "w") as f:
            f.write("#!/bin/sh\nsleep 30\n")
        os.chmod(hang, 0o755)
        code, _, took, out = self.run_watchdog(
            [sys.executable, "-c", 'import threading; print("◇ Test stuck() started."); '
             'l=threading.Lock(); l.acquire(); l.acquire()'],
            stall=3, env={"WATCHDOG_SAMPLE": hang, "WATCHDOG_STEP_TIMEOUT": "1"})
        self.assertEqual(code, 124)
        self.assertLess(took, 25)
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        self.assertTrue(any(s["status"] == "failed" and "timed out" in s["detail"] for s in report["steps"]))


if __name__ == "__main__":
    unittest.main()
