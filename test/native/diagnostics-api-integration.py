"""Actual network/CPU/IOSurface trace ROI; host/display stage times are fixtures,
not measurements of a physical guest or a CAMetalDrawable presentation."""
import json,queue,struct,subprocess,sys,tempfile,threading
from pathlib import Path
from supervisor_integration import fixtures
work=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='zig-diagnostics-api-',dir=work) as folder:
 folder=Path(folder)
 def openssl(*args,input=None):return subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
 openssl('genrsa','-out','ticket.key','1024');public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER')
 decrypt=lambda encrypted:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=encrypted)
 Peer,_,_,_,_=fixtures(work,public,decrypt)
 subprocess.run([str(work/'trace-marker-jpeg'),str(folder/'marker.jpg')],check=True)
 jpeg=(folder/'marker.jpg').read_bytes()
 width,height=400,48;pixels=bytearray([127,127,127,255])*(width*height)
 bits=f'{0xa5c3:016b}{0x0123456789abcdef:064b}{9:064b}{0xaabbccdd:032b}'
 for i,bit in enumerate(bits):
  component=0 if bit=='1' else 255
  for y in range(8+(i//88)*4,12+(i//88)*4):
   for x in range(8+(i%88)*4,12+(i%88)*4):
    offset=(y*width+x)*4;pixels[offset:offset+4]=bytes([component,component,component,255])
 rect=struct.pack('<4i',0,0,height,width)
 base=struct.pack('<I',7)+rect+b'\0'
 bitmap=struct.pack('<QBBII',123,0,0,width,height)+struct.pack('<BBIIII',8,4,width,height,width*4,0)+pixels
 draw=base+struct.pack('<I',57)+rect+struct.pack('<HB',8,0)+bytes(13)+bitmap
 for native in (False,True):
  with Peer([(2,0)]) as peer:
   output=folder/f'{native}.jsonl'
   process=subprocess.Popen([str(work/'diagnostics-consumer'),str(peer.port),str(int(native)),str(work/'compositor.metallib'),str(output)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
   lines=queue.Queue()
   def read():
    for line in process.stdout:lines.put(line.strip())
   reader=threading.Thread(target=read);reader.start()
   try:
    assert lines.get(timeout=10)=='ready';peer.message((2,0),101)
    process.stdin.write('arm\n');process.stdin.flush();assert lines.get(timeout=10)=='armed'
    peer.send((2,0),314,struct.pack('<5I',7,width,height,32,0))
    if native:
     peer.send((1,0),106,struct.pack('<I',0))
     peer.send((2,0),122,struct.pack('<IIBBQ4I4iB',7,0,1,1,0,width,height,width,height,0,0,height,width,0))
     peer.send((2,0),123,struct.pack('<III',0,100,len(jpeg))+jpeg)
    else:peer.send((2,0),304,draw)
    process.stdin.write('frame\n');process.stdin.flush();assert process.wait(timeout=15)==0,process.stderr.read();reader.join(2)
    raw=lines.get(timeout=2);value=json.loads(raw);assert value['valid'],value
    assert value['marker_revision']==9 and value['marker_checksum']=='aabbccdd' and value['surface_id']==7
    assert output.read_text()==raw+'\n';assert output.stat().st_mode&0o777==0o600
   except BaseException:
    if process.poll() is None:process.kill();process.wait()
    print(process.stderr.read(),file=sys.stderr);raise
   finally:
    if process.poll() is None:process.kill();process.wait()
    reader.join(2)
print(json.dumps(dict(result='passed',cases=2,modes=['CPU','native Metal/IOSurface'],checks=['actual TCP received/ready timing and marker ROI','public ABI sizes and cancellation','single active capture','original identity on authoritative redelivery','known dropped drawable retry','epoch fenced metrics','capture and canonical record survive Source/Desktop destruction','mode0600 canonical JSONL'],limitations='host input/guest timestamps and drawable presentation stages supplied by fixture; no physical guest/display latency claim',instrumentation='C consumer and native adapters ASan/UBSan; Zig ReleaseSafe'),indent=2))
