#!/usr/bin/env python3
"""Check the packaged public command surface without connecting to a desktop.

The product ships one command line, `agentdesktop` (Sources/AgentDesktopCLI),
speaking agentdesktop.runtime/1. This checks, against the packaged binary:
- help needs no Runtime and lists the current commands;
- the old engine command line's entries (screen, screenshot, task,
  agent-bridge, agent, and its MCP server) are absent and refused as
  argument errors (exit 2), before any connection;
- the bundle carries no second command line beside it.
The MCP server of the new command line arrives with plan A7; until then
`mcp` is refused like the other old entries.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

cli = Path(sys.argv[1]).resolve()
env = dict(os.environ)
# Any accidental connection would hit this path and fail with exit 3, not 2.
env['AGENTDESKTOP_ENDPOINT'] = '/nonexistent/agentdesktop-surface-check.sock'
env.pop('AGENTDESKTOP_SOCKET', None)


def run(*args):
    return subprocess.run([str(cli), *args], capture_output=True, text=True, timeout=15, env=env)


help_run = run('--help')
assert help_run.returncode == 0, help_run.stderr
help_text = help_run.stdout + help_run.stderr
assert help_text.startswith('usage: agentdesktop'), help_text[:200]
current = ['version', 'runtime status', 'runtime capabilities', 'doctor', 'desktop create', 'desktop destroy',
           'app launch', 'window bind', 'session open', 'observe', 'act click', 'act type', 'wait',
           'run cancel', 'runtime stop-all', 'artifact get']
missing = [c for c in current if f'  {c}' not in help_text]
assert not missing, f'help lacks current commands: {missing}'
old = ['screen', 'screenshot', 'task', 'agent-bridge', 'agent', 'mcp']
listed = [c for c in old if f'\n  {c} ' in help_text]
assert not listed, f'help lists old commands: {listed}'

for command in old:
    rejected = run(command, 'list')
    assert rejected.returncode == 2, (command, rejected.returncode, rejected.stderr)

version = run('version', '--format', 'json')
assert version.returncode == 0, version.stderr
data = json.loads(version.stdout)
assert data['ok'] and data['data']['product'] == 'AgentDesktop', data

resources = cli.parent.parent
others = sorted(p.name for p in (resources / 'bin').iterdir() if p.name != 'agentdesktop')
assert not others, f'second command line in the bundle: {others}'
assert not (resources / 'libexec').exists(), 'libexec/ is not part of the product bundle'

print(json.dumps({'commands': len(current), 'oldEntries': 'refused', 'otherCommandLines': 0}))
