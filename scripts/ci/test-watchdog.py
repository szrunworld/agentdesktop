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
# The sampler, ps and lsof; the self-tests point them at tools that fail or lie.
SAMPLE = os.environ.get("WATCHDOG_SAMPLE", "sample")
PS = os.environ.get("WATCHDOG_PS", "ps")
LSOF = os.environ.get("WATCHDOG_LSOF", "lsof")
# The self-tests turn sudo off to act out a machine without passwordless sudo.
USE_SUDO = os.environ.get("WATCHDOG_NO_SUDO") != "1"
# Self-test switches, so a case does not depend on one machine's timing or on
# what its kernel shows: no snapshots at all, and environments treated as
# unreadable ("all", or a comma list of pids).
SNAPSHOTS = os.environ.get("WATCHDOG_NO_SNAPSHOTS") != "1"
FAKE_UNREADABLE = os.environ.get("WATCHDOG_FAKE_UNREADABLE", "")
# And the kernel's process list failing (#193).
FAKE_NO_PROCESS_LIST = os.environ.get("WATCHDOG_FAKE_NO_PROCESS_LIST") == "1"


MARKER = "TEST_WATCHDOG_RUN"
_libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)


KINFO_SIZE = 648  # struct kinfo_proc on this platform


def kernel_info(pid):
    """(ppid, pgid, real uid, (seconds, microseconds) started, effective
    uid) of a process, all from one sysctl(KERN_PROC_PID) read, or None when
    there is no such live process (zombies included). The start time with
    the pid identifies a process: pids are reused, even within a second
    (Codex and b9 on #196). Unlike proc_pidinfo this answers for every
    user's processes, so a run is followed through another user's process,
    such as one sudo started (#206). The offsets of struct kinfo_proc were
    checked against ps for this user's processes, launchd and WindowServer:
    p_starttime at 0, p_stat at 36, p_pid at 40, the real uid at 392, the
    effective uid at 420, e_ppid at 560, e_pgid at 564."""
    mib = (ctypes.c_int * 4)(1, 14, 1, pid)  # CTL_KERN, KERN_PROC, KERN_PROC_PID
    buf = ctypes.create_string_buffer(KINFO_SIZE)
    size = ctypes.c_size_t(KINFO_SIZE)
    if _libc.sysctl(mib, 4, buf, ctypes.byref(size), None, 0) != 0 or size.value != KINFO_SIZE:
        return None
    raw = buf.raw
    if struct.unpack_from("<i", raw, 40)[0] != pid or raw[36] == 5:  # not this pid, or SZOMB
        return None
    sec, usec = struct.unpack_from("<qi", raw, 0)
    ruid, = struct.unpack_from("<I", raw, 392)
    euid, = struct.unpack_from("<I", raw, 420)
    ppid, pgid = struct.unpack_from("<ii", raw, 560)
    return ppid, pgid, ruid, (sec, usec), euid


def start_time(pid):
    info = kernel_info(pid)
    return None if info is None else info[3]


def _bsdinfo_start(pid):
    """This process's start time as proc_pidinfo gives it: a second reader
    to check kernel_info against."""
    buf = ctypes.create_string_buffer(136)  # struct proc_bsdinfo
    if _libc.proc_pidinfo(pid, 3, ctypes.c_uint64(0), buf, 136) != 136:
        return None
    return struct.unpack_from("<QQ", buf, 120)


_kernel_problem = []  # [] unchecked, [None] fine, [reason] unusable


