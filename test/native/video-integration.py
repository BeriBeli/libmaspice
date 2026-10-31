#!/usr/bin/env python3
import base64,ctypes as c,json,sys,random,subprocess,re,struct
from pathlib import Path
work=Path(sys.argv[1]).resolve();root=Path(__file__).resolve().parents[2]
lib=c.CDLL(str(work/'libvideo-fixture.dylib'));P=c.c_void_p;Z=c.c_size_t;U=c.POINTER(c.c_uint8)
def bind(name,args,result):
 f=getattr(lib,'video_fixture_'+name);f.argtypes=args;f.restype=result;return f
create=bind('create',[c.c_uint8,Z,Z],P);destroy=bind('destroy',[P],None)
decode=bind('decode',[P,U,Z,c.c_uint32,c.POINTER(P)],c.c_int)
synthetic=bind('synthetic',[c.c_uint32,c.c_uint32,c.c_int,c.c_int,U,U],P)
gpu=bind('gpu',[P,c.c_char_p,U,Z],c.c_int)
release=bind('frame_release',[P],None);pixels=bind('pixels',[P,U,Z],c.c_int);stats=bind('stats',[P,c.POINTER(Z)],None)
def frame(d,data):
 out=P();buf=(c.c_uint8*len(data)).from_buffer_copy(data)
 assert decode(d,buf,len(data),0,c.byref(out))==1 and out.value
 return out
def compare(f,expected):
 out=(c.c_uint8*len(expected))();assert pixels(f,out,len(out))==0
 delta=max(abs(x-y) for x,y in zip(out,expected));assert delta<=4,delta
 assert bytes(out)[3::4]==expected[3::4]
 result=gpu(f,str(work/'compositor.metallib').encode(),out,len(out))
 assert result in (0,1),result
 if result==0:
  gpu_delta=max(abs(x-y) for x,y in zip(out,expected));assert gpu_delta<=4,gpu_delta
 return delta
fixtures={p.stem:json.loads(p.read_text()) for p in (root/'test/fixtures/SpiceVideoToolboxTests').glob('*.json')}
for name,d in fixtures.items():
 raw=base64.b64decode(d['annexBBase64']);(work/(name+'.annexb')).write_bytes(raw)
 nals=[n.rstrip(b'\0') for n in re.split(b'\0\0(?:\0)?\1',raw)[1:]]
 kind=lambda n: ((n[0]>>1)&63) if d['codec']=='h265' else n[0]&31
 types=(32,33,34) if d['codec']=='h265' else (7,8,13)
 params=[n for k in types for n in nals if kind(n)==k]
 avcc=b''.join(struct.pack('>I',len(n))+n for n in nals if kind(n) not in types)
 container=struct.pack('<II',int(d['codec']=='h265'),len(params))+b''.join(struct.pack('<I',len(n))+n for n in params)+struct.pack('<I',len(avcc))+avcc
 (work/(name+'.native')).write_bytes(container)
(work/'video_data.zig').write_text('pub const baseline = @embedFile("h264-baseline-128x128.annexb");\n'+'pub const high = @embedFile("h264-high-128x128.annexb");\n')
jpeg=json.loads((root/'test/fixtures/SpiceCodecsTests/jpeg-8x8.json').read_text())
(work/'jpeg.encoded').write_bytes(base64.b64decode(jpeg['jpegBase64']))
with (work/'video_data.zig').open('a') as f:f.write('pub const jpeg = @embedFile("jpeg.encoded");\n')
results=[]
for name,data in sorted(fixtures.items()):
 payload=base64.b64decode(data['annexBBase64']);expected=base64.b64decode(data['expectedBGRABase64'])
 decoder=create(int(data['codec']=='h265'),data['width'],data['height']);assert decoder
 held=[]
 try:
  for repeat in range(3):held.append(frame(decoder,payload))
  record=(Z*6)();stats(decoder,record);assert list(record)==[1,1,0,0,3,0],list(record)
 finally:destroy(decoder)
 try:delta=max(compare(f,expected) for f in held)
 finally:
  for f in held:release(f)
 results.append({'fixture':name,'max_color_delta':delta,'hardware_sessions':1,'retained_after_decoder_destroy':3})
# Parameter changes rebuild only on change, retaining old decoded frames.
decoder=create(0,128,128);held=[]
try:
 for name in ['h264-baseline-128x128','h264-high-128x128','h264-baseline-128x128']:
  d=fixtures[name];held.append((frame(decoder,base64.b64decode(d['annexBBase64'])),base64.b64decode(d['expectedBGRABase64'])))
 record=(Z*6)();stats(decoder,record);assert list(record)==[3,3,0,0,3,0],list(record)
finally:destroy(decoder)
try:
 for f,expected in held:compare(f,expected)
finally:
 for f,_ in held:release(f)
# Exact comparison to unchanged Swift CPU conversion, including odd planes,
# full/video range, BT601/709 and unsupported/missing matrix fallback.
rng=random.Random(0x4356);inputs=[];owned=[]
for width,height in [(2,2),(3,3),(4,6),(7,5),(16,10)]:
 for full in [False,True]:
  for matrix in [0,601,709,2020]:
   y=bytes(rng.randrange(256) for _ in range(width*height));uv=bytes(rng.randrange(256) for _ in range(((width+1)//2)*((height+1)//2)*2))
   inputs.append(dict(width=width,height=height,full=full,matrix=matrix,y=base64.b64encode(y).decode(),uv=base64.b64encode(uv).decode()));owned.append((y,uv))
oracle=json.loads(subprocess.check_output([str(work/'video-oracle')],input=json.dumps(inputs).encode()))
for request,(y,uv),encoded in zip(inputs,owned,oracle):
 yb=(c.c_uint8*len(y)).from_buffer_copy(y);uvb=(c.c_uint8*len(uv)).from_buffer_copy(uv)
 f=synthetic(request['width'],request['height'],int(request['full']),request['matrix'],yb,uvb);assert f
 try:
  expected=base64.b64decode(encoded);out=(c.c_uint8*len(expected))();assert pixels(f,out,len(out))==0
  assert bytes(out)==expected,request
  code=gpu(f,str(work/'compositor.metallib').encode(),out,len(out))
  supported=request['matrix'] in (601,709) and request['width']%2==0 and request['height']%2==0
  assert code==(0 if supported else 1),code
  if supported:
   w=request['width'];h=request['height'];full=request['full'];bt709=request['matrix']==709
   for row in range(h):
    for col in range(w):
     yy=y[row*w+col]/255;ci=(row//2)*w+(col//2)*2;cb=uv[ci]/255-128/255;cr=uv[ci+1]/255-128/255
     if not full:yy=(yy-16/255)*255/219;cb*=255/224;cr*=255/224
     rgb=[yy+(1.5748 if bt709 else 1.402)*cr,yy-(.187324 if bt709 else .344136)*cb-(.468124 if bt709 else .714136)*cr,yy+(1.8556 if bt709 else 1.772)*cb]
     expected_gpu=[round(max(0,min(1,v))*255) for v in reversed(rgb)]+[255]
     actual=out[(row*w+col)*4:(row*w+col+1)*4];assert max(abs(x-y) for x,y in zip(actual,expected_gpu))<=1
 finally:release(f)
print(json.dumps({'synthetic_swift_exact':len(inputs),'result':'passed' ,'fixtures':results,'parameter_rebuilds':3,'scope':'real hardware property, fixture pixels tolerance <=4 (existing Swift contract), frame retention across decoder replacement and destruction'},indent=2))
