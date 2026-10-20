"""Run standalone Ruby checks from an ASCII temp path on Windows Ruby 3."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='cj-cache-checks-') as folder:
    target = Path(folder)
    for name in ['src/geometry_cache.rb', 'src/native_engine.rb', 'dev/geometry_cache_checks.rb']:
        destination = target/name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root/name, destination)
    result = subprocess.run(['ruby', str(target/'dev/geometry_cache_checks.rb')], capture_output=True, text=True, check=True)
    report = json.loads(result.stdout)
    (root/'reports/geometry_cache_offline_check.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    assert report['passed']
    print(f"PASS: {len(report['checks'])} cache protocol/invalidation/cleanup checks; no EXE launched")
