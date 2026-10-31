"""Native Swift public frame and typed-error conversion over independent peers."""
import base64,json,queue,struct,subprocess,sys,tempfile,threading
from pathlib import Path
from supervisor_integration import fixtures
from integration_metadata import instrumentation
work=Path(sys.argv[1]).resolve();root=Path(__file__).resolve().parents[2]
fixture=json.loads((root/'test/fixtures/SpiceCodecsTests/jpeg-8x8.json').read_text())
jpeg=base64.b64decode(fixture['jpegBase64']);rgb=base64.b64decode(fixture['expectedRGBBase64'])
expected=b''.join(bytes([rgb[i+2],rgb[i+1],rgb[i],255]) for i in range(0,len(rgb),3))
with tempfile.TemporaryDirectory(prefix='zig-swift-native-',dir=work) as folder:
    folder=Path(folder)
    def openssl(*args,input=None):return subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
    openssl('genrsa','-out','ticket.key','1024');public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER')
    decrypt=lambda data:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=data)
    Peer,*_=fixtures(work,public,decrypt,library=None)
    (folder/'pixels').write_bytes(expected)
    with Peer([(2,0)]) as peer,Peer([(2,0)]) as h264,Peer([(2,0)]) as h265:
        process=subprocess.Popen([str(work/'swift-boundary/native-consumer'),str(peer.port),str(folder/'pixels'),str(h264.port),str(h265.port)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        lines=queue.Queue()
        def read():
            for line in process.stdout:lines.put(line.strip())
        reader=threading.Thread(target=read);reader.start()
        try:
            assert lines.get(timeout=15)=='ready'
            peer.message((2,0),101)
            peer.send((2,0),314,struct.pack('<5I',7,8,8,32,0))
            peer.send((2,0),122,struct.pack('<IIBBQ4I4iB',7,0,1,1,0,8,8,8,8,0,0,8,8,0))
            peer.send((1,0),106,struct.pack('<I',0))
            peer.send((2,0),123,struct.pack('<III',0,500,len(jpeg))+jpeg)
            for index,target in enumerate((h264,h265)):
                assert lines.get(timeout=15)==f'video {index}'
                target.message((2,0),101)
                target.send((2,0),314,struct.pack('<5I',1,8,8,32,0))
                target.send((2,0),122,struct.pack('<IIBBQ4I4iB',1,0,1,3 if index==0 else 5,0,8,8,8,8,0,0,8,8,0))
                nals=(b'\x67\x01',b'\x68\x01') if index==0 else (b'\x40\x01\x01',b'\x42\x01\x01',b'\x44\x01\x01')
                encoded=b''.join(b'\0\0\1'+nal for nal in nals)
                target.send((2,0),123,struct.pack('<III',0,100000,len(encoded))+encoded)
            assert process.wait(timeout=15)==0,process.stderr.read()
            reader.join(2)
            assert lines.get(timeout=1)=='Swift native pixels, mutation isolation, diagnostics and typed video errors passed'
        except BaseException:
            if process.poll() is None:process.kill();process.wait()
            print(process.stderr.read(),file=sys.stderr)
            raise
        finally:
            if process.poll() is None:process.kill();process.wait()
            reader.join(2)
print(json.dumps({'instrumentation':instrumentation(),'result':'passed','checks':['bundled compositor discovered by public default initializer','actual MJPEG IOSurface and exact independent decoded pixels','equality does not read back; concurrent Swift pixels materialize once','mutable Data cannot alter native frame','pipeline and Source metric conversion and reconnect reset','H264/H265 failure preserves codec and signed native status'],'not_claimed':['successful H264/H265 hardware decoding','onscreen presentation']},indent=2))
