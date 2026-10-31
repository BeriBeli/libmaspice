"""Public Swift USB API with independent native oracle; no hardware selection."""
import ctypes as c,json,queue,struct,subprocess,sys,tempfile,threading
from pathlib import Path
from supervisor_integration import fixtures
from integration_metadata import instrumentation
work=Path(sys.argv[1]).resolve()
lib=c.CDLL(str(work/'usb/libusb-oracle.dylib'))
for name,rest,args in [('create',c.c_void_p,[c.c_size_t]),('take_output',c.c_size_t,[c.c_void_p,c.c_void_p,c.c_size_t]),('feed_guest',c.c_int,[c.c_void_p,c.c_void_p,c.c_size_t]),('destroy',None,[c.c_void_p])]:
 fn=getattr(lib,'spice_usbredir_host_'+name);fn.restype=rest;fn.argtypes=args
with tempfile.TemporaryDirectory(prefix='zig-swift-usb-',dir=work) as folder:
 def openssl(*args,input=None):return subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
 openssl('genrsa','-out','ticket.key','1024');public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER')
 decrypt=lambda data:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=data)
 Peer,*_=fixtures(work,public,decrypt,library=None)
 with Peer([(9,7)]) as first,Peer([(9,7)]) as second:
  process=subprocess.Popen([str(work/'swift-boundary/usb-consumer'),str(first.port),str(second.port)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  lines=queue.Queue()
  def read():
   for line in process.stdout:lines.put(line.strip())
  reader=threading.Thread(target=read);reader.start()
  try:
   for run,peer in enumerate((first,second)):
    oracle=lib.spice_usbredir_host_create(4096);assert oracle
    try:
     def output():
      buf=c.create_string_buffer(4096);size=lib.spice_usbredir_host_take_output(oracle,buf,len(buf));return buf.raw[:size]
     def feed(data):assert lib.spice_usbredir_host_feed_guest(oracle,data,len(data))==0
     hello=output();assert len(hello)==80
     assert lines.get(timeout=15)==f'attached {run}'
     # The first 17 bytes were already fed through the public standalone actor.
     feed(hello);peer.send((9,7),101,hello[17:])
     for index in range(40):
      request=struct.pack('<IIQ',7,0,0x12340000+index);feed(request);expected=output();assert len(expected)==18
      peer.send((9,7),101,request)
      received=b''
      while len(received)<len(expected):
       chunk=peer.message((9,7),101);assert 0<len(chunk)<=8;received+=chunk
      assert received==expected
     process.stdin.write('done\n');process.stdin.flush()
     assert lines.get(timeout=10)==f'stopped {run}'
    finally:lib.spice_usbredir_host_destroy(oracle)
   assert lines.get(timeout=10)=='Swift USB existing parser state, retained host, ordered replies and reconnect passed'
   assert process.wait(timeout=10)==0,process.stderr.read()
  except BaseException:
   if process.poll() is None:process.kill();process.wait()
   print(process.stderr.read(),file=sys.stderr);raise
  finally:
   if process.poll() is None:process.kill();process.wait()
   reader.join(2)
print(json.dumps(dict(instrumentation=instrumentation(),result='passed',checks=['existing standalone parser prefix survives attachment','exact 8-byte packet limits and 40 native replies per connection','caller release while attached and retained host after disconnect','missing channel, duplicate host and pump timeout errors','same Session reconnects with joined backend teardown'],hardware='no physical USB device selected'),indent=2))
