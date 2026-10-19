"""Independent nearest-hit reference, protocol failures and parallel batch test."""
import math
import hashlib
from pathlib import Path
import random
import struct
import subprocess
import tempfile

ENGINE = Path(__file__).parent / 'stable/cj_engine.exe'
APPROVED_SHA256 = 'b6a02b00a3cb35cd93976be0d070683f275c6b8e61b98c474dd75a97b3c0e376'
def sub(a,b): return tuple(x-y for x,y in zip(a,b))
def dot(a,b): return sum(x*y for x,y in zip(a,b))
def cross(a,b): return (a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
def reference(triangles,o,d):
    best = math.inf
    for a,b,c in triangles:
        e1,e2=sub(b,a),sub(c,a); p=cross(d,e2); det=dot(e1,p)
        if abs(det)<1e-12: continue
        s=sub(o,a);u=dot(s,p)/det
        if not 0<=u<=1: continue
        q=cross(s,e1);v=dot(d,q)/det
        if v<0 or u+v>1: continue
        t=dot(e2,q)/det
        if t>1e-7: best=min(best,t)
    return -1 if math.isinf(best) else best

def run():
    if hashlib.sha256(ENGINE.read_bytes()).hexdigest() != APPROVED_SHA256:
        raise RuntimeError('Stable engine changed; refusing to execute it.')
    rng=random.Random(823)
    triangles=[tuple(tuple(rng.uniform(-20,20) for _ in range(3)) for _ in range(3)) for _ in range(80)]
    points=[tuple(rng.uniform(-30,30) for _ in range(3)) for _ in range(30)]
    directions=[]
    for _ in range(40):
        d=tuple(rng.uniform(-1,1) for _ in range(3));n=math.sqrt(dot(d,d));directions.append(tuple(x/n for x in d))
    with tempfile.TemporaryDirectory(prefix='cj-engine-test-') as folder:
        source=Path(folder)/'input.bin';target=Path(folder)/'output.bin'
        data=b'CJIN0001'+struct.pack('<III',len(triangles),len(points),len(directions))
        data+=b''.join(struct.pack('<3d',*v) for tri in triangles for v in tri)
        data+=b''.join(struct.pack('<3d',*v) for v in points+directions)
        source.write_bytes(data)
        subprocess.run([str(ENGINE),str(source),str(target)],check=True)
        output=target.read_bytes();assert output[:8]==b'CJOUT001'
        actual=struct.unpack('<'+'d'*(len(points)*len(directions)),output[16:])
        expected=[reference(triangles,p,d) for p in points for d in directions]
        assert all((a==-1)==(b==-1) and abs(a-b)<1e-8 for a,b in zip(actual,expected))
        for invalid in [b'',data[:19],data[:-1],data+b'bad',b'BADMAGIC'+data[8:]]:
            source.write_bytes(invalid)
            assert subprocess.run([str(ENGINE),str(source),str(target)],capture_output=True).returncode==2
        # Empty geometry is valid and must return misses, never fabricated hits.
        source.write_bytes(b'CJIN0001'+struct.pack('<III',0,1,1)+struct.pack('<6d',0,0,0,1,0,0))
        subprocess.run([str(ENGINE),str(source),str(target)],check=True)
        assert struct.unpack('<d',target.read_bytes()[16:])[0]==-1
    print('PASS: 1200 rays against independent reference; malformed inputs; empty scene')

if __name__=='__main__': run()
