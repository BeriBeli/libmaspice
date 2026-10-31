"""Independent C consumer against authenticated socket peers and real GPU/CPU."""
import base64,json,os,queue,struct,subprocess,sys,tempfile,threading
from pathlib import Path
from supervisor_integration import fixtures
work=Path(sys.argv[1]).resolve();root=Path(__file__).resolve().parents[2]
fixture=json.loads((root/'test/fixtures/SpiceCodecsTests/jpeg-8x8.json').read_text());jpeg=base64.b64decode(fixture['jpegBase64']);rgb=base64.b64decode(fixture['expectedRGBBase64']);expected=b''.join(bytes([rgb[i+2],rgb[i+1],rgb[i],255]) for i in range(0,len(rgb),3))
with tempfile.TemporaryDirectory(prefix='zig-desktop-api-',dir=work) as folder:
 folder=Path(folder)
 def openssl(*args,input=None):return subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
 openssl('genrsa','-out','ticket.key','1024');public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER')
 decrypt=lambda encrypted:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=encrypted)
 Peer,_,_,_,_=fixtures(work,public,decrypt)
 (folder/'pixels').write_bytes(expected)
 for native in (False,True):
  keys=[(k,0) for k in (2,3,4,5,6,8,9,11)]
  with Peer(keys,agent=True) as peer:
   process=subprocess.Popen([str(work/'desktop-consumer'),str(peer.port),str(int(native)),str(work/'compositor.metallib'),str(folder/'pixels'),str(work/'presentation.metallib')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
   lines=queue.Queue()
   def read():
    for line in process.stdout:lines.put(line.strip())
   reader=threading.Thread(target=read);reader.start()
   try:
    assert lines.get(timeout=8)=='ready'
    assert peer.message((3,0),111)==struct.pack('<iiH',-2,4,0)
    peer.message((2,0),101)
    peer.send((2,0),314,struct.pack('<5I',7,8,8,32,0))
    peer.send((2,0),122,struct.pack('<IIBBQ4I4iB',7,0,1,1,0,8,8,8,8,0,0,8,8,0))
    peer.send((1,0),106,struct.pack('<I',0))
    peer.send((2,0),123,struct.pack('<III',0,500,len(jpeg))+jpeg)
    peer.send((2,0),317,struct.pack('<HH7I',1,1,0,7,8,8,0,0,0))
    cursor=struct.pack('<hhHHBH',10,20,2,3,1,2)+struct.pack('<QB4H',77,0,2,1,0,0)+bytes(range(1,9));peer.send((4,0),101,cursor)
    peer.send((5,0),102,struct.pack('<IH',100,1));peer.send((5,0),103,struct.pack('<IHII',2,1,48000,100));peer.send((5,0),105,bytes([32])+struct.pack('<32H',*range(100,132)));peer.send((5,0),101,struct.pack('<I',120)+b'\1\2\3\4')
    peer.send((6,0),101,struct.pack('<IHI',2,1,48000))
    peer.send((8,0),101,struct.pack('<III',7,3,3)+b'APD')
    peer.send((9,0),101,b'USB')
    name=b'org.spice-space.webdav.0\0';peer.send((11,0),201,struct.pack('<IIB',len(name),9,1)+name);peer.send((11,0),101,struct.pack('<qH',-7,3)+b'DAV')
    assert peer.message((6,0),102)==struct.pack('<IH',11,1);assert peer.message((6,0),103)==struct.pack('<I',11);assert peer.message((6,0),101)==struct.pack('<I',12)+b'\1\2\3\4'
    assert peer.message((8,0),101)==struct.pack('<III',7,3,3)+b'APD';assert peer.message((9,0),101)==b'USB';assert peer.message((11,0),101)==struct.pack('<qH',-7,3)+b'DAV'
    assert process.wait(timeout=10)==0,process.stderr.read();reader.join(2);assert lines.get(timeout=1)=='public desktop C ABI lifetime and exact pixels passed'
   except BaseException:
    if process.poll() is None:process.kill();process.wait()
    print(process.stderr.read(),file=sys.stderr)
    raise
   finally:
    if process.poll() is None:process.kill();process.wait()
    reader.join(2)
print(json.dumps({'result':'passed','consumer':'public C header only; ASan/UBSan native adapters and C consumer, Zig ReleaseSafe','cases':['CPU and native authenticated desktop','typed Input/Record/Smartcard/USB/WebDAV sends','monitor metadata','frame/damage/Cursor/PCM lifetime after desktop destruction','concurrent lazy readback caches once and exact JPEG pixels','independent frame retains','pre-cancelled Agent token','public native presenter submits after Desktop destruction and matches exact pixels']},indent=2))
