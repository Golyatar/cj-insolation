"""Push local commit objects through gh REST API when HTTPS git transport is unavailable."""
import argparse
import base64
from datetime import datetime, timezone, timedelta
import json
from pathlib import Path
import re
import subprocess
import tempfile
import sys

sys.stdout.reconfigure(encoding='utf-8')
parser = argparse.ArgumentParser()
parser.add_argument('repository')
parser.add_argument('--branch', default='master')
parser.add_argument('--since', help='Already uploaded ancestor SHA; upload only subsequent commits')
args = parser.parse_args()
if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repository):
    parser.error('Expected owner/repository')

def git(*arguments):
    return subprocess.check_output(['git', *arguments])

def api(endpoint, payload=None, method='POST'):
    command = ['gh', 'api', endpoint]
    if payload is None:
        return json.loads(subprocess.check_output(command))
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', encoding='utf-8', delete=False) as file:
        json.dump(payload, file)
        path = Path(file.name)
    try:
        return json.loads(subprocess.check_output(command + ['--method', method, '--input', str(path)]))
    finally:
        path.unlink()

prefix = f'repos/{args.repository}/git'
commits = git('rev-list', '--reverse', f'{args.since}..HEAD' if args.since else 'HEAD').decode().splitlines()
uploaded = set()
if args.since:
    api(prefix + '/commits/' + args.since, method='GET')
    uploaded = {line.split()[0] for line in git('rev-list', '--objects', args.since).decode().splitlines()}
for commit in commits:
    entries = []
    for entry in git('ls-tree', '-rz', commit).split(b'\0'):
        if not entry:
            continue
        info, path = entry.split(b'\t', 1)
        mode, kind, sha = info.decode().split()
        if kind != 'blob':
            raise RuntimeError('Only regular file blobs are supported')
        if sha not in uploaded:
            blob = api(prefix + '/blobs', {'content': base64.b64encode(git('cat-file', 'blob', sha)).decode(), 'encoding': 'base64'})
            if blob['sha'] != sha:
                raise RuntimeError('Blob SHA mismatch')
            uploaded.add(sha)
        entries.append({'path': path.decode('utf-8'), 'mode': mode, 'type': kind, 'sha': sha})
    tree = api(prefix + '/trees', {'tree': entries})
    raw = git('cat-file', 'commit', commit).decode('utf-8')
    headers, message = raw.split('\n\n', 1)
    metadata = {}
    parents = []
    expected_tree = None
    for line in headers.splitlines():
        if line.startswith('tree '):
            expected_tree = line[5:]
        elif line.startswith('parent '):
            parents.append(line[7:])
        elif line.startswith(('author ', 'committer ')):
            match = re.fullmatch(r'(author|committer) (.*) <(.*)> (\d+) ([+-])(\d{2})(\d{2})', line)
            role, name, email, timestamp, sign, hours, minutes = match.groups()
            offset = timedelta(hours=int(hours), minutes=int(minutes)) * (1 if sign == '+' else -1)
            metadata[role] = {'name': name, 'email': email, 'date': datetime.fromtimestamp(int(timestamp), timezone(offset)).isoformat()}
    if tree['sha'] != expected_tree:
        raise RuntimeError('Tree SHA mismatch')
    created = api(prefix + '/commits', {'message': message, 'tree': tree['sha'], 'parents': parents, **metadata})
    if created['sha'] != commit:
        raise RuntimeError(f"Commit SHA mismatch: {created['sha']} != {commit}")
    print('Uploaded commit ' + commit, flush=True)
head = commits[-1] if commits else git('rev-parse', 'HEAD').decode().strip()
refs = api(prefix + '/matching-refs/heads/' + args.branch, method='GET')
if any(ref['ref'] == 'refs/heads/' + args.branch for ref in refs):
    api(prefix + '/refs/heads/' + args.branch, {'sha': head, 'force': False}, method='PATCH')
else:
    api(prefix + '/refs', {'ref': 'refs/heads/' + args.branch, 'sha': head})
print(json.dumps({'repository': args.repository, 'branch': args.branch, 'sha': head}))
