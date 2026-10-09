#!/usr/bin/env python3
"""Run a test command and capture evidence if it stalls (#183).

The engine tests on CI once sat for eight minutes after every test had
started and none had finished. Two things hid the cause:

* Through a pipe, the test process buffers its output, so the log showed
  every "started" line at one timestamp and no result at all. Here the
  command runs on a pseudo-terminal, so each line arrives when written and
  the log shows which tests really never finished.
* Nothing recorded what the process was doing. Here, when no output arrives
  for --stall seconds, the unfinished tests are listed, every process of
  the run that could be found is sampled (`sample`, and `spindump` when sudo
  works without a password), a summary goes to the log and the full reports
  to --out, and the command is stopped with exit status 124.

No output for --stall seconds means only that output stalled: the run may
be waiting on something slow, not necessarily deadlocked. The evidence is
there to tell which.

Every external step (ps, lsof, sample, spindump, cleanup) has a time
limit, and the whole collection has a budget. `diagnosis.json` in --out is
rewritten after every step with the trigger, the time since the last
output, the command's exit status, the processes and each step's outcome,
so a step that fails or times out leaves the rest of the evidence and says
what is missing.

Limits: not every process can be found. The command's environment carries
a marker (TEST_WATCHDOG_RUN) that every descendant inherits, so one that
left the run's terminal, group and session is still found, unless it
emptied its own environment (env -i). Reading another process's
environment needs root for platform binaries (/bin/sleep, perl, codesign);
without passwordless sudo those are reported as unverifiable and never
killed on a guess.

If the command exits but processes of its run remain (a Runtime, a
helper, a background task that may still hold the terminal), the same
evidence is collected, they are stopped and the status is 124: output is
drained without blocking, so a leftover can never hang the watchdog.

Otherwise the command's own exit status is returned. Usage:

    test-watchdog.py --stall 120 --out DIR -- swift test --package-path engine
"""
import argparse
import ctypes
import ctypes.util
import os
import struct
import uuid
import pty
import re
import select
import signal
import subprocess
import sys
import json
import time

# Time limits for each external step and for the whole collection; the
# environment can lower them (the self-tests do).
STEP_TIMEOUT = float(os.environ.get("WATCHDOG_STEP_TIMEOUT", "30"))
DIAGNOSIS_BUDGET = float(os.environ.get("WATCHDOG_DIAGNOSIS_BUDGET", "150"))
# The sampler; the self-tests point it at a tool that fails.
SAMPLE = os.environ.get("WATCHDOG_SAMPLE", "sample")
# The self-tests turn sudo off to act out a machine without passwordless sudo.
USE_SUDO = os.environ.get("WATCHDOG_NO_SUDO") != "1"
# Self-test switches, so a case does not depend on one machine's timing or on
# what its kernel shows: no snapshots at all, and environments treated as
# unreadable ("all", or a comma list of pids).
SNAPSHOTS = os.environ.get("WATCHDOG_NO_SNAPSHOTS") != "1"
FAKE_UNREADABLE = os.environ.get("WATCHDOG_FAKE_UNREADABLE", "")


MARKER = "TEST_WATCHDOG_RUN"
_libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)


