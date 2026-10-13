"""Local MCP stdio server for the CJ SketchUp file bridge (stdlib only)."""
from __future__ import annotations

import argparse
import concurrent.futures
from datetime import datetime, timezone, timedelta
import json
import math
from pathlib import Path
import sys
import threading
import time
import uuid

VERSIONS = ('2025-06-18', '2025-03-26', '2024-11-05')
EMPTY = {'type': 'object', 'properties': {}, 'additionalProperties': False}
TRIPLE = {'type': 'array', 'items': {'type': 'number'}, 'minItems': 3, 'maxItems': 3}
TOOLS = [
    ('sketchup_status', 'status', 'Read SketchUp version, bridge session and current model entity count.', EMPTY, True),
    ('sketchup_reload_plugin', 'reload', 'Reload trusted project source src/cj.rb in the current SketchUp process. Does not save the model.', EMPTY, False),
    ('sketchup_run_checks', 'check', 'Run basic vector and interval checks and write a report. May load the project plugin on first use.', EMPTY, False),
    ('sketchup_run_geometry_tests', 'geometry_test', 'Run temporary wall/cone tests and roll back the created geometry. Use an idle test model outside group edit mode.', EMPTY, False),
    ('sketchup_raycast', 'raycast', 'Read the first visible geometry intersection. Origin and result are in millimeters; direction is a nonzero vector.',
     {'type': 'object', 'properties': {'origin_mm': TRIPLE, 'direction': TRIPLE},
      'required': ['origin_mm', 'direction'], 'additionalProperties': False}, True),
]


class BridgeError(Exception):
    def __init__(self, message, details=None):
        super().__init__(message)
        self.details = details


class Bridge:
    def __init__(self, root: Path, timeout: float = 30):
        self.root = root.resolve()
        self.queue = self.root / 'tooling' / 'runtime'
        self.timeout = timeout

    def request(self, command: str, arguments: dict, cancelled: threading.Event):
        session_path = self.queue / 'session.json'
        try:
            session = json.loads(session_path.read_text(encoding='utf-8'))
        except (OSError, ValueError) as error:
            raise BridgeError('SketchUp bridge is not available. Load tooling/sketchup_bridge.rb in Ruby Console.') from error
        if not session.get('running'):
            raise BridgeError('SketchUp bridge is stopped. Reload tooling/sketchup_bridge.rb.')
        updated = datetime.fromisoformat(session['updated_at'].replace('Z', '+00:00'))
        if (datetime.now(timezone.utc) - updated).total_seconds() > 10:
            raise BridgeError('SketchUp heartbeat is stale. The app may be closed, busy or blocked by a dialog.')
        if command not in session.get('commands', []):
            raise BridgeError(f'Bridge does not support command: {command}')
        request_id = str(uuid.uuid4())
        path = self.queue / f'{request_id}.request.json'
        response_path = self.queue / f'{request_id}.response.json'
        request = {
            'protocol': 1, 'id': request_id, 'session_id': session['session_id'],
            'expires_at': (datetime.now(timezone.utc) + timedelta(seconds=self.timeout)).isoformat(),
            'command': command, 'args': arguments,
        }
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(request, ensure_ascii=False, allow_nan=False), encoding='utf-8')
        temporary.replace(path)
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            if response_path.exists():
                response = json.loads(response_path.read_text(encoding='utf-8'))
                if response.get('id') != request_id or response.get('session_id') != session['session_id']:
                    raise BridgeError('SketchUp response identity mismatch.')
                if not response.get('ok'):
                    raise BridgeError('SketchUp command failed.', response)
                return response
            if cancelled.wait(0.05):
                # Expire an unclaimed request; do not pretend to interrupt Ruby already running.
                try:
                    request['expires_at'] = datetime.now(timezone.utc).isoformat()
                    temporary.write_text(json.dumps(request), encoding='utf-8')
                    temporary.replace(path)
                except OSError:
                    pass
                raise BridgeError('MCP wait cancelled. A SketchUp command already started may still finish.', {'request_id': request_id})
        raise BridgeError('SketchUp timeout. Inspect this request response before retrying an action; it may still finish.',
                          {'request_id': request_id, 'response_file': str(response_path)})


