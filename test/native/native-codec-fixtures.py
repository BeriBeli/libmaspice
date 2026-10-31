#!/usr/bin/env python3
import base64,ctypes as c,json,sys
from pathlib import Path
work=Path(sys.argv[1]).resolve();root=Path(__file__).resolve().parents[2];lib=c.CDLL(str(work/'libglz-fixture.dylib'));P=c.c_void_p;Z=c.c_size_t;U=c.POINTER(c.c_uint8)
lib.glz_fixture_native.argtypes=[c.c_int,U,Z,Z,Z,c.POINTER(P)];lib.glz_fixture_native.restype=c.c_int
lib.glz_fixture_pixels.argtypes=[P,c.POINTER(Z)];lib.glz_fixture_pixels.restype=U
lib.glz_fixture_release.argtypes=[P]
def decode(kind,data,w,h):
 buf=(c.c_uint8*len(data)).from_buffer_copy(data);image=P();status=lib.glz_fixture_native(kind,buf,len(data),w,h,c.byref(image))
 if status:assert not image;return None
 try:
  size=Z();pixels=lib.glz_fixture_pixels(image,c.byref(size));assert size.value==w*h*4;return c.string_at(pixels,size.value)
 finally:lib.glz_fixture_release(image)
counts={'jpeg_images':0,'quic_images':0,'truncations':0,'dimension_rejections':0}
for prefix in ['jpeg','quic']:
 for path in sorted((root/'test/fixtures/SpiceCodecsTests').glob(prefix+'*.json')):
  fixture=json.loads(path.read_text());kind=int(prefix=='quic');data=base64.b64decode(fixture['compressedBase64' if kind else 'jpegBase64']);w=fixture['width'];h=fixture['height']
  if kind:expected=base64.b64decode(fixture['expectedBGRABase64'])
  else:
   rgb=base64.b64decode(fixture['expectedRGBBase64']);expected=b''.join(bytes([rgb[i+2],rgb[i+1],rgb[i],255]) for i in range(0,len(rgb),3))
  assert decode(kind,data,w,h)==expected,path
  counts[prefix+'_images']+=1
  assert decode(kind,data,w+1,h) is None;counts['dimension_rejections']+=1
  for end in range(len(data)):
   assert decode(kind,data[:end],w,h) is None,(path,end)
   counts['truncations']+=1
print(json.dumps(dict(result='passed',**counts),indent=2))
