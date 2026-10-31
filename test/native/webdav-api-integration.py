"""Public native WebDAV executor against independently encoded authenticated peers."""
import json,queue,struct,subprocess,sys,tempfile,threading
from pathlib import Path
from supervisor_integration import fixtures
work=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='zig-webdav-api-',dir=work) as folder:
 folder=Path(folder)
 def openssl(*args,input=None):return subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
 openssl('genrsa','-out','ticket.key','1024');public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER')
 decrypt=lambda encrypted:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=encrypted)
 Peer,_,_,_,offer=fixtures(work,public,decrypt)
 payload=bytes(range(256))*274
 for writable,seamless,switch_host in ((False,False,False),(True,True,False),(True,False,True)):
  root=folder/('root-'+str(writable)+str(seamless));root.mkdir();(root/'file').write_bytes(payload)
  keys=[(11,0)]
  with Peer(keys) as source,Peer(keys,target=not switch_host,seamless=seamless) as target:
   process=subprocess.Popen([str(work/'webdav-consumer'),str(source.port),str(root),str(int(writable))],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
   lines=queue.Queue()
   def read():
    for line in process.stdout:lines.put(line.strip())
   reader=threading.Thread(target=read);reader.start()
   try:
    assert lines.get(timeout=10)=='ready'
    name=b'org.spice-space.webdav.0\0'
    source.send((11,0),201,struct.pack('<IIB',len(name),9,1)+name)
    def request(peer,client,data):
     # Deliberately split inside the mux header and HTTP parser boundaries.
     packet=struct.pack('<qH',client,len(data))+data
     for part in (packet[:3],packet[3:12],packet[12:]):peer.send((11,0),101,part)
    buffers={}
    def response(peer,client,head=False):
     key=(peer.port,client);buffer=buffers.setdefault(key,bytearray())
     while True:
      header_end=buffer.find(b'\r\n\r\n')
      if header_end>=0:
       header=bytes(buffer[:header_end]);length=int(next(line.split(b':',1)[1] for line in header.split(b'\r\n')[1:] if line.lower().startswith(b'content-length:')))
       consumed=header_end+4+(0 if head else length)
       if len(buffer)>=consumed:
        data=bytes(buffer[header_end+4:consumed]);del buffer[:consumed];return int(header.split(b' ')[1]),data,header
      frame=peer.message((11,0),101);id_,size=struct.unpack_from('<qH',frame);assert len(frame)==10+size and size
      buffers.setdefault((peer.port,id_),bytearray()).extend(frame[10:])
    def completed(count):
     process.stdin.write(f'completed {count}\n');process.stdin.flush();assert lines.get(timeout=10)=='completed'
    request(source,-7,b'GET /file HTTP/1.1\r\n\r\nHEAD /file HTTP/1.1\r\n\r\n')
    assert response(source,-7)[:2]==(200,payload)
    status,data,header=response(source,-7,True);assert status==200 and not data and b'Content-Length: '+str(len(payload)).encode() in header
    request(source,2,b'PUT /new HTTP/1.1\r\nContent-Length: 3\r\n\r\nnew')
    assert response(source,2)[:2]==(201 if writable else 403,b'')
    assert (root/'new').exists()==writable
    request(source,3,b'GET /../ticket.key HTTP/1.1\r\n\r\n');assert response(source,3)[0]==403
    completed(4)
    # Same-guest handoff retains a partial HTTP request; switch-host retires it.
    request(source,4,b'GET /fi')
    process.stdin.write('buffered 7\n');process.stdin.flush();assert lines.get(timeout=10)=='buffered'
    source.send((1,0),111 if switch_host else (116 if seamless else 101),offer(target.port,seamless))
    if not switch_host:source.message((1,0),111 if seamless else 102)
    if seamless:
     for key in [(1,0),*keys]:source.send(key,1,struct.pack('<I',3));source.send(key,2,b'webdav-state')
     for key in [(1,0),*keys]:assert target.message(key,5)==b'webdav-state'
    elif not switch_host:source.send((1,0),112)
    assert lines.get(timeout=10)=='migrated'
    if switch_host:target.send((11,0),201,struct.pack('<IIB',len(name),9,1)+name)
    request(target,4,b'GET /file HTTP/1.1\r\n\r\n' if switch_host else b'le HTTP/1.1\r\n\r\n');assert response(target,4)[:2]==(200,payload)
    # Reuse after a remote client close, with a following independent request.
    target.send((11,0),101,struct.pack('<qH',4,0))
    request(target,4,b'GET /missing HTTP/1.1\r\n\r\n');assert response(target,4)[0]==404
    completed(6)
    process.stdin.write('stop\n');process.stdin.flush()
    assert process.wait(timeout=10)==0,process.stderr.read();reader.join(2)
    assert lines.get(timeout=1)=='public WebDAV executor lifecycle passed'
   except BaseException:
    if process.poll() is None:process.kill();process.wait()
    print(process.stderr.read(),file=sys.stderr);raise
   finally:
    if process.poll() is None:process.kill();process.wait()
    reader.join(2)
print(json.dumps(dict(result='passed',cases=['public C default read-only and explicit writable root','fragmented mux and HTTP pipeline','70144-byte exact GET with 65535-byte response chunking and HEAD declared size','PUT permissions and traversal rejection','semi/seamless partial HTTP continuity and switch-host reset','remote client-close reuse and joined destruction'],instrumentation='C consumer and native bridges ASan/UBSan; Zig ReleaseSafe',scope='owned temporary fixtures, loopback peers; no live guest mount'),indent=2))
