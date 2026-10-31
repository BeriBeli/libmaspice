"""Run deterministic mixed policy traces against the unmodified Swift definitions."""
import ctypes as c,json,random,subprocess,sys
from pathlib import Path
work=Path(sys.argv[1]).resolve();root=Path(__file__).resolve().parents[2]
view=(root/'test/oracle/swift/SwiftSpice/SpiceDesktopView.swift').read_text()
source=(root/'test/oracle/swift/SwiftSpice/SpiceDesktopSource.swift').read_text()
presenter=(root/'test/oracle/swift/SwiftSpice/SpiceMetalPresenter.swift').read_text()
# Exact declaration ranges, never translated or patched implementations.
selected='import Foundation\n'+source[source.index('public struct SpiceSurfaceIdentity:'):source.index('public enum SpiceDamageRegion:')]
for name in ['package struct SpiceMetalFailureRecoveryPolicy {','package struct SpiceDrawablePresentationDropRecoveryPolicy {','package struct SpiceDesktopPresentationPacingPolicy:']:
 start=view.index(name);depth=0;opened=False;stop=None
 for i in range(start,len(view)):
  if view[i]=='{':depth+=1;opened=True
  elif view[i]=='}':
   depth-=1
   if opened and depth==0:stop=i+1;break
 assert stop;selected+=view[start:stop]+'\n'
selected+=presenter[presenter.index('package enum SpiceMetalCommandCompletion:'):presenter.index('package enum SpiceMetalDrawablePresentationOutcome:')]
(work/'swift-policy-definitions.swift').write_text(selected)
subprocess.run(['swiftc','-parse-as-library','-warnings-as-errors','-package-name','SwiftSpice','-module-cache-path',str(work/'swift-cache'),str(work/'swift-policy-definitions.swift'),str(root/'test/native/presentation-policy-oracle.swift'),'-o',str(work/'policy-oracle')],check=True)
lib=c.CDLL(str(work/'libpolicy-fixture.dylib'));lib.policy_create.restype=c.c_void_p;lib.policy_destroy.argtypes=[c.c_void_p];lib.policy_step.argtypes=[c.c_void_p,c.c_uint32,c.c_int64,c.c_int64,c.c_int64];lib.policy_step.restype=c.c_int64
rng=random.Random(0x53504943);commands=[];attempts=[]
for _ in range(12000):
 op=rng.choice([0,1,2,10,10,11,11,12,13,20,21,21,22,23]);x=y=z=0
 if op==10:x=rng.randrange(30);attempts.append(x)
 elif op in (11,12):
  if not attempts:continue
  x=rng.randrange(len(attempts));y=rng.choice([attempts[x],-1,rng.randrange(30)]);z=rng.randrange(2)
 elif op in (20,21,22):x=rng.randrange(30);y=rng.choice([x,-1,rng.randrange(30)]);z=rng.randrange(2)
 elif op==1:x=rng.randrange(2)
 commands.append([op,x,y,z])
expected=json.loads(subprocess.run([str(work/'policy-oracle')],input=json.dumps(commands),text=True,stdout=subprocess.PIPE,check=True).stdout)
state=lib.policy_create();assert state
try:
 actual=[lib.policy_step(state,*command) for command in commands]
 for i,(swift,zig) in enumerate(zip(expected,actual)):
  assert swift==zig,(i,commands[i],swift,zig)
finally:lib.policy_destroy(state)
print(json.dumps({'result':'passed','commands':len(commands),'oracle':'exact existing Swift pacing, Metal failure recovery, drawable drop recovery declarations','seed':'0x53504943'},indent=2))