def kernel_problem():
    """Why kernel_info cannot be trusted on this machine, or None. Its
    offsets were measured on one macOS; a runner with another layout would
    read wrong parents or owners, and those decide what may be signalled
    (b9 on #206). So before anything is trusted, this process is read and
    every field compared with what the process knows of itself, and the
    start time with proc_pidinfo's. Any mismatch: nothing is listed, so
    nothing is signalled, and the reason is reported."""
    if not _kernel_problem:
        me = os.getpid()
        info = kernel_info(me)
        if info is None:
            reason = "sysctl(KERN_PROC_PID) gave no kinfo_proc of the expected size for this process"
        else:
            ppid, pgid, ruid, start, euid = info
            expected = {"ppid": (ppid, os.getppid()), "pgid": (pgid, os.getpgrp()), "real uid": (ruid, os.getuid()),
                        "effective uid": (euid, os.geteuid()), "start": (tuple(start), tuple(_bsdinfo_start(me) or ()))}
            wrong = [f"{k} read {a}, expected {b}" for k, (a, b) in expected.items() if a != b]
            reason = ("kinfo_proc does not match this process (" + "; ".join(wrong) + ")") if wrong else None
        _kernel_problem.append(reason)
    return _kernel_problem[0]


def all_pids():
    """Every pid the kernel lists (proc_listallpids), or None when it does
    not answer: then nothing is known, which is not the same as nothing
    there (#193)."""
    if FAKE_NO_PROCESS_LIST:
        return None
    n = _libc.proc_listallpids(None, 0)
    if n <= 0:
        return None
    buf = (ctypes.c_int * (n + 512))()
    got = _libc.proc_listallpids(buf, ctypes.sizeof(buf))
    if got <= 0:
        return None
    return [buf[i] for i in range(got) if buf[i] > 0]


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


def run_step(args, timeout=None, keep_stderr=False):
    """Run an external step with a time limit; (ok, stdout, detail). With
    keep_stderr, what the step wrote there is added to detail."""
    limit = timeout or STEP_TIMEOUT
    try:
        # Its own process group, so a timeout stops whatever the step started too.
        p = subprocess.Popen(args, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE if keep_stderr else subprocess.DEVNULL,
                             stdin=subprocess.DEVNULL, text=True, start_new_session=True)
    except OSError as e:
        return False, "", f"could not run: {e}"
    try:
        out, err = p.communicate(timeout=limit)
        detail = f"exit {p.returncode}"
        if err and err.strip():
            detail += ": " + err.strip().splitlines()[0][:200]
        return p.returncode == 0, out, detail
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
    """One row of `ps -o pid=,command=`: (pid, command), or None. The
    command is the rest of the row, spaces and all."""
    parts = row.split(None, 1)
    if len(parts) < 2 or not parts[0].isdigit():
        return None
    return int(parts[0]), parts[1].rstrip()


def processes(deadline=None, problems=None, foreign=None):
    """pid -> (ppid, pgid, start, command) for every live process of this
    user. Parent, group and start time come from the kernel, together, in
    one call per process (kernel_info), so a relationship is never paired
    with another process's identity (Codex on #196); zombies are not
    listed (b9 on #194). ps supplies only the command line, for reports;
    a pid that changed hands between the two shows the wrong text but is
    never acted on by it. What went wrong goes to problems (#193): the
    kernel list failing means the list is empty, not that nothing runs; ps
    failing costs only the command lines. Only processes whose real and
    effective uid are this user's are listed: only those may be signalled.
    Other users' processes (one sudo started, say) go to `foreign` with
    their uids, so a run can be followed through them (#206)."""
    reason = kernel_problem()
    if reason is not None:
        if problems is not None:
            problems.append(f"process list: {reason}")
        return {}
    ok, rows, detail = run_step([PS, "-axo", "pid=,command="], timeout=within(deadline, 10))
    if not ok and problems is not None:
        problems.append(f"ps (command lines only): {detail}")
    commands = {}
    for row in rows.splitlines():
        parsed = parse_ps_row(row)
        if parsed is not None:
            commands[parsed[0]] = parsed[1]
    procs = {}
    me = os.getuid()
    pids = all_pids()
    if pids is None:
        if problems is not None:
            problems.append("process list: proc_listallpids failed")
        pids = []
    for pid in pids:
        info = kernel_info(pid)
        if info is None:
            continue  # gone, or a zombie
        ppid, pgid, ruid, start, euid = info
        command = commands.get(pid, "(command unknown)")
        if ruid == me and euid == me:
            procs[pid] = (ppid, pgid, start, command)
        elif foreign is not None:
            foreign[pid] = (ppid, pgid, start, command, ruid, euid)
    return procs


