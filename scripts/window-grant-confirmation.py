#!/usr/bin/env python3
"""Submit once; reconcile uncertain confirmation replies using request.show."""
import json
import subprocess
import sys
import time
import uuid


def confirm(cli, args, *, run=None, clock=time.monotonic, sleep=time.sleep,
            limit=180):
    if run is None:
        def run(arguments):
            reply = subprocess.run([cli, *arguments, '--format', 'json'],
                                   capture_output=True, text=True, timeout=15)
            if reply.stderr:
                print(reply.stderr, file=sys.stderr, end='')
            return json.loads(reply.stdout)
    request_id = 'req_' + uuid.uuid4().hex
    deadline = clock() + limit
    reply = run([*args, '--request-id', request_id])
    uncertain = {'request_acceptance_unknown', 'connection_lost', 'connection_closed'}
    if reply.get('ok') or reply.get('error', {}).get('code') not in uncertain:
        return reply
    print(f'Waiting for confirmation result: {request_id} (no resubmission)', file=sys.stderr)
    while clock() < deadline:
        record = run(['request', 'show', request_id])
        if not record.get('ok'):
            # Query failures never justify submitting the write again.
            code = record.get('error', {}).get('code')
            if code not in uncertain | {'not_found'}:
                return record
        else:
            data = record.get('data', {})
            if data.get('state') in {'completed', 'failed'}:
                outcome = data.get('outcome')
                success = data['state'] == 'completed'
                if not isinstance(outcome, dict) or ('data' if success else 'error') not in outcome:
                    raise ValueError('terminal request has no valid outcome')
                return dict(outcome, ok=success, apiVersion=reply.get('apiVersion'), requestId=request_id)
        sleep(0.5)
    return {'ok': False, 'requestId': request_id, 'error': {
        'code': 'request_acceptance_unknown',
        'message': f'Confirmation result still unknown; query request show {request_id}; do not resubmit'}}


if __name__ == '__main__':
    try:
        result = confirm(sys.argv[1], sys.argv[2:])
        print(json.dumps(result))
        sys.exit(0 if result.get('ok') else 1)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(f'Cannot reconcile confirmation: {error}', file=sys.stderr)
        sys.exit(1)
