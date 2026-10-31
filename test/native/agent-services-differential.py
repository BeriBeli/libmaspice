#!/usr/bin/env python3
"""Compare unchanged Swift Agent wire codecs and clipboard state actions."""
import base64,ctypes as c,json,random,struct,subprocess,sys
from pathlib import Path
work=Path(sys.argv[1]).resolve();lib=c.CDLL(str(work/'libagent-services.dylib'))
P=c.c_void_p;B=c.POINTER(c.c_uint8);Z=c.c_size_t
lib.service_parse.argtypes=[c.c_uint32,c.c_uint32,B,Z];lib.service_parse.restype=c.c_int
lib.service_filename.argtypes=[B,Z,B,Z];lib.service_filename.restype=c.c_ssize_t
lib.clipboard_create.restype=P;lib.clipboard_destroy.argtypes=[P]
lib.clipboard_step.argtypes=[P,c.c_uint32,c.c_int64,c.c_uint32,B,Z,B,Z];lib.clipboard_step.restype=c.c_ssize_t
out=(c.c_uint8*65536)()
def buf(data):return (c.c_uint8*len(data)).from_buffer_copy(data)
def item(op=4,value=1,kind=0,data=b''):return dict(op=op,value=value,kind=kind,data=base64.b64encode(data).decode())
def oracle(mode,inputs):
 return [base64.b64decode(v) for v in json.loads(subprocess.run([str(work/'agent-services-oracle')],input=json.dumps(dict(mode=mode,inputs=inputs)),text=True,capture_output=True,check=True,timeout=60).stdout)]
def compare(mode,inputs,actual):
 expected=oracle(mode,inputs);assert len(expected)==len(actual)
 for i,(x,y) in enumerate(zip(expected,actual)):
  assert x==y,(mode,i,inputs[max(0,i-3):i+1],x.hex(),y.hex())
u32=lambda *x:struct.pack('<'+'I'*len(x),*x)
seeds=[(6,u32(1,0x50ae)),(6,u32(0)),(7,u32(1)),(7,u32(0,1,99)),(8,u32(1)),(9,b''),(4,u32(1)+b'hello'),(4,u32(0)),(10,u32(7)+b'metadata\0'),(12,u32(7)+struct.pack('<Q',3)+b'xyz'),(3,u32(2,1)),(3,u32(2,2)),(3,u32(99,77))]
for result in range(8):seeds.append((11,u32(7,result)))
seeds += [(11,u32(7,2)+b'\0'+u32(88)),(11,u32(7,4)+struct.pack('<Q',2**63))]
rng=random.Random(0x4147454e54);inputs=[];actual=[]
def parse(kind,data,protocol=1):
 inputs.append(item(kind=kind,data=data,value=protocol));actual.append(struct.pack('<i',lib.service_parse(protocol,kind,buf(data),len(data))))
for kind,data in seeds:
 parse(kind,data);parse(kind,data,2)
 for end in range(len(data)):parse(kind,data[:end])
 parse(kind,data+b'\0')
 for _ in range(150 if data else 0):
  mutant=bytearray(data)
  for _ in range(rng.randint(1,3)):mutant[rng.randrange(len(mutant))]=rng.randrange(256)
  parse(kind,mutant)
for n in (0,1,16,17):parse(6,u32(1)+u32(0)*n)
for n in (0,1,64,65):parse(7,u32(1)*n)
for n in (0,4096,4097):parse(10,u32(7)+b'x'*n)
for n in (0,16000,16001):parse(12,u32(7)+struct.pack('<Q',n)+b'x'*n)
compare('parse',inputs,actual);parse_count=len(inputs)
# Every BMP scalar at each basename edge, plus supplementary-plane samples.
# Include combining scalars, non-BMP Unicode, separators and raw invalid UTF-8.
inputs=[];actual=[]
scalars=list(range(0x10000))+[0x10000,0x1f642,0x10ffff]
for scalar in scalars:
 if 0xd800<=scalar<=0xdfff:continue
 char=chr(scalar)
 for name in (char+'x','x'+char):
  data=name.encode();inputs.append(item(data=data));count=lib.service_filename(buf(data),len(data),out,len(out));actual.append(bytes(out[:count]) if count>=0 else b'\xff')
for data in [b'',b'.',b'..',b'../x',b'a\\b',b'\xff',b'a'*4100,'报告.txt'.encode(),b'a b']:
 inputs.append(item(data=data));count=lib.service_filename(buf(data),len(data),out,len(out));actual.append(bytes(out[:count]) if count>=0 else b'\xff')
