"""Read-only MCP handshake and bridge round-trip for the SketchUp connection UI."""
import argparse
import json
import os
from pathlib import Path
from queue import Queue
import subprocess
import sys
import threading
from datetime import datetime, timezone


def diagnose(instance):
    executable = Path(sys.executable).with_name('python.exe') if os.name == 'nt' else Path(sys.executable)
    process = subprocess.Popen([str(executable), str(Path(__file__).with_name('server.py'))],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, encoding='utf-8', creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    responses = Queue()
    def read():
        for line in process.stdout:
            try:
                responses.put(json.loads(line))
            except ValueError:
                responses.put({'error': 'Invalid MCP JSON'})
    threading.Thread(target=read, daemon=True).start()
    def send(method, params=None, identity=None):
        request = {'jsonrpc': '2.0', 'method': method}
        if identity is not None:
            request['id'] = identity
        if params is not None:
            request['params'] = params
        process.stdin.write(json.dumps(request) + '\n')
        process.stdin.flush()
        if identity is None:
            return
        response = responses.get(timeout=35)
        if response.get('id') != identity or 'error' in response:
            raise RuntimeError(str(response.get('error', 'MCP response ID mismatch')))
        return response['result']
    try:
        send('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'cj-panel', 'version': '1'}}, 1)
        send('notifications/initialized')
        tools = send('tools/list', identity=2)['tools']
        result = send('tools/call', {'name': 'sketchup_status', 'arguments': {'instance_id': instance}}, 3)
        if result.get('isError'):
            raise RuntimeError(result['content'][0]['text'])
        return {'passed': True, 'tool_count': len(tools), 'tools': [t['name'] for t in tools],
                'message': 'MCP отвечает; чтение этой модели через MCP прошло.',
                'scope': 'Проверен отдельный диагностический клиент, не соединение текущего Codex.'}
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--instance', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2] / 'tooling' / 'runtime'
    output = args.output.resolve()
    if root.resolve() not in output.parents:
        parser.error('Output must be inside tooling/runtime')
    try:
        report = diagnose(args.instance)
    except Exception as error:
        report = {'passed': False, 'message': str(error)}
    report['checked_at'] = datetime.now(timezone.utc).isoformat()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix('.tmp')
    temporary.write_text(json.dumps(report, ensure_ascii=False), encoding='utf-8')
    temporary.replace(output)
