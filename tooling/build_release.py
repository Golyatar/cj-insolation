"""Build a portable RBZ and source archive without local paths or dev tools in the plugin."""
from pathlib import Path
import hashlib
import json
import zipfile
import math
import struct
import zlib
import sys
import re

sys.stdout.reconfigure(encoding='utf-8')

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.search(r"VERSION = '([0-9]+\.[0-9]+\.[0-9]+)'", (ROOT / 'src/version.rb').read_text(encoding='utf-8')).group(1)
engine = ROOT / 'native/stable/cj_engine.exe'
stable = json.loads((engine.parent / 'manifest.json').read_text(encoding='utf-8'))
if not engine.is_file() or hashlib.sha256(engine.read_bytes()).hexdigest() != stable['sha256']:
    raise RuntimeError('Saved stable worker is missing or changed; experimental builds are never packaged.')
OUTPUT = ROOT / 'dist'
OUTPUT.mkdir(exist_ok=True)
icons = ROOT / 'src/icons'
icons.mkdir(exist_ok=True)
rbz = OUTPUT / f'cj-insolation-{VERSION}.rbz'
with zipfile.ZipFile(rbz, 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.write(ROOT / 'src/cj_insolation.rb', 'cj_insolation.rb')
    archive.write(ROOT / 'src/cj.rb', 'cj_insolation/main.rb')
    archive.write(ROOT / 'src/version.rb', 'cj_insolation/version.rb')
    archive.write(ROOT / 'src/updates.rb', 'cj_insolation/updates.rb')
    archive.write(ROOT / 'src/result_style.rb', 'cj_insolation/result_style.rb')
    archive.write(ROOT / 'src/window_geometry.rb', 'cj_insolation/window_geometry.rb')
    archive.write(ROOT / 'src/window_components.rb', 'cj_insolation/window_components.rb')
    for name in ['settings.rb', 'saved_points.rb', 'interface.rb', 'native_engine.rb', 'geometry_cache.rb']:
        archive.write(ROOT / 'src' / name, 'cj_insolation/' + name)
    archive.write(engine, 'cj_insolation/bin/cj_engine.exe')
    for icon in (ROOT / 'src/icons').glob('*'):
        archive.write(icon, 'cj_insolation/icons/' + icon.name)
    archive.write(ROOT / 'INSTALL.md', 'cj_insolation/INSTALL.md')
    archive.write(ROOT / 'WINDOW_COMPONENTS.md', 'cj_insolation/WINDOW_COMPONENTS.md')
with zipfile.ZipFile(rbz) as archive:
    assert archive.testzip() is None
    assert {'cj_insolation.rb', 'cj_insolation/main.rb', 'cj_insolation/INSTALL.md'} <= set(archive.namelist())
    assert archive.read('cj_insolation/main.rb') == (ROOT / 'src/cj.rb').read_bytes()
digest = hashlib.sha256(rbz.read_bytes()).hexdigest()
(OUTPUT / 'SHA256SUMS.txt').write_text(f'{digest}  {rbz.name}\n', encoding='utf-8')
source = OUTPUT / f'cj-insolation-{VERSION}-source.zip'
with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name in ['README.md', 'INSTALL.md', 'CHANGELOG.md', 'WINDOW_POINTS.md', 'WINDOW_COMPONENTS.md', 'RELEASING.md', '.gitignore']:
        archive.write(ROOT / name, name)
    for folder in ['src', 'tooling', 'dev', 'native', 'reference']:
        for file in (ROOT / folder).rglob('*'):
            if file.is_file() and not any(part in ('runtime', '__pycache__', 'build') for part in file.parts) and file.suffix not in ('.exe', '.dll', '.obj', '.rbz', '.zip') and (file.suffix not in ('.pyc', '.csv', '.json') or file in (ROOT / 'dev/window_examples.json', ROOT / 'native/stable/manifest.json')) and file.name != 'config.example.toml':
                archive.write(file, file.relative_to(ROOT).as_posix())
print(json.dumps({'rbz': str(rbz), 'sha256': digest, 'source': str(source)}, ensure_ascii=False))
