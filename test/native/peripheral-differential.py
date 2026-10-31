#!/usr/bin/env python3
"""Smartcard, VMC and port acceptance against unchanged Swift codecs."""
import base64,ctypes as c,json,random,struct,subprocess,sys
from pathlib import Path
work=Path(sys.argv[1]).resolve();lib=c.CDLL(str(work/'libdisplay-fixture.dylib'))
parse=lib.display_fixture_peripheral_wire;parse.argtypes=[c.c_uint16,c.POINTER(c.c_uint8),c.c_size_t];parse.restype=c.c_int
seeds=[]
for kind,reader,data in [(1,0xffffffff,struct.pack('<III',0x44435356,2,0)),(2,2,struct.pack('<I',0)),(3,0xffffffff,b'reader'),(4,2,b''),(5,2,b'\x3b\0'),(6,2,b''),(7,2,b'\1\2\3\4'),(8,2,b''),(9,2,b'')]:seeds.append((8,struct.pack('<III',kind,reader,len(data))+data))
seeds.append((9,b'raw-vmc'))
for opened in (0,1):
 for name in ('org.spice-space.webdav.0','共享'):
  name=name.encode()+b'\0';seeds.append((201,struct.pack('<IIB',len(name),9,opened)+name))
for event in range(3):seeds.append((202,bytes([event])))
rng=random.Random(0x504552);cases=[];expected=[];truncations=mutations=0
def add(kind,data,valid=None):
 buf=(c.c_uint8*len(data)).from_buffer_copy(data);got=parse(kind,buf,len(data))==0
 if valid is not None:assert got==valid,(kind,len(data),got)
 cases.append(dict(kind=kind,data=base64.b64encode(data).decode()));expected.append(got)
for kind,data in seeds:
 add(kind,data,True)
 for end in range(len(data)):add(kind,data[:end]);truncations+=1
 add(kind,data+b'\0')
 for _ in range(200 if data else 0):
  mutant=bytearray(data)
  for _ in range(rng.randint(1,4)):mutant[rng.randrange(len(mutant))]=rng.randrange(256)
  add(kind,mutant);mutations+=1
for kind,limit in [(3,255),(5,40),(7,64*1024+8)]:
 for size in (0,limit,limit+1):add(8,struct.pack('<III',kind,0xffffffff if kind==3 else 2,size)+b'a'*size,size>0 and size<=limit)
for size in (0,1024*1024,1024*1024+1):add(9,b'x'*size,size>0 and size<=1024*1024)
actual=json.loads(subprocess.run([str(work/'peripheral-oracle')],input=json.dumps(cases),text=True,capture_output=True,check=True,timeout=60).stdout)
assert len(actual)==len(expected)
for i,(want,got) in enumerate(zip(actual,expected)):assert want==got,(i,cases[i],want,got)
print(json.dumps(dict(result='passed',cases=len(cases),valid_seeds=len(seeds),truncations=truncations,mutations=mutations,scope='Smartcard, VMC, port wire bounds and acceptance; host device/filesystem access not exercised'),indent=2))
