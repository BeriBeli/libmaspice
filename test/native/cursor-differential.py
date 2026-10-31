#!/usr/bin/env python3
"""Unchanged Swift cursor parser is the independent acceptance oracle."""
import base64,ctypes as c,json,random,struct,subprocess,sys
from pathlib import Path
work=Path(sys.argv[1]).resolve();lib=c.CDLL(str(work/'libdisplay-fixture.dylib'))
parse=lib.display_fixture_cursor_wire;parse.argtypes=[c.c_uint16,c.POINTER(c.c_uint8),c.c_size_t];parse.restype=c.c_int
seeds=[(101,struct.pack('<hhHHBH',-32768,32767,2,3,0,1)),(102,b''),(104,struct.pack('<hh',-2,5)),(105,b''),(106,struct.pack('<HH',2,3)),(107,struct.pack('<Q',77)),(108,b'')]
for kind in range(7):
 for width,height in [(1,1),(3,3),(9,2),(16,1)]:
  header=struct.pack('<QB4H',77,kind,width,height,width,height)
  seeds.append((103,struct.pack('<hhBH',11,21,1,4)+header))
  pixels=width*height;mask=(pixels+7)//8
  size={0:pixels*4,1:((width+7)//8)*height*2,2:((width+1)//2)*height+64+mask,4:pixels*2+mask,6:pixels*4+mask}.get(kind)
  if size is not None:seeds.append((101,struct.pack('<hhHHBH',10,20,2,3,1,2)+header+bytes((i%256 for i in range(size)))))
rng=random.Random(0x435552);cases=[];expected=[];truncations=mutations=0
def add(kind,data,valid=None):
 buf=(c.c_uint8*len(data)).from_buffer_copy(data);got=parse(kind,buf,len(data))==0
 if valid is not None:assert got==valid,(kind,data.hex(),got)
 cases.append(dict(kind=kind,data=base64.b64encode(data).decode()));expected.append(got)
for kind,data in seeds:
 add(kind,data,True)
 for end in range(len(data)):add(kind,data[:end],False);truncations+=1
 add(kind,data+b'\0',False)
 for _ in range(100 if data else 0):
  mutant=bytearray(data)
  for _ in range(rng.randint(1,4)):mutant[rng.randrange(len(mutant))]=rng.randrange(256)
  add(kind,mutant);mutations+=1
actual=json.loads(subprocess.run([str(work/'cursor-oracle')],input=json.dumps(cases),text=True,capture_output=True,check=True,timeout=60).stdout)
assert len(actual)==len(expected)
for i,(want,got) in enumerate(zip(actual,expected)):assert want==got,(i,cases[i],want,got)
print(json.dumps(dict(result='passed',cases=len(cases),valid_seeds=len(seeds),truncations=truncations,mutations=mutations,scope='cursor wire acceptance for existing formats, cached unsupported formats, bounds, truncations and malformed data'),indent=2))
