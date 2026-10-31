"""Exact native USB host over authenticated peers; no physical device selected."""
import ctypes as c,json,queue,struct,subprocess,sys,tempfile,threading
from pathlib import Path
from supervisor_integration import fixtures
work=Path(sys.argv[1]).resolve()
lib=c.CDLL(str(work/'usb/libusb-oracle.dylib'))
for name,rest,args in [('create',c.c_void_p,[c.c_size_t]),('take_output',c.c_size_t,[c.c_void_p,c.c_void_p,c.c_size_t]),('feed_guest',c.c_int,[c.c_void_p,c.c_void_p,c.c_size_t]),('destroy',None,[c.c_void_p])]:
 fn=getattr(lib,'spice_usbredir_host_'+name);fn.restype=rest;fn.argtypes=args
with tempfile.TemporaryDirectory(prefix='zig-usb-api-',dir=work) as folder:
 folder=Path(folder)
 def openssl(*args,input=None):return subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
 openssl('genrsa','-out','ticket.key','1024');public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER')
 decrypt=lambda encrypted:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=encrypted)
 Peer,_,_,_,offer=fixtures(work,public,decrypt)
 for seamless,switch_host in ((False,False),(True,False),(False,True)):
  oracle=lib.spice_usbredir_host_create(4096);assert oracle
  try:
   def output():
    buf=c.create_string_buffer(4096);size=lib.spice_usbredir_host_take_output(oracle,buf,len(buf));return buf.raw[:size]
   def feed(data):assert lib.spice_usbredir_host_feed_guest(oracle,data,len(data))==0
   hello=output();assert len(hello)==80
   keys=[(9,0)]
   with Peer(keys) as source,Peer(keys,target=not switch_host,seamless=seamless) as target:
    process=subprocess.Popen([str(work/'usb-consumer'),str(source.port)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    lines=queue.Queue()
    def read():
     for line in process.stdout:lines.put(line.strip())
    reader=threading.Thread(target=read);reader.start()
    try:
     assert lines.get(timeout=10)=='ready'
     def exact(peer,expected):
      received=b''
      while len(received)<len(expected):
       chunk=peer.message((9,0),101);assert 0<len(chunk)<=8;received+=chunk
      assert received==expected
     def command(text,reply):
      process.stdin.write(text+'\n');process.stdin.flush();assert lines.get(timeout=10)==reply
     exact(source,hello)
     feed(hello)
     for part in (hello[:3],hello[3:17],hello[17:]):source.send((9,0),101,part)
     request=struct.pack('<IIQ',7,0,0x1122334455667788)
     feed(request);response=output();assert len(response)==18
     source.send((9,0),101,request);exact(source,response)
     command('received '+str(len(hello)+len(request)),'received')
     command('missing','missing')
     # Native parser prefix must survive a same-guest transport change.
     request2=struct.pack('<IIQ',7,0,0x8877665544332211)
     feed(request2);response2=output();assert len(response2)==18
     source.send((9,0),101,request2[:5]);command('received '+str(len(hello)+len(request)+5),'received')
     source.send((1,0),111 if switch_host else (116 if seamless else 101),offer(target.port,seamless))
     if not switch_host:source.message((1,0),111 if seamless else 102)
     if seamless:
      for key in [(1,0),*keys]:source.send(key,1,struct.pack('<I',3));source.send(key,2,b'usb-state')
      for key in [(1,0),*keys]:assert target.message(key,5)==b'usb-state'
     elif not switch_host:source.send((1,0),112)
     assert lines.get(timeout=10)=='migrated'
     if switch_host:command('finished','finished')
     else:
      target.send((9,0),101,request2[5:]);exact(target,response2)
      command('received '+str(len(hello)+len(request)+len(request2)),'received')
      command('missing','missing')
     process.stdin.write('stop\n');process.stdin.flush()
     assert process.wait(timeout=10)==0,process.stderr.read();reader.join(2)
     assert lines.get(timeout=1)=='public USB executor lifecycle passed'
    except BaseException:
     if process.poll() is None:process.kill();process.wait()
     print(process.stderr.read(),file=sys.stderr);raise
    finally:
     if process.poll() is None:process.kill();process.wait()
     reader.join(2)
  finally:lib.spice_usbredir_host_destroy(oracle)
print(json.dumps(dict(result='passed',cases=['exact native hello and configuration-status bytes from unchanged C oracle','8-byte SPICE chunks and fragmented native input','semi/seamless migration retains partial native packet','switch-host closes USB owner; no automatic device reselection','explicit impossible-address selection and joined cleanup'],instrumentation='C consumer/native bridges ASan/UBSan; Zig ReleaseSafe; prebuilt USB framework unchanged',scope='loopback peers; no physical USB device attached'),indent=2))
