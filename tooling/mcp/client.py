"""Local stdio MCP client for diagnostic and developer commands."""
import json
from pathlib import Path
from queue import Queue
import subprocess
import sys
import threading

SERVER = Path(__file__).with_name('server.py')
ROOT = SERVER.parents[2]

class Client:
    def __init__(self, root=ROOT, timeout=2):
        self.timeout = timeout
        self.process = subprocess.Popen([sys.executable, str(SERVER), '--project-root', str(root), '--timeout', str(timeout)],
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
        response = self.responses.get(timeout=max(5, self.timeout + 3))
        if response.get('id') != request_id:
            raise RuntimeError(str(response))
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

