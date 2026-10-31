"""Actual malformed H264/H265 format errors through the public session ABI."""
import json,queue,struct,subprocess,sys,tempfile,threading
from pathlib import Path
from supervisor_integration import fixtures
work=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='zig-video-errors-',dir=work) as folder:
    def openssl(*args,input=None):
        return subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
    openssl('genrsa','-out','ticket.key','1024')
    public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER')
    decrypt=lambda data:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=data)
    Peer,*_=fixtures(work,public,decrypt)
    for hevc in (0,1):
        with Peer([(2,0)]) as peer:
            process=subprocess.Popen([str(work/'video-error-consumer'),str(peer.port),str(hevc)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            lines=queue.Queue()
            def read():
                for line in process.stdout:lines.put(line.strip())
            reader=threading.Thread(target=read);reader.start()
            try:
                assert lines.get(timeout=15)=='ready'
                peer.message((2,0),101)
                peer.send((2,0),314,struct.pack('<5I',1,8,8,32,0))
                peer.send((2,0),122,struct.pack('<IIBBQ4I4iB',1,0,1,5 if hevc else 3,0,8,8,8,8,0,0,8,8,0))
                nals=(b'\x40\x01\x01',b'\x42\x01\x01',b'\x44\x01\x01') if hevc else (b'\x67\x01',b'\x68\x01')
                encoded=b''.join(b'\0\0\1'+nal for nal in nals)
                peer.send((2,0),123,struct.pack('<III',0,100000,len(encoded))+encoded)
                assert process.wait(timeout=15)==0,process.stderr.read()
                reader.join(2)
                assert lines.get(timeout=1)=='typed video error preserves codec and native status after teardown; reset clears context'
            except BaseException:
                if process.poll() is None:process.kill();process.wait()
                print(process.stderr.read(),file=sys.stderr)
                raise
            finally:
                if process.poll() is None:process.kill();process.wait()
                reader.join(2)
print(json.dumps({'result':'passed','cases':2,'checks':['H264 and H265 unsupported format from real CoreMedia calls through stream scheduler and supervised terminal event','codec, channel and exact native status match independent CoreMedia reference','retained failure event after Desktop destruction','reset clears typed context before a generic failed connect'],'not_claimed':['successful video decode','hardware decoding availability'],'instrumentation':'public C consumer/native bridges ASan/UBSan; Zig ReleaseSafe'},indent=2))
