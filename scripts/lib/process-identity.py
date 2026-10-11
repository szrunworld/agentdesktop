#!/usr/bin/env python3
"""macOS process identity and PID-version-bound signalling; never fall back to kill."""
import ctypes
import errno
import signal
import subprocess
import sys

class Unique(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16), ('unique', ctypes.c_uint64),
                ('parent', ctypes.c_uint64), ('version', ctypes.c_uint32),
                ('reserved', ctypes.c_uint32), ('reserved3', ctypes.c_uint64),
                ('reserved4', ctypes.c_uint64)]

lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
lib.proc_signal_with_audittoken.argtypes = [ctypes.c_void_p, ctypes.c_int]

def version(pid):
    info = Unique()
    if lib.proc_pidinfo(pid, 17, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        raise ProcessLookupError(pid)
    return info.version

def identity(pid):
    first = version(pid)
    value = subprocess.check_output(['ps', '-o', 'lstart=', '-o', 'comm=', '-p', str(pid)], text=True).rstrip('\n')
    if first != version(pid):
        raise ProcessLookupError(pid)
    return f'{first}:{value}'

def stop(pid, recorded):
    if not recorded or identity(pid) != recorded:
        return
    # The kernel validates PID + version when signalling, closing the gap
    # after identity(). An exited/reused PID yields ESRCH, not a signal.
    token = (ctypes.c_uint32 * 8)()
    token[5] = pid
    token[7] = int(recorded.split(':', 1)[0])
    if lib.proc_signal_with_audittoken(ctypes.byref(token), signal.SIGTERM) != 0:
        error = ctypes.get_errno()
        if error != errno.ESRCH:
            raise OSError(error, 'version-bound signal failed')

if __name__ == '__main__':
    try:
        mode, value, *rest = sys.argv[1:]
        pid = int(value)
        if pid <= 0:
            raise ValueError('positive PID required')
        if mode == 'identity':
            print(identity(pid))
        elif mode == 'stop':
            stop(pid, rest[0])
        else:
            raise ValueError('unknown operation')
    except ProcessLookupError:
        sys.exit(1 if sys.argv[1] == 'identity' else 0)
    except Exception as error:
        print(f'process identity: {error}', file=sys.stderr)
        sys.exit(1)
