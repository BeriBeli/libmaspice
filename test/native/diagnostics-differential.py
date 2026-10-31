"""Compare exact existing Swift histogram/record/ROI implementations to Zig."""
import base64,ctypes as c,json,random,subprocess,sys
from pathlib import Path
work=Path(sys.argv[1]).resolve();root=Path(__file__).resolve().parents[2]
presentation=(root/'test/oracle/swift/SwiftSpice/SpicePresentationDiagnostics.swift').read_text()
causal=(root/'test/oracle/swift/SwiftSpice/SpiceInteractionCausalTrace.swift').read_text()
selected=(root/'test/oracle/swift/SpiceChannels/SpiceTimingDiagnostics.swift').read_text()
selected+='\n'+presentation[presentation.index('package enum SpiceInteractionActionClass:'):]
selected+='\n'+causal[causal.index('package struct SpiceInteractionFrameIdentity:'):causal.index('package enum SpiceInteractionHostClock {')]
selected+='\n'+causal[causal.index('package final class SpiceInteractionTraceAssembler:'):causal.index('extension SpiceDesktopSnapshot {')]
collector=(root/'test/oracle/swift/SwiftSpice/SpiceInteractionTraceCollector.swift').read_text()
selected+='\nimport Synchronization\n'+collector[collector.index('package enum SpiceInteractionTraceCollectionError:'):collector.index('/// A cross-process serialized')]
(work/'swift-diagnostics-definitions.swift').write_text(selected)
subprocess.run(['swiftc','-parse-as-library','-warnings-as-errors','-package-name','SwiftSpice','-module-cache-path',str(work/'swift-cache'),str(work/'swift-diagnostics-definitions.swift'),str(root/'test/native/diagnostics-oracle.swift'),'-o',str(work/'diagnostics-oracle')],check=True)
lib=c.CDLL(str(work/'libdiagnostics-fixture.dylib'))
lib.histogram_create.restype=c.c_void_p;lib.histogram_destroy.argtypes=[c.c_void_p]
lib.histogram_step.argtypes=[c.c_void_p,c.c_uint32,c.c_uint32,c.c_uint32,c.c_int64,c.c_int64,c.POINTER(c.c_double)]
lib.record_fixture.argtypes=[c.c_void_p,c.c_size_t,c.c_uint32,c.c_void_p,c.c_size_t];lib.record_fixture.restype=c.c_ssize_t
lib.marker_fixture.argtypes=[c.c_void_p,c.c_size_t,c.c_size_t,c.c_size_t,c.c_size_t,c.c_void_p,c.c_size_t,c.c_uint32,c.POINTER(c.c_uint64)]
def oracle(cases):
 p=subprocess.run([str(work/'diagnostics-oracle')],input=''.join(json.dumps(v)+'\n' for v in cases),text=True,capture_output=True,check=True,timeout=90)
 return p.stdout.splitlines()
rng=random.Random(0xd1a690);hist=[];counts=[0,0,0]
bounds=[250_000_000_000_000,500_000_000_000_000,1_000_000_000_000_000,2_000_000_000_000_000,4_000_000_000_000_000,8_000_000_000_000_000,12_000_000_000_000_000,16_000_000_000_000_000,20_000_000_000_000_000,24_000_000_000_000_000,33_000_000_000_000_000,50_000_000_000_000_000,67_000_000_000_000_000,100_000_000_000_000_000,150_000_000_000_000_000,250_000_000_000_000_000,500_000_000_000_000_000]
for i in range(3000):
 op=rng.choices([0,1,2],[8,1,1])[0];slot=rng.randrange(3);other=rng.randrange(3)
 if counts[slot]+counts[other]>100000:op=2
 if op==0:counts[slot]+=1
 elif op==1:counts[slot]+=counts[other]
 else:counts[slot]=0
 seconds=rng.choice([0,0,0,1,2,5,10,-1,-10]);attoseconds=rng.choice(bounds)+rng.choice([-1,0,1])
 hist.append(dict(mode='histogram',op=op,slot=slot,other=other,seconds=seconds,attoseconds=attoseconds))
