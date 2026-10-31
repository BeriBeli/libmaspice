#!/usr/bin/env python3
"""Existing Swift playback/record wire decoder acceptance, unchanged sources."""
import base64,ctypes as c,json,random,struct,subprocess,sys
from pathlib import Path
work=Path(sys.argv[1]).resolve();lib=c.CDLL(str(work/'libdisplay-fixture.dylib'))
parse=lib.display_fixture_audio_wire;parse.argtypes=[c.c_bool,c.c_uint16,c.POINTER(c.c_uint8),c.c_size_t];parse.restype=c.c_int
seeds=[(False,101,struct.pack('<I',120)+bytes(range(8))),(False,102,struct.pack('<IH',100,1)),(False,102,struct.pack('<IH',100,3)+b'codec'),(False,103,struct.pack('<IHII',2,1,48000,100)),(False,104,b''),(False,107,struct.pack('<I',40)),(True,101,struct.pack('<IHI',2,1,48000)),(True,102,b'')]
for record in (False,True):
 for count in (1,2,8,32):seeds.append((record,103 if record else 105,bytes([count])+b''.join(struct.pack('<H',i*2000) for i in range(count))))
 for mute in (0,1):seeds.append((record,104 if record else 106,bytes([mute])))
rng=random.Random(0x415544);cases=[];expected=[];truncations=mutations=0
def add(record,kind,data,valid=None):
 buf=(c.c_uint8*len(data)).from_buffer_copy(data);got=parse(record,kind,buf,len(data))==0
 if valid is not None:assert got==valid,(record,kind,len(data),got)
 cases.append(dict(record=record,kind=kind,data=base64.b64encode(data).decode()));expected.append(got)
for record,kind,data in seeds:
 add(record,kind,data,True)
 for end in range(len(data)):add(record,kind,data[:end]);truncations+=1
 add(record,kind,data+b'\0')
 for _ in range(200 if data else 0):
  mutant=bytearray(data)
  for _ in range(rng.randint(1,4)):mutant[rng.randrange(len(mutant))]=rng.randrange(256)
  add(record,kind,mutant);mutations+=1
for size in (0,1,256*1024,256*1024+1):add(False,101,struct.pack('<I',100)+b'\0'*size,size>0 and size<=256*1024)
for size in (64*1024,64*1024+1):add(False,102,struct.pack('<IH',100,1)+b'\0'*size,size<=64*1024)
actual=json.loads(subprocess.run([str(work/'audio-oracle')],input=json.dumps(cases),text=True,capture_output=True,check=True,timeout=60).stdout)
assert len(actual)==len(expected)
for i,(want,got) in enumerate(zip(actual,expected)):assert want==got,(i,cases[i],want,got)
print(json.dumps(dict(result='passed',cases=len(cases),valid_seeds=len(seeds),truncations=truncations,mutations=mutations,scope='RAW/codec-mode wire parsing, volume/mute, exact framing and maximum packet/mode sizes; runtime remains RAW S16'),indent=2))