# Chunk input to keep independent oracle transient JSON bounded.
for start in range(0,len(inputs),4096):compare('names',inputs[start:start+4096],actual[start:start+4096])
name_count=len(inputs)
inputs=[item(op=0),item(op=5,value=1,kind=1,data=b'hello'),item(kind=6,data=u32(1,1<<5)),item(op=3,kind=6),item(kind=8,data=u32(1)),item(kind=7,data=u32(1)),item(kind=4,data=u32(1)+b'guest'),item(op=6,value=2),item(op=5,value=2,kind=1,data=b'guest')]
inputs += [item(kind=7,data=u32(1)),item(kind=4,data=u32(1)+b'\xef\xbb\xbfguest'),item(kind=7,data=u32(1)),item(kind=4,data=u32(1)+b'\xef\xbb\xbf\xef\xbb\xbf')]
# Snapshot metadata path must match the existing full-text Swift state machine:
# boundary sizes, repeated change counts, old ownership/request, disable/re-enable.
inputs += [item(op=0),item(kind=6,data=u32(0,1<<5))]
for change,size in [(101,31),(102,32),(103,33),(103,33),(104,65)]:
 inputs += [item(op=8 if size>32 else 5,value=change,kind=1,data=b'x'*size),item(kind=8,data=u32(1))]
inputs += [item(kind=7,data=u32(1)),item(op=8,value=105,kind=1,data=b'x'*33),item(kind=4,data=u32(1)+b'stale'),item(op=2,value=0),item(op=8,value=106,kind=1,data=b'x'*33),item(op=2,value=1),item(op=8,value=106,kind=1,data=b'x'*33),item(op=8,value=106,kind=1,data=b'x'*33),item(kind=8,data=u32(1))]
# Stateful randomized event histories; all text inputs are valid Swift Strings.
for _ in range(10000):
 op=rng.choices(range(8),[2,2,3,2,60,25,3,3])[0]
 if op==4:
  kind,data=rng.choice(seeds[:8]);data=bytearray(data)
  if rng.randrange(3)==0 and data:data[rng.randrange(len(data))]=rng.randrange(256)
  if kind==6:data=u32(rng.randrange(2),rng.randrange(1<<15))
  inputs.append(item(kind=kind,data=data))
 elif op==5:inputs.append(item(op=op,value=rng.randrange(32),kind=rng.randrange(2),data=rng.choice([b'',b'hello',b'a'*32,b'a'*33,'你好'.encode()])))
 else:inputs.append(item(op=op,value=rng.randrange(2) if op==2 else rng.randrange(32),kind=6))
state=lib.clipboard_create();actual=[]
try:
 for value in inputs:
  data=base64.b64decode(value['data']);count=lib.clipboard_step(state,value['op'],value['value'],value['kind'],buf(data),len(data),out,len(out));assert count>=0;actual.append(bytes(out[:count]))
finally:lib.clipboard_destroy(state)
compare('state',inputs,actual)

lib.service_layout.argtypes=[c.c_uint8,c.c_uint32,B,Z,B,Z];lib.service_layout.restype=c.c_ssize_t
lib.monitor_create.restype=P;lib.monitor_destroy.argtypes=[P];lib.monitor_step.argtypes=[P,c.c_uint32,c.c_int64,c.POINTER(c.c_int64)]
layout_inputs=[];layout_actual=[]
for i in range(4000):
 entries=[]
 for _ in range(rng.randrange(6)):
  entries.append([rng.randrange(-1,6),rng.choice([0,-100,2**31,-2**31-1]),rng.choice([0,1]),rng.choice([0,640,-1,2**32]),rng.choice([0,480])])
 if i==0:entries=[[0,0,0,640,480]]
 data=u32(len(entries))+b''.join(struct.pack('<qqqqq',*m) for m in entries)
 explicit=rng.randrange(2);caps=rng.randrange(1<<15)
 layout_inputs.append(item(value=explicit,kind=caps,data=data));count=lib.service_layout(explicit,caps,buf(data),len(data),out,len(out));layout_actual.append(bytes(out[:count]) if count>=0 else b'\xff')
compare('layout',layout_inputs,layout_actual)
coordinator=lib.monitor_create();coordinate_inputs=[];coordinate_actual=[];values=(c.c_int64*3)()
try:
 for _ in range(5000):
  op=rng.choices(range(6),[40,25,10,15,5,5])[0];width=rng.choice([640,800,1920]);coordinate_inputs.append(item(op=op,value=width));lib.monitor_step(coordinator,op,width,values);coordinate_actual.append(bytes(values))
finally:lib.monitor_destroy(coordinator)
compare('coordinator',coordinate_inputs,coordinate_actual)
print(json.dumps(dict(result='passed',wire_cases=parse_count,unicode_basename_cases=name_count,clipboard_transitions=len(inputs),monitor_layouts=len(layout_inputs),monitor_transitions=len(coordinate_inputs),scope='unchanged Swift wire/state comparison; no host clipboard, filesystem or real guest access'),indent=2))