h=lib.histogram_create();assert h
try:
 for case,line in zip(hist,oracle(hist),strict=True):
  output=(c.c_double*3)();lib.histogram_step(h,case['op'],case['slot'],case['other'],case['seconds'],case['attoseconds'],output)
  assert list(output)==json.loads(line),(case,list(output),line)
finally:lib.histogram_destroy(h)
valid=dict(pair_id='pair',version='zig',run_id='run',order=1,action_class='click',token='0123456789abcdef',scheduled_ns=1,host_input_ns=2,send_started_ns=3,send_completed_ns=100,guest_received_ns=9000,guest_marker_drawn_ns=9010,marker_revision=9,marker_checksum='aabbccdd',display_receive_ns=4,surface_ready_ns=5,selected_revision_ready_ns=6,selection_ns=7,metal_commit_ns=8,presented_ns=9,display_channel_id=0,surface_id=1,surface_generation=2,desktop_generation=3,frame_revision=4,delivery_sequence=5)
records=[valid.copy()]
for name in valid:
 r=valid.copy()
 if isinstance(r[name],int) and name!='order':r.pop(name);records.append(r)
for name in ['pair_id','run_id','version','token','marker_checksum']:
 for value in ['', 'ABCDEF0123456789','g'*16,'0012','\u0001\n雪/😀\u2028']:
  r=valid.copy();r[name]=value;records.append(r)
for i in range(1500):
 r=valid.copy();r['action_class']=rng.choice(['click','key','motion']);r['order']=rng.randrange(2**64)
 for _ in range(rng.randrange(1,5)):
  name=rng.choice([k for k in valid if k.endswith('_ns') or k in ['marker_revision','delivery_sequence','frame_revision','surface_generation','desktop_generation']])
  if rng.random()<.1:r.pop(name,None)
  else:r[name]=rng.choice([0,1,2,3,4,5,7,9,100,9010,2**64-1])
 if rng.random()<.3:r['invalid_reason']=rng.choice(['cancelled','missing_scheduled','','帧/expired'])
 if rng.random()<.2:r['motion_ack_ns']=rng.choice([0,3,9,10])
 records.append(r)
def encoded(d):return json.dumps(d,separators=(',',':'),ensure_ascii=False).encode()
def case(mode,raw):return dict(mode=mode,record=base64.b64encode(raw).decode())
def zig(raw,mode):
 output=c.create_string_buffer(65536);n=lib.record_fixture(raw,len(raw),mode,output,len(output));return None if n<0 else output.raw[:n]
canonical=[]
for i,(record,line) in enumerate(zip(records,oracle([case('construct',encoded(r)) for r in records]),strict=True)):
 assert line!='error';expected=base64.b64decode(line);actual=zig(encoded(record),0)
 assert expected==actual,(i,record,expected,actual)
 canonical.append(expected)
decode=canonical[:]
for name in ['schema_version','valid','pair_id','order','action_class','token','version','run_id']:
 d=json.loads(canonical[0]);d.pop(name);decode.append(encoded(d))
for name,value in [('valid',False),('schema_version',1),('schema_version',3),('invalid_reason','missing_scheduled'),('invalid_reason','non_monotonic_timestamps'),('invalid_reason',''),('display_channel_id',256),('surface_id',2**32),('scheduled_ns',-1),('order',2**64),('action_class','wrong')]:
 d=json.loads(canonical[0]);d[name]=value;decode.append(encoded(d))
for raw in canonical[:100]:
 d=json.loads(raw);d['valid']=not d['valid'];decode.append(encoded(d))
for i,(raw,line) in enumerate(zip(decode,oracle([case('decode',raw) for raw in decode]),strict=True)):
 expected=None if line=='error' else base64.b64decode(line);actual=zig(raw,1)
 assert expected==actual,(i,raw,expected,actual)
