#!/usr/bin/env python3
import base64,ctypes as c,json,random,subprocess,sys
from pathlib import Path
work=Path(sys.argv[1]).resolve();root=Path(__file__).resolve().parents[2]
lib=c.CDLL(str(work/'libglz-fixture.dylib'));U=c.POINTER(c.c_uint8);Z=c.c_size_t
fn=lib.glz_fixture_annexb;fn.argtypes=[c.c_uint8,U,Z,U,Z];fn.restype=c.c_ssize_t
seeds=[]
for p in sorted((root/'test/fixtures/SpiceVideoToolboxTests').glob('*.json')):
 d=json.loads(p.read_text());seeds.append((int(d['codec']=='h265'),base64.b64decode(d['annexBBase64'])))
seeds.extend([(0,bytes([0,0,1,0x67,1,0,0,0,1,0x68,2,0,0,1,0x65,3,0,0])),(1,bytes([0,0,1,0x40,1,2,0,0,1,0x26,1,3]))])
cases=[];expected=[];rng=random.Random(0x414E4E);truncations=mutations=0
for codec,data in seeds:
 corpus=[data]+[data[:end] for end in range(len(data))];truncations+=len(data)
 for _ in range(1000):
  value=bytearray(data)
  for _ in range(rng.randint(1,4)):value[rng.randrange(len(value))]=rng.randrange(256)
  corpus.append(bytes(value));mutations+=1
 for value in corpus:
  buf=(c.c_uint8*len(value)).from_buffer_copy(value);out=(c.c_uint8*(len(value)*2+16384))();size=fn(codec,buf,len(value),out,len(out))
  expected.append(None if size<0 else base64.b64encode(bytes(out[:size])).decode());cases.append(dict(codec=codec,bytes=base64.b64encode(value).decode()))
actual=json.loads(subprocess.run([str(work/'annexb-oracle')],input=json.dumps(cases),text=True,capture_output=True,check=True,timeout=60).stdout)
assert len(actual)==len(expected)
for i,(want,got) in enumerate(zip(actual,expected)):assert want==got,(i,cases[i],want,got)
print(json.dumps(dict(result='passed',cases=len(cases),upstream_codec_fixtures=3,truncations=truncations,mutations=mutations,scope='acceptance, exact AVCC bytes and every NAL range, picture and random-access flags'),indent=2))
