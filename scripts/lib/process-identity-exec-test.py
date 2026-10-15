#!/usr/bin/env python3
"""An exec while the identity is read changes the PID version: the live
process is read again, never reported gone (CI flake, 2026-10-12)."""
import sys
sys.dont_write_bytecode = True
import importlib.util
from pathlib import Path
import subprocess
spec = importlib.util.spec_from_file_location('identity', Path(__file__).with_name('process-identity.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
child = subprocess.Popen(['/bin/sleep', '30'])
real = module.version
try:
    # The version moves once between the two reads, as an exec would.
    calls = []
    def moving(pid):
        calls.append(pid)
        return real(pid) + (1 if len(calls) >= 2 else 0)
    module.version = moving
    got = module.identity(child.pid)
    assert got.startswith(f'{real(child.pid) + 1}:'), got
    assert got.endswith('/bin/sleep') or got.endswith('sleep'), got
    # A version that never settles is an error, not "gone".
    counter = iter(range(10**6))
    module.version = lambda pid: next(counter)
    try:
        module.identity(child.pid)
        raise AssertionError('a version that never settles was accepted')
    except RuntimeError:
        pass
    module.version = real
    # A PID with no process is gone.
    child.kill(); child.wait()
    try:
        module.identity(child.pid)
        raise AssertionError('an exited process still has an identity')
    except ProcessLookupError:
        pass
    print('PASS an exec while reading is read again; a gone PID is gone')
finally:
    module.version = real
    if child.poll() is None:
        child.kill(); child.wait()
