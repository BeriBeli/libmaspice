"""Public runtime reuse with independent authenticated TCP peers."""
import json,queue,struct,subprocess,sys,tempfile,threading
from pathlib import Path
from supervisor_integration import fixtures
work=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='zig-reconnect-api-',dir=work) as folder:
    def openssl(*args,input=None):
        return subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
    openssl('genrsa','-out','ticket.key','1024')
    public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER')
    decrypt=lambda data:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=data)
    Peer,*_=fixtures(work,public,decrypt)
    with Peer([(2,0)]) as first,Peer([(2,0)],fail_key=(1,0)) as rejected,Peer([(2,0)]) as second:
        process=subprocess.Popen([str(work/'reconnect-consumer'),str(first.port),str(rejected.port),str(second.port)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        lines=queue.Queue()
        def read():
            for line in process.stdout:lines.put(line.strip())
        reader=threading.Thread(target=read);reader.start()
        try:
            for index,peer in enumerate((first,second)):
                assert lines.get(timeout=15)==f'ready {index}'
                peer.message((2,0),101)
                peer.send((2,0),314,struct.pack('<5I',7,8,8,32,0))
                peer.send((2,0),302,struct.pack('<I4iBBIH',7,0,0,8,8,0,1,0x11 if index==0 else 0x22,8)+b'\0'*13)
                assert lines.get(timeout=15)==f'stopped {index}'
            assert process.wait(timeout=10)==0,process.stderr.read()
            reader.join(2)
            assert lines.get(timeout=1)=='reconnect, failed authentication recovery, stable Source and stale-event fencing passed'
        except BaseException:
            if process.poll() is None:process.kill();process.wait()
            print(process.stderr.read(),file=sys.stderr)
            raise
        finally:
            if process.poll() is None:process.kill();process.wait()
            reader.join(2)
print(json.dumps({'result':'passed','checks':['same Desktop/Source/subscription across two successful connections','rejected authentication between connections and reset recovery','live reset rejected without disturbing session','old event fenced and old exact pixels retained','terminal clearing and preserved visibility demand','fresh pipeline counters and retired final metrics'],'instrumentation':'public C consumer/native bridges ASan/UBSan; Zig ReleaseSafe'},indent=2))
