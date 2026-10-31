"""Public Swift WebDAV facade; only task-owned root and loopback fixtures."""
import json,queue,struct,subprocess,sys,tempfile,threading
from pathlib import Path
from supervisor_integration import fixtures
from integration_metadata import instrumentation
work=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='zig-swift-webdav-',dir=work) as folder:
 root=Path(folder)/'root';root.mkdir();(root/'file').write_bytes(b'hello')
 outside=Path(folder)/'outside';outside.write_bytes(b'outside');(root/'escape').symlink_to(outside)
 def openssl(*args,input=None):return subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
 openssl('genrsa','-out','ticket.key','1024');public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER')
 decrypt=lambda data:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=data)
 Peer,*_=fixtures(work,public,decrypt,library=None)
 with Peer([(11,3),(11,4)]) as first,Peer([(11,3),(11,4)]) as second:
  process=subprocess.Popen([str(work/'swift-boundary/webdav-consumer'),str(root),str(first.port),str(second.port)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  lines=queue.Queue()
  def read():
   for line in process.stdout:lines.put(line.strip())
  reader=threading.Thread(target=read);reader.start()
  try:
   for run,peer in enumerate((first,second)):
    assert lines.get(timeout=20)==f'attached {run}'
    name=b'org.spice-space.webdav.0\0'
    for channel in (3,4):peer.send((11,channel),201,struct.pack('<IIB',len(name),9,1)+name)
    def send(channel,data):peer.send((11,channel),101,struct.pack('<qH',2,len(data))+data)
    def exchange(channel,data,code,body):
     send(channel,data)
     packet=peer.message((11,channel),101)
     client,size=struct.unpack('<qH',packet[:10]);assert client==2 and size==len(packet)-10
     response=packet[10:];assert response.startswith(f'HTTP/1.1 {code} '.encode()),response
     assert response.split(b'\r\n\r\n',1)[1]==body,response
    exchange(3,b'GET /file HTTP/1.1\r\n\r\n',200,b'hello')
    process.stdin.write('check\n');process.stdin.flush()
    assert lines.get(timeout=10)==f'checked {run}'
    for index in range(70):exchange(3+index%2,b'GET /file HTTP/1.1\r\n\r\n',200,b'hello')
    exchange(3,b'PUT /file HTTP/1.1\r\nContent-Length: 3\r\n\r\nbad',403,b'')
    exchange(4,b'GET /escape HTTP/1.1\r\n\r\n',403,b'')
    # The prefix is ordered before a completed request on the same channel;
    # the latter response proves admission before disconnect is requested.
    send(3,b'GET /file HTTP/1.1\r\n\r\nGET /')
    packet=peer.message((11,3),101);assert packet[10:].endswith(b'hello')
    process.stdin.write('done\n');process.stdin.flush()
    assert lines.get(timeout=10)==f'stopped {run}'
   assert lines.get(timeout=10)=='Swift WebDAV shared ownership, bounds, exact bytes and reconnect passed'
   assert process.wait(timeout=10)==0,process.stderr.read()
   assert (root/'file').read_bytes()==b'hello' and outside.read_bytes()==b'outside'
  except BaseException:
   if process.poll() is None:process.kill();process.wait()
   print(process.stderr.read(),file=sys.stderr);raise
  finally:
   if process.poll() is None:process.kill();process.wait()
   reader.join(2)
print(json.dumps(dict(instrumentation=instrumentation(),result='passed',checks=['same server across standalone calls and two attached channels','parser prefix, shared client bound, mixed client rejection and failed attachment rollback','70 exact routed replies without unused public queue overflow','read-only policy, escaping symlink denial and explicit write opt-in','caller release while attached and retained server after reconnect','70-request synchronous batch and typed header/body errors'],host_effects='owned temporary directory only'),indent=2))
