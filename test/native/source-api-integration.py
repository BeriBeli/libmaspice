"""Independent public Source API consumer over real CPU/GPU TCP migration."""
import json,queue,struct,subprocess,sys,tempfile,threading
from pathlib import Path
from supervisor_integration import fixtures
work=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='zig-source-api-',dir=work) as folder:
 folder=Path(folder)
 def openssl(*args,input=None):return subprocess.run(['openssl',*args],cwd=folder,input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
 openssl('genrsa','-out','ticket.key','1024');public=openssl('rsa','-in','ticket.key','-pubout','-outform','DER')
 decrypt=lambda encrypted:openssl('pkeyutl','-decrypt','-inkey','ticket.key','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha1',input=encrypted)
 Peer,_,_,_,offer=fixtures(work,public,decrypt)
 for native in (False,True):
  for seamless,switching in ((False,False),(True,False),(False,True)):
   keys=[(2,0),(4,0)]
   with Peer(keys) as source,Peer(keys,target=not switching,seamless=seamless) as target:
    process=subprocess.Popen([str(work/'source-consumer'),str(source.port),str(int(native)),str(work/'compositor.metallib')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    lines=queue.Queue()
    def read():
     for line in process.stdout:lines.put(line.strip())
    reader=threading.Thread(target=read);reader.start()
    try:
     assert lines.get(timeout=10)=='ready';source.message((2,0),101)
     def command(text):
      process.stdin.write(text+'\n');process.stdin.flush();assert lines.get(timeout=10)==text.split()[0]
     source.send((2,0),314,struct.pack('<5I',7,8,8,32,0))
     source.send((2,0),302,struct.pack('<I4iBBIH',7,0,0,8,8,0,1,0x112233,8)+b'\0'*13)
     command('frame')
     source.send((4,0),101,struct.pack('<hhHHBH',10,20,2,3,1,2)+struct.pack('<QB4H',77,0,2,1,0,0)+bytes(range(1,9)))
     command('cursor');command('hidden');command('visible');command('handler')
     if not native and not seamless and not switching:
      with Peer(keys,target=True,fail_key=(4,0)) as rejected:
       subject=b'CN=guest.example\0'
       source.send((1,0),101,offer(rejected.port)[:-4]+struct.pack('<I',len(subject))+subject)
       source.message((1,0),103)
       assert lines.get(timeout=10)=='migration_failed'
     source.send((1,0),111 if switching else (116 if seamless else 101),offer(target.port,seamless))
     if not switching:source.message((1,0),111 if seamless else 102)
     if seamless:
      for key in [(1,0),*keys]:source.send(key,1,struct.pack('<I',3));source.send(key,2,b'source-state')
      for key in [(1,0),*keys]:assert target.message(key,5)==b'source-state'
     elif not switching:source.send((1,0),112)
     assert lines.get(timeout=10)=='migrated';command('migration '+str(int(switching)))
     process.stdin.write('stop\n');process.stdin.flush();assert process.wait(timeout=10)==0,process.stderr.read();reader.join(2)
     assert lines.get(timeout=1)=='public Source subscriptions and retained snapshots passed'
    except BaseException:
     if process.poll() is None:process.kill();process.wait()
     print(process.stderr.read(),file=sys.stderr);raise
    finally:
     if process.poll() is None:process.kill();process.wait()
     reader.join(2)
print(json.dumps({'result':'passed','cases':6,'modes':['CPU','Metal context configured; fill drawing remains CPU backed'],'migration':['semi','seamless','switch-host'],'checks':['demand before connect','hidden/visible forces fresh full publication','cursor-only empty damage','handler context lifetime and explicit ACK','ready latch borrowed/owned snapshots','stale event fenced after handoff','same guest retains static desktop','guest switch clears desktop','snapshot/subscription lifetime beyond source and Desktop destruction','pipeline counters preserved without duplication across handoff and switch-host retirement; rejected target excluded; live Surface budget sampled independently'],'instrumentation':'C consumer and native bridges ASan/UBSan; Zig ReleaseSafe'},indent=2))
