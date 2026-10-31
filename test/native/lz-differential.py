#!/usr/bin/env python3
import base64
import ctypes as c
import json
from pathlib import Path
import random
import subprocess
import struct
import sys

work = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parents[2]
lib = c.CDLL(str(work/'libspicezig.dylib'))
ptr,size = c.c_void_p,c.c_size_t
lib.spice_zig_lz_decode.argtypes=[c.POINTER(c.c_uint8),size,size,size,c.POINTER(c.c_uint32),size,c.POINTER(ptr)]
lib.spice_zig_lz_decode.restype=c.c_int
lib.spice_zig_image_destroy.argtypes=[ptr]
lib.spice_zig_image_data.argtypes=[ptr,c.POINTER(size)]
lib.spice_zig_image_data.restype=c.POINTER(c.c_uint8)
lib.spice_zig_image_flags.argtypes=[ptr]
lib.spice_zig_image_flags.restype=c.c_int

def decode(case):
    data = base64.b64decode(case['data'])
    storage = (c.c_uint8*len(data)).from_buffer_copy(data)
    palette = case.get('palette')
    entries = (c.c_uint32*len(palette))(*palette) if palette is not None else None
    image = ptr()
    result = lib.spice_zig_lz_decode(storage,len(data),case['width'],case['height'],entries,len(palette or []),c.byref(image))
    try:
        if result:
            assert not image
            return dict(status=-1)
        length = size()
        pixels = lib.spice_zig_image_data(image,c.byref(length))
        return dict(status=0,pixels=base64.b64encode(c.string_at(pixels,length.value)).decode(),flags=lib.spice_zig_image_flags(image))
    finally:
        lib.spice_zig_image_destroy(image)

rng=random.Random(0x4c5a)
cases=[]
fixtures=sorted((root/'test/fixtures/SpiceCodecsTests').glob('lz*.json'))
truncations=0
for path in fixtures:
    fixture=json.loads(path.read_text())
    case=dict(data=fixture['compressedBase64'],width=fixture['width'],height=fixture['height'])
    if 'paletteARGB' in fixture: case['palette']=fixture['paletteARGB']
    got=decode(case)
    flags=3 if fixture['format'] in ('rgba','xxxa','a8') else 1
    assert got==dict(status=0,pixels=fixture['expectedXRGBBase64'],flags=flags),(path,got)
    cases.append(case)
    data=base64.b64decode(case['data'])
    for end in range(len(data)):
        truncated=dict(case,data=base64.b64encode(data[:end]).decode())
        assert decode(truncated)==dict(status=-1),(path,end)
        cases.append(truncated)
        truncations+=1
    # Metadata orientation is retained; no implicit row flip.
    bottom=bytearray(data);bottom[27]=0
    cases.append(dict(case,data=base64.b64encode(bottom).decode()))
    cases.append(dict(case,width=case['width']+1))
    cases.append(dict(case,data=base64.b64encode(data+b'\0').decode()))
    for _ in range(600):
        mutant=bytearray(data)
        for _ in range(rng.randint(1,4)):
            mutant[rng.randrange(len(mutant))]=rng.randrange(256)
        cases.append(dict(case,data=base64.b64encode(mutant).decode()))

# Independent command synthesis covers the far-distance escape, multi-byte
# length extension, overlapping periods, alpha preservation and 4-bit modulo
# palettes that small upstream fixtures do not necessarily exercise.
def literals(units):
    return b''.join(bytes([len(units[i:i+32])-1])+b''.join(units[i:i+32]) for i in range(0,len(units),32))

def match(length,distance,bias):
    encoded_length=length-bias
    assert encoded_length >= 0
    near=min(distance-1,8191)
    control=((min(encoded_length,6)+1)<<5)|(near>>8)
    extra=b''
    if encoded_length>=6:
        remainder=encoded_length-6
        while remainder>=255:
            extra+=b'\xff';remainder-=255
        extra+=bytes([remainder])
    extra+=bytes([near&255])
    if distance-1>=8191: extra+=struct.pack('>H',distance-1-8191)
    return bytes([control])+extra

synthetic=0
for kind in range(6,12):
    for distance,length in ((1,280),(7,513),(8192,128)):
        width=distance+length
        stride=width*({6:2,7:3,8:4,9:4,10:4,11:1}[kind])
        header=struct.pack('>7I',0x20205a4c,0x10001,kind,width,1,stride,1)
        colors=[bytes([(i*3)&255,(i*5)&255,(i*7)&255]) for i in range(distance)]
        alpha=[bytes([(i*11)&255]) for i in range(distance)]
        if kind==6:
            units=[bytes([(i*3)&255,(i*5)&255]) for i in range(distance)]
            commands=literals(units)+match(length,distance,2)
            original=[]
            for red,blue in units:
                green=((red<<6)|(blue>>2))&0xf8
                original.append(bytes([((blue<<3)|((blue>>2)&7))&255,green|(green>>5),((red<<1)&0xf8)|((red>>4)&7),0]))
        elif kind in (7,8,9):
            commands=literals(colors)+match(length,distance,1)
            if kind==9: commands+=literals(alpha)+match(length,distance,3)
            original=[color+(alpha[i] if kind==9 else b'\0') for i,color in enumerate(colors)]
        else:
            commands=literals(alpha)+match(length,distance,3)
            original=[b'\0\0\0'+value for value in alpha]
        expected_pixels=b''.join(original[i%distance] for i in range(width))
        case=dict(data=base64.b64encode(header+commands).decode(),width=width,height=1)
        assert decode(case)==dict(status=0,pixels=base64.b64encode(expected_pixels).decode(),flags=3 if kind>=9 else 1)
        cases.append(case);synthetic+=1
for kind in (1,2,3,4,5):
    width,height=9,5
    per_byte=8 if kind<=2 else 2 if kind<=4 else 1
    stride=(width+per_byte-1)//per_byte
    palette=[0x112233,0x445566,0x778899]
    if kind<=2: palette=palette[:2]
    units=[bytes([i%len(palette) if kind==5 else (i*37+15)&255]) for i in range(stride)]
    commands=literals(units)+match(stride*(height-1),stride,3)
    header=struct.pack('>7I',0x20205a4c,0x10001,kind,width,height,stride,1)
    case=dict(data=base64.b64encode(header+commands).decode(),width=width,height=height,palette=palette)
    expected_pixels=bytearray()
    for _ in range(height):
        for x in range(width):
            byte=units[x//per_byte][0]
            shift=(x%per_byte if kind==1 else 7-x%per_byte) if kind<=2 else ((x%2)*4 if kind==3 else (1-x%2)*4)
            index=((byte>>shift)&(1 if kind<=2 else 15)) if kind!=5 else byte
            color=palette[index%len(palette)]
            expected_pixels+=struct.pack('<I',color)
    assert decode(case)==dict(status=0,pixels=base64.b64encode(expected_pixels).decode(),flags=1)
    cases.append(case);synthetic+=1
expected=json.loads(subprocess.run([str(work/'lz-oracle')],input=json.dumps(cases).encode(),stdout=subprocess.PIPE,check=True).stdout)
for index,(case,want) in enumerate(zip(cases,expected,strict=True)):
    got=decode(case)
    assert want==got,(index,case,want,got)
print(json.dumps({'independent_upstream_fixtures':len(fixtures),'synthetic_reference_cases':synthetic,'truncations':truncations,'mutations':600*len(fixtures),'swift_differential_cases':len(cases),'result':'passed'},indent=2))
