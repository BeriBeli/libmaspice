#!/usr/bin/env python3
"""Compile unchanged Swift damage declarations, compare exact journal output."""
import ctypes as c,hashlib,json,random,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parents[2];work=Path(sys.argv[1]).resolve()
def declaration(source,marker):
 start=source.index(marker);brace=source.index('{',start);depth=1;end=brace+1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]
store=(root/'test/oracle/swift/SpiceRenderer/SurfaceStore.swift').read_text();backing=(root/'test/oracle/swift/SpiceRenderer/SurfaceBacking.swift').read_text()
selected='\n\n'.join([declaration(store,'package struct PixelRect:'),declaration(backing,'package struct SurfaceDamageJournal:'),declaration(backing,'private extension PixelRect {')])
main='''
@main struct DamageOracle {
    struct Input:Decodable{let width:Int;let height:Int;let rectangles:[[Int]]}
    struct Output:Encodable{let full:Bool;let rectangles:[[Int]]}
    static func main()throws{
        let inputs=try JSONDecoder().decode([Input].self,from:FileHandle.standardInput.readDataToEndOfFile())
        let results=inputs.map{input in
            var journal=SurfaceDamageJournal(width:input.width,height:input.height)
            for r in input.rectangles{journal.append(PixelRect(x:r[0],y:r[1],width:r[2],height:r[3]))}
            return Output(full:journal.isFullFrame,rectangles:journal.copyRectangles.map{[$0.x,$0.y,$0.width,$0.height]})
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(results))
    }
}
'''
source=work/'damage-oracle.swift';source.write_text('import Foundation\n'+selected+main)
subprocess.run(['swiftc','-parse-as-library','-warnings-as-errors','-package-name','SwiftSpice','-module-cache-path',str(work/'swift-cache'),str(source),'-o',str(work/'damage-oracle')],check=True)
lib=c.CDLL(str(work/'libgraphics-fixture.dylib'));fn=lib.graphics_fixture_damage;fn.argtypes=[c.c_size_t,c.c_size_t,c.POINTER(c.c_int64),c.c_size_t,c.POINTER(c.c_int64),c.POINTER(c.c_bool)];fn.restype=c.c_int
cases=[dict(width=10,height=10,rectangles=[]),dict(width=10,height=10,rectangles=[[0,0,10,1],[0,0,1,10]]),dict(width=200,height=1,rectangles=[[i*2,0,1,1] for i in range(65)])]
rng=random.Random(0x44414d)
for _ in range(1500):
 w,h=rng.randint(1,128),rng.randint(1,128);rects=[]
 for i in range(rng.randint(1,80)):
  x,y=rng.randrange(w),rng.randrange(h)
  rects.append([x,y,rng.randint(1,w-x),rng.randint(1,h-y)])
 cases.append(dict(width=w,height=h,rectangles=rects))
actual=json.loads(subprocess.run([str(work/'damage-oracle')],input=json.dumps(cases),text=True,capture_output=True,check=True,timeout=60).stdout)
for case,expected in zip(cases,actual):
 flat=[v for r in case['rectangles'] for v in r];buf=(c.c_int64*len(flat))(*flat);out=(c.c_int64*256)();full=c.c_bool();count=fn(case['width'],case['height'],buf,len(case['rectangles']),out,c.byref(full));assert count>=0
 got=dict(full=full.value,rectangles=[list(out[i*4:i*4+4]) for i in range(count)])
 assert got==expected,(case,expected,got)
print(json.dumps(dict(result='passed',cases=len(cases),scope='exact damage rectangles/order and full-frame threshold against unchanged Swift declarations',selected_swift_sha256=hashlib.sha256(selected.encode()).hexdigest()),indent=2))