# Independent fixture painter: whole cells, channels at inclusive detector thresholds.
markers=[]
for i in range(240):
 width=rng.choice([360,384,400]);height=rng.choice([16,24,48]);stride=width*4+rng.choice([0,16,64]);pixels=bytearray([127])*(stride*height)
 token=rng.randrange(2**64);revision=rng.randrange(2**64);checksum=rng.randrange(2**32)
 origins=[(rng.randrange(8,min(32,width-352)+1,4),rng.randrange(8,min(32,height-8)+1,4))]
 if i%5==0 and height==48:origins=[(8,8),(8,24)]
 bits=f'{0xa5c3:016b}{token:064b}{revision:064b}{checksum:032b}'
 for ox,oy in origins:
  for index,bit in enumerate(bits):
   value=rng.choice([0,8]) if bit=='1' else rng.choice([247,255])
   for y in range(oy+(index//88)*4,oy+(index//88)*4+4):
    for x in range(ox+(index%88)*4,ox+(index%88)*4+4):
     offset=y*stride+x*4;pixels[offset:offset+4]=bytes([value,value,value,rng.randrange(256)])
 if i%7==0:pixels=pixels[:rng.randrange(1,len(pixels))]
 if i%11==0:checksum^=1
 token_string=f'{token:016x}'
 if i%17==0:token_string=token_string.upper()
 if i%13==0:
  ox,oy=origins[0];offset=(oy+2)*stride+(ox+2)*4
  if offset<len(pixels):pixels[offset]=9
 markers.append(dict(mode='marker',width=width,height=height,stride=stride,token=token_string,checksum=checksum,pixels=base64.b64encode(pixels).decode()))
for i,(m,line) in enumerate(zip(markers,oracle(markers),strict=True)):
 pixels=base64.b64decode(m['pixels']);token=m['token'].encode();out=(c.c_uint64*4)();lib.marker_fixture(pixels,len(pixels),m['width'],m['height'],m['stride'],token,len(token),m['checksum'],out)
 assert list(out)==json.loads(line),(i,list(out),line)
lib.trace_create.restype=c.c_void_p;lib.trace_destroy.argtypes=[c.c_void_p];lib.trace_step.argtypes=[c.c_void_p,c.c_uint32]+[c.c_uint64]*5;lib.trace_finish.argtypes=[c.c_void_p,c.c_void_p,c.c_size_t];lib.trace_finish.restype=c.c_ssize_t
none=2**64-1
prefix=[[0,0,1,2,3,0],[1,0,100,none,0,0],[3,0,9000,9010,9,0]]
base=prefix+[[4,1,1,9,4,5],[5,1,6,7,0,0],[6,1,8,0,0,0],[7,1,9,0,0,0]]
traces=[base,base[:-1]+[[8,1,0,0,0,0],[5,1,6,7,0,0],[6,1,8,0,0,0],base[-1]]]
for i in range(800):
 commands=prefix.copy() if i%3 else []
 for step in range(rng.randrange(1,35)):
  op=rng.choices(list(range(11)),[1,1,1,1,10,5,4,4,3,1,1])[0];n=rng.choice([1,1,1,2,3,11,101,201]);x=y=z=w=0
  if op==0:x,y,z=1,2,3
  elif op==1:x,y=100,rng.choice([none,5])
  elif op==2:x=rng.choice([3,5,10])
  elif op==3:x,y,z=9000,9010,rng.choice([9,10])
  elif op==4:x=rng.choice([0,1,1,1,2]);y=rng.choice([9,9,10]);z,w=rng.choice([(4,5),(none,none),(1,2)])
  elif op==5:x,y=6,7
  elif op==6:x=8
  elif op==7:x=9
  elif op in [9,10]:x=rng.choice([0,1,2,3])
  commands.append([op,n,x,y,z,w])
 traces.append(commands)
for i,(commands,line) in enumerate(zip(traces,oracle([dict(mode='trace',commands=v) for v in traces]),strict=True)):
 value=lib.trace_create();assert value
 try:
  for command in commands:assert lib.trace_step(value,*command)==0
  output=c.create_string_buffer(65536);n=lib.trace_finish(value,output,len(output));assert n>=0
  actual=output.raw[:n];expected=base64.b64decode(line)
  assert actual==expected,(i,commands,actual,expected)
 finally:lib.trace_destroy(value)
print(json.dumps(dict(result='passed',histogram_steps=len(hist),constructed_records=len(records),decoded_records=len(decode),marker_frames=len(markers),trace_sequences=len(traces),trace_operations=sum(map(len,traces)),oracle='unchanged existing Swift histogram, trace record, ROI decoder and trace assembler; fixture supplies host nanoseconds',seed='0xd1a690'),indent=2))
