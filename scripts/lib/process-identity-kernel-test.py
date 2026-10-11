#!/usr/bin/env python3
"""Force the check/signal race: a stale PID version must not signal the live child."""
import importlib.util
from pathlib import Path
import subprocess
spec = importlib.util.spec_from_file_location('identity', Path(__file__).with_name('process-identity.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
child = subprocess.Popen(['/bin/sleep', '30'])
recorded = module.identity(child.pid)
try:
    stale = f'{module.version(child.pid) + 1}:' + recorded.split(':', 1)[1]
    # Pretend userspace validation succeeded before PID reuse. The kernel
    # must reject the old version even when userspace now says it matches.
    original = module.identity
    module.identity = lambda pid: stale
    module.stop(child.pid, stale)
    assert child.poll() is None, 'stale version signalled the child'
    module.identity = original
    module.stop(child.pid, recorded)
    child.wait(timeout=5)
    print('PASS kernel rejects stale PID version; valid version stops child')
finally:
    module.identity = original
    if child.poll() is None:
        module.stop(child.pid, recorded)
        child.wait(timeout=5)
