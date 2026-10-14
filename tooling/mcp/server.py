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
INSTANCE = {'type': 'string', 'minLength': 36, 'maxLength': 36}
def schema(properties, required=()):
    props = {'instance_id': INSTANCE, 'expected_model_token': {'type': 'string'}, **properties}
    return {'type': 'object', 'properties': props,
            'required': ['instance_id', *required], 'additionalProperties': False}

TOOLS = [
    ('sketchup_capture_model', 'snapshot', 'Capture exact world geometry in mm to JSON, including loops, edges, instance paths and transforms. Returns artifact path and root summary; read file for detail. Selection capture respects edit context. Check truncated flag.',
     schema({'selection_only': {'type': 'boolean'}, 'include_geometry': {'type': 'boolean'},
             'limit': {'type': 'integer', 'minimum': 1, 'maximum': 10000}, 'depth': {'type': 'integer', 'minimum': 0, 'maximum': 32}}), True),
    ('sketchup_capture_view', 'view', 'Write current model viewport to a PNG artifact without changing the camera.', schema({}), True),
    ('sketchup_export_model', 'export', 'Export the entire target model as DAE or OBJ to a project runtime artifact. Does not save the SKP.', schema({'format': {'type': 'string', 'enum': ['dae', 'obj']}}), True),
    ('sketchup_list_instances', 'instances', 'List running SketchUp instances and their model paths.', EMPTY, True),
    ('sketchup_status', 'status', 'Read SketchUp version, bridge session, model path and root entity count.', schema({}), True),
    ('sketchup_inspect_model', 'inspect', 'Read model units, counts, tags, materials, scenes and save state.', schema({}), True),
    ('sketchup_list_entities', 'entities', 'Search model entities by type, name or tag; returns persistent IDs.',
     schema({'type': {'type': 'string'}, 'name_contains': {'type': 'string'}, 'tag': {'type': 'string'},
             'limit': {'type': 'integer', 'minimum': 1, 'maximum': 1000}}), True),
    ('sketchup_get_selection', 'selection', 'Read the current selection in the target model.', schema({}), True),
    ('sketchup_set_selection', 'select', 'Select entities by persistent ID in the target model.',
     schema({'persistent_ids': {'type': 'array', 'items': {'type': 'integer'}, 'maxItems': 1000}}, ['persistent_ids']), False),
    ('sketchup_raycast', 'raycast', 'Read the first visible geometry intersection. Origin and result are in millimeters; direction is a nonzero vector.',
     schema({'origin_mm': TRIPLE, 'direction': TRIPLE}, ['origin_mm', 'direction']), True),
    ('sketchup_create_geometry', 'create', 'Create a line or face inside a new group. Coordinates are in millimeters.',
     schema({'kind': {'type': 'string', 'enum': ['line', 'face']},
             'points_mm': {'type': 'array', 'items': TRIPLE, 'minItems': 2, 'maxItems': 500},
             'name': {'type': 'string'}, 'tag': {'type': 'string'}}, ['kind', 'points_mm']), False),
    ('sketchup_edit_entity', 'edit', 'Change supported entity properties: name, hidden, tag, material.',
     schema({'persistent_id': {'type': 'integer'}, 'properties': {'type': 'object'}}, ['persistent_id', 'properties']), False),
    ('sketchup_move_entities', 'move', 'Move entities by an offset in millimeters.',
     schema({'persistent_ids': {'type': 'array', 'items': {'type': 'integer'}, 'minItems': 1, 'maxItems': 1000},
             'offset_mm': TRIPLE}, ['persistent_ids', 'offset_mm']), False),
    ('sketchup_delete_entities', 'delete', 'Delete entities by persistent ID. This is undoable in SketchUp.',
     schema({'persistent_ids': {'type': 'array', 'items': {'type': 'integer'}, 'minItems': 1, 'maxItems': 1000}}, ['persistent_ids']), False),
    ('sketchup_save_model', 'save', 'Save the currently open model to its existing file path.', schema({}), False),
    ('sketchup_reload_plugin', 'reload', 'Reload trusted project source src/cj.rb in the target SketchUp process. Does not save the model.', schema({}), False),
    ('sketchup_run_checks', 'check', 'Run basic vector and interval checks in the target SketchUp process.', schema({}), False),
    ('sketchup_run_geometry_tests', 'geometry_test', 'Run temporary wall/occluder tests and roll back the created geometry. Use an idle test model outside group edit mode.', schema({}), False),
]


class BridgeError(Exception):
    def __init__(self, message, details=None):
        super().__init__(message)
        self.details = details


