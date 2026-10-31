"""Public Swift compatibility consumer with independent TCP peers."""
import json,queue,struct,subprocess,sys,tempfile,threading
from pathlib import Path
from supervisor_integration import fixtures
from integration_metadata import instrumentation
work=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='zig-reconnect-api-',dir=work) as folder:
    def openssl(*args,input=None):
        return subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
    openssl('genrsa','-out','ticket.key','1024')
    public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER')
    decrypt=lambda data:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=data)
    Peer,*_=fixtures(work,public,decrypt,library=None)
    with Peer([(5,0),(6,0)]) as first,Peer([(5,0),(6,0)]) as second:
        process=subprocess.Popen([str(work/'swift-boundary/audio-consumer'),str(first.port),str(second.port)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        lines=queue.Queue()
        def read():
            for line in process.stdout:lines.put(line.strip())
        reader=threading.Thread(target=read);reader.start()
        try:
            for run,peer in enumerate((first,second)):
                assert lines.get(timeout=15)==f'ready {run}'
                for index in range(40):
                    value=bytes([int(index%2==0)])
                    peer.send((5,0),106,value)
                    peer.send((6,0),104,value)
                    assert lines.get(timeout=10)==f'received {run} {index}'
            assert lines.get(timeout=10)=='Swift audio late attachment, stream draining, reconnect and joined stop passed'
            assert process.wait(timeout=10)==0,process.stderr.read()
        except BaseException:
            if process.poll() is None:process.kill();process.wait()
            print(process.stderr.read(),file=sys.stderr)
            raise
        finally:
            if process.poll() is None:process.kill();process.wait()
            reader.join(2)
print(json.dumps({'result':'passed','checks':['late native audio attachment with public event synchronization','40 ordered controls per reconnect without unused Swift stream overflow','duplicate start, detach and reacquire','no START sent; no speaker or microphone opened'],'instrumentation':instrumentation()},indent=2))
