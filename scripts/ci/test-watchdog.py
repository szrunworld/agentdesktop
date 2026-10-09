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


def tree(root):
    """pid -> command for root and all its descendants."""
    rows = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    procs = {}
    for row in rows.splitlines():
        parts = row.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            procs[int(parts[0])] = (int(parts[1]), parts[2])
    found, changed = {root}, True
    while changed:
        changed = False
        for pid, (ppid, _) in procs.items():
            if ppid in found and pid not in found:
                found.add(pid)
                changed = True
    return {pid: procs[pid][1] for pid in sorted(found) if pid in procs}


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


def diagnose(child_pid, started, finished, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    print("\n=== test-watchdog: no output for the stall limit; collecting evidence (#183) ===", flush=True)
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
            # Drain whatever is left, then return the command's own status.
            try:
                while (data := os.read(master, 65536)):
                    sys.stdout.buffer.write(data)
            except OSError:
                pass
            sys.stdout.flush()
            return child.returncode
        if time.monotonic() - last_output > args.stall:
            diagnose(child.pid, started, finished, args.out)
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            print(f"test-watchdog: stopped after {args.stall:.0f} s without output (exit 124)", flush=True)
            return 124


if __name__ == "__main__":
    sys.exit(main())
