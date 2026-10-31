#!/usr/bin/env python3
"""Drawing payload acceptance vs unchanged Swift decoder; bounded offset corpus."""
import base64,ctypes as c,json,random,struct,subprocess,sys
from pathlib import Path
work=Path(sys.argv[1]).resolve();root=Path(__file__).resolve().parents[2];lib=c.CDLL(str(work/'libglz-fixture.dylib'));lib.glz_fixture_display_parse.argtypes=[c.c_uint16,c.POINTER(c.c_uint8),c.c_size_t];lib.glz_fixture_display_parse.restype=c.c_int
lib.glz_fixture_stream_parse.argtypes=lib.glz_fixture_display_parse.argtypes;lib.glz_fixture_stream_parse.restype=c.c_int
rect=struct.pack('<4i',0,0,1,2);base=struct.pack('<I',0)+rect+b'\0';mask=b'\0'*13
seeds=[(104,base+struct.pack('<2i',0,0)),(302,base+b'\1'+struct.pack('<IH',0x11223344,8)+mask)]
def descriptor(kind,flags=0):return struct.pack('<QBBII',501,kind,flags,2,1)
def draw(image,pad=b''):
 return base+struct.pack('<I',57+len(pad))+rect+struct.pack('<HB',8,0)+mask+pad+image
images=[descriptor(0)+struct.pack('<BBIIII',8,4,2,1,8,0)+bytes(range(8)),descriptor(103),descriptor(106),descriptor(104)+struct.pack('<I',0)]
for kind in [1,101,102,105]:images.append(descriptor(kind)+struct.pack('<I',3)+b'abc')
images.append(descriptor(107)+struct.pack('<II',64,3)+b'abc')
for image in images:
 seeds.append((304,draw(image)));seeds.append((304,draw(image,b'\0\1\2')))
seeds.append((302,base+b'\2'+struct.pack('<IiiH',49,0,0,8)+mask+images[0]))
stream_base=struct.pack('<IIBBQIIII',0,63,1,1,0,2,1,2,1)+rect
for codec in range(1,6):
 create=bytearray(stream_base);create[9]=codec;seeds.append((122,bytes(create)+b'\0'))
seeds.extend([(122,stream_base+b'\1'+struct.pack('<I',1)+rect),(123,struct.pack('<III',1,0xffffffff,3)+b'abc'),(316,struct.pack('<IIII',1,5,2,1)+rect+struct.pack('<I',3)+b'abc'),(124,struct.pack('<I',1)+b'\0'),(125,struct.pack('<I',63)),(126,b''),(317,struct.pack('<HH7I',1,1,0,0,2,1,0,0,0))])
cases=[];expected=[];rng=random.Random(0x445350);truncations=mutations=0
def add(kind,data,valid=None):
 buf=(c.c_uint8*len(data)).from_buffer_copy(data);got=(lib.glz_fixture_stream_parse if kind in (122,123,124,125,126,316,317) else lib.glz_fixture_display_parse)(kind,buf,len(data))==0
 if valid is not None:assert got==valid,(kind,data.hex(),got)
 cases.append(dict(kind=kind,data=base64.b64encode(data).decode()));expected.append(got)
for kind,data in seeds:
 add(kind,data,True)
 for end in range(len(data)):add(kind,data[:end],False);truncations+=1
 add(kind,data+b'\0',False)
 for _ in range(200 if data else 0):
  mutant=bytearray(data)
  for _ in range(rng.randint(1,4)):mutant[rng.randrange(len(mutant))]=rng.randrange(256)
  add(kind,mutant);mutations+=1
actual=json.loads(subprocess.run([str(work/'display-oracle')],input=json.dumps(cases),text=True,capture_output=True,check=True,timeout=60).stdout)
assert len(actual)==len(expected)
for i,(want,got) in enumerate(zip(actual,expected)):assert want==got,(i,cases[i],want,got)
print(json.dumps(dict(result='passed',cases=len(cases),valid_seeds=len(seeds),truncations=truncations,mutations=mutations,scope='draw/stream/monitor wire acceptance; exact draw pixels and transaction rollback verified separately'),indent=2))