def process_environment(pid):
    """The environment of a process from KERN_PROCARGS2, or None when the
    kernel refuses. For platform binaries such as /bin/sleep it answers with
    the environment stripped (an empty list) unless the caller is root."""
    if FAKE_UNREADABLE == "all" or str(pid) in FAKE_UNREADABLE.split(","):
        return []
    mib = (ctypes.c_int * 2)(1, 8)  # CTL_KERN, KERN_ARGMAX
    argmax, n = ctypes.c_int(), ctypes.c_size_t(ctypes.sizeof(ctypes.c_int))
    if _libc.sysctl(mib, 2, ctypes.byref(argmax), ctypes.byref(n), None, 0) != 0:
        return None
    mib = (ctypes.c_int * 3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t(argmax.value)
    buf = ctypes.create_string_buffer(size.value)
    if _libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0 or size.value < 4:
        return None
    raw = buf.raw[:size.value]
    argc = struct.unpack("i", raw[:4])[0]
    rest = raw[4:]
    i = rest.find(b"\0")
    if i < 0:
        return None
    while i < len(rest) and rest[i] == 0:
        i += 1
    parts = [p for p in rest[i:].split(b"\0")]
    return [p.decode("utf-8", "replace") for p in parts[argc:] if p]


def within(deadline, limit):
    """A step's time limit: its own, or less when a deadline is nearer
    (never below half a second, so the step can still answer)."""
    if deadline is None:
        return limit
    return max(0.5, min(limit, deadline - time.monotonic()))


def run_step(args, timeout=None):
    """Run an external step with a time limit; (ok, stdout, detail)."""
    limit = timeout or STEP_TIMEOUT
    try:
        # Its own process group, so a timeout stops whatever the step started too.
        p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL,
                             text=True, start_new_session=True)
    except OSError as e:
        return False, "", f"could not run: {e}"
    try:
        out, _ = p.communicate(timeout=limit)
        return p.returncode == 0, out, f"exit {p.returncode}"
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        p.communicate()
        return False, "", f"timed out after {limit:.0f} s"

STARTED = re.compile(r'Test (?:"(.+?)"|(\S+?\(.*?\))) started')
FINISHED = re.compile(r'Test (?:"(.+?)"|(\S+?\(.*?\))) (?:passed|failed|skipped)')
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# Frames that mean a thread is parked; used to pick the threads worth showing.
WAITING = ("semaphore_wait", "__psynch_cvwait", "__ulock_wait", "__psynch_mutexwait", "__workq_kernreturn",
           "mach_msg", "kevent", "read", "__wait4", "waitUntilExit", "dispatch_sync", "_dispatch_sync")


def parse_ps_row(row):
    """One row of `ps -o pid=,ppid=,pgid=,uid=,stat=,lstart=,command=`:
    (pid, ppid, pgid, uid, stat, start, command), or None. Every column but
    the last has a fixed number of fields (lstart has five), so the command
    is the rest of the row, spaces and all."""
    parts = row.split(None, 10)
    if len(parts) < 11 or not all(p.isdigit() for p in parts[:4]):
        return None
    try:
        start = time.mktime(time.strptime(" ".join(parts[5:10]), "%a %b %d %H:%M:%S %Y"))
    except ValueError:
        return None
    return int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]), parts[4], start, parts[10].rstrip()


def processes(deadline=None):
    """pid -> (ppid, pgid, start, command) for every live process; start is
    the process start time (with the pid it identifies a process; pids are
    reused). Zombies are left out: they have already exited, cannot be
    killed and run nothing (b9 on #194)."""
    ok, rows, _ = run_step(["ps", "-axo", "pid=,ppid=,pgid=,uid=,stat=,lstart=,command="],
                           timeout=within(deadline, 10))
    procs = {}
    for row in rows.splitlines():
        parsed = parse_ps_row(row)
        if parsed is None:
            continue
        pid, ppid, pgid, uid, stat, start, command = parsed
        if uid != os.getuid() or stat.startswith("Z"):
            continue  # only this user's processes can belong to the run
        procs[pid] = (ppid, pgid, start, command)
    return procs


