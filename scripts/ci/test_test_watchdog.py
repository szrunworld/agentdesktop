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


    def test_unverifiable_leftovers_are_reported_left_alone_and_do_not_fail_the_run(self):
        # Codex and b9 on #188: a detached platform binary (whose environment
        # only root can read) with sudo off, as on a machine without
        # passwordless sudo: reported, not stopped, the command's status kept.
        secs = str(3000 + uuid.uuid4().int % 900)
        marker = f"sleep {secs}"
        try:
            code, log, _, out = self.run_watchdog(
                [sys.executable, "-S", "-c",
                 f'import subprocess; subprocess.Popen(["/bin/sleep", "{secs}"], start_new_session=True, '
                 'stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)'],
                # Deterministic on any machine (CI, 63b7816): no sudo, no
                # snapshots (one could catch the parent alive on a slow
                # runner), and every environment read as unreadable (a
                # runner may well show /bin/sleep's).
                env={"WATCHDOG_NO_SUDO": "1", "WATCHDOG_NO_SNAPSHOTS": "1", "WATCHDOG_FAKE_UNREADABLE": "all"})
            self.assertEqual(code, 0, log)
            self.assertIn("unverifiable (left alone)", log)
            self.assertIn(marker, log)
            with open(os.path.join(out, "diagnosis.json")) as f:
                report = json.load(f)
            self.assertEqual(report["trigger"], "unverifiable processes at exit")
            self.assertTrue(any(marker in u["command"] for u in report["unverifiable"]))
            self.assertTrue(alive(marker), "an unverifiable process was stopped")
        finally:
            subprocess.run(["pkill", "-f", marker], capture_output=True)

    def test_every_step_stays_within_the_diagnosis_budget(self):
        hang = os.path.join(tempfile.mkdtemp(prefix="watchdog-hang-"), "sample")
        with open(hang, "w") as f:
            f.write("#!/bin/sh\nsleep 30\n")
        os.chmod(hang, 0o755)
        code, _, took, out = self.run_watchdog(
            [sys.executable, "-c", 'import threading; print("◇ Test stuck() started."); '
             'l=threading.Lock(); l.acquire(); l.acquire()'],
            stall=3, env={"WATCHDOG_SAMPLE": hang, "WATCHDOG_STEP_TIMEOUT": "20", "WATCHDOG_DIAGNOSIS_BUDGET": "6"})
        self.assertEqual(code, 124)
        self.assertLess(took, 20, "a step ran past the diagnosis budget")
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        statuses = {s["step"]: s["status"] for s in report["steps"]}
        self.assertTrue(any(k.startswith("sample") and v == "failed" for k, v in statuses.items()))


    def test_a_clean_run_never_reports_the_watchdogs_own_helpers(self):
        # Codex on #188: the snapshot's own ps, gone by the time it was
        # checked, was reported as an unverifiable leftover of every run.
        code, log, _, _ = self.run_watchdog(
            ["sh", "-c", "echo hi; exit 0"],
            env={"WATCHDOG_NO_SUDO": "1", "WATCHDOG_FAKE_UNREADABLE": "all"})
        self.assertEqual(code, 0, log)
        self.assertNotIn("ps -axo", log)
        self.assertNotIn("lsof -t", log)

    def test_output_read_while_draining_is_parsed_like_the_rest(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("watchdog", WATCHDOG)
        wd = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(wd)
        out = wd.Output()
        out.take("◇ Test a() started.\n◇ Test \"b c\" st".encode())
        out.take("arted.\n✔ Test a() passed after 0.1 seconds.\n✘ Test \"b c\" failed".encode())
        out.finish()  # the last line has no newline
        self.assertEqual(out.started, ["a()", "b c"])
        self.assertEqual(out.finished, {"a()", "b c"})

    def test_results_printed_just_before_exit_reach_the_diagnosis(self):
        code, _, _, out = self.run_watchdog(
            ["sh", "-c", "(sleep 30 &); echo '◇ Test a() started.'; echo '✔ Test a() passed after 0.1 seconds.'; exit 0"])
        self.assertEqual(code, 124)
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        self.assertEqual(report["tests_finished"], 1)
        self.assertEqual(report["tests_unfinished"], [])

    def test_process_discovery_is_charged_to_the_budget(self):
        code, _, took, _ = self.run_watchdog(
            [sys.executable, "-c", 'import threading; print("◇ Test stuck() started."); '
             'l=threading.Lock(); l.acquire(); l.acquire()'],
            stall=3, env={"WATCHDOG_DIAGNOSIS_BUDGET": "0.5", "WATCHDOG_NO_SUDO": "1"})
        self.assertEqual(code, 124)
        self.assertLess(took, 15)


    def test_after_the_command_exits_its_group_id_is_never_signalled(self):
        # Codex on #188: once the command has exited, its pid and group id
        # may belong to unrelated processes; stop() must not killpg it, and
        # members() must not trust the tree under that id.
        import importlib.util
        spec = importlib.util.spec_from_file_location("watchdog", WATCHDOG)
        wd = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(wd)
        bystander = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        try:
            # A run whose root id is now the bystander's (a reused pid/group).
            run = wd.Run(bystander.pid, None, uuid.uuid4().hex, time.time())
            run.root_alive = False
            calls = []
            real = wd.os.killpg
            wd.os.killpg = lambda *a: calls.append(a)
            try:
                self.assertNotIn(bystander.pid, run.members())
                run.stop()
            finally:
                wd.os.killpg = real
            self.assertEqual(calls, [])
            self.assertIsNone(bystander.poll(), "a process under the old group id was stopped")
        finally:
            bystander.kill()
            bystander.wait()


if __name__ == "__main__":
    unittest.main()