def validate_value(value, spec, path='argument'):
    kind = spec.get('type')
    valid = {
        'string': lambda v: isinstance(v, str),
        'integer': lambda v: type(v) is int,
        'number': lambda v: type(v) in (int, float) and math.isfinite(v),
        'boolean': lambda v: type(v) is bool,
        'array': lambda v: isinstance(v, list),
        'object': lambda v: isinstance(v, dict),
    }.get(kind, lambda _v: True)
    if not valid(value):
        return f'{path} must be {kind}'
    if kind == 'array':
        if len(value) < spec.get('minItems', 0) or len(value) > spec.get('maxItems', float('inf')):
            return f'{path} has an invalid number of items'
        if 'items' in spec:
            for index, item in enumerate(value):
                error = validate_value(item, spec['items'], f'{path}[{index}]')
                if error:
                    return error
    if kind == 'object':
        props = spec.get('properties', {})
        if spec.get('additionalProperties') is False and set(value) - set(props):
            return f'{path} has unsupported properties'
        if any(key not in value for key in spec.get('required', [])):
            return f'{path} is missing required properties'
        for key, item in value.items():
            if key in props:
                error = validate_value(item, props[key], f'{path}.{key}')
                if error:
                    return error
    if kind in ('integer', 'number'):
        if value < spec.get('minimum', float('-inf')) or value > spec.get('maximum', float('inf')):
            return f'{path} is outside the permitted range'
    if kind == 'string' and (len(value) < spec.get('minLength', 0) or len(value) > spec.get('maxLength', float('inf'))):
        return f'{path} has an invalid length'
    if 'enum' in spec and value not in spec['enum']:
        return f'{path} has an unsupported value'
    return None


class Bridge:
    def __init__(self, root: Path, timeout: float = 30):
        self.root = root.resolve()
        self.queue = self.root / 'tooling' / 'runtime'
        self.timeout = timeout

    def instances(self):
        instances = []
        for session_path in (self.queue / 'instances').glob('*/session.json'):
            try:
                session = json.loads(session_path.read_text(encoding='utf-8'))
                age = (datetime.now(timezone.utc) - datetime.fromisoformat(session['updated_at'].replace('Z', '+00:00'))).total_seconds()
                session['instance_id'] = session['session_id']
                session['available'] = bool(session.get('running')) and age <= 10
                session['heartbeat_age_seconds'] = max(0, round(age, 1))
                instances.append(session)
            except (OSError, ValueError, KeyError, TypeError):
                continue
        return sorted(instances, key=lambda item: (item.get('model_path', '').casefold(), item.get('pid', 0)))

    def request(self, command: str, arguments: dict, cancelled: threading.Event):
        instance_id = arguments.get('instance_id')
        if not isinstance(instance_id, str) or len(instance_id) != 36 or any(c not in '0123456789abcdef-' for c in instance_id.lower()):
            raise BridgeError('Choose an instance_id returned by sketchup_list_instances.')
        instance_queue = self.queue / 'instances' / instance_id
        session_path = instance_queue / 'session.json'
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
        path = instance_queue / f'{request_id}.request.json'
        response_path = instance_queue / f'{request_id}.response.json'
        request = {
            'protocol': 1, 'id': request_id, 'session_id': session['session_id'],
            'expires_at': (datetime.now(timezone.utc) + timedelta(seconds=self.timeout)).isoformat(),
            'command': command, 'args': {key: value for key, value in arguments.items() if key != 'instance_id'},
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
            schema_spec = tool[3]
            properties = schema_spec.get('properties', {})
            required = schema_spec.get('required', [])
            if not isinstance(arguments, dict) or set(arguments) - set(properties) or any(key not in arguments for key in required):
                self.error(request_id, -32602, 'Arguments do not match this tool schema')
                return
            validation_error = validate_value(arguments, schema_spec, 'arguments')
            if validation_error:
                self.error(request_id, -32602, validation_error)
                return
            if tool[1] == 'instances':
                result = self.bridge.instances()
                self.result(request_id, {'content': [{'type': 'text', 'text': json.dumps(result, ensure_ascii=False)}],
                                         'structuredContent': {'instances': result}, 'isError': False})
                return
            if 'instance_id' not in arguments:
                self.error(request_id, -32602, 'instance_id is required; call sketchup_list_instances first')
                return
            if tool[1] == 'raycast':
                for key in ('origin_mm', 'direction'):
                    value = arguments.get(key)
                    if not isinstance(value, list) or len(value) != 3 or not all(type(n) in (int, float) and math.isfinite(n) for n in value):
                        self.error(request_id, -32602, f'{key} must contain three finite numbers')
                        return
                if all(n == 0 for n in arguments['direction']):
                    self.error(request_id, -32602, 'Direction must not be zero')
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
                'serverInfo': {'name': 'sketchup-cj', 'version': '0.2.0'},
                'instructions': 'Call sketchup_list_instances first. Pass the selected instance_id to every SketchUp tool. Model edits run in one undoable SketchUp operation.',
            })
        elif method == 'ping':
            self.result(request_id, {})
        elif not self.ready:
            self.error(request_id, -32000, 'Initialize and send notifications/initialized first')
        elif method == 'tools/list':
            self.result(request_id, {'tools': [
                {'name': name, 'description': description, 'inputSchema': schema,
                 'annotations': {'readOnlyHint': readonly, 'destructiveHint': command in ('delete', 'save'),
                                 'idempotentHint': command in ('instances', 'status', 'inspect', 'entities', 'selection', 'raycast'), 'openWorldHint': False}}
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
