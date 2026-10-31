#!/usr/bin/env python3
"""Local TCP/TLS and actual Zig SPICE handshake. Temporary synthetic keys only."""
import contextlib, ctypes as c, json, os, socket, ssl, struct, subprocess, sys, tempfile, threading, time
from pathlib import Path
work=Path(sys.argv[1]).resolve()
lib=c.CDLL(str(work/'libspicezig.dylib'))
P=c.c_void_p; Z=c.c_size_t; U8=c.POINTER(c.c_uint8); U32=c.POINTER(c.c_uint32)
class DER(c.Structure): _fields_=[('data',U8),('size',Z)]
sigs={
 'transport_create':([c.c_char_p,c.c_uint16,c.c_uint8,c.c_char_p,c.c_char_p,c.POINTER(DER),Z,c.c_uint32,c.POINTER(P)],c.c_int),
 'transport_connect':([P],c.c_int), 'transport_cancel':([P],None),'transport_destroy':([P],None),
 'transport_read_exact':([P,U8,Z],c.c_int),'transport_read':([P,U8,Z,Z,c.POINTER(Z)],c.c_int),'transport_write':([P,U8,Z],c.c_int),
 'link_handshake':([P,c.c_uint32,c.c_uint8,c.c_uint8,U32,Z,U32,Z,U8,Z,c.POINTER(P)],c.c_int),
 'link_destroy':([P],None),'link_mode':([P],c.c_int),'link_capabilities':([P,c.c_uint8,c.POINTER(Z)],U32),
}
for name,(args,result) in sigs.items():
 fn=getattr(lib,'spice_zig_'+name);fn.argtypes=args;fn.restype=result;globals()[name]=fn

def storage(data): return (c.c_uint8*len(data)).from_buffer_copy(data)
def create(port,kind=0,anchors=(),name=None,subject=None,timeout=2000):
 owners=[storage(cert) for cert in anchors]
 ders=(DER*len(owners))(*(DER(owner,len(owner)) for owner in owners))
 handle=P()
 code=transport_create(b'127.0.0.1',port,kind,name,subject,ders,len(ders),timeout,c.byref(handle))
 assert code==0,(code,kind)
 return handle

def exact(sock,size):
 result=b''
 while len(result)<size:
  chunk=sock.recv(size-len(result))
  if not chunk: raise EOFError
  result+=chunk
 return result

@contextlib.contextmanager
def peer(handler, tls=None):
 listener=socket.socket();listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
 listener.bind(('127.0.0.1',0));listener.listen();listener.settimeout(5)
 port=listener.getsockname()[1];accepted=threading.Event();stop=threading.Event();errors=[];connections=[]
 def run():
  try:
   conn,_=listener.accept();connections.append(conn);conn.settimeout(5);accepted.set()
   if tls:
    conn=tls.wrap_socket(conn,server_side=True);connections.append(conn)
   handler(conn,stop)
  except (ssl.SSLError,ConnectionError,EOFError,OSError): pass # expected negative clients close
  except BaseException as error: errors.append(error)
  finally:
   for conn in connections:
    try: conn.close()
    except OSError: pass
 thread=threading.Thread(target=run);thread.start()
 try: yield port,accepted,stop
 finally:
  stop.set();listener.close()
  for conn in connections:
   try: conn.shutdown(socket.SHUT_RDWR)
   except OSError: pass
  thread.join(7)
  assert not thread.is_alive(),'peer failed to stop'
  if errors: raise errors[0]

def call_thread(fn):
 results=[]
 thread=threading.Thread(target=lambda:results.append(fn()));thread.start()
 return thread,results

def finish(thread,results,expected):
 thread.join(3);assert not thread.is_alive(),'cancellation did not unblock'
 assert results==[expected],results

checks=[]
def echo(conn,stop):
 data=exact(conn,8)
 for byte in data: conn.sendall(bytes([byte]))