def own_ancestors():
    """pid -> start of each of the watchdog's own ancestors (the shell that
    started it, and up), confirmed link by link as the run's tree is: the
    parent is read, the child still names it as its parent and is the same
    process, and the parent is read again, unchanged. A link that does not
    hold ends the chain there (#209: Kevin, not "started about the same
    time" but identity and parent). Up to launchd, which is never a
    candidate anyway."""
    chain = {}
    pid = os.getpid()
    while kernel_problem() is None:
        child = kernel_info(pid)
        if child is None or child[0] <= 1:
            break
        parent = child[0]
        before = kernel_info(parent)
        again = kernel_info(pid)
        after = kernel_info(parent)
        if (before is None or after is None or again is None or again[0] != parent
                or again[3] != child[3] or before[3] != after[3]):
            break
        chain[parent] = before[3]
        pid = parent
    return chain


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
        self.seen = {}  # pid -> ((seconds, microseconds) started, command)
        self.unverifiable = {}  # pid -> command: could not be confirmed as the run's, never signalled
        self.unlinked = {}  # of those, pid -> command: the link to a parent in the run did not hold
        self.last_snapshot = 0.0
        self.idents = {}  # pid -> start_time(), as the last members() found it
        # Once the command has exited its pid and group id may be given to
        # unrelated processes: from then on neither is used to find or stop
        # anything (Codex on #188).
        self.root_alive = True
        self.not_stopped = {}  # what stop() could not end
        # What went wrong in the last members(), so a report never presents
        # an incomplete list as complete (#193); snapshots that failed.
        self.discovery_problems = []
        self.failed_snapshots = 0
        # Why `sudo ps` could not read environments; its outcome is the
        # unverifiable list, so it is reported with that.
        self.sudo_problem = ""
        # Other users' processes confirmed part of the run (by a checked
        # link or the run's group): never signalled, reported with their
        # uid (#206). pid -> (start, command, real uid, effective uid).
        self.foreign_members = {}
        self.seen_foreign = {}
        self._foreign_linked = {}
        # The watchdog's own ancestors, confirmed link by link: never part
        # of the run, so never unverifiable (#209).
        self.ancestors = own_ancestors()

    def command_gone(self):
        """The command has exited and been reaped: its pid may be reused at
        once. It is forgotten (start times are only exact to the second, so
        a remembered entry could match a new process in the same second)
        and members() no longer accepts its pid from any source (Codex and
        b9 on #196)."""
        self.root_alive = False
        self.seen.pop(self.root, None)

    def snapshot(self, force=False):
        now = time.monotonic()
        if not SNAPSHOTS or (not force and now - self.last_snapshot < 1.0):
            return
        self.last_snapshot = now
        problems = []
        foreign = {}
        procs = processes(problems=problems, foreign=foreign)
        if any(not p.startswith("ps ") for p in problems):
            self.failed_snapshots += 1
        for pid, cmd in self._tree(procs, foreign).items():
            self.seen.setdefault(pid, (procs[pid][2], cmd))
        for pid, row in self._foreign_linked.items():
            self.seen_foreign.setdefault(pid, row)

    def _tree(self, procs, foreign=None):
        """The root, its group (the root is unreaped, so the group id is
        its own) and its descendants. A child is linked by its parent's pid,
        and the listing is read in no set order: the pid may have belonged
        to another process when the child was read. So each link is checked
        after the listing, the child's read between two of the parent's:
        the parent is the process listed, the child still names that pid as
        its parent and is the process listed, and the parent is still the
        process listed. Then, at that moment, the child's parent was ours
        (b9 on #196). A link that fails leaves the child, and what hangs
        only from it, out of this look. The tree runs through other users'
        processes too (one sudo started): those are kept apart, never
        signalled, and this user's processes under them are the run's
        (#206). Returns this user's members; the others are left in
        self._foreign_linked."""
        foreign = foreign or {}
        nodes = {pid: row[:3] for pid, row in procs.items()}
        nodes.update({pid: row[:3] for pid, row in foreign.items()})
        found = {pid for pid, (_, pgid, _) in nodes.items() if pgid == self.root}
        found.add(self.root)
        checked = {}
        self._unlinked = {}

        def linked(pid, ppid):
            if pid not in checked:
                parent = nodes.get(ppid, (None, None, None))[2]
                ok = parent is not None and start_time(ppid) == parent
                if ok:
                    now = kernel_info(pid)
                    ok = now is not None and now[0] == ppid and now[3] == nodes[pid][2]
                ok = ok and start_time(ppid) == parent
                checked[pid] = ok
            return checked[pid]
        changed = True
        while changed:
            changed = False
            for pid, (ppid, _, _) in nodes.items():
                if ppid in found and pid not in found and linked(pid, ppid):
                    found.add(pid)
                    changed = True
        # A child whose link did not hold, and what hangs from it, is not
        # known to be ours or not: unverified, reported, never signalled
        # (Kevin, 2026-10-09).
        unlinked = {pid for pid, ok in checked.items() if not ok and pid not in found}
        changed = True
        while changed:
            changed = False
            for pid, (ppid, _, _) in nodes.items():
                if ppid in unlinked and pid not in unlinked and pid not in found:
                    unlinked.add(pid)
                    changed = True
        def command(pid):
            return procs[pid][3] if pid in procs else foreign[pid][3]
        self._unlinked = {pid: command(pid) for pid in unlinked}
        self._foreign_linked = {pid: (foreign[pid][2], foreign[pid][3], foreign[pid][4], foreign[pid][5])
                                for pid in found if pid in foreign}
        return {pid: procs[pid][3] for pid in found if pid in procs}

    def members(self, deadline=None):
        """pid -> command of every live process of the run. With a deadline,
        every step is limited to the time left (Codex on #188)."""
        self.discovery_problems = problems = []
        foreign = {}
        procs = processes(deadline, problems, foreign)
        ids = {pid: row[2] for pid, row in procs.items()}
        # The live tree only while the command runs; afterwards only what is
        # confirmed: seen as the same process, the marker, the terminal.
        self._unlinked = {}
        self._foreign_linked = {}
        live = self._tree(procs, foreign) if self.root_alive else {}
        unlinked = self._unlinked
        # Other users' processes of the run: found in the tree now, or seen
        # in it before, still the same process. Never signalled (#206).
        members = dict(self._foreign_linked)
        for pid, row in self.seen_foreign.items():
            if pid in foreign and foreign[pid][2] == row[0]:
                members.setdefault(pid, row)
        self.foreign_members = {pid: row for pid, row in members.items()
                                if start_time(pid) == row[0]}
        for pid, (ident, cmd) in self.seen.items():
            if ids.get(pid) == ident:
                live[pid] = procs[pid][3]
        if self.tty:
            ok, out, detail = run_step([LSOF, "-t", self.tty], timeout=within(deadline, 10), keep_stderr=True)
            # lsof exits 1 with no output when nothing has the file open:
            # that is an answer, not a failure. It also exits 1 on an error,
            # but then says so on stderr (this lsof, 4.91, has no -Q to tell
            # them apart; Codex on #197).
            if not ok and not (detail == "exit 1" and not out.strip()):
                problems.append(f"lsof: {detail}")
            for t in out.split():
                if t.isdigit() and int(t) in procs and int(t) != os.getpid():
                    live[int(t)] = procs[int(t)][3]
        live.update(self._marked(procs, set(live), deadline))
        if not self.root_alive:
            live.pop(self.root, None)
        # Only what is still there as the process listed: a candidate that
        # exited before its link was checked is gone, not uncertain (Codex
        # on #196).
        starts = {pid: row[2] for pid, row in foreign.items()}
        starts.update(ids)
        self.unlinked = {pid: cmd for pid, cmd in unlinked.items()
                         if pid not in live and pid in starts and start_time(pid) == starts[pid]}
        self.unverifiable.update(self.unlinked)
        self.idents = {pid: ids[pid] for pid in live}
        return dict(sorted(live.items()))

    def signal(self, targets):
        """SIGKILL each target that is still the process members() found.
        A scan takes seconds (ps, lsof, sudo); in that time a target can
        exit and its pid go to an unrelated process. So right before each
        signal the kernel is asked when the process with that pid started,
        to the microsecond: gone, or not the identity found, and it is left
        alone (Codex and b9 on #196). What remains is the microseconds between
        this check and the kill."""
        for pid in targets:
            ident = self.idents.get(pid)
            if ident is None or start_time(pid) != ident:
                continue
            try:
                os.kill(pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass

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
        """Processes started since the run began that carry its marker. The
        identity is read again after each environment read: the marker is
        taken as the identified process's only if it did not change."""
        ids = {pid: row[2] for pid, row in procs.items()}
        tag = f"{MARKER}={self.marker}"
        found, unread = {}, []
        helpers = self._own_helpers(procs)
        for pid, (_, _, start, cmd) in procs.items():
            if pid in known or pid in helpers or start[0] < self.started_at - 1:
                continue
            if pid in self.ancestors and start_time(pid) == self.ancestors[pid]:
                continue  # the watchdog's own ancestor, still the same process (#209)
            # (A process gone meanwhile fails the identity check below; its
            # command line is not a sign of anything, and may be unknown.)
            env = process_environment(pid)
            if start_time(pid) != ids.get(pid):
                continue  # gone or replaced while being read
            # For platform binaries the kernel returns the arguments with the
            # environment stripped, not an error: an empty environment cannot
            # be checked either (nor can one emptied with env -i).
            if not env:
                unread.append(pid)
            elif tag in env:
                found[pid] = cmd
        self.unverifiable = {}
        if unread and USE_SUDO:
            ok, out, detail = run_step(["sudo", "-n", PS, "-E", "-ww", "-o", "pid=,command=", "-p",
                                        ",".join(map(str, unread))], timeout=within(deadline, 10))
            self.sudo_problem = "" if ok else f"sudo ps: {detail}"
            readable = set()
            if ok:
                for row in out.splitlines():
                    head = row.strip().split(None, 1)
                    if head and head[0].isdigit():
                        pid = int(head[0])
                        readable.add(pid)
                        # Read by pid; still the identified process?
                        if tag in row and pid in procs and start_time(pid) == ids.get(pid):
                            found[pid] = procs[pid][3]
            self.unverifiable = {pid: procs[pid][3] for pid in unread if pid not in readable}
        elif unread:
            self.sudo_problem = "sudo turned off"
            self.unverifiable = {pid: procs[pid][3] for pid in unread}
        if self.unverifiable:
            # Only what is still there, as the same process: asked of the
            # kernel pid by pid, so this check cannot fail and drop the very
            # processes nobody could check (#193).
            self.unverifiable = {pid: cmd for pid, cmd in self.unverifiable.items()
                                 if start_time(pid) == procs[pid][2]}
        return found

    def stop(self):
        """Take the whole set first, then kill: the group (only while the
        command is unreaped, so the group id is surely its own), then each
        confirmed process. Every per-pid signal follows a fresh look and is
        checked against the kernel right before it is sent (signal())."""
        # What went wrong in any scan of the stop is kept to the end: a scan
        # that failed may have missed a process a later scan can no longer
        # find (it left the group when the group was killed; Codex on #197).
        problems = []
        # Every process of the run seen during the stop, with its identity,
        # to say at the end which of them are confirmed gone (Kevin on
        # #206: stopped, running and unverified are told apart).
        met = {}

        def look():
            found = self.members()
            problems.extend(p for p in self.discovery_problems if p not in problems)
            for pid, cmd in found.items():
                met.setdefault(pid, (self.idents.get(pid), cmd, None))
            for pid, (start, cmd, ruid, euid) in self.foreign_members.items():
                met.setdefault(pid, (start, cmd, (ruid, euid)))
            return found
        targets = look()
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
                    self.command_gone()
                except subprocess.TimeoutExpired:
                    pass
                # Look again either way: during the wait the reaped root,
                # or any other target that exited, may have had its pid
                # given to an unrelated process (Codex on #196).
                targets = look()
        # Up to five rounds of kill, wait, look again: a leftover may start a
        # detached child just before it dies, and the last look must be acted
        # on (Codex on #188). Each round kills only confirmed processes, as
        # members() gives them; no group signal once the command has exited.
        for _ in range(5):
            if not targets:
                break
            self.signal(targets)
            time.sleep(0.2)
            targets = look()
        self.not_stopped = targets
        self.discovery_problems = problems
        # Other users' processes are never signalled: if still there, they
        # are confirmed running, and the stop did not end the run (#206).
        running = {pid: f"{cmd}" for pid, cmd in targets.items()}
        reasons = {pid: "still running after the watchdog's signals" for pid in targets}
        for pid, (start, cmd, ruid, euid) in self.foreign_members.items():
            running[pid] = cmd
            reasons[pid] = (f"another user's process (real uid {ruid}, effective uid {euid}); "
                            "the watchdog never signals those")
        stopped = {pid: cmd for pid, (start, cmd, _) in met.items()
                   if pid not in running and start_time(pid) != start}
        self.outcome = {"stopped": stopped, "running": running, "reasons": reasons,
                        "unverified": dict(self.unverifiable)}
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
    step("processes of the run", *discovery_outcome(run, f"{len(procs)} found"))
    print("processes of the run:", flush=True)
    for pid, cmd in procs.items():
        print(f"  {pid} {cmd[:200]}", flush=True)
    if run.foreign_members:
        # Part of the run, but another user's: listed, never signalled, and
        # not sampled (sampling another user's process needs root; spindump
        # below covers them where sudo works).
        report["other_users_processes"] = [
            {"pid": pid, "command": cmd, "real_uid": ruid, "effective_uid": euid}
            for pid, (_, cmd, ruid, euid) in run.foreign_members.items()]
        for pid, (_, cmd, ruid, euid) in run.foreign_members.items():
            print(f"  {pid} {cmd[:160]} (another user's: uid {ruid}/{euid}; never signalled)", flush=True)
    if run.unverifiable:
        report["unverifiable"] = unverified_entries(run)
        step("environment check", "incomplete",
             f"{len(run.unverifiable)} process(es) that could not be confirmed as the run's or not; not killed")
        for e in report["unverifiable"]:
            print(f"  unverifiable (left alone): {e['pid']} {e['command'][:160]} ({e['why']})", flush=True)

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


def unverified_entries(run):
    """The unverifiable processes with why each could not be confirmed."""
    return [{"pid": pid, "command": cmd,
             "why": "its link to a parent in the run could not be confirmed" if pid in run.unlinked
             else f"its environment could not be read ({run.sudo_problem or 'sudo ps did not show it'})"}
            for pid, cmd in run.unverifiable.items()]


def incomplete(run):
    """The problems that leave the list of processes incomplete: all but ps,
    which only supplies command lines. A snapshot that failed while the
    command ran counts too: a process it would have remembered (one that
    then left the tree) cannot be found by any later look (Codex on #197)."""
    problems = [p for p in run.discovery_problems if not p.startswith("ps ")]
    if run.failed_snapshots:
        problems.append(f"{run.failed_snapshots} snapshot(s) while the command ran: the process list failed")
    return problems


def discovery_outcome(run, found):
    """(status, detail) of a process discovery (#193): ok; partial when a
    tool failed or a snapshot did, so the list may be incomplete; failed
    when the kernel's process list failed in this look, so there is no list
    to speak of. ps failing is noted, but costs only command lines."""
    problems = incomplete(run)
    notes = [p for p in run.discovery_problems if p.startswith("ps ")]
    if not problems:
        return "ok", "; ".join([found] + notes)
    status = "failed" if any(p.startswith("process list:") for p in problems) else "partial"
    return status, f"{found}; may be incomplete: {'; '.join(problems + notes)}"


def report_failed_discovery(run, out_dir, exit_status, last_output):
    """The command exited and the check for leftovers could not be done in
    full (the process list or lsof failed). The command's own status is
    kept: this is a diagnostic tool, and a passing run must not turn red
    because a tool failed once (b9 on #193). It is made visible instead:
    the log, diagnosis.json and a warning annotation on the CI run."""
    status, detail = discovery_outcome(run, "no leftovers found")
    os.makedirs(out_dir, exist_ok=True)
    report = {"trigger": "leftover check failed",
              "why": "the command exited; whether processes of its run remain could not be checked",
              "seconds_since_last_output": round(time.monotonic() - last_output, 1),
              "command_exit_status": exit_status, "processes": [],
              "steps": [{"step": "processes of the run", "status": status, "detail": detail}]}
    # Processes nobody could check are reported here too: this path runs
    # first (Codex on #197).
    if run.unverifiable:
        report["unverifiable"] = unverified_entries(run)
        report["steps"].append({"step": "environment check", "status": "incomplete",
                                "detail": f"{len(run.unverifiable)} process(es) could not be confirmed as the "
                                          "run's or not; not stopped"})
    with open(os.path.join(out_dir, "diagnosis.json"), "w") as f:
        json.dump(report, f, indent=1, ensure_ascii=False)
    print(f"\n=== test-watchdog: the command exited ({exit_status}); the check for processes left behind "
          f"is {status}: {detail} ===", flush=True)
    for e in report.get("unverifiable", []):
        print(f"  unverifiable (left alone): {e['pid']} {e['command'][:160]} ({e['why']})", flush=True)
    print(f"::warning title=test-watchdog::could not check for processes left behind by the run ({detail}); "
          f"the command's exit status ({exit_status}) is kept", flush=True)
    print(f"=== report in {out_dir} ===", flush=True)


def record_stop(run, out_dir):
    """Add the outcome of stop() to the log and to diagnosis.json."""
    path = os.path.join(out_dir, "diagnosis.json")
    try:
        with open(path) as f:
            report = json.load(f)
    except (OSError, ValueError):
        report = {"steps": []}
    # Each process of the run met during the stop, in one of three states
    # (Kevin on #206): stopped (confirmed gone), running (confirmed still
    # there: not stopped, or another user's, which is never signalled) and
    # unverified (could not be confirmed either way; never signalled).
    outcome = getattr(run, "outcome", None) or {"stopped": {}, "running": dict(run.not_stopped),
                                                "reasons": {}, "unverified": dict(run.unverifiable)}
    running, reasons = outcome["running"], outcome["reasons"]
    report["outcome"] = {
        "stopped": [{"pid": pid, "command": cmd} for pid, cmd in outcome["stopped"].items()],
        "running": [{"pid": pid, "command": cmd, "why": reasons.get(pid, "still running")}
                    for pid, cmd in running.items()],
        "unverified": unverified_entries(run),
    }
    if running:
        report["not_stopped"] = report["outcome"]["running"]
        report.setdefault("steps", []).append(
            {"step": "stop", "status": "failed", "detail": f"{len(running)} process(es) of the run still running"})
        print(f"test-watchdog: could not stop {len(running)} process(es) of the run:", flush=True)
        for e in report["not_stopped"]:
            print(f"  still running (not stopped): {e['pid']} {e['command'][:160]} ({e['why']})", flush=True)
    elif incomplete(run):
        # The last look itself failed in part: nothing is known to be left,
        # which is not the same as nothing left (#193).
        status, detail = discovery_outcome(run, "nothing of the run found")
        report.setdefault("steps", []).append({"step": "stop", "status": status, "detail": detail})
        print(f"test-watchdog: stop {status}: {detail}", flush=True)
        if run.unverifiable:
            report["unverified_at_stop"] = unverified_entries(run)
            for e in report["unverified_at_stop"]:
                print(f"  unverified: {e['pid']} {e['command'][:160]} ({e['why']})", flush=True)
    elif run.unverifiable:
        # Unverified is not stopped (Kevin, 2026-10-09): they were left
        # alone, and whether they belong to the run is not known.
        report["unverified_at_stop"] = unverified_entries(run)
        report.setdefault("steps", []).append(
            {"step": "stop", "status": "unverified",
             "detail": f"nothing confirmed as the run's is left; {len(run.unverifiable)} process(es) could not be "
                       "verified and were not signalled"})
        print(f"test-watchdog: nothing confirmed as the run's is left, but {len(run.unverifiable)} process(es) "
              "could not be verified (not signalled):", flush=True)
        for e in report["unverified_at_stop"]:
            print(f"  unverified: {e['pid']} {e['command'][:160]} ({e['why']})", flush=True)
    else:
        report.setdefault("steps", []).append(
            {"step": "stop", "status": "ok", "detail": discovery_outcome(run, "nothing of the run left")[1]})
    os.makedirs(out_dir, exist_ok=True)
    with open(path, "w") as f:
        json.dump(report, f, indent=1, ensure_ascii=False)


def report_unverifiable(run, out_dir, exit_status, last_output):
    os.makedirs(out_dir, exist_ok=True)
    report = {"trigger": "unverifiable processes at exit",
              "why": "processes that could not be confirmed as the run's or not; not stopped",
              "seconds_since_last_output": round(time.monotonic() - last_output, 1),
              "command_exit_status": exit_status, "processes": [],
              "unverifiable": unverified_entries(run),
              "steps": [{"step": "environment check", "status": "incomplete",
                         "detail": f"{len(run.unverifiable)} process(es) could not be checked; not stopped"}]}
    with open(os.path.join(out_dir, "diagnosis.json"), "w") as f:
        json.dump(report, f, indent=1, ensure_ascii=False)
    print(f"\n=== test-watchdog: the command exited ({exit_status}); {len(run.unverifiable)} process(es) "
          "could not be confirmed as the run's or not (unverifiable, not stopped) ===", flush=True)
    for e in report["unverifiable"]:
        print(f"  unverifiable (left alone): {e['pid']} {e['command'][:160]} ({e['why']})", flush=True)
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
            run.command_gone()
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
            # Another user's process of the run that is still there is a
            # leftover confirmed running, like one of this user's: it fails
            # the run (b9 on #206; before, it was not seen at all).
            remaining = len(left) + len(run.foreign_members)
            if not remaining and incomplete(run):
                report_failed_discovery(run, args.out, child.returncode, output.last)
                return child.returncode
            if not remaining and run.unverifiable:
                # Nothing confirmed as the run's, but processes started since
                # it began could not be checked: reported, left alone, and the
                # command's own status kept (Codex and b9 on #188; locally
                # they are likely other sessions', and CI has sudo).
                report_unverifiable(run, args.out, child.returncode, output.last)
                return child.returncode
            if remaining:
                diagnose(run, output.started, output.finished, args.out,
                         f"the command exited ({child.returncode}) but {remaining} process(es) of its run remain",
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
