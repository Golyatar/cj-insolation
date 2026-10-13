"""Protocol smoke tests and optional real SketchUp integration tests."""
import argparse
import importlib.util
import json
from pathlib import Path
from queue import Queue
import subprocess
import sys
import tempfile
import threading
import time

SERVER = Path(__file__).with_name('server.py')
ROOT = SERVER.parents[2]


class Client:
    def __init__(self, root=ROOT):
        self.process = subprocess.Popen([sys.executable, str(SERVER), '--project-root', str(root), '--timeout', '2'],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        text=True, encoding='utf-8')
        self.responses = Queue()
        self.next_id = 0
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        for line in self.process.stdout:
            try:
                self.responses.put(json.loads(line))
            except ValueError:
                self.responses.put({'invalid_stdout': line})

    def send(self, method, params=None, notification=False):
        message = {'jsonrpc': '2.0', 'method': method}
        if not notification:
            self.next_id += 1
            message['id'] = self.next_id
        if params is not None:
            message['params'] = params
        self.process.stdin.write(json.dumps(message) + '\n')
        self.process.stdin.flush()
        return message.get('id')

    def call(self, method, params=None):
        request_id = self.send(method, params)
        response = self.responses.get(timeout=5)
        assert response.get('id') == request_id, response
        return response

    def initialize(self):
        result = self.call('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                                          'clientInfo': {'name': 'cj-test', 'version': '1'}})
        assert result['result']['protocolVersion'] == '2025-06-18'
        self.send('notifications/initialized', notification=True)

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
            raise AssertionError('Server did not exit after stdin closed')
        errors = self.process.stderr.read()
        assert self.process.returncode == 0, errors


def run(live=False):
    checks = []
    def check(name, condition):
        assert condition, name
        checks.append({'name': name, 'passed': True})

    with tempfile.TemporaryDirectory(prefix='cj-mcp-') as empty_root:
        client = Client(empty_root)
        try:
            check('lifecycle_required', client.call('tools/list')['error']['code'] == -32000)
            client.initialize()
            checks.append({'name': 'initialize', 'passed': True})
            tools = client.call('tools/list')['result']['tools']
            check('five_tools_listed', len(tools) == 5)
            check('read_write_annotations', sum(t['annotations']['readOnlyHint'] for t in tools) == 2)
            check('ping', client.call('ping')['result'] == {})
            check('unknown_method', client.call('no-such-method')['error']['code'] == -32601)
            check('unknown_tool', client.call('tools/call', {'name': 'no-such-tool'})['error']['code'] == -32602)
            check('reject_zero_direction', client.call('tools/call', {'name': 'sketchup_raycast',
                   'arguments': {'origin_mm': [0, 0, 0], 'direction': [0, 0, 0]}})['error']['code'] == -32602)
            check('reject_extra_arguments', client.call('tools/call', {'name': 'sketchup_status',
                   'arguments': {'path': 'untrusted'}})['error']['code'] == -32602)
            missing = client.call('tools/call', {'name': 'sketchup_status'})['result']
            check('missing_bridge_tool_error', missing['isError'] is True)
            client.process.stdin.write('{broken json\n')
            client.process.stdin.flush()
            check('parse_error', client.responses.get(timeout=5)['error']['code'] == -32700)
            check('continues_after_error', client.call('ping')['result'] == {})
        finally:
            client.close()

    # Exercise the file transport and failing test propagation without SketchUp.
    specification = importlib.util.spec_from_file_location('cj_mcp', SERVER)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    with tempfile.TemporaryDirectory(prefix='cj-mcp-fake-') as fake_root:
        queue = Path(fake_root) / 'tooling' / 'runtime'
        queue.mkdir(parents=True)
        session = {'running': True, 'session_id': 'fake', 'commands': ['check'],
                   'updated_at': module.datetime.now(module.timezone.utc).isoformat()}
        (queue / 'session.json').write_text(json.dumps(session), encoding='utf-8')
        def respond():
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                requests = list(queue.glob('*.request.json'))
                if requests:
                    request = json.loads(requests[0].read_text(encoding='utf-8'))
                    response = {'id': request['id'], 'session_id': 'fake', 'ok': True,
                                'result': {'passed': False, 'checks': []}}
                    output = queue / (request['id'] + '.response.json')
                    temporary = output.with_suffix('.tmp')
                    temporary.write_text(json.dumps(response), encoding='utf-8')
                    temporary.replace(output)
                    return
                time.sleep(0.01)
        worker = threading.Thread(target=respond)
        worker.start()
        client = Client(fake_root)
        try:
            client.initialize()
            result = client.call('tools/call', {'name': 'sketchup_run_checks'})['result']
            check('failed_checks_is_tool_error', result['isError'] and result['structuredContent']['result']['passed'] is False)
        finally:
            client.close()
            worker.join(timeout=5)

    if live:
        client = Client()
        try:
            client.initialize()
            for name in ['sketchup_status', 'sketchup_reload_plugin', 'sketchup_run_checks', 'sketchup_run_geometry_tests', 'sketchup_raycast']:
                arguments = {'origin_mm': [0, 0, 1000000], 'direction': [0, 0, 1]} if name == 'sketchup_raycast' else {}
                result = client.call('tools/call', {'name': name, 'arguments': arguments})['result']
                check('live_' + name, result.get('isError') is False)
        finally:
            client.close()
    report = {'passed': True, 'live_sketchup': live, 'checks': checks}
    (ROOT / 'reports' / 'mcp_check.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--live', action='store_true')
    run(parser.parse_args().live)
