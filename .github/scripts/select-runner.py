#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def api(path, payload=None):
    command = ['gh', 'api', path]
    if payload is not None:
        command += ['--method', 'POST', '--input', '-']
    result = subprocess.run(command, input=json.dumps(payload) if payload else None,
                            capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError('GitHub runner coordination API unavailable')
    return json.loads(result.stdout)


def trusted(event, environ):
    if environ.get('GITHUB_ACTOR') != 'adcmdev':
        return False
    name = environ.get('GITHUB_EVENT_NAME')
    if name not in ('push', 'workflow_dispatch', 'workflow_run', 'repository_dispatch'):
        return False
    if name == 'workflow_run':
        source = event.get('workflow_run', {})
        if source.get('event') != 'push' or source.get('head_repository', {}).get('full_name') != environ['GITHUB_REPOSITORY']:
            return False
    ref = environ.get('GITHUB_REF', '')
    return ref in ('refs/heads/main', 'refs/heads/develop', 'refs/heads/master',
                   'refs/heads/full-deploy', 'refs/heads/full-deploy-dev',
                   'refs/heads/full-deploy-prod', 'refs/heads/deploy-infrastructure',
                   'refs/heads/ci/mac-primary-github-fallback') or ref.startswith('refs/tags/')


def select(environ, event, call=api, now=time.time, sleep=time.sleep):
    fallback = json.loads(environ['FALLBACK_RUNNER'])
    if not trusted(event, environ):
        return fallback, 'This event uses GitHub-hosted runners'
    if environ.get('FORCE_GITHUB') == 'true' or int(environ.get('GITHUB_RUN_ATTEMPT', '1')) > 1:
        return fallback, 'GitHub-hosted runner requested for this attempt'
    timeout = min(int(environ.get('LOCAL_WAIT_SECONDS', '180')), 180)
    key = hashlib.sha256(environ['RUNNER_REQUEST_KEY'].encode()).hexdigest()[:12]
    identity = f"{environ['GITHUB_RUN_ID']}-{environ.get('GITHUB_RUN_ATTEMPT', '1')}-{key}"
    context = 'macmini/' + identity
    label = 'request-' + identity
    repository = environ['GITHUB_REPOSITORY']
    sha = environ['GITHUB_SHA']
    if environ.get('GITHUB_EVENT_NAME') == 'workflow_run':
        try:
            sha = call(f'repos/{repository}/actions/runs/{environ["GITHUB_RUN_ID"]}')['head_sha']
        except (RuntimeError, subprocess.TimeoutExpired, ValueError, KeyError):
            return fallback, 'Run metadata unavailable; continuing on GitHub'
    endpoint = f'repos/{repository}/statuses/{sha}'
    deadline = now() + timeout
    request = {'context': context, 'state': 'pending',
               'description': json.dumps({'kind': environ['LOCAL_RUNNER_KIND'], 'expires': int(deadline)}, separators=(',', ':')),
               'target_url': f'https://github.com/{repository}/actions/runs/{environ["GITHUB_RUN_ID"]}'}
    try:
        call(endpoint, request)
        while now() < deadline:
            statuses = call(endpoint + '?per_page=100')
            status = next((item for item in statuses if item['context'] == context), None)
            if status and status['state'] == 'success' and status.get('creator', {}).get('login') == 'adcmdev':
                return ['self-hosted', label], 'Mac mini confirmed a runner reserved for this job'
            if status and status['state'] in ('failure', 'error'):
                break
            sleep(min(10, max(0, deadline - now())))
    except (RuntimeError, subprocess.TimeoutExpired, ValueError, KeyError):
        pass
    try:
        call(endpoint, {**request, 'state': 'success', 'description': 'Using GitHub-hosted runner: no local reservation before deadline'})
    except (RuntimeError, subprocess.TimeoutExpired, ValueError):
        pass
    return fallback, 'Mac mini unavailable or occupied; continuing on GitHub'


def main():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    labels, reason = select(os.environ, event)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('runner=' + json.dumps(labels, separators=(',', ':')) + '\n')
        output.write('reason=' + reason + '\n')
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
        summary.write(f'Runner: `{json.dumps(labels)}`. {reason}.\n')
    print(reason)


if __name__ == '__main__':
    main()