class Server:
    def __init__(self, bridge):
        self.bridge = bridge
        self.initialized = False
        self.ready = False
        self.lock = threading.Lock()
        self.pending_lock = threading.Lock()
        self.pending = {}
        self.executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)

    def send(self, message):
        with self.lock:
            sys.stdout.write(json.dumps(message, ensure_ascii=False, allow_nan=False, separators=(',', ':')) + '\n')
            sys.stdout.flush()

    def result(self, request_id, result):
        self.send({'jsonrpc': '2.0', 'id': request_id, 'result': result})

    def error(self, request_id, code, message):
        self.send({'jsonrpc': '2.0', 'id': request_id, 'error': {'code': code, 'message': message}})

    def call(self, request_id, params, cancelled):
        try:
            if not isinstance(params, dict) or not isinstance(params.get('name'), str):
                self.error(request_id, -32602, 'Expected tool name and arguments object')
                return
            tool = next((t for t in TOOLS if t[0] == params['name']), None)
            if tool is None:
                self.error(request_id, -32602, 'Unknown tool')
                return
            arguments = params.get('arguments', {})
            if not isinstance(arguments, dict):
                self.error(request_id, -32602, 'Arguments must be an object')
                return
            if tool[1] == 'raycast':
                if set(arguments) != {'origin_mm', 'direction'}:
                    self.error(request_id, -32602, 'Expected origin_mm and direction only')
                    return
                for value in arguments.values():
                    if not isinstance(value, list) or len(value) != 3 or not all(type(n) in (int, float) and math.isfinite(n) for n in value):
                        self.error(request_id, -32602, 'Expected triples of finite numbers')
                        return
                if all(n == 0 for n in arguments['direction']):
                    self.error(request_id, -32602, 'Direction must not be zero')
                    return
            elif arguments:
                self.error(request_id, -32602, 'This tool accepts no arguments')
                return
            if cancelled.is_set():
                return
            response = self.bridge.request(tool[1], arguments, cancelled)
            failed = response.get('result', {}).get('passed') is False
            self.result(request_id, {
                'content': [{'type': 'text', 'text': json.dumps(response, ensure_ascii=False)}],
                'structuredContent': response, 'isError': failed,
            })
        except (BridgeError, OSError, ValueError, KeyError) as error:
            payload = {'message': str(error)}
            if isinstance(error, BridgeError) and error.details:
                payload['details'] = error.details
            self.result(request_id, {'content': [{'type': 'text', 'text': json.dumps(payload, ensure_ascii=False)}],
                                     'structuredContent': payload, 'isError': True})
        except Exception as error:
            print(f'MCP internal error: {type(error).__name__}: {error}', file=sys.stderr)
            self.error(request_id, -32603, 'Internal server error')
        finally:
            with self.pending_lock:
                self.pending.pop(request_id, None)

    def handle(self, message):
        if not isinstance(message, dict) or message.get('jsonrpc') != '2.0' or not isinstance(message.get('method'), str):
            self.error(None, -32600, 'Invalid JSON-RPC request')
            return
        request_id = message.get('id')
        method = message['method']
        params = message.get('params', {})
        if 'id' not in message:
            if method == 'notifications/initialized' and self.initialized:
                self.ready = True
            elif method == 'notifications/cancelled' and isinstance(params, dict):
                if type(params.get('requestId')) not in (str, int):
                    return
                with self.pending_lock:
                    event = self.pending.get(params.get('requestId'))
                    if event:
                        event.set()
            return
        if type(request_id) not in (str, int):
            self.error(None, -32600, 'Request ID must be a string or integer')
            return
        if method == 'initialize':
            if self.initialized or not isinstance(params, dict) or not isinstance(params.get('protocolVersion'), str):
                self.error(request_id, -32602, 'Invalid or duplicate initialize')
                return
            version = params['protocolVersion']
            self.initialized = True
            self.result(request_id, {
                'protocolVersion': version if version in VERSIONS else VERSIONS[0],
                'capabilities': {'tools': {'listChanged': False}},
                'serverInfo': {'name': 'sketchup-cj', 'version': '0.1.0'},
                'instructions': 'Uses the local CJ Ruby bridge. SketchUp must be running with tooling/sketchup_bridge.rb loaded. Use geometry tests on an idle test model.',
            })
        elif method == 'ping':
            self.result(request_id, {})
        elif not self.ready:
            self.error(request_id, -32000, 'Initialize and send notifications/initialized first')
        elif method == 'tools/list':
            self.result(request_id, {'tools': [
                {'name': name, 'description': description, 'inputSchema': schema,
                 'annotations': {'readOnlyHint': readonly, 'destructiveHint': False,
                                 'idempotentHint': command in ('status', 'raycast'), 'openWorldHint': False}}
                for name, command, description, schema, readonly in TOOLS
            ]})
        elif method == 'tools/call':
            with self.pending_lock:
                if request_id in self.pending:
                    self.error(request_id, -32600, 'Duplicate pending request ID')
                    return
                event = threading.Event()
                self.pending[request_id] = event
            self.executor.submit(self.call, request_id, params, event)
        else:
            self.error(request_id, -32601, f'Method not found: {method}')

    def run(self):
        try:
            for line in sys.stdin:
                try:
                    message = json.loads(line, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
                except ValueError:
                    self.error(None, -32700, 'Parse error')
                    continue
                self.handle(message)
        finally:
            with self.pending_lock:
                for event in self.pending.values():
                    event.set()
            self.executor.shutdown(wait=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--project-root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--timeout', type=float, default=30)
    arguments = parser.parse_args()
    if not 1 <= arguments.timeout <= 60:
        parser.error('timeout must be between 1 and 60 seconds')
    sys.stdin.reconfigure(encoding='utf-8')
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    Server(Bridge(arguments.project_root, arguments.timeout)).run()


if __name__ == '__main__':
    main()
