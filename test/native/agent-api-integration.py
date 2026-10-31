"""Independent peer + public C manager: clipboard, layouts, files, migration."""
import json,queue,struct,subprocess,sys,tempfile,threading
from pathlib import Path
from supervisor_integration import fixtures
work=Path(sys.argv[1]).resolve()
native=len(sys.argv)==3 and sys.argv[2]=="--native-runner"
assert len(sys.argv)==2 or native
consumer="agent-runner-consumer" if native else "agent-consumer"
with tempfile.TemporaryDirectory(prefix='zig-agent-api-',dir=work) as folder:
 folder=Path(folder)
 def openssl(*args,input=None):return subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
 openssl('genrsa','-out','ticket.key','1024');public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER');decrypt=lambda encrypted:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=encrypted)
 Peer,_,_,_,offer=fixtures(work,public,decrypt)
 content=bytes(range(256))*157;path=folder/'upload';path.write_bytes(content)
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
 for seamless,switch_host in ((False,False),(True,False),(False,True)):
  with Peer([],agent=True) as source,Peer([],target=not switch_host,seamless=seamless,agent=switch_host) as target:
   process=subprocess.Popen([str(work/consumer),str(source.port),str(path),str(int(switch_host))],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);lines=queue.Queue()
   def read():
    for line in process.stdout:lines.put(line.strip())
   reader=threading.Thread(target=read);reader.start()
   try:
    assert lines.get(timeout=10)=='ready';agent=Agent(source)
    caps=agent.expect(6);assert struct.unpack('<II',caps)==(1,0x50ae)
    config=agent.expect(2);assert config==struct.pack('<IIIIIii',1,0,480,640,32,0,0)
    agent.send(6,struct.pack('<II',1,0x50ae));agent.send(3,struct.pack('<II',2,1))
    assert agent.expect(7)==struct.pack('<I',1);agent.send(8,struct.pack('<I',1));assert agent.expect(4)==struct.pack('<I',1)+b'host'
    config=agent.expect(2);assert config==struct.pack('<II',3,1)+struct.pack('<IIIii',0,0,32,0,0)*2+struct.pack('<IIIii',600,800,32,-20,50);agent.send(3,struct.pack('<II',2,1))
    agent.send(7,struct.pack('<I',1));assert agent.expect(8)==struct.pack('<I',1);agent.send(4,struct.pack('<I',1)+b'\xef\xbb\xbfguest')
    start=agent.expect(10);identifier=struct.unpack_from('<I',start)[0];assert start[4:]==b'[vdagent-file-xfer]\nname=fixture.bin\nsize='+str(len(content)).encode()+b'\n\0'
    # Migration while upload waits for guest approval must retain file and caps.
    source.send((1,0),111 if switch_host else (116 if seamless else 101),offer(target.port,seamless))
    if not switch_host:source.message((1,0),111 if seamless else 102)
    if seamless:
     source.send((1,0),1,struct.pack('<I',3));source.send((1,0),2,b'agent-state');assert target.message((1,0),5)==b'agent-state'
    elif not switch_host:source.send((1,0),112)
    assert lines.get(timeout=10)=='migrated';target_agent=Agent(target)
    if switch_host:
     assert target_agent.expect(6)==struct.pack('<II',1,0x5086)
    else:
     target_agent.send(11,struct.pack('<II',identifier,0))
     received=bytearray()
     while len(received)<len(content):
      data=target_agent.expect(12);id_,size=struct.unpack_from('<IQ',data);assert id_==identifier and size<=16000 and len(data)==12+size;received.extend(data[12:])
     assert received==content;target_agent.send(11,struct.pack('<II',identifier,3))
     second=target_agent.expect(10);second_id=struct.unpack_from('<I',second)[0];assert second_id!=identifier;assert target_agent.expect(11)==struct.pack('<II',second_id,1);target_agent.send(11,struct.pack('<II',second_id,1))
    target.send((1,0),108,struct.pack('<I',0));target.send((1,0),115,struct.pack('<I',100));target.message((1,0),106)
    # Same-session Agent reconnect advertises clipboard-disabled capabilities.
    if native:target_agent.send(6,struct.pack('<II',0,0x50ae))
    assert target_agent.expect(6)==struct.pack('<II',1,0x5086)
    assert process.wait(timeout=10)==0,process.stderr.read();reader.join(2);assert lines.get(timeout=1)=='public Agent manager lifetime migration and file transfer passed'
   except BaseException:
    if process.poll() is None:process.kill();process.wait()
    print(process.stderr.read(),file=sys.stderr);raise
   finally:
    if process.poll() is None:process.kill();process.wait()
    reader.join(2)
print(json.dumps(dict(result='passed',cases=['native executor periodic AppKit access and owned events after destruction' if native else 'public C manager callbacks and owned events after destruction','UTF8 BOM guest text and local demand reply','legacy then sparse positioned monitor requests and ACKs','40192-byte regular-file upload preserves state across semi/seamless migration','remote cancellation and same-session Agent epoch rejection','switch-host retires old uploads and rejects old identity even with the same Agent epoch'],host_effects='private named AppKit pasteboard; owned temporary regular file read only' if native else 'synthetic host writer callback; owned temporary regular file read only'),indent=2))
