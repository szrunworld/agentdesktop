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


MARKER = "TEST_WATCHDOG_RUN"
_libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)


def process_environment(pid):
    """The environment of a process from KERN_PROCARGS2, or None when the
    kernel refuses. For platform binaries such as /bin/sleep it answers with
    the environment stripped (an empty list) unless the caller is root."""
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


def processes():
    """pid -> (ppid, pgid, start, command) for every process; start is the
    process start time (with the pid it identifies a process; pids are
    reused)."""
    ok, rows, _ = run_step(["ps", "-axo", "pid=,ppid=,pgid=,uid=,lstart=,command="], timeout=10)
    procs = {}
    for row in rows.splitlines():
        parts = row.split()
        if len(parts) < 10 or not all(p.isdigit() for p in parts[:4]):
            continue
        if int(parts[3]) != os.getuid():
            continue  # only this user's processes can belong to the run
        try:
            start = time.mktime(time.strptime(" ".join(parts[4:9]), "%a %b %d %H:%M:%S %Y"))
        except ValueError:
            continue
        procs[int(parts[0])] = (int(parts[1]), int(parts[2]), start, " ".join(parts[9:]))
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

    def __init__(self, root, tty, marker, started_at):
        self.root, self.tty = root, tty
        self.marker, self.started_at = marker, started_at
        self.seen = {}  # pid -> (start, command)
        self.unverifiable = {}  # pid -> command: started since the run, environment unreadable
        self.last_snapshot = 0.0

    def snapshot(self, force=False):
        now = time.monotonic()
        if not force and now - self.last_snapshot < 1.0:
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

    def members(self):
        """pid -> command of every live process of the run."""
        procs = processes()
        live = self._tree(procs)
        for pid, (start, cmd) in self.seen.items():
            if pid in procs and procs[pid][2] == start:
                live[pid] = procs[pid][3]
        if self.tty:
            _, out, _ = run_step(["lsof", "-t", self.tty], timeout=10)
            for t in out.split():
                if t.isdigit() and int(t) in procs and int(t) != os.getpid():
                    live[int(t)] = procs[int(t)][3]
        live.update(self._marked(procs, set(live)))
        return dict(sorted(live.items()))

    def _marked(self, procs, known):
        """Processes started since the run began that carry its marker."""
        tag = f"{MARKER}={self.marker}"
        found, unread = {}, []
        for pid, (_, _, start, cmd) in procs.items():
            if pid in known or pid == os.getpid() or start < self.started_at - 1:
                continue
            if cmd == "<defunct>" or (cmd.startswith("(") and cmd.endswith(")")):
                continue  # already exited (a zombie, or gone while ps ran)
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
                                   ",".join(map(str, unread))], timeout=10)
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
        return found

    def stop(self):
        """Take the whole set first, then kill: the group, then each one."""
        targets = self.members()
        try:
            os.killpg(self.root, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        for _ in range(2):
            for pid in targets:
                try:
                    os.kill(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            time.sleep(0.2)
            targets = self.members()


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

    procs = run.members()
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
    run = Run(child.pid, tty, marker, started_at)
    started, finished = [], set()
    last_output = time.monotonic()
    pending = b""
    while True:
        ready, _, _ = select.select([master], [], [], 0.25)
        if ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if data:
                last_output = time.monotonic()
                sys.stdout.buffer.write(data)
                sys.stdout.flush()
                pending += data
                *lines, pending = pending.split(b"\n")
                for raw in lines:
                    line = ANSI.sub("", raw.decode("utf-8", "replace"))
                    if (m := FINISHED.search(line)):
                        finished.add(m.group(1) or m.group(2))
                    elif (m := STARTED.search(line)):
                        started.append(m.group(1) or m.group(2))
        # Checked on every turn, data or not (Codex on #188): a leftover
        # writing to the terminal must not keep the exit from being seen.
        if child.poll() is None:
            run.snapshot()
        else:
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
                sys.stdout.buffer.write(data)
            sys.stdout.flush()
            # The command is done; anything of its run still alive is a
            # leftover (a Runtime, a helper, a background task): evidence,
            # then stop it and fail.
            left = run.members()
            if not left and run.unverifiable:
                # Nothing confirmed as the run's, but processes started since
                # it began could not be checked: reported, left alone, and the
                # command's own status kept (Codex and b9 on #188; locally
                # they are likely other sessions', and CI has sudo).
                report_unverifiable(run, args.out, child.returncode, last_output)
                return child.returncode
            if left:
                diagnose(run, started, finished, args.out,
                         f"the command exited ({child.returncode}) but {len(left)} process(es) of its run remain",
                         "leftover processes", last_output, child.returncode)
                run.stop()
                print("test-watchdog: stopped processes left behind by the run (exit 124)", flush=True)
                return 124
            return child.returncode
        if time.monotonic() - last_output > args.stall:
            run.snapshot(force=True)
            diagnose(run, started, finished, args.out,
                     f"output stalled for {args.stall:.0f} s (waiting on something, not necessarily a deadlock)",
                     "output stalled", last_output, None)
            run.stop()
            child.wait()
            print(f"test-watchdog: stopped after output stalled for {args.stall:.0f} s (exit 124)", flush=True)
            return 124


if __name__ == "__main__":
    sys.exit(main())
