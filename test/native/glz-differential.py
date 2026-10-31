#!/usr/bin/env python3
"""Independent upstream GLZ pixels, Swift differential, and zlib envelope checks."""
import base64,ctypes as c,json,random,struct,subprocess,sys,zlib
from pathlib import Path
work=Path(sys.argv[1]).resolve();root=Path(__file__).resolve().parents[2]
lib=c.CDLL(str(work/'libglz-fixture.dylib'));P=c.c_void_p;Z=c.c_size_t;U=c.POINTER(c.c_uint8)
for name,args,result in [('create',[],P),('destroy',[P],None),('clear',[P],c.c_int),('decode',[P,U,Z,Z,Z,c.POINTER(P)],c.c_int),('pixels',[P,c.POINTER(Z)],U),('flags',[P],c.c_int),('release',[P],None),('inflate',[U,Z,U,Z],c.c_int)]:
 f=getattr(lib,'glz_fixture_'+name);f.argtypes=args;f.restype=result
state=lib.glz_fixture_create();assert state

def decode(case):
 if case['reset']:assert lib.glz_fixture_clear(state)==0
 data=base64.b64decode(case['data']);storage=(c.c_uint8*len(data)).from_buffer_copy(data);image=P()
 status=lib.glz_fixture_decode(state,storage,len(data),case['width'],case['height'],c.byref(image))
 if status:assert not image;return dict(status=-1)
 try:
  size=Z();pixels=lib.glz_fixture_pixels(image,c.byref(size))
  return dict(status=0,pixels=base64.b64encode(c.string_at(pixels,size.value)).decode(),flags=lib.glz_fixture_flags(image))
 finally:lib.glz_fixture_release(image)

cases=[];expected=[];truncations=mutations=0;rng=random.Random(0x474c5a)
entries=json.loads((root/'test/fixtures/SpiceCodecsTests/glz-reference-sequence.json').read_text())['entries']
def add(data,width,height,reset=True,pixels=None,flags=None):
 case=dict(data=base64.b64encode(data).decode(),width=width,height=height,reset=reset);got=decode(case)
 if pixels is not None:assert got==dict(status=0,pixels=base64.b64encode(pixels).decode(),flags=flags),(case,got)
 cases.append(case);expected.append(got)
def seed(prefix):
 assert lib.glz_fixture_clear(state)==0
 for i,entry in enumerate(prefix):add(base64.b64decode(entry['compressedBase64']),entry['width'],entry['height'],reset=i==0)
for i,entry in enumerate(entries):
 data=base64.b64decode(entry['compressedBase64']);add(data,entry['width'],entry['height'],reset=i==0,pixels=base64.b64decode(entry['expectedBGRABase64']),flags=(1 if data[8]&16 else 0)|(2 if data[8]&15==9 else 0))
# Mutations cannot wait for missing IDs: both oracles explicitly disable waits.
for i,entry in enumerate(entries):
 data=base64.b64decode(entry['compressedBase64']);w=entry['width'];h=entry['height']
 for end in range(len(data)):
  seed(entries[:i]);add(data[:end],w,h,reset=i==0);assert expected[-1]['status']==-1;truncations+=1
 for _ in range(400):
  mutant=bytearray(data)
  for _ in range(rng.randint(1,4)):mutant[rng.randrange(len(mutant))]=rng.randrange(256)
  seed(entries[:i]);add(mutant,w,h,reset=i==0);mutations+=1
 seed(entries[:i]);add(data+b'\0',w,h,reset=i==0);assert expected[-1]['status']==-1
# Large overlapping prefixes exercise bounded copy chunks and period continuity.
def header(kind,w,h,id=0,window=0):return struct.pack('>IIBIIIQI',0x20205a4c,0x10001,kind|16,w,h,w*(2 if kind==6 else 3 if kind==7 else 4),id,window)
def length_bytes(n):
 output=bytearray()
 while n>=255:output.append(255);n-=255
 output.append(n);return output
for kind,bias in [(6,1),(7,0),(8,0),(9,0)]:
 w,h=1024,129;count=w*h
 literals=bytes([1,0x7c,0,3,0xe0]) if kind==6 else bytes([1,1,2,3,4,5,6])
 body=literals+bytes([0xe1])+length_bytes(count-2-bias-7)+bytes([0,0])
 if kind==9:body+=bytes([1,11,77,0xe1])+length_bytes(count-2-2-7)+bytes([0,0])
 data=header(kind,w,h)+body
 pixel0=bytes([0,0,255,0]) if kind==6 else bytes([1,2,3,11 if kind==9 else 0])
 pixel1=bytes([0,255,0,0]) if kind==6 else bytes([4,5,6,77 if kind==9 else 0])
 add(data,w,h,pixels=(pixel0+pixel1)*(count//2),flags=3 if kind==9 else 1)
result=subprocess.run([str(work/'glz-oracle')],input=json.dumps(cases),text=True,capture_output=True,check=True,timeout=120)
actual=json.loads(result.stdout);assert len(actual)==len(expected)
for i,(want,got) in enumerate(zip(actual,expected)):
 want={k:v for k,v in want.items() if v is not None};assert want==got,(i,cases[i],want,got)
lib.glz_fixture_destroy(state)
fixture=json.loads((root/'test/fixtures/SpiceCodecsTests/zlib-glz-rgb32.json').read_text());compressed=base64.b64decode(fixture['compressedBase64']);plain=base64.b64decode(fixture['expectedGLZBase64'])
zchecks=0
for data,exact,success in [(compressed,len(plain),True),(compressed,len(plain)-1,False),(compressed,len(plain)+1,False),(compressed+b'\0',len(plain),False),(compressed+compressed,len(plain),False),*[(compressed[:n],len(plain),False) for n in range(len(compressed))]]:
 source=(c.c_uint8*len(data)).from_buffer_copy(data);output=(c.c_uint8*exact)();status=lib.glz_fixture_inflate(source,len(data),output,exact)
 assert (status==0)==success
 if success:assert bytes(output)==plain
 zchecks+=1
print(json.dumps(dict(result='passed',upstream_images=len(entries),differential_cases=len(cases),truncations=truncations,mutations=mutations,large_overlap_images=4,zlib_cases=zchecks),indent=2))
