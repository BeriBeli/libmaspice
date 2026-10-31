#!/usr/bin/env python3
import ctypes as C,json,random,subprocess,sys
from pathlib import Path
work=Path(sys.argv[1]).resolve();lib=C.CDLL(str(work/'libaudio-ring.dylib'));U8=C.c_uint8;U64=C.c_uint64
lib.audio_ring_create.argtypes=[C.c_size_t,C.c_size_t,C.c_bool];lib.audio_ring_create.restype=C.c_void_p
lib.audio_ring_destroy.argtypes=[C.c_void_p]
lib.audio_ring_step.argtypes=[C.c_void_p,C.c_uint32,C.c_uint32,C.POINTER(U8),C.c_size_t,C.POINTER(U8),C.POINTER(U64)];lib.audio_ring_step.restype=C.c_int
rng=random.Random(0xa0d10);cases=[]
for i in range(700):
 capacity=rng.randrange(1,129);slots=rng.randrange(1,17);staged=bool(i%2);ops=[]
 for j in range(150):
  kind=rng.choices([0,1,2,3,4],[47,24,22,6,1])[0]
  if kind==4 and j<140:kind=0
  if kind==0 and staged and rng.randrange(2):kind=5
  size=rng.randrange(0,capacity+17);data=[rng.randrange(256) for _ in range(size)] if kind in [0,5] else []
  ops.append(dict(op=kind,timestamp=rng.getrandbits(32),bytes=data,size=size))
 cases.append(dict(capacity=capacity,slots=slots,staged=staged,operations=ops))
proc=subprocess.run([str(work/'audio-ring-oracle')],input='\n'.join(json.dumps(c) for c in cases)+'\n',text=True,capture_output=True,check=True)
lines=proc.stdout.splitlines();assert len(lines)==len(cases)
count=0
for case,line in zip(cases,lines):
 handle=lib.audio_ring_create(case['capacity'],case['slots'],case['staged']);assert handle
 try:
  for op,expected in zip(case['operations'],json.loads(line),strict=True):
   data=(U8*max(1,len(op['bytes'])))(*op['bytes']);output=(U8*256)();meta=(U64*33)()
   assert lib.audio_ring_step(handle,op['op'],op['timestamp'],data,op['size'],output,meta)==0
   actual=dict(meta=list(meta),bytes=list(output[:meta[4]]));assert actual==expected,(count,case['capacity'],case['slots'],op,actual,expected)
   count+=1
 finally:lib.audio_ring_destroy(handle)
print(json.dumps(dict(seed='0xa0d10',sequences=len(cases),operations=count,oracle='unchanged PreallocatedAudioPacketRing.swift and RecordCaptureBuffer.swift',result='pass')))