with peer(echo) as (port,accepted,stop):
 handle=create(port)
 try:
  assert transport_connect(handle)==0
  data=storage(b'zig-wire');assert transport_write(handle,data,len(data))==0
  output=(c.c_uint8*8)();assert transport_read_exact(handle,output,8)==0;assert bytes(output)==b'zig-wire'
  one=(c.c_uint8*1)();assert transport_read_exact(handle,one,1)==-34
 finally: transport_destroy(handle)
checks.append('TCP fragmented exact read, write, EOF')

for _ in range(25):
 with peer(lambda conn,stop:stop.wait(5)) as (port,accepted,stop):
  handle=create(port,kind=1,timeout=5000)
  thread,result=call_thread(lambda:transport_connect(handle))
  assert accepted.wait(2)
  transport_cancel(handle);transport_cancel(handle)
  finish(thread,result,-31)
  transport_destroy(handle)
checks.append('25 stalled TLS connect cancellations and fresh handle reuse')
with peer(lambda conn,stop:stop.wait(5)) as (port,accepted,stop):
 handle=create(port,kind=1,timeout=80)
 try: assert transport_connect(handle)==-30
 finally: transport_destroy(handle)
checks.append('TLS establishment timeout')
for operation in ('read','write'):
 with peer(lambda conn,stop:stop.wait(5)) as (port,accepted,stop):
  handle=create(port)
  try:
   assert transport_connect(handle)==0
   data=(c.c_uint8*(1 if operation=='read' else 32*1024*1024))()
   fn=transport_read_exact if operation=='read' else transport_write
   thread,result=call_thread(lambda:fn(handle,data,len(data)))
   thread.join(.05);assert thread.is_alive(),'operation did not reach a blocked state'
   transport_cancel(handle);finish(thread,result,-31)
  finally: transport_destroy(handle)
checks.append('cancel blocked read and backpressured 32MiB write')

