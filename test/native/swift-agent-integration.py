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
    class Agent:
     def __init__(self,peer):self.peer=peer;self.buffer=bytearray();self.pending=[]
     def send(self,kind,data=b''):
      body=struct.pack('<IIQI',1,kind,0,len(data))+data
      for start in range(0,len(body),2048):self.peer.send((1,0),109,body[start:start+2048])
     def next(self):
      while len(self.buffer)<20 or len(self.buffer)<20+struct.unpack_from('<I',self.buffer,16)[0]:self.buffer.extend(self.peer.message((1,0),107))
      protocol,kind,opaque,size=struct.unpack_from('<IIQI',self.buffer);assert protocol==1 and opaque==0;data=bytes(self.buffer[20:20+size]);del self.buffer[:20+size];return kind,data
     def expect(self,kind):
      for i,(k,data) in enumerate(self.pending):
       if k==kind:self.pending.pop(i);return data
      for _ in range(32):
       k,data=self.next()
       if k==kind:return data
       self.pending.append((k,data))
      raise AssertionError('missing Agent message')
    small=Path(folder)/'small';small.write_bytes(bytes(range(64)))
    large=Path(folder)/'large';large.write_bytes(bytes(range(256)))
    with Peer([],agent=True) as first,Peer([],agent=True) as second:
        process=subprocess.Popen([str(work/'swift-boundary/agent-consumer'),str(first.port),str(second.port),str(small),str(large)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        lines=queue.Queue()
        def read():
            for line in process.stdout:lines.put(line.strip())
        reader=threading.Thread(target=read);reader.start()
        try:
            for run,peer in enumerate((first,second)):
                assert lines.get(timeout=15)==f'ready {run}'
                agent=Agent(peer)
                agent.send(6,struct.pack('<II',0,0x50ae))
                assert agent.expect(6)==struct.pack('<II',1,0x5086)
                assert agent.expect(2)==struct.pack('<IIIIIii',1,0,480,640,32,0,0)
                agent.send(3,struct.pack('<II',2,1))
                start=agent.expect(10);identifier=struct.unpack_from('<I',start)[0]
                assert identifier==run+1 and start[4:]==b'[vdagent-file-xfer]\nname=fixture.bin\nsize=64\n\0'
                agent.send(11,struct.pack('<II',identifier,0))
                packet=agent.expect(12)
                assert packet==struct.pack('<IQ',identifier,64)+bytes(range(64))
                agent.send(11,struct.pack('<II',identifier,3))
                assert lines.get(timeout=10)==f'stopped {run}'
            assert lines.get(timeout=10)=='Swift Agent late start, policy, layout, file limits, reconnect boundary and metrics passed'
            assert process.wait(timeout=10)==0,process.stderr.read()
        except BaseException:
            if process.poll() is None:process.kill();process.wait()
            print(process.stderr.read(),file=sys.stderr)
            raise
        finally:
            if process.poll() is None:process.kill();process.wait()
            reader.join(2)
print(json.dumps({'instrumentation':instrumentation(),'result':'passed','checks':['Agent starts after buffered peer capabilities','disabled clipboard never advertised; explicit publish and sync remain disabled','exact monitor layout and acknowledgement','regular file exact bytes, native size errors, identity across stop/start','cancelled and completed reconnect boundary waits; cumulative native diagnostics'],'host_effects':'owned temporary files read only; general pasteboard synchronization disabled'},indent=2))
