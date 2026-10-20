"""Checks that need no Rhino installation and never launch an EXE."""
import importlib.util
import json
import pathlib
import re
import struct
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('engine_io', ROOT/'rhino/engine_io.py')
io = importlib.util.module_from_spec(spec)
spec.loader.exec_module(io)
raw = (ROOT/'src/cj.rb').read_text(encoding='utf-8').split('RAY_VECTORS_RAW = <<~VECTORS',1)[1].split('    VECTORS',1)[0]
expected = [list(map(float,m)) for m in re.findall(r'\{\s*([-+\d.]+),\s*([-+\d.]+),\s*([-+\d.]+)\}',raw)]
assert json.loads((ROOT/'rhino/sun_vectors.json').read_text()) == expected
assert len(io.directions(str(ROOT/'rhino/sun_vectors.json'))) == 510
assert not io.assess([None]*89)['passed']
assert io.assess([None]*90)['passed']
assert io.assess([None]*60+[1]+[None]*60)['passed']
assert not io.assess([None]*59+[1]+[None]*59)['passed']
with tempfile.TemporaryDirectory() as folder:
    path = pathlib.Path(folder)/'output.bin'
    correct = b'CJOUT001'+struct.pack('<II3d',1,3,-1,1,2)
    path.write_bytes(correct)
    assert io.read_output(str(path),1,3,25.4) == [[None,25.4,50.8]]
    for payload in [b'', correct[:-1], correct+b'x', b'BADMAGIC'+correct[8:], b'CJOUT001'+struct.pack('<II3d',1,3,float('nan'),0,-2)]:
        path.write_bytes(payload)
        try:
            io.read_output(str(path),1,3,25.4)
        except ValueError:
            pass
        else:
            raise AssertionError('Invalid response accepted')
    path.write_bytes(b'not an executable')
    try:
        io.approved_worker(str(path))
    except ValueError:
        pass
    else:
        raise AssertionError('Unapproved worker accepted')
print('PASS: original 510 directions, assessment boundaries, unit conversion, malformed output, worker pin')