with tempfile.TemporaryDirectory(prefix='network-fixtures-',dir=work) as directory:
 folder=Path(directory)
 def openssl(*args,input=None):
  result=subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
  return result.stdout
 openssl('req','-x509','-newkey','rsa:2048','-nodes','-sha256','-days','2','-keyout','ca.key','-out','ca.pem','-subj','/C=SG/O=SwiftSpice/CN=Test CA')
 openssl('req','-new','-newkey','rsa:2048','-nodes','-keyout','leaf.key','-out','leaf.csr','-subj','/C=SG/L=Singapore/O=SwiftSpice/CN=remote.example.test')
 modern='basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:remote.example.test\n'
 legacy='basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n'
 for label,extensions,days in [('modern',modern,'2'),('legacy',legacy,'2')]:
  (folder/'extensions').write_text(extensions)
  openssl('x509','-req','-in','leaf.csr','-CA','ca.pem','-CAkey','ca.key','-CAcreateserial','-days',days,'-sha256','-extfile','extensions','-out',label+'.pem')
 (folder/'index.txt').write_text('')
 (folder/'serial').write_text('1000\n')
 (folder/'ca.cnf').write_text('[ca]\ndefault_ca=local\n[local]\ndatabase=index.txt\nserial=serial\nnew_certs_dir=.\nprivate_key=ca.key\ncertificate=ca.pem\ndefault_md=sha256\npolicy=policy\n[policy]\ncountryName=optional\nlocalityName=optional\norganizationName=optional\ncommonName=supplied\n[extensions]\n'+modern)
 openssl('ca','-batch','-config','ca.cnf','-extensions','extensions','-in','leaf.csr','-startdate','200101000000Z','-enddate','200102000000Z','-notext','-out','expired.pem')
 ca=(folder/'ca.pem').read_bytes()
 escaped=ca.replace(b'\n',b'\\n')
 ca_der=openssl('x509','-in','ca.pem','-outform','DER')
 def context(label):
  ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(str(folder/(label+'.pem')),str(folder/'leaf.key'));return ctx
 subject=b'C=SG,L=Singapore,O=SwiftSpice,CN=remote.example.test'
 cases=[('modern',2,[ca],b'remote.example.test',None,0),('modern',2,[escaped],b'remote.example.test',None,0),
        ('modern',2,[ca_der],b'remote.example.test',None,0),('modern',2,[ca],b'wrong.example.test',None,-32),
        ('modern',1,[],None,None,-32),('modern',4,[],None,None,0),
        ('legacy',3,[escaped],None,subject,0),('legacy',2,[ca],b'remote.example.test',None,-32),
        ('legacy',3,[ca],None,b'CN=remote.example.test',-32),('legacy',3,[ca],None,b'CN=remote.example.test,O=SwiftSpice,L=Singapore,C=SG',-32),
        ('legacy',3,[ca],None,b' c=sg, l=Singapore, o=SWIFTSPICE, cn=REMOTE.EXAMPLE.TEST',0),
        ('expired',2,[ca],b'remote.example.test',None,-32),('expired',3,[ca],None,subject,-32)]
 for label,kind,anchors,name,expected_subject,expected in cases:
  with peer(lambda conn,stop:stop.wait(3),context(label)) as (port,accepted,stop):
   handle=create(port,kind,anchors,name,expected_subject)
   try:
    code=transport_connect(handle)
    assert code==expected,(label,kind,expected_subject,code,expected)
    assert transport_connect(handle)==expected,'terminal connection must not restart or wait again'
   finally: transport_destroy(handle)
 checks.append('13 TLS policy cases: PEM/escaped/DER, hostname, EKU, complete subject/order, expiry, explicit insecure, system rejection')
 # Actual SPICE auth with independent OpenSSL decrypt and split server writes.
 openssl('genrsa','-out','ticket.key','1024')
 public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER')
 assert len(public)==162
 handshake_count=0
 def spice(conn,stop):
  global handshake_count
  magic,major,minor,size=struct.unpack('<4I',exact(conn,16));assert (magic,major,minor)==(0x51444552,2,2)
  request=exact(conn,size);assert request[4:6]==b'\x01\x00'
  body=struct.pack('<I',0)+public+struct.pack('<III',1,1,178)+struct.pack('<II',11,13)
  wire=struct.pack('<4I',magic,2,2,len(body))+body
  for offset in range(0,len(wire),7): conn.sendall(wire[offset:offset+7])
  assert exact(conn,4)==struct.pack('<I',1)
  encrypted=exact(conn,128)
  clear=openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=encrypted)
  assert clear==b'synthetic-test\0'
  conn.sendall(b'\0\0\0\0');handshake_count+=1
 for use_tls in (False,True):
  with peer(spice,context('modern') if use_tls else None) as (port,accepted,stop):
   handle=create(port,2 if use_tls else 0,[ca] if use_tls else [],b'remote.example.test' if use_tls else None)
   negotiated=P();common=(c.c_uint32*1)(11);channel=(c.c_uint32*1)(13);password=storage(b'synthetic-test')
   try:
    assert link_handshake(handle,0,1,0,common,1,channel,1,password,len(password),c.byref(negotiated))==0
    assert link_mode(negotiated)==1
    count=Z();words=link_capabilities(negotiated,0,c.byref(count));assert list(words[:count.value])==[11]
   finally: link_destroy(negotiated);transport_destroy(handle)
 assert handshake_count==2
 checks.append('real Zig Link handshake over TCP and trusted TLS, independent RSA ticket decrypt')
 from session_integration import run
 checks.extend(run(lib,peer,exact,public,lambda encrypted:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=encrypted),call_thread,finish))
 from supervisor_integration import run as run_supervisor
 checks.extend(run_supervisor(work,public,lambda encrypted:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=encrypted)))
 from display_integration import run as run_display
 checks.extend(run_display(work,public,lambda encrypted:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=encrypted)))
print(json.dumps({'checks':checks,'result':'passed'},indent=2))
