"""Compare keyboard and geometry against exact Swift AppKit implementation ranges."""
import ctypes as c,json,random,subprocess,sys,math
from pathlib import Path
root=Path(__file__).resolve().parents[2];work=Path(sys.argv[1]).resolve()
view=(root/'test/oracle/swift/SwiftSpice/SpiceDesktopView.swift').read_text()
def declaration(marker):
 start=view.index(marker);depth=0;opened=False
 for i in range(start,len(view)):
  if view[i]=='{':depth+=1;opened=True
  elif view[i]=='}':
   depth-=1
   if opened and depth==0:return view[start:i+1]
 raise AssertionError(marker)
swift='''import AppKit
package enum Input {case keyDown(scanCode:UInt32), keyUp(scanCode:UInt32)}
@MainActor package final class OracleView:NSView {
 var pressedScanCodes:Set<UInt32>=[]
 var output:[UInt32]=[]
 func onInput(_ input:Input) {switch input {case let .keyDown(code):output.append(0x10000|code);case let .keyUp(code):output.append(0x20000|code)}}
 func releasePointerCapture() {}
'''
for marker in ['    package override func keyDown(', '    package override func keyUp(', '    package override func flagsChanged(', '    private func synchronizeModifiers(', '    package override func resignFirstResponder(']:swift+=declaration(marker)+'\n'
swift+='}\n'+declaration('package enum MacXTScanCode {')+'\n'
swift+='package enum Drawing {\n'+declaration('    static func contentRectangle(')+'\n}\n'
(work/'swift-input-definitions.swift').write_text(swift)
subprocess.run(['swiftc','-parse-as-library','-warnings-as-errors','-package-name','SwiftSpice','-module-cache-path',str(work/'swift-cache'),str(work/'swift-input-definitions.swift'),str(root/'test/native/host-input-oracle.swift'),'-o',str(work/'input-oracle')],check=True)
rng=random.Random(0x1a2b3c)
commands=[]
for key in range(128):
 for flags in [0,1<<21,1<<17,1<<18,1<<19,1<<20]:
  for decimal in [0,1]:commands.extend([[0,key,flags,decimal],[1,key,flags,decimal]])
commands.append([3,0,0,0])
for _ in range(8000):
 flags=rng.randrange(16)<<17
 if rng.randrange(2):flags|=rng.randrange(128)|(rng.randrange(2)<<13)
 commands.append([rng.choices([0,1,2,3],[4,3,5,1])[0],rng.choice([0,57,rng.randrange(140)]),flags,rng.randrange(2)])
# Independent rectangle edges and arbitrary letterboxing/non-zero bounds.
geometry=[]
for i in range(2000):
 w=rng.randrange(1,16385);h=rng.randrange(1,16385)
 x=rng.uniform(-300,300);y=rng.uniform(-300,300);bw=rng.uniform(.01,3000);bh=rng.uniform(.01,3000)
 px=rng.uniform(x-100,x+bw+100);py=rng.uniform(y-100,y+bh+100)
 geometry.append([x,y,bw,bh,w,h,px,py])
geometry.extend([[20,40,800,600,400,200,x,y] for x,y in [(20,140),(820,140),(20,540),(819.99,539.99),(0,0),(420,340)]])
expected=json.loads(subprocess.run([str(work/'input-oracle')],input=json.dumps({'commands':commands,'geometry':geometry}),text=True,stdout=subprocess.PIPE,check=True).stdout)
lib=c.CDLL(str(work/'libhost-input-fixture.dylib'));lib.keyboard_create.restype=c.c_void_p;lib.keyboard_destroy.argtypes=[c.c_void_p]
lib.keyboard_step.argtypes=[c.c_void_p,c.c_uint32,c.c_uint16,c.c_uint64,c.c_uint8,c.POINTER(c.c_uint32)];lib.keyboard_step.restype=c.c_int32
lib.host_geometry.argtypes=[c.POINTER(c.c_double),c.c_uint32,c.c_uint32,c.POINTER(c.c_double),c.POINTER(c.c_double)]
state=lib.keyboard_create();assert state;out=(c.c_uint32*349)()
try:
 for i,(cmd,want) in enumerate(zip(commands,expected['commands'])):
  count=lib.keyboard_step(state,*cmd,out);actual=None if count==-1 else list(out[:count]);assert count>=-1
  if cmd[0]==3 and actual is not None:actual.sort();want.sort()
  assert actual==want,(i,cmd,actual,want)
finally:lib.keyboard_destroy(state)
for i,(data,want) in enumerate(zip(geometry,expected['geometry'])):
 bounds=(c.c_double*4)(*data[:4]);point=(c.c_double*2)(*data[6:]);out=(c.c_double*6)()
 lib.host_geometry(bounds,int(data[4]),int(data[5]),point,out)
 assert all(math.isclose(a,b,rel_tol=1e-12,abs_tol=1e-9) for a,b in zip(out[:4],want[:4])),(i,list(out),want)
 assert list(out[4:])==want[4:],(i,list(out),want)
print(json.dumps({'result':'passed','keyboard_commands':len(commands),'geometry_cases':len(geometry),'seed':'0x1a2b3c','oracle':'exact existing Swift key event, modifier, key map, focus cleanup and contentRectangle implementations; actual NSEvent values','intentional_safety_extensions':['reject nonfinite geometry and scroll','reject nonfinite saved cursor point']},indent=2))
