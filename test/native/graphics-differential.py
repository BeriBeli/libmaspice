#!/usr/bin/env python3
import base64,ctypes as c,json,subprocess,sys
from pathlib import Path
work=Path(sys.argv[1]).resolve();lib=c.CDLL(str(work/'libgraphics-fixture.dylib'));U=c.POINTER(c.c_uint8);Z=c.c_size_t
lib.graphics_fixture_scale.argtypes=[c.c_char_p,U,Z,Z,U,Z,Z];lib.graphics_fixture_scale.restype=c.c_int
cases=[];patterns=['checker','thin_lines','color_alpha_edges']
for pattern in patterns:
 for w,h,tw,th in [(17,13,29,23),(31,19,11,7),(13,17,7,29)]:
  pixels=bytearray()
  for y in range(h):
   for x in range(w):
    if pattern=='checker':value=255 if (x+y)%2 else 0;pixel=[value,255-value,value,255]
    elif pattern=='thin_lines':pixel=[255 if x%5==0 else 7,255 if y%3==0 else 19,(x*17+y*23)%256,255]
    else:pixel=[x*255//(w-1),y*255//(h-1),(x*11+y*7)%256,255 if x>w//2 else (64 if y>h//2 else 0)]
    pixels.extend(pixel)
  cases.append(dict(width=w,height=h,targetWidth=tw,targetHeight=th,pixels=base64.b64encode(pixels).decode()))
reference=subprocess.run([str(work/'mps-reference')],input=json.dumps(cases),text=True,capture_output=True,check=True,timeout=60)
expected=json.loads(reference.stdout);maximum=0
for case,want in zip(cases,expected):
 data=base64.b64decode(case['pixels']);source=(c.c_uint8*len(data)).from_buffer_copy(data);output=(c.c_uint8*(case['targetWidth']*case['targetHeight']*4))()
 assert lib.graphics_fixture_scale(str(work/'compositor.metallib').encode(),source,case['width'],case['height'],output,case['targetWidth'],case['targetHeight'])==0
 target=base64.b64decode(want);delta=max(abs(x-y) for x,y in zip(output,target));maximum=max(maximum,delta);assert delta==0,(case,delta)
print(json.dumps(dict(result='passed',mps_pattern_cases=len(cases),patterns=patterns,maximum_channel_difference=maximum,allowed_channel_difference=0,reference='independent Swift MPSImageLanczosScale with clamp, matching existing presenter configuration'),indent=2))
