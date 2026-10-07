#!/usr/bin/env python3
"""Check the packaged public surface without connecting to a desktop."""
import json
from pathlib import Path
import subprocess
import sys

cli = str(Path(sys.argv[1]).resolve())
help_run = subprocess.run([cli, '--help'], capture_output=True, text=True, timeout=15)
assert help_run.returncode == 0, help_run.stderr
help_text = help_run.stdout + help_run.stderr
assert 'agentdesktop screen create' in help_text
assert 'agent-bridge' not in help_text
assert 'agentdesktop task ' not in help_text
requests = [
    {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2024-11-05', 'capabilities': {}, 'clientInfo': {'name': 'packaging-check', 'version': '1'}}},
    {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list', 'params': {}},
    {'jsonrpc': '2.0', 'id': 3, 'method': 'resources/list', 'params': {}},
]
run = subprocess.run([cli, 'mcp'], input=''.join(json.dumps(r)+'\n' for r in requests), capture_output=True, text=True, timeout=15)
assert run.returncode == 0, run.stderr
responses = {r['id']: r for r in map(json.loads, run.stdout.splitlines()) if 'id' in r}
assert responses[1]['result']['serverInfo']['name'] == 'AgentDesktop'
names = {t['name'] for t in responses[2]['result']['tools']}
assert {'screen_create', 'screen_list', 'screen_destroy', 'screenshot', 'state', 'click'} <= names
assert not any(n.startswith('task_') for n in names)
assert not responses.get(3, {}).get('result', {}).get('resources', [])
for old in ['agent-bridge', 'task']:
    rejected = subprocess.run([cli, old], capture_output=True, text=True, timeout=15)
    assert rejected.returncode != 0, old
print(json.dumps({'nativeTools': len(names), 'oldEntries': 'absent', 'desktopActions': 0}))
