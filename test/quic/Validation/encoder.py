#!/usr/bin/env python3
"""Zig encoder versus upstream C: exact bitstreams and original decoded pixels."""
import ctypes as ct
import hashlib
import json
import random
import struct
import audit
import stream
from audit import BASE, ROOT, require

MORE_LINES = ct.CFUNCTYPE(ct.c_int, ct.c_void_p, ct.POINTER(ct.c_void_p))


def pixels(rng, kind, width, height, pattern):
    bgra = bytearray(rng.randbytes(width*height*4))
    for y in range(height):
        for x in range(width):
            i = (y*width+x)*4
            if pattern == 1:
                v = ((x//2047 + y//2)*97)&255
                bgra[i:i+4] = bytes([v, v^85, v^170, (y//3*83)&255])
            elif pattern == 2:
                bgra[i:i+4] = bytes([(x+y*13)&255, (x*3+y)&255,
                                      (x*7+y*5)&255, (y//3*83)&255])
            elif pattern == 3:
                bgra[i:i+4] = bytes([37, 37, 37, 37])
            if kind == 1:
                bgra[i+1:i+3] = bytes([bgra[i], bgra[i]])
            if kind == 2:
                for c in range(3):
                    value = bgra[i+c]>>3
                    bgra[i+c] = (value<<3)|(value>>2)
            if kind != 5:
                bgra[i+3] = 0
    native = bytearray()
    for i in range(0, len(bgra), 4):
        if kind == 1:
            native.append(bgra[i])
        elif kind == 2:
            native.extend(struct.pack('<H', (bgra[i+2]>>3)<<10 | (bgra[i+1]>>3)<<5 | bgra[i]>>3))
        else:
            native.extend(bgra[i:i+min(kind, 4)])
    return bytes(bgra), bytes(native)


def encode_zig(z, kind, w, h, native, padding, sign, chunk, batch, initial_empty=False):
    bpp = min(kind, 4)
    pitch = w*bpp+padding
    rows = [native[y*w*bpp:(y+1)*w*bpp] for y in range(h)]
    consumed = 0
    active = None
    prior = None
    active_before = prior_before = None
    guard = b'\xa5'*32
    def next_batch():
        nonlocal consumed, active, prior, active_before, prior_before
        if consumed == h:
            return None, 0
        # Release older batches while retaining the immediately previous batch
        # (including its last row) through consumption of this one.
        if prior is not None:
            require(prior.raw == prior_before, 'source mutation in retired batch')
            ct.memset(ct.addressof(prior), 0xdd, len(prior))
            prior = None
        prior, prior_before = active, active_before
        n = min(batch, h-consumed)
        data = bytearray(b'\xa5'*(n*pitch))
        for i in range(n):
            y = i if sign > 0 else n-1-i
            data[y*pitch:y*pitch+w*bpp] = rows[consumed+i]
        active = ct.create_string_buffer(guard+data+guard)
        pointer = ct.addressof(active)+32+(0 if sign > 0 else (n-1)*pitch)
        active_before = active.raw
        consumed += n
        return pointer, n
    @MORE_LINES
    def more_lines(_, pointer):
        address, count = next_batch()
        pointer[0] = address
        return count
    out = ct.create_string_buffer(guard + b'\xcc'*(chunk*4)+guard)
    chunks = []
    progress = []
    @stream.MORE
    def more_output(_, pointer, completed):
        require(out.raw[:32] == guard and out.raw[32+chunk*4:64+chunk*4] == guard, 'output guards')
        chunks.append(out.raw[32:32+chunk*4])
        ct.memset(ct.addressof(out)+32, 0xcc, chunk*4)
        pointer[0] = ct.addressof(out)+32
        progress.append(completed)
        return chunk
    if initial_empty:
        address, count = None, 0
    else:
        address, count = next_batch()
    words = z.zig_quic_encode(kind, w, h, address, count, pitch*sign,
                              ct.byref(out, 32), chunk*4, more_output, more_lines, None)
    require(words > 0, f'Zig encode {kind} {w}x{h}')
    require(progress == sorted(progress) and all(0 <= r <= h for r in progress), 'output progress')
    require(out.raw[:32] == guard and out.raw[32+chunk*4:64+chunk*4] == guard, 'last output guard')
    for allocation, before in [(active, active_before), (prior, prior_before)]:
        if allocation is not None:
            require(allocation.raw == before, 'source mutation')
    used = words*4 - len(chunks)*chunk*4
    require(0 <= used <= chunk*4, 'word count')
    return b''.join(chunks)+out.raw[32:32+used]


def main():
    ref, c_encode, c, z = stream.bindings()
    z.zig_quic_encode.argtypes = [ct.c_int, ct.c_int, ct.c_int, ct.c_void_p,
        ct.c_size_t, ct.c_int64, ct.c_void_p, ct.c_size_t, stream.MORE, MORE_LINES, ct.c_void_p]
    z_decode = audit.decoder(audit.build_production(), 'audit_decode')
    c_decode = audit.decoder(ref, 'audit_decode')
    rng = random.Random(audit.SEED+2)
    count = 0
    for kind in range(1, 6):
        for w, h in [(1, 1), (1, 33), (33, 1), (17, 19), (2047, 7), (2048, 7),
                     (2049, 7), (4097, 5), (16384, 3), (127, 129), (32769, 2)]:
            for pattern in range(4):
                bgra, native = pixels(rng, kind, w, h, pattern)
                expected = stream.encoded(ref, c_encode, kind, w, h, bgra)
                for padding, sign, chunk, batch, empty in [(0, 1, len(expected)//4+8, h, False),
                    (7, -1, 1, 1, True), (3, 1, 5, 3, False), (5, -1, 17, 2, False)]:
                    actual = encode_zig(z, kind, w, h, native, padding, sign, chunk, batch, empty)
                    require(actual == expected, f'bitstream {kind} {w}x{h} pattern {pattern} stride {sign} chunk {chunk}')
                    require(audit.decode(c_decode, actual, w, h) == (0, bgra), 'Zig encode -> C decode pixels')
                    require(audit.decode(z_decode, expected, w, h) == (0, bgra), 'C encode -> production Zig decode pixels')
                    count += 1
        print(f'encoder type {kind}: passed', flush=True)
    report = {'encodedCases': count, 'identicalCBitstreams': count,
              'sourceSHA256': hashlib.sha256((ROOT/'pkg/quic/codec.zig').read_bytes()).hexdigest(),
              'scope': 'five formats; positive/negative padded strides; one-word output; more_lines batches; exact independent C bitstreams and original pixels'}
    (ROOT/'.build/quic-audit/full-encoder.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
