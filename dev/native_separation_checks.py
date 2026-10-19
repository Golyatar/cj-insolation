"""Verify experimental files cannot be launched or silently enter a release.

Runs Python/Ruby packaging code only; never executes a C++ worker.
"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run():
    stable = ROOT / 'native/stable'
    manifest = json.loads((stable / 'manifest.json').read_text())
    expected = manifest['sha256']
    with tempfile.TemporaryDirectory(prefix='cj-native-separation-') as directory:
        root = Path(directory)
        shutil.copytree(ROOT / 'src', root / 'src')
        (root / 'tooling').mkdir()
        shutil.copy2(ROOT / 'tooling/build_release.py', root / 'tooling/build_release.py')
        shutil.copytree(stable, root / 'native/stable')
        for name in ['README.md', 'INSTALL.md', 'CHANGELOG.md', 'WINDOW_POINTS.md',
                     'WINDOW_COMPONENTS.md', 'RELEASING.md', '.gitignore']:
            shutil.copy2(ROOT / name, root / name)
        for folder in ['dev', 'reference']:
            (root / folder).mkdir()
        for relative in ['native/build/cj_engine.exe', 'native/build/experimental/cj_engine.exe']:
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'NOT AN EXECUTABLE: experimental sentinel')

        command = [sys.executable, str(root / 'tooling/build_release.py')]
        result = subprocess.run(command, capture_output=True, check=True, encoding='utf-8')
        package = Path(json.loads(result.stdout)['rbz'])
        with zipfile.ZipFile(package) as archive:
            assert hashlib.sha256(archive.read('cj_insolation/bin/cj_engine.exe')).hexdigest() == expected
            assert not any('scene_cache' in n or 'scene_export' in n for n in archive.namelist())
        original_package = package.read_bytes()

        worker = root / 'native/stable/cj_engine.exe'
        worker.write_bytes(b'CHANGED STABLE FILE')
        assert subprocess.run(command, capture_output=True).returncode != 0
        assert package.read_bytes() == original_package, 'Failed build overwrote the working package'
        worker.unlink()
        assert subprocess.run(command, capture_output=True).returncode != 0
        assert package.read_bytes() == original_package, 'Missing stable file caused an experimental fallback'

        code = '''require 'json'
require ARGV.fetch(0)
module CJ::Settings
  def self.values; {'engine'=>'cpp'}; end
end
module CJ::RayTubesUp
  def self.log(_message); end
end
def Process.spawn(*args); raise 'Unexpected child launch'; end
raise 'Working backup rejected' unless CJ::NativeEngine.approved?
raise 'Runtime uses build directory' if CJ::NativeEngine.executable.include?('/build/')
path=ARGV.fetch(1)
CJ::NativeEngine.define_singleton_method(:executable) { path }
raise 'Experimental file accepted' if CJ::NativeEngine.approved?
raise 'Experimental calculation started' unless CJ::NativeEngine.start({}) == false
path=ARGV.fetch(2)
raise 'Missing worker accepted' if CJ::NativeEngine.approved?
raise 'Missing worker calculation started' unless CJ::NativeEngine.start({}) == false
puts 'PASS: runtime rejects changed/missing workers before Process.spawn'
'''
        result = subprocess.run(['ruby', '-e', code, str(ROOT / 'src/native_engine.rb'),
                                 str(root / 'native/build/experimental/cj_engine.exe'),
                                 str(root / 'missing.exe')], capture_output=True, check=True, text=True)
        print(result.stdout.strip())
    print('PASS: packaging pins stable EXE, ignores both experimental paths, preserves releases on failure')


if __name__ == '__main__':
    run()
