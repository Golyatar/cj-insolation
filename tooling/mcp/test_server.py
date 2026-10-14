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


try:
    from .client import Client
except ImportError:
    from client import Client


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
            check('expanded_tools_listed', len(tools) == 18)
            check('read_write_annotations', sum(t['annotations']['readOnlyHint'] for t in tools) >= 6)
            check('ping', client.call('ping')['result'] == {})
            check('unknown_method', client.call('no-such-method')['error']['code'] == -32601)
            check('unknown_tool', client.call('tools/call', {'name': 'no-such-tool'})['error']['code'] == -32602)
            check('reject_missing_instance', client.call('tools/call', {'name': 'sketchup_status',
                   'arguments': {}})['error']['code'] == -32602)
            check('reject_zero_direction', client.call('tools/call', {'name': 'sketchup_raycast',
                   'arguments': {'origin_mm': [0, 0, 0], 'direction': [0, 0, 0]}})['error']['code'] == -32602)
            check('reject_extra_arguments', client.call('tools/call', {'name': 'sketchup_status',
                   'arguments': {'path': 'untrusted'}})['error']['code'] == -32602)
            missing = client.call('tools/call', {'name': 'sketchup_status', 'arguments': {'instance_id': '0' * 36}})['result']
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
        instances_root = Path(fake_root) / 'tooling' / 'runtime' / 'instances'
        instances_root.mkdir(parents=True)
        now = module.datetime.now(module.timezone.utc).isoformat()
        for instance_id, model_path in [('0' * 36, r'C:\models\work.skp'), ('1' * 36, r'C:\models\agent.skp')]:
            instance_dir = instances_root / instance_id
            instance_dir.mkdir()
            session = {'running': True, 'session_id': instance_id, 'commands': ['check'],
                       'updated_at': now, 'pid': int(instance_id[0]), 'model_path': model_path}
            (instance_dir / 'session.json').write_text(json.dumps(session), encoding='utf-8')
        queue = instances_root / ('1' * 36)
        def respond():
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline:
                requests = list(queue.glob('*.request.json'))
                if requests:
                    request = json.loads(requests[0].read_text(encoding='utf-8'))
                    response = {'id': request['id'], 'session_id': '1' * 36, 'ok': True,
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
            instances = client.call('tools/call', {'name': 'sketchup_list_instances', 'arguments': {}})['result']['structuredContent']['instances']
            check('discovers_multiple_instances', len(instances) == 2 and {item['model_path'] for item in instances} == {r'C:\models\work.skp', r'C:\models\agent.skp'})
            result = client.call('tools/call', {'name': 'sketchup_run_checks',
                                    'arguments': {'instance_id': '1' * 36}})['result']
            check('failed_checks_is_tool_error', result['isError'] and result['structuredContent']['result']['passed'] is False)
        finally:
            client.close()
            worker.join(timeout=5)

    if live:
        client = Client(timeout=15)
        try:
            client.initialize()
            listing = client.call('tools/call', {'name': 'sketchup_list_instances', 'arguments': {}})['result']['structuredContent']['instances']
            target = next((item for item in listing if item.get('available')), None)
            if target is None:
                raise AssertionError('No active SketchUp bridge instances')
            instance_id = target['instance_id']
            for name in ['sketchup_status', 'sketchup_inspect_model', 'sketchup_get_selection', 'sketchup_list_entities', 'sketchup_run_checks', 'sketchup_run_geometry_tests', 'sketchup_raycast']:
                arguments = {'instance_id': instance_id}
                if name == 'sketchup_raycast':
                    arguments.update({'origin_mm': [0, 0, 1000000], 'direction': [0, 0, 1]})
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
