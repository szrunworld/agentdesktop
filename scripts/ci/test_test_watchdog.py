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
        self.assertNotIn("::warning", log)  # #193: lsof finding nothing is not a failure

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


    def test_children_started_while_stopping_are_stopped_too(self):
        # Codex on #188: a leftover that keeps starting detached children
        # (each carries the run's marker) until it is killed; every one of
        # them must be gone and the diagnosis must say the stop succeeded.
        tag = f"spawner-{uuid.uuid4().hex[:8]}"
        child = (f"import time; time.sleep(60) # {tag}-child")
        spawner = ("import subprocess, sys, time\n"
                   "while True:\n"
                   f"    subprocess.Popen([sys.executable, '-c', {child!r}], start_new_session=True, "
                   "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
                   "    time.sleep(0.05)\n"
                   f"# {tag}")
        code, log, _, out = self.run_watchdog(
            [sys.executable, "-c",
             f"import subprocess, sys; subprocess.Popen([sys.executable, '-c', {spawner!r}], start_new_session=True, "
             "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)"])
        try:
            self.assertEqual(code, 124, log)
            time.sleep(0.5)
            self.assertFalse(alive(tag), "a process of the run survived the stop")
            with open(os.path.join(out, "diagnosis.json")) as f:
                report = json.load(f)
            self.assertStopped(report)
        finally:
            subprocess.run(["pkill", "-f", tag], capture_output=True)

    def failing_tool(self, name, script="#!/bin/sh\nexit 2\n"):
        path = os.path.join(tempfile.mkdtemp(prefix="watchdog-tool-"), name)
        with open(path, "w") as f:
            f.write(script)
        os.chmod(path, 0o755)
        return path

    def assertStopped(self, report):
        """Everything confirmed as the run's was stopped. Where sudo works
        without a password (CI) every process can be checked, so the stop
        must be ok; elsewhere processes that cannot be checked are reported
        as unverified, which is not the same as stopped (Kevin, 2026-10-09).
        The outcome goes to stderr, so the CI log shows which it was (b9)."""
        status = [s["status"] for s in report["steps"] if s["step"] == "stop"]
        sudo = subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0
        print(f"\n[{self.id().rsplit('.', 1)[-1]}] stop: {status}, passwordless sudo: {sudo}", file=sys.stderr)
        for e in report.get("unverified_at_stop", []):
            print(f"  unverified: {e['pid']} {e['command'][:120]} ({e['why']})", file=sys.stderr)
        self.assertNotIn("not_stopped", report)
        if sudo or not report.get("unverified_at_stop"):
            self.assertEqual(status, ["ok"])
        else:
            self.assertEqual(status, ["unverified"])

    def load(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("watchdog", WATCHDOG)
        wd = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(wd)
        return wd

    def test_a_stall_reports_the_stopped_command_as_stopped(self):
        # #194: the killed command must not be reported as still running
        # while it waits to be reaped.
        code, log, _, out = self.run_watchdog(
            [sys.executable, "-c",
             'import threading; print("◇ Test stuck() started."); l=threading.Lock(); l.acquire(); l.acquire()'],
            stall=3)
        self.assertEqual(code, 124, log)
        self.assertNotIn("could not stop", log)
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        self.assertStopped(report)
        self.assertNotIn("not_stopped", report)

    def test_a_zombie_is_not_a_process_of_the_run(self):
        # #194: an exited child its parent has not reaped is not running.
        wd = self.load()
        parent = subprocess.Popen(
            [sys.executable, "-c", "import os, sys, time\npid = os.fork()\nif pid == 0: os._exit(0)\n"
             "print(pid, flush=True)\ntime.sleep(60)"], stdout=subprocess.PIPE, text=True, start_new_session=True)
        try:
            zombie = int(parent.stdout.readline())
            time.sleep(0.3)
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(zombie)], capture_output=True, text=True).stdout
            self.assertTrue(state.strip().startswith("Z"), f"not a zombie: {state!r}")
            run = wd.Run(parent.pid, None, uuid.uuid4().hex, time.time())
            members = run.members()
            self.assertIn(parent.pid, members)
            self.assertNotIn(zombie, members)
        finally:
            parent.kill()
            parent.wait()

    def test_a_command_line_with_spaces_is_parsed_whole(self):
        wd = self.load()
        self.assertEqual(wd.parse_ps_row("  812 /usr/bin/python3 -c print('a  b') --flag x"),
                         (812, "/usr/bin/python3 -c print('a  b') --flag x"))
        self.assertIsNone(wd.parse_ps_row("not-a-pid something"))

    def test_relationships_come_from_the_kernel_never_from_ps(self):
        # Codex on #196: ps's view of a pid may be a process that has since
        # exited and whose pid went to another; its parent and group must
        # never be paired with the new process's identity. Here ps claims a
        # bystander is the command's child; the kernel knows better.
        wd = self.load()
        bystander = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        root = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        lie = self.failing_tool("ps", "#!/bin/sh\n"
                                f"echo '{bystander.pid} {root.pid} {root.pid} {os.getuid()} S "
                                "Thu Oct  9 13:36:03 2026 lying-ps-row'\n")
        try:
            wd.PS = lie
            procs = wd.processes()
            self.assertEqual(procs[bystander.pid][:2], (os.getpid(), bystander.pid))
            self.assertEqual(procs[bystander.pid][2], wd.start_time(bystander.pid))
            run = wd.Run(root.pid, None, uuid.uuid4().hex, time.time())
            self.assertNotIn(bystander.pid, run.members())
        finally:
            for p in (bystander, root):
                p.kill()
                p.wait()
    def test_a_reaped_commands_pid_is_never_signalled(self):
        # Codex and b9 on #196: once stop() has reaped the command, its pid
        # may be reused at once; the process that now has it must survive.
        wd = self.load()
        bystander = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)

        class Reaped:
            # The command, reaped by stop(); its pid now is the bystander's.
            def wait(self, timeout=None):
                return 0
        try:
            run = wd.Run(bystander.pid, None, uuid.uuid4().hex, time.time(), Reaped())
            self.assertIn(bystander.pid, run.members())  # found while the command "ran"
            # The forced snapshot before a diagnosis remembers the root; with
            # the bystander's own start time this acts out a pid reused in
            # the same second (lstart is exact to the second).
            run.snapshot(force=True)
            self.assertIn(bystander.pid, run.seen)
            real = wd.kill_command
            wd.kill_command = lambda *a: None  # killing the command itself is not what is tested here
            try:
                run.stop()
            finally:
                wd.kill_command = real
            time.sleep(0.3)
            self.assertIsNone(bystander.poll(), "the process that reused the reaped pid was killed")
            self.assertFalse(run.root_alive)
            self.assertNotIn(bystander.pid, run.seen)
            self.assertNotIn(bystander.pid, run.members())
        finally:
            bystander.kill()
            bystander.wait()

    def test_targets_are_found_again_when_reaping_times_out(self):
        # Codex on #196: while stop() waits for the command, a target may
        # exit and its pid go to an unrelated process; even when the wait
        # times out, the list taken before it is not acted on after it.
        # (Right after the first look, before the wait, its members are
        # signalled, identity-checked: Codex on #215.) Signals are recorded,
        # not sent, and the recorded identity matches throughout, the worst
        # case, so only looking again after the wait keeps the old list
        # from being acted on.
        wd = self.load()
        bystander = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        phase = {"waited": False}
        sent = []

        class Unreaped:
            def wait(self, timeout=None):
                phase["waited"] = True
                raise subprocess.TimeoutExpired("cmd", timeout)
        try:
            run = wd.Run(999999, None, uuid.uuid4().hex, time.time(), Unreaped())
            looks = iter([{bystander.pid: "old target"}])
            ident = wd.start_time(bystander.pid)

            def members(deadline=None):
                found = next(looks, {})
                run.idents = {pid: ident for pid in found}
                return found
            run.members = members
            real, real_kill = wd.kill_command, wd.os.kill
            wd.kill_command = lambda *a: None
            wd.os.kill = lambda pid, sig: sent.append((phase["waited"], pid))
            try:
                run.stop()
            finally:
                wd.kill_command, wd.os.kill = real, real_kill
            self.assertNotIn((True, bystander.pid), sent, "the list taken before the wait was acted on after it")
            self.assertTrue(run.root_alive)
        finally:
            bystander.kill()
            bystander.wait()

    def test_a_target_is_signalled_only_while_it_is_the_process_found(self):
        # Codex and b9 on #196: a pid found in a scan may belong to another
        # process by the time the signal is sent, even within the same
        # second. Signalled only if the kernel's start time still matches
        # the identity found, to the microsecond.
        wd = self.load()
        procs = [subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
                 for _ in range(3)]
        same_second, older, found = procs
        try:
            run = wd.Run(999999, None, uuid.uuid4().hex, time.time())
            run.root_alive = False
            sec, usec = wd.start_time(same_second.pid)
            run.idents = {
                # Found as a process that started in the same second, a
                # microsecond apart: its pid has since gone to this one.
                same_second.pid: (sec, (usec + 1) % 1000000),
                older.pid: (wd.start_time(older.pid)[0] - 5, 0),
                found.pid: wd.start_time(found.pid),  # still the process found
            }
            run.signal([same_second.pid, older.pid, found.pid, 999998])  # 999998: no such process
            time.sleep(0.3)
            self.assertIsNone(same_second.poll(), "a same-second replacement was killed")
            self.assertIsNone(older.poll(), "a process with a reused pid was killed")
            self.assertEqual(found.wait(timeout=5), -9)
        finally:
            for p in procs:
                if p.poll() is None:
                    p.kill()
                p.wait()

    def test_the_marker_counts_only_for_the_process_identified(self):
        # b9 on #196: the identity is read again after the environment; if
        # the pid changed hands in between, the marker is not taken as the
        # identified process's.
        wd = self.load()
        marker = uuid.uuid4().hex
        run = wd.Run(999999, None, marker, time.time() - 5)
        now = int(time.time())
        procs = {424242: (1, 424242, (now, 1), "replaced"), 424243: (1, 424243, (now, 2), "same")}
        after = {424242: (now, 7), 424243: (now, 2)}  # 424242 changed during the read
        real_env, real_start = wd.process_environment, wd.start_time
        wd.process_environment = lambda pid: [f"{wd.MARKER}={marker}"]
        wd.start_time = lambda pid: after.get(pid)
        try:
            found = run._marked(procs, set(), None)
        finally:
            wd.process_environment, wd.start_time = real_env, real_start
        self.assertEqual(found, {424243: "same"})

    def test_a_child_hangs_from_its_parent_only_if_the_link_still_holds(self):
        # b9 and Kevin on #196: the listing is in no set order. R may be read
        # while pid p was another process's; p then goes to our X, and X is
        # read unchanged: R names p as its parent, yet X never was. Each
        # link is checked with the child read between two reads of the
        # parent; a parent that changed breaks the link too; a child whose
        # link fails is reported as unverified, never signalled.
        wd = self.load()
        root = subprocess.Popen([sys.executable, "-c", "import subprocess, time; "
                                 "c = subprocess.Popen(['sleep', '60']); print(c.pid, flush=True); time.sleep(60)"],
                                stdout=subprocess.PIPE, text=True, start_new_session=True)
        stranger = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        child = 0
        try:
            child = int(root.stdout.readline())
            ident = wd.start_time

            def listing():
                return {
                    root.pid: (1, root.pid, ident(root.pid), "root"),
                    # Listed in a group of its own, so only the parent link
                    # can bring it in (the root's group is trusted: unreaped).
                    child: (root.pid, child, ident(child), "the root's child"),
                    # Read while its parent pid was another process's: it
                    # names the root's pid, but the root never was its parent.
                    stranger.pid: (root.pid, stranger.pid, ident(stranger.pid), "R"),
                }
            run = wd.Run(root.pid, None, uuid.uuid4().hex, time.time())
            tree = run._tree(listing())
            self.assertIn(child, tree)  # a real link holds
            self.assertNotIn(stranger.pid, tree)
            self.assertIn(stranger.pid, run._unlinked)
            changed = listing()
            sec, usec = changed[root.pid][2]
            changed[root.pid] = (1, root.pid, (sec, (usec + 1) % 1000000), "root")  # listed, replaced now
            self.assertNotIn(child, run._tree(changed))
            self.assertIn(child, run._unlinked)
        finally:
            if child:
                subprocess.run(["kill", "-9", str(child)], capture_output=True)
            for p in (root, stranger):
                p.kill()
                p.wait()

    def test_an_unconfirmed_link_is_reported_unverified_never_stopped(self):
        # Kevin, 2026-10-09: a process that cannot be confirmed is not
        # signalled and is recorded as unverified, not as stopped.
        wd = self.load()
        stranger = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        root = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        try:
            real = wd.processes

            def lying(deadline=None, problems=None, foreign=None):
                procs = real(deadline, problems, foreign)
                if stranger.pid in procs:  # its parent pid claims the root
                    procs[stranger.pid] = (root.pid,) + procs[stranger.pid][1:]
                return procs
            wd.processes = lying
            real_killpg = wd.kill_command
            wd.kill_command = lambda *a: None
            try:
                run = wd.Run(root.pid, None, uuid.uuid4().hex, time.time())
                self.assertNotIn(stranger.pid, run.members())
                self.assertIn(stranger.pid, run.unverifiable)
                run.stop()
            finally:
                wd.processes, wd.kill_command = real, real_killpg
            time.sleep(0.3)
            self.assertIsNone(stranger.poll(), "an unverified process was signalled")
            out = tempfile.mkdtemp(prefix="watchdog-test-")
            wd.record_stop(run, out)
            with open(os.path.join(out, "diagnosis.json")) as f:
                report = json.load(f)
            self.assertEqual([s["status"] for s in report["steps"] if s["step"] == "stop"], ["unverified"])
            entry = [e for e in report["unverified_at_stop"] if e["pid"] == stranger.pid]
            self.assertEqual(entry[0]["why"], "its link to a parent in the run could not be confirmed")
        finally:
            for p in (stranger, root):
                p.kill()
                p.wait()
    def test_a_candidate_gone_before_its_link_is_checked_is_not_reported(self):
        # Codex on #196: a child listed, then gone before its link was
        # checked, is not an uncertain process; the stop is ok.
        wd = self.load()
        root = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        gone = subprocess.Popen(["/usr/bin/true"])
        gone.wait()
        try:
            real = wd.processes
            listed = {}

            def with_the_gone_child(deadline=None, problems=None, foreign=None):
                procs = real(deadline, problems, foreign)
                # As listed just before it exited: the root's child.
                procs[gone.pid] = (root.pid, gone.pid, (int(time.time()), 1), "gone")
                listed[gone.pid] = True
                return procs
            wd.processes = with_the_gone_child
            real_killpg = wd.kill_command
            wd.kill_command = lambda *a: None
            try:
                # Started in the future: nothing is a marker candidate, so
                # only the link check can make anything unverified here.
                run = wd.Run(root.pid, None, uuid.uuid4().hex, time.time() + 3600)
                run.root_alive = True
                self.assertNotIn(gone.pid, run.members())
                self.assertTrue(listed)
                self.assertNotIn(gone.pid, run._unlinked.keys() & run.unverifiable.keys())
                self.assertEqual(run.unverifiable, {})
                run.stop()
            finally:
                wd.processes, wd.kill_command = real, real_killpg
            out = tempfile.mkdtemp(prefix="watchdog-test-")
            wd.record_stop(run, out)
            with open(os.path.join(out, "diagnosis.json")) as f:
                report = json.load(f)
            self.assertEqual([s["status"] for s in report["steps"] if s["step"] == "stop"], ["ok"])
        finally:
            root.kill()
            root.wait()

    STALL = [sys.executable, "-c",
             'import threading; print("◇ Test stuck() started."); l=threading.Lock(); l.acquire(); l.acquire()']

    def test_a_failing_lsof_makes_the_process_list_partial(self):
        # #193: a list found without the terminal holders is not reported as
        # complete.
        code, log, _, out = self.run_watchdog(self.STALL, stall=3, env={"WATCHDOG_LSOF": self.failing_tool("lsof")})
        self.assertEqual(code, 124, log)
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        step = [s for s in report["steps"] if s["step"] == "processes of the run"][0]
        self.assertEqual(step["status"], "partial", step)
        self.assertIn("lsof: exit 2", step["detail"])
        self.assertIn("processes of the run", log.split("incomplete steps:")[-1])

    def test_a_failing_process_list_at_exit_keeps_the_status_and_warns(self):
        # #193, b9: the leftover check could not be done; the command's own
        # status is kept, and the failure is visible (log, diagnosis.json,
        # a warning annotation on the CI run).
        code, log, _, out = self.run_watchdog(
            ["sh", "-c", "echo hi; exit 3"], env={"WATCHDOG_FAKE_NO_PROCESS_LIST": "1", "WATCHDOG_NO_SUDO": "1"})
        self.assertEqual(code, 3, log)
        self.assertIn("::warning title=test-watchdog::", log)
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        self.assertEqual(report["trigger"], "leftover check failed")
        self.assertEqual(report["steps"][0]["status"], "failed")
        self.assertIn("process list: proc_listallpids failed", report["steps"][0]["detail"])

    def test_a_failing_process_list_never_reports_the_stop_as_clean(self):
        # #193: after a stall with the process list failing, nothing is
        # known to be left, which is not "nothing left".
        code, log, _, out = self.run_watchdog(
            self.STALL, stall=3, env={"WATCHDOG_FAKE_NO_PROCESS_LIST": "1", "WATCHDOG_NO_SUDO": "1"})
        self.assertEqual(code, 124, log)
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        statuses = {s["step"]: s["status"] for s in report["steps"]}
        self.assertEqual(statuses["processes of the run"], "failed")
        self.assertEqual(statuses["stop"], "failed")

    def test_a_failing_ps_costs_only_command_lines(self):
        # #193: ps now supplies only command lines. With it failing, a
        # detached leftover is still found by its marker and stopped, the
        # list is complete (no warning), and the failure is noted.
        secs = str(3000 + uuid.uuid4().int % 900)
        tag = f"ps-down-{uuid.uuid4().hex[:8]}"
        try:
            code, log, _, out = self.run_watchdog(
                [sys.executable, "-c",
                 "import subprocess, sys; subprocess.Popen([sys.executable, '-c', "
                 f"'import time; time.sleep({secs}) # {tag}'], start_new_session=True, "
                 "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)"],
                env={"WATCHDOG_PS": self.failing_tool("ps")})
            self.assertEqual(code, 124, log)
            self.assertNotIn("::warning", log)
            time.sleep(0.5)
            self.assertFalse(alive(tag), "the leftover was not found without ps")
            with open(os.path.join(out, "diagnosis.json")) as f:
                report = json.load(f)
            step = [s for s in report["steps"] if s["step"] == "processes of the run"][0]
            self.assertEqual(step["status"], "ok", step)
            self.assertIn("ps (command lines only): exit 2", step["detail"])
        finally:
            subprocess.run(["pkill", "-f", tag], capture_output=True)

    def test_the_unverifiable_recheck_keeps_what_is_still_there(self):
        # #193: the recheck asks the kernel pid by pid, so it cannot fail
        # and drop processes nobody could check; only what is gone goes.
        os.environ["WATCHDOG_FAKE_UNREADABLE"] = "all"
        os.environ["WATCHDOG_NO_SUDO"] = "1"
        try:
            wd = self.load()
        finally:
            del os.environ["WATCHDOG_FAKE_UNREADABLE"], os.environ["WATCHDOG_NO_SUDO"]
        live = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        gone = subprocess.Popen(["/usr/bin/true"])
        gone_start = (int(time.time()), 1)
        gone.wait()
        try:
            run = wd.Run(999999, None, uuid.uuid4().hex, time.time() - 30)
            procs = {live.pid: (1, live.pid, wd.start_time(live.pid), "live"),
                     gone.pid: (1, gone.pid, gone_start, "gone")}
            real = wd.start_time
            # The environment read itself must pass the identity check for
            # the gone one, so it is the recheck that drops it.
            calls = {}

            def start_time(pid):
                calls[pid] = calls.get(pid, 0) + 1
                return gone_start if pid == gone.pid and calls[pid] == 1 else real(pid)
            wd.start_time = start_time
            try:
                run._marked(procs, set())
            finally:
                wd.start_time = real
            self.assertEqual(run.unverifiable, {live.pid: "live"})
            self.assertEqual(run.sudo_problem, "sudo turned off")
        finally:
            live.kill()
            live.wait()

    def test_a_failed_leftover_check_still_reports_the_unverifiable(self):
        # Codex on #197: the failed-discovery report runs first; processes
        # nobody could check must reach it.
        wd = self.load()
        run = wd.Run(999999, None, uuid.uuid4().hex, time.time())
        run.root_alive = False
        run.discovery_problems = ["process list: proc_listallpids failed"]
        run.sudo_problem = "sudo turned off"
        run.unverifiable = {424242: "/bin/sleep 100"}
        out = tempfile.mkdtemp(prefix="watchdog-test-")
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()) as printed:  # not a real annotation on CI
            wd.report_failed_discovery(run, out, 0, time.monotonic())
        self.assertIn("::warning", printed.getvalue())
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        self.assertEqual([e["pid"] for e in report["unverifiable"]], [424242])
        self.assertIn("sudo turned off", report["unverifiable"][0]["why"])
        self.assertEqual([s["step"] for s in report["steps"]], ["processes of the run", "environment check"])

    def test_lsof_exiting_1_is_an_error_only_when_it_says_so(self):
        # Codex on #197: lsof exits 1 both when nothing holds the terminal
        # and on an error; only the error writes to stderr (no -Q in 4.91).
        quiet = self.failing_tool("lsof", "#!/bin/sh\nexit 1\n")
        loud = self.failing_tool("lsof", "#!/bin/sh\necho 'lsof: status error on /dev/ttys0: Operation not permitted' >&2\n"
                                         "exit 1\n")
        for tool, status in ((quiet, "ok"), (loud, "partial")):
            code, log, _, out = self.run_watchdog(self.STALL, stall=3, env={"WATCHDOG_LSOF": tool})
            self.assertEqual(code, 124, log)
            with open(os.path.join(out, "diagnosis.json")) as f:
                report = json.load(f)
            step = [s for s in report["steps"] if s["step"] == "processes of the run"][0]
            self.assertEqual(step["status"], status, step)
        self.assertIn("lsof: exit 1: lsof: status error", step["detail"])

    def test_a_failed_scan_during_the_stop_is_not_forgotten(self):
        # Codex on #197: the first scan of a stop fails, a later one works;
        # what the failed one may have missed cannot be found any more, so
        # the stop is not reported as clean.
        wd = self.load()
        run = wd.Run(999999, None, uuid.uuid4().hex, time.time())
        run.root_alive = False
        # The failed scan still finds a target (a pid no process has, so
        # nothing is signalled); later scans work and find nothing.
        looks = iter([(["process list: proc_listallpids failed"], {999998: "missed?"}), ([], {}), ([], {})])

        def members(deadline=None):
            run.discovery_problems, found = next(looks, ([], {}))
            return found
        run.members = members
        run.stop()
        self.assertEqual(run.discovery_problems, ["process list: proc_listallpids failed"])
        out = tempfile.mkdtemp(prefix="watchdog-test-")
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()):
            wd.record_stop(run, out)
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        self.assertEqual([s["status"] for s in report["steps"] if s["step"] == "stop"], ["failed"])

    def test_a_failed_snapshot_makes_the_exit_check_incomplete(self):
        # Codex on #197: a snapshot failed while the command ran, the last
        # look worked and found nothing. What that snapshot would have
        # remembered cannot be found any more: the check is reported as
        # incomplete (with a warning), not passed over in silence.
        wd = self.load()
        real = wd.processes
        calls = {"n": 0}

        def flaky(deadline=None, problems=None, foreign=None):
            calls["n"] += 1
            if calls["n"] <= 2:  # the first snapshots, while the command runs
                if problems is not None:
                    problems.append("process list: proc_listallpids failed")
                return {}
            return real(deadline, problems, foreign)
        wd.processes = flaky
        out = tempfile.mkdtemp(prefix="watchdog-test-")
        argv = sys.argv
        sys.argv = ["test-watchdog.py", "--stall", "20", "--out", out, "--", "sh", "-c", "sleep 2.5; exit 0"]
        import contextlib
        import io
        try:
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                code = wd.main()
        finally:
            sys.argv, wd.processes = argv, real
        self.assertGreaterEqual(calls["n"], 3)
        self.assertEqual(code, 0)
        self.assertIn("::warning title=test-watchdog::", printed.getvalue())
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        self.assertEqual(report["trigger"], "leftover check failed")
        self.assertEqual(report["steps"][0]["status"], "partial")
        self.assertIn("snapshot(s) while the command ran", report["steps"][0]["detail"])

    # ---- #206, #209 and the kernel reader's self-check -------------------

    def test_a_kernel_reader_that_does_not_match_this_process_lists_nothing(self):
        # b9 on #206: kinfo_proc offsets measured on one macOS; read wrong on
        # another layout, parents and owners would decide what is signalled.
        # A mismatch lists nothing, says why, and no process is signalled.
        wd = self.load()
        real = wd.kernel_info
        # Each field read wrong in turn: the parent, the real uid, the start.
        wrong = {
            "ppid": lambda r: (r[0] + 1,) + r[1:],
            "real uid": lambda r: r[:2] + (r[2] + 1,) + r[3:],
            "start": lambda r: r[:3] + ((r[3][0], r[3][1] + 1),) + r[4:],
        }
        bystander = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        calls = []
        real_kill = wd.os.kill
        wd.os.kill = lambda *a: calls.append(a)
        try:
            for field, corrupt in wrong.items():
                wd.kernel_info = lambda pid, c=corrupt: (lambda r: None if r is None else c(r))(real(pid))
                wd._kernel_problem.clear()
                problems = []
                self.assertEqual(wd.processes(problems=problems), {}, field)
                self.assertTrue(any(field in p and "does not match this process" in p for p in problems),
                                (field, problems))
                run = wd.Run(bystander.pid, None, uuid.uuid4().hex, time.time())
                run.root_alive = False
                run.stop()
                self.assertEqual(calls, [], field)
                self.assertTrue(wd.incomplete(run), field)
        finally:
            wd.os.kill, wd.kernel_info = real_kill, real
            wd._kernel_problem.clear()
            bystander.kill()
            bystander.wait()
        self.assertIsNone(wd.kernel_problem(), "the real reader matches this process")

    def test_the_watchdogs_own_ancestors_are_confirmed_by_identity(self):
        wd = self.load()
        chain = wd.own_ancestors()
        self.assertIn(os.getppid(), chain)
        self.assertEqual(chain[os.getppid()], wd.start_time(os.getppid()))

    def test_the_parent_shell_is_never_reported_as_unverifiable(self):
        # #209: the shell that starts the watchdog started just before it
        # and its environment cannot be read; it is the watchdog's own
        # parent, confirmed by identity, never the run's.
        tag = f"parent-shell-{uuid.uuid4().hex[:8]}"
        out = tempfile.mkdtemp(prefix="watchdog-test-")
        r = subprocess.run(["/bin/sh", "-c", f'"$0" "$1" --stall 20 --out "$2" -- sh -c "echo hi"; : {tag}',
                            sys.executable, WATCHDOG, out],
                           capture_output=True, text=True, timeout=90,
                           env=dict(os.environ, WATCHDOG_NO_SUDO="1", WATCHDOG_NO_SNAPSHOTS="1",
                                    WATCHDOG_FAKE_UNREADABLE="all"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn(tag, r.stdout + r.stderr)

    def test_a_reused_ancestor_pid_is_not_excused(self):
        # #209: an ancestor's pid now naming another process is not the
        # ancestor; that process stays unverifiable (and is not signalled).
        os.environ["WATCHDOG_FAKE_UNREADABLE"] = "all"
        os.environ["WATCHDOG_NO_SUDO"] = "1"
        try:
            wd = self.load()
        finally:
            del os.environ["WATCHDOG_FAKE_UNREADABLE"], os.environ["WATCHDOG_NO_SUDO"]
        started = time.time()
        tag = f"reused-{uuid.uuid4().hex[:8]}"
        # Not a child of this process (that would make it the watchdog's own
        # helper here): started by a shell that exits at once.
        subprocess.run(["/bin/sh", "-c", f"{sys.executable} -c 'import time; time.sleep(60) # {tag}' >/dev/null 2>&1 &"],
                       check=True)
        time.sleep(0.3)
        found = subprocess.run(["pgrep", "-f", tag], capture_output=True, text=True).stdout.split()
        self.assertEqual(len(found), 1, found)

        class Stranger:
            pid = int(found[0])
            def kill(self): subprocess.run(["kill", "-9", str(self.pid)])
            def wait(self): pass
        stranger = Stranger()
        try:
            run = wd.Run(999999, None, uuid.uuid4().hex, started)
            run.root_alive = False
            sec, usec = wd.start_time(stranger.pid)
            run.ancestors = {stranger.pid: (sec, (usec + 1) % 1000000)}  # the ancestor once had this pid
            run.members()
            self.assertIn(stranger.pid, run.unverifiable)
            run.ancestors = {stranger.pid: (sec, usec)}  # the very process: excused
            run.members()
            self.assertNotIn(stranger.pid, run.unverifiable)
        finally:
            stranger.kill()
            stranger.wait()

    def test_the_tree_runs_through_another_users_process(self):
        # #206: root (ours) -> another user's process (as sudo starts) ->
        # ours again. The middle one is the run's but never signalled; the
        # one below it is the run's and may be stopped.
        wd = self.load()
        start = {1001: (100, 1), 1002: (100, 2), 1003: (100, 3)}
        kernel = {1001: (1, 1001, os.getuid(), start[1001], os.getuid()),
                  1002: (1001, 1002, 0, start[1002], 0),
                  1003: (1002, 1003, os.getuid(), start[1003], os.getuid())}
        real = wd.kernel_info
        wd.kernel_info = lambda pid: kernel.get(pid)
        try:
            run = wd.Run(1001, None, uuid.uuid4().hex, time.time())
            procs = {1001: (1, 1001, start[1001], "root"), 1003: (1002, 1003, start[1003], "ours under sudo")}
            foreign = {1002: (1001, 1002, start[1002], "sudo thing", 0, 0)}
            members = run._tree(procs, foreign)
        finally:
            wd.kernel_info = real
        self.assertEqual(set(members), {1001, 1003})
        self.assertEqual(set(run._foreign_linked), {1002})
        self.assertEqual(run._foreign_linked[1002][2:], (0, 0))

    def test_another_users_leftover_is_running_never_signalled(self):
        # #206, Kevin: stopped, running and unverified apart; another
        # user's process still there is running, not stopped.
        wd = self.load()
        run = wd.Run(999999, None, uuid.uuid4().hex, time.time())
        run.root_alive = False
        alive = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        calls = []
        real_kill = wd.os.kill
        wd.os.kill = lambda *a: calls.append(a)
        try:
            ident = wd.start_time(alive.pid)

            def members(deadline=None):
                run.discovery_problems = []
                run.foreign_members = {alive.pid: (ident, "a root process sudo started", 0, 0)}
                return {}
            run.members = members
            run.stop()
        finally:
            wd.os.kill = real_kill
        try:
            self.assertEqual(calls, [])
            out = tempfile.mkdtemp(prefix="watchdog-test-")
            import contextlib
            import io
            with contextlib.redirect_stdout(io.StringIO()):
                wd.record_stop(run, out)
            with open(os.path.join(out, "diagnosis.json")) as f:
                report = json.load(f)
            self.assertEqual([s["status"] for s in report["steps"] if s["step"] == "stop"], ["failed"])
            running = report["outcome"]["running"]
            self.assertEqual([e["pid"] for e in running], [alive.pid])
            self.assertIn("another user's process (real uid 0", running[0]["why"])
            self.assertIsNone(alive.poll())
        finally:
            alive.kill()
            alive.wait()

    @unittest.skipUnless(subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0,
                         "needs passwordless sudo (CI has it)")
    def test_a_root_leftover_from_sudo_fails_the_run_and_is_reported_running(self):
        # #206 end to end: the command leaves a root process (sudo) behind.
        # Before, it was not seen and the run passed; now it is a leftover
        # confirmed running, never signalled: exit 124. It ends by itself.
        code, log, _, out = self.run_watchdog(
            ["sh", "-c", "sudo -n /bin/sleep 6 & sleep 2; exit 0"], stall=30)
        self.assertEqual(code, 124, log)
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        running = report["outcome"]["running"]
        self.assertTrue(any("another user's process" in e["why"] for e in running), running)

    def test_what_a_command_leaves_in_its_group_as_it_exits_is_found(self):
        # Codex on #215: a command that exits before any snapshot ran. Its
        # leftover has no marker (env -i) and stays in its group: found by
        # the last look before the command is reaped, and stopped.
        secs = str(3000 + uuid.uuid4().int % 900)
        marker = f"sleep {secs}"
        try:
            code, log, _, out = self.run_watchdog(
                # Not on the run's terminal either: only its group links it.
                ["sh", "-c", f"env -i /bin/sleep {secs} </dev/null >/dev/null 2>&1 & exit 0"],
                env={"WATCHDOG_NO_SNAPSHOTS": "1", "WATCHDOG_NO_SUDO": "1"})
            self.assertEqual(code, 124, log)
            time.sleep(0.5)
            self.assertFalse(alive(marker), "the leftover was missed")
        finally:
            subprocess.run(["pkill", "-f", marker], capture_output=True)

    @unittest.skipUnless(subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0,
                         "needs passwordless sudo (CI has it)")
    def test_a_root_leftover_of_a_command_that_exits_at_once_is_reported_running(self):
        # Codex on #215: sudo's process left by a command that exits at once,
        # before any snapshot: still found (by the look before reaping),
        # reported as another user's process still running; exit 124.
        code, log, _, out = self.run_watchdog(["sh", "-c", "sudo -n /bin/sleep 6 & exit 0"],
                                              env={"WATCHDOG_NO_SNAPSHOTS": "1"})
        self.assertEqual(code, 124, log)
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        self.assertTrue(any("another user's process" in e["why"] for e in report["outcome"]["running"]), report)

    def test_without_waitid_the_missing_last_look_is_reported_partial(self):
        # b9 on #215: a Python without os.waitid/WNOWAIT cannot take the last
        # look before reaping; that is reported (partial, with a warning),
        # never skipped in silence. The command's status is kept.
        code, log, _, out = self.run_watchdog(["sh", "-c", "echo hi; exit 0"],
                                              env={"WATCHDOG_FAKE_NO_WAITID": "1", "WATCHDOG_NO_SUDO": "1"})
        self.assertEqual(code, 0, log)
        self.assertIn("::warning title=test-watchdog::", log)
        with open(os.path.join(out, "diagnosis.json")) as f:
            report = json.load(f)
        step = report["steps"][0]
        self.assertEqual(step["status"], "partial", step)
        self.assertIn("last look before reaping the command was not taken", step["detail"])

    def test_a_stop_never_signals_another_users_process_in_the_group(self):
        # Codex on #215 (P1): a group signal reaches every member of the
        # command's group, another user's too (sudo's), wherever the
        # permissions allow. The stop signals the command itself and this
        # user's checked members, one by one; never the group, never theirs.
        wd = self.load()
        root = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        theirs = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)

        class Reaped:
            def wait(self, timeout=None):
                return root.wait(timeout=5)
        real_processes, real_kill, real_killpg = wd.processes, wd.os.kill, wd.os.killpg
        kills, groups = [], []

        def listing(deadline=None, problems=None, foreign=None):
            procs = real_processes(deadline, problems, foreign)
            # "theirs" in the command's group, as another user's process.
            row = procs.pop(theirs.pid)
            if foreign is not None:
                foreign[theirs.pid] = (row[0], root.pid, row[2], "a process sudo started", 0, 0)
            return procs
        wd.processes = listing
        wd.os.kill = lambda pid, sig: (kills.append(pid), real_kill(pid, sig))
        wd.os.killpg = lambda *a: groups.append(a)
        try:
            run = wd.Run(root.pid, None, uuid.uuid4().hex, time.time(), Reaped())
            run.stop()
        finally:
            wd.processes, wd.os.kill, wd.os.killpg = real_processes, real_kill, real_killpg
        try:
            self.assertEqual(groups, [], "a group signal was sent")
            self.assertNotIn(theirs.pid, kills, "another user's process was signalled")
            self.assertIn(root.pid, kills, "the command itself was not stopped")
            self.assertIsNone(theirs.poll())
            self.assertIn(theirs.pid, run.outcome["running"])
        finally:
            theirs.kill()
            theirs.wait()

    def test_the_spindump_is_of_a_process_still_there(self):
        # Codex on #215: only another user's process left: the spindump is
        # of it, not of the reaped command; none left: none.
        wd = self.load()
        run = wd.Run(999999, None, uuid.uuid4().hex, time.time())
        self.assertIsNone(wd.spindump_target({}, run))
        run.foreign_members = {4242: ((1, 2), "sudo's", 0, 0)}
        self.assertEqual(wd.spindump_target({}, run), 4242)
        self.assertEqual(wd.spindump_target({777: "ours"}, run), 777)

    def test_a_member_known_only_through_the_live_tree_is_still_stopped(self):
        # Codex on #215: no group signal any more; a child of the command
        # with no marker, not on the terminal, never snapshotted, is known
        # only through the command's tree. It is stopped all the same, and
        # reported as stopped, not lost when the command is reaped.
        wd = self.load()
        root = subprocess.Popen(
            [sys.executable, "-c", "import subprocess, time; c = subprocess.Popen(['/bin/sleep', '60'], "
             "stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env={}); "
             "print(c.pid, flush=True); time.sleep(60)"],
            stdout=subprocess.PIPE, text=True, start_new_session=True)
        child = int(root.stdout.readline())

        class Command:
            def wait(self, timeout=None):
                return root.wait(timeout=timeout)
        try:
            run = wd.Run(root.pid, None, uuid.uuid4().hex, time.time(), Command())
            run.stop()
            time.sleep(0.3)
            self.assertIsNone(wd.start_time(child), "the command's child survived the stop")
            self.assertIn(child, run.outcome["stopped"])
        finally:
            subprocess.run(["kill", "-9", str(child)], capture_output=True)
            if root.poll() is None:
                root.kill()
            root.wait()


if __name__ == "__main__":
    unittest.main()
