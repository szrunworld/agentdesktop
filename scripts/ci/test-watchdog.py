#!/usr/bin/env python3
"""Run a test command and capture evidence if it stalls (#183).

The engine tests on CI once sat for eight minutes after every test had
started and none had finished. Two things hid the cause:

* Through a pipe, the test process buffers its output, so the log showed
  every "started" line at one timestamp and no result at all. Here the
  command runs on a pseudo-terminal, so each line arrives when written and
  the log shows which tests really never finished.
* Nothing recorded what the process was doing. Here, when no output arrives
  for --stall seconds, the unfinished tests are listed, every process in
  the command's tree is sampled (`sample`, and `spindump` when sudo works
  without a password), a summary goes to the log and the full reports to
  --out, and the command is stopped with exit status 124.

If the command exits but processes of its run remain (a Runtime, a
helper, a background task that may still hold the terminal), the same
evidence is collected, they are stopped and the status is 124: output is
drained without blocking, so a leftover can never hang the watchdog.

Otherwise the command's own exit status is returned. Usage:

    test-watchdog.py --stall 120 --out DIR -- swift test --package-path engine
"""
import argparse
import os
import pty
import re
import select
import signal
import subprocess
import sys
import time

STARTED = re.compile(r'Test (?:"(.+?)"|(\S+?\(.*?\))) started')
FINISHED = re.compile(r'Test (?:"(.+?)"|(\S+?\(.*?\))) (?:passed|failed|skipped)')
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# Frames that mean a thread is parked; used to pick the threads worth showing.
WAITING = ("semaphore_wait", "__psynch_cvwait", "__ulock_wait", "__psynch_mutexwait", "__workq_kernreturn",
           "mach_msg", "kevent", "read", "__wait4", "waitUntilExit", "dispatch_sync", "_dispatch_sync")


def processes():
    """pid -> (ppid, pgid, command) for every process."""
    rows = subprocess.run(["ps", "-axo", "pid=,ppid=,pgid=,command="], capture_output=True, text=True).stdout
    procs = {}
    for row in rows.splitlines():
        parts = row.strip().split(None, 3)
        if len(parts) == 4 and all(p.isdigit() for p in parts[:3]):
            procs[int(parts[0])] = (int(parts[1]), int(parts[2]), parts[3])
    return procs


def tree(root):
    """pid -> command for everything the run started: root, its descendants,
    and anything still in its process group (orphans are re-parented to
    launchd once the root exits, but keep the group)."""
    procs = processes()
    found = {pid for pid, (_, pgid, _) in procs.items() if pgid == root}
    found.add(root)
    changed = True
    while changed:
        changed = False
        for pid, (ppid, _, _) in procs.items():
            if ppid in found and pid not in found:
                found.add(pid)
                changed = True
    return {pid: procs[pid][2] for pid in sorted(found) if pid in procs}


def stop_all(root):
    """Kill the process group, then every remaining process of the run."""
    try:
        os.killpg(root, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    for pid in tree(root):
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass


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


def diagnose(child_pid, started, finished, out_dir, why):
    os.makedirs(out_dir, exist_ok=True)
    print(f"\n=== test-watchdog: {why}; collecting evidence (#183) ===", flush=True)
    open_tests = [t for t in started if t not in finished]
    print(f"tests started: {len(started)}, finished: {len(finished)}, still running: {len(open_tests)}", flush=True)
    for t in open_tests[:50]:
        print(f"  still running: {t}", flush=True)
    with open(os.path.join(out_dir, "unfinished-tests.txt"), "w") as f:
        f.write("\n".join(open_tests) + "\n")
    procs = tree(child_pid)
    print("process tree:", flush=True)
    for pid, cmd in procs.items():
        print(f"  {pid} {cmd[:200]}", flush=True)
    for pid, cmd in procs.items():
        path = os.path.join(out_dir, f"sample-{pid}.txt")
        try:
            subprocess.run(["sample", str(pid), "3", "-file", path], capture_output=True, timeout=30)
        except Exception as e:  # sampling is evidence, never the reason to fail differently
            print(f"  sample {pid} failed: {e}", flush=True)
            continue
        if os.path.exists(path):
            print(f"--- sample {pid} ({cmd[:80]}): threads parked in a wait ---", flush=True)
            for line in summarise(open(path, errors="replace").read()):
                print(line, flush=True)
    spin = os.path.join(out_dir, "spindump.txt")
    try:
        r = subprocess.run(["sudo", "-n", "spindump", str(child_pid), "5", "-file", spin],
                           capture_output=True, timeout=90)
        print(f"spindump: {'saved' if r.returncode == 0 else 'not available'}", flush=True)
    except Exception as e:
        print(f"spindump: not available ({e})", flush=True)
    print(f"=== full reports in {out_dir} ===", flush=True)


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
    child = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    started, finished = [], set()
    last_output = time.monotonic()
    pending = b""
    while True:
        ready, _, _ = select.select([master], [], [], 1.0)
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
                continue
        if child.poll() is not None:
            # Drain what is left, never blocking: a process the run left
            # behind can hold the terminal open forever (b9 on #188).
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.5)
                if not ready:
                    continue
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
            left = {pid: cmd for pid, cmd in tree(child.pid).items() if pid != child.pid}
            if left:
                diagnose(child.pid, started, finished, args.out,
                         f"the command exited ({child.returncode}) but {len(left)} process(es) of its run remain")
                stop_all(child.pid)
                print("test-watchdog: stopped processes left behind by the run (exit 124)", flush=True)
                return 124
            return child.returncode
        if time.monotonic() - last_output > args.stall:
            diagnose(child.pid, started, finished, args.out, f"no output for {args.stall:.0f} s")
            stop_all(child.pid)
            child.wait()
            print(f"test-watchdog: stopped after {args.stall:.0f} s without output (exit 124)", flush=True)
            return 124


if __name__ == "__main__":
    sys.exit(main())
