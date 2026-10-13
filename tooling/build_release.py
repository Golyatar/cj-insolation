"""Build a portable RBZ and source archive without local paths or dev tools in the plugin."""
from pathlib import Path
import hashlib
import json
import zipfile
import math
import struct
import zlib
import sys

sys.stdout.reconfigure(encoding='utf-8')

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.1.0'
OUTPUT = ROOT / 'dist'
OUTPUT.mkdir(exist_ok=True)
icons = ROOT / 'src/icons'
icons.mkdir(exist_ok=True)
size = 32
pixels = bytearray()
for y in range(size):
    pixels.append(0)
    for x in range(size):
        distance = math.hypot(x - 16, y - 11)
        angle = math.atan2(y - 11, x - 16)
        sun = distance <= 5 or (7 <= distance <= 10 and abs(math.sin(angle * 8)) < 0.24)
        color = (255, 190, 25, 255) if sun else (26, 52, 72, 255)
        if y >= 23:
            color = (0, 180, 75, 255) if x < 22 else (215, 55, 55, 255)
        pixels.extend(color)
def chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', size, size, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(bytes(pixels))) + chunk(b'IEND', b'')
(icons / 'insolation.png').write_bytes(png)
rbz = OUTPUT / f'cj-insolation-{VERSION}.rbz'
with zipfile.ZipFile(rbz, 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.write(ROOT / 'src/cj_insolation.rb', 'cj_insolation.rb')
    archive.write(ROOT / 'src/cj.rb', 'cj_insolation/main.rb')
    for icon in (ROOT / 'src/icons').glob('*'):
        archive.write(icon, 'cj_insolation/icons/' + icon.name)
    archive.write(ROOT / 'INSTALL.md', 'cj_insolation/INSTALL.md')
with zipfile.ZipFile(rbz) as archive:
    assert archive.testzip() is None
    assert {'cj_insolation.rb', 'cj_insolation/main.rb', 'cj_insolation/INSTALL.md'} <= set(archive.namelist())
    assert archive.read('cj_insolation/main.rb') == (ROOT / 'src/cj.rb').read_bytes()
digest = hashlib.sha256(rbz.read_bytes()).hexdigest()
(OUTPUT / 'SHA256SUMS.txt').write_text(f'{digest}  {rbz.name}\n', encoding='utf-8')
source = OUTPUT / f'cj-insolation-{VERSION}-source.zip'
with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name in ['README.md', 'INSTALL.md', 'CHANGELOG.md', '.gitignore']:
        archive.write(ROOT / name, name)
    for folder in ['src', 'tooling', 'dev', 'reference']:
        for file in (ROOT / folder).rglob('*'):
            if file.is_file() and not any(part in ('runtime', '__pycache__') for part in file.parts) and file.suffix not in ('.pyc', '.csv', '.json') and file.name != 'config.example.toml':
                archive.write(file, file.relative_to(ROOT).as_posix())
print(json.dumps({'rbz': str(rbz), 'sha256': digest, 'source': str(source)}, ensure_ascii=False))