class Run:
    """Every process that belongs to one run of the command.

    Four sources, because each misses something (Codex on #188):
    * the run's marker: the command gets TEST_WATCHDOG_RUN=<uuid> in its
      environment, which every descendant inherits whatever it does to its
      session, group or parent; a process of this user started since the
      run began that carries the marker is part of it. The kernel shows the
      environment of platform binaries (/bin/sleep, perl, codesign) only to
      root, so those are read with `sudo -n ps -E` when that works (CI);
      where it does not, they are reported as unverifiable and left alone,
      never killed on a guess. A child that empties its own environment
      (env -i) is not found this way;
    * the live tree: the root, its descendants, its process group;
    * every descendant seen while the command ran, remembered with its
      start time (a background process started with setsid or in a new
      process group is re-parented to launchd when the command exits, and
      then neither its parent nor its group leads back here);
    * every process that still has the run's terminal open.
    A remembered pid counts only while its start time is unchanged.
    """

    def __init__(self, root, tty, marker, started_at, child=None):
        self.root, self.tty, self.child = root, tty, child
        self.marker, self.started_at = marker, started_at
        self.seen = {}  # pid -> (start, command)
        self.unverifiable = {}  # pid -> command: started since the run, environment unreadable
        self.last_snapshot = 0.0
        # Once the command has exited its pid and group id may be given to
        # unrelated processes: from then on neither is used to find or stop
        # anything (Codex on #188).
        self.root_alive = True
        self.not_stopped = {}  # what stop() could not end

    def snapshot(self, force=False):
        now = time.monotonic()
        if not SNAPSHOTS or (not force and now - self.last_snapshot < 1.0):
            return
        self.last_snapshot = now
        procs = processes()
        for pid, cmd in self._tree(procs).items():
            self.seen.setdefault(pid, (procs[pid][2], cmd))

    def _tree(self, procs):
        found = {pid for pid, (_, pgid, _, _) in procs.items() if pgid == self.root}
        found.add(self.root)
        changed = True
        while changed:
            changed = False
            for pid, (ppid, _, _, _) in procs.items():
                if ppid in found and pid not in found:
                    found.add(pid)
                    changed = True
        return {pid: procs[pid][3] for pid in found if pid in procs}

    def members(self, deadline=None):
        """pid -> command of every live process of the run. With a deadline,
        every step is limited to the time left (Codex on #188)."""
        procs = processes(deadline)
        # The live tree only while the command runs; afterwards only what is
        # confirmed: seen with the same start time, the marker, the terminal.
        live = self._tree(procs) if self.root_alive else {}
        for pid, (start, cmd) in self.seen.items():
            if pid in procs and procs[pid][2] == start:
                live[pid] = procs[pid][3]
        if self.tty:
            _, out, _ = run_step(["lsof", "-t", self.tty], timeout=within(deadline, 10))
            for t in out.split():
                if t.isdigit() and int(t) in procs and int(t) != os.getpid():
                    live[int(t)] = procs[int(t)][3]
        live.update(self._marked(procs, set(live), deadline))
        return dict(sorted(live.items()))

    def _own_helpers(self, procs):
        """The watchdog's own helper processes (ps, lsof, sudo and what they
        start), which are never part of the run (Codex on #188: the snapshot
        ps showed up as an unverifiable leftover)."""
        mine = {os.getpid()}
        changed = True
        while changed:
            changed = False
            for pid, (ppid, _, _, _) in procs.items():
                if ppid in mine and pid not in mine and pid != self.root:
                    mine.add(pid)
                    changed = True
        return mine

    def _marked(self, procs, known, deadline=None):
        """Processes started since the run began that carry its marker."""
        tag = f"{MARKER}={self.marker}"
        found, unread = {}, []
        helpers = self._own_helpers(procs)
        for pid, (_, _, start, cmd) in procs.items():
            if pid in known or pid in helpers or start < self.started_at - 1:
                continue
            if cmd.startswith("(") and cmd.endswith(")"):
                continue  # gone while ps ran (zombies are already left out)
            env = process_environment(pid)
            # For platform binaries the kernel returns the arguments with the
            # environment stripped, not an error: an empty environment cannot
            # be checked either (nor can one emptied with env -i).
            if not env:
                unread.append(pid)
            elif tag in env:
                found[pid] = cmd
        self.unverifiable = {}
        if unread and USE_SUDO:
            ok, out, _ = run_step(["sudo", "-n", "ps", "-E", "-ww", "-o", "pid=,command=", "-p",
                                   ",".join(map(str, unread))], timeout=within(deadline, 10))
            readable = set()
            if ok:
                for row in out.splitlines():
                    head = row.strip().split(None, 1)
                    if head and head[0].isdigit():
                        readable.add(int(head[0]))
                        if tag in row:
                            found[int(head[0])] = procs[int(head[0])][3]
            self.unverifiable = {pid: procs[pid][3] for pid in unread if pid not in readable}
        elif unread:
            self.unverifiable = {pid: procs[pid][3] for pid in unread}
        if self.unverifiable:
            # Only what is still there, as the same process (same start time).
            now = processes(deadline)
            self.unverifiable = {pid: cmd for pid, cmd in self.unverifiable.items()
                                 if pid in now and now[pid][2] == procs[pid][2]}
        return found

    def stop(self):
        """Take the whole set first, then kill: the group (only while the
        command still runs, so the group id is surely its own), then each
        confirmed process."""
        targets = self.members()
        if self.root_alive:
            try:
                os.killpg(self.root, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            # Reap the command at once, within a limit: unreaped, it would
            # be reported as not stopped (#194). Once reaped its pid and group
            # id may be reused, so from then on neither is used.
            if self.child is not None:
                try:
                    self.child.wait(timeout=2)
                    self.root_alive = False
                except subprocess.TimeoutExpired:
                    pass
        # Up to five rounds of kill, wait, look again: a leftover may start a
        # detached child just before it dies, and the last look must be acted
        # on (Codex on #188). Each round kills only confirmed processes, as
        # members() gives them; no group signal once the command has exited.
        for _ in range(5):
            if not targets:
                break
            for pid in targets:
                try:
                    os.kill(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            time.sleep(0.2)
            targets = self.members()
        self.not_stopped = targets
        return targets


def summarise(sample_text, limit=400):
    """Each thread's header and its deepest frames (where it is parked), for
    the main thread and every thread whose stack shows a wait."""
    graph = sample_text.split("Call graph:", 1)[-1].split("Total number in stack", 1)[0]
    threads, current = [], None
    for line in graph.splitlines():
        if re.match(r"\s{4}\d+ Thread_", line):
            current = [line]
            threads.append(current)
        elif current is not None and line.strip():
            current.append(line)
    out = []
    for t in threads:
        if "main-thread" in t[0] or any(w in line for line in t[1:] for w in WAITING):
            out.append(t[0])
            if len(t) > 31:
                out.append("      ...")
            out.extend(t[-30:] if len(t) > 31 else t[1:])
    return out[:limit]


def diagnose(run, started, finished, out_dir, why, trigger, last_output, exit_status):
    """Collect evidence within DIAGNOSIS_BUDGET; diagnosis.json is rewritten
    after every step so a failed or slow step loses nothing collected."""
    os.makedirs(out_dir, exist_ok=True)
    began = time.monotonic()
    report = {"trigger": trigger, "why": why,
              "seconds_since_last_output": round(time.monotonic() - last_output, 1),
              "command_exit_status": exit_status, "steps": []}

    def save():
        with open(os.path.join(out_dir, "diagnosis.json"), "w") as f:
            json.dump(report, f, indent=1, ensure_ascii=False)

    def step(name, status, detail=""):
        report["steps"].append({"step": name, "status": status, "detail": detail})
        save()
        if status != "ok":
            print(f"  step {name}: {status} {detail}", flush=True)

    print(f"\n=== test-watchdog: {why}; collecting evidence (#183) ===", flush=True)
    open_tests = [t for t in started if t not in finished]
    report.update(tests_started=len(started), tests_finished=len(finished), tests_unfinished=open_tests)
    print(f"tests started: {len(started)}, finished: {len(finished)}, still running: {len(open_tests)}", flush=True)
    for t in open_tests[:50]:
        print(f"  still running: {t}", flush=True)
    with open(os.path.join(out_dir, "unfinished-tests.txt"), "w") as f:
        f.write("\n".join(open_tests) + "\n")
    step("unfinished tests", "ok")

    procs = run.members(deadline=began + DIAGNOSIS_BUDGET)
    report["processes"] = [{"pid": pid, "command": cmd} for pid, cmd in procs.items()]
    step("processes of the run", "ok", f"{len(procs)} found")
    print("processes of the run:", flush=True)
    for pid, cmd in procs.items():
        print(f"  {pid} {cmd[:200]}", flush=True)
    if run.unverifiable:
        report["unverifiable"] = [{"pid": pid, "command": cmd} for pid, cmd in run.unverifiable.items()]
        step("environment check", "incomplete",
             f"{len(run.unverifiable)} process(es) started since the run whose environment could not be read; not killed")
        for pid, cmd in run.unverifiable.items():
            print(f"  unverifiable (left alone): {pid} {cmd[:160]}", flush=True)

    def remaining():
        return DIAGNOSIS_BUDGET - (time.monotonic() - began)

    for pid, cmd in procs.items():
        name = f"sample {pid}"
        # Each step gets at most what is left of the budget (Codex on #188);
        # too little left for a 3 s sample and it is skipped.
        if remaining() < 5:
            step(name, "skipped", f"diagnosis budget left: {max(remaining(), 0):.0f} s")
            continue
        path = os.path.join(out_dir, f"sample-{pid}.txt")
        ok, _, detail = run_step([SAMPLE, str(pid), "3", "-file", path], timeout=min(STEP_TIMEOUT, remaining()))
        if not ok or not os.path.exists(path):
            step(name, "failed", detail)
            continue
        step(name, "ok", path)
        print(f"--- sample {pid} ({cmd[:80]}): main thread and threads parked in a wait ---", flush=True)
        for line in summarise(open(path, errors="replace").read()):
            print(line, flush=True)

    if not USE_SUDO:
        step("spindump", "skipped", "sudo turned off")
    elif remaining() < 10:
        step("spindump", "skipped", f"diagnosis budget left: {max(remaining(), 0):.0f} s")
    else:
        target = next(iter(procs), run.root)
        ok, _, detail = run_step(["sudo", "-n", "spindump", str(target), "5", "-file",
                                  os.path.join(out_dir, "spindump.txt")], timeout=min(90, remaining()))
        step("spindump", "ok" if ok else "unavailable", detail)
    missing = [s["step"] for s in report["steps"] if s["status"] != "ok"]
    print(f"=== reports in {out_dir}; incomplete steps: {', '.join(missing) or 'none'} ===", flush=True)


def record_stop(run, out_dir):
    """Add the outcome of stop() to the log and to diagnosis.json."""
    path = os.path.join(out_dir, "diagnosis.json")
    try:
        with open(path) as f:
            report = json.load(f)
    except (OSError, ValueError):
        report = {"steps": []}
    if run.not_stopped:
        report["not_stopped"] = [{"pid": pid, "command": cmd} for pid, cmd in run.not_stopped.items()]
        report.setdefault("steps", []).append(
            {"step": "stop", "status": "failed", "detail": f"{len(run.not_stopped)} process(es) still running"})
        print(f"test-watchdog: could not stop {len(run.not_stopped)} process(es) of the run:", flush=True)
        for pid, cmd in run.not_stopped.items():
            print(f"  still running (not stopped): {pid} {cmd[:160]}", flush=True)
    else:
        report.setdefault("steps", []).append({"step": "stop", "status": "ok", "detail": "nothing of the run left"})
    os.makedirs(out_dir, exist_ok=True)
    with open(path, "w") as f:
        json.dump(report, f, indent=1, ensure_ascii=False)


def report_unverifiable(run, out_dir, exit_status, last_output):
    os.makedirs(out_dir, exist_ok=True)
    report = {"trigger": "unverifiable processes at exit",
              "why": "processes started since the run began whose environment could not be read; not stopped",
              "seconds_since_last_output": round(time.monotonic() - last_output, 1),
              "command_exit_status": exit_status, "processes": [],
              "unverifiable": [{"pid": pid, "command": cmd} for pid, cmd in run.unverifiable.items()],
              "steps": [{"step": "environment check", "status": "incomplete",
                         "detail": f"{len(run.unverifiable)} process(es) could not be checked; not stopped"}]}
    with open(os.path.join(out_dir, "diagnosis.json"), "w") as f:
        json.dump(report, f, indent=1, ensure_ascii=False)
    print(f"\n=== test-watchdog: the command exited ({exit_status}); {len(run.unverifiable)} process(es) started "
          "since the run began could not be checked (unverifiable, not stopped) ===", flush=True)
    for pid, cmd in run.unverifiable.items():
        print(f"  unverifiable (left alone): {pid} {cmd[:160]}", flush=True)
    print(f"=== report in {out_dir}; incomplete steps: environment check ===", flush=True)


class Output:
    """The command's output: echoed as it comes, parsed for test results,
    and the time of the last byte. The main loop and the final drain both
    go through take() (Codex on #188)."""

    def __init__(self):
        self.started, self.finished = [], set()
        self.last = time.monotonic()
        self._pending = b""

    def take(self, data):
        self.last = time.monotonic()
        sys.stdout.buffer.write(data)
        sys.stdout.flush()
        self._pending += data
        *lines, self._pending = self._pending.split(b"\n")
        for raw in lines:
            self._line(raw)

    def finish(self):
        """The last line may have no newline."""
        if self._pending:
            self._line(self._pending)
            self._pending = b""
        sys.stdout.flush()

    def _line(self, raw):
        line = ANSI.sub("", raw.decode("utf-8", "replace"))
        if (m := FINISHED.search(line)):
            self.finished.add(m.group(1) or m.group(2))
        elif (m := STARTED.search(line)):
            self.started.append(m.group(1) or m.group(2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stall", type=float, default=120)
    ap.add_argument("--out", default="test-watchdog")
    ap.add_argument("command", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    cmd = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not cmd:
        ap.error("no command")

    master, slave = pty.openpty()
    tty = os.ttyname(slave)
    marker = uuid.uuid4().hex
    env = dict(os.environ, **{MARKER: marker})
    started_at = time.time()
    child = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave, start_new_session=True, env=env)
    os.close(slave)
    run = Run(child.pid, tty, marker, started_at, child)
    output = Output()
    while True:
        ready, _, _ = select.select([master], [], [], 0.25)
        if ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if data:
                output.take(data)
        # Checked on every turn, data or not (Codex on #188): a leftover
        # writing to the terminal must not keep the exit from being seen.
        if child.poll() is None:
            run.snapshot()
        else:
            run.root_alive = False
            # Drain what is left, never blocking: a process the run left
            # behind can hold the terminal open forever (b9 on #188).
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.5)
                if not ready:
                    break
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                output.take(data)  # the same parser (Codex on #188)
            output.finish()
            # The command is done; anything of its run still alive is a
            # leftover (a Runtime, a helper, a background task): evidence,
            # then stop it and fail.
            left = run.members()
            if not left and run.unverifiable:
                # Nothing confirmed as the run's, but processes started since
                # it began could not be checked: reported, left alone, and the
                # command's own status kept (Codex and b9 on #188; locally
                # they are likely other sessions', and CI has sudo).
                report_unverifiable(run, args.out, child.returncode, output.last)
                return child.returncode
            if left:
                diagnose(run, output.started, output.finished, args.out,
                         f"the command exited ({child.returncode}) but {len(left)} process(es) of its run remain",
                         "leftover processes", output.last, child.returncode)
                run.stop()
                record_stop(run, args.out)
                print("test-watchdog: stopped processes left behind by the run (exit 124)", flush=True)
                return 124
            return child.returncode
        if time.monotonic() - output.last > args.stall:
            run.snapshot(force=True)
            diagnose(run, output.started, output.finished, args.out,
                     f"output stalled for {args.stall:.0f} s (waiting on something, not necessarily a deadlock)",
                     "output stalled", output.last, None)
            run.stop()
            record_stop(run, args.out)
            child.wait()
            print(f"test-watchdog: stopped after output stalled for {args.stall:.0f} s (exit 124)", flush=True)
            return 124


if __name__ == "__main__":
    sys.exit(main())
