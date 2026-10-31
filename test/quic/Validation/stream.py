#!/usr/bin/env python3
"""Full decoder contract against the independent upstream C implementation."""
import ctypes as ct
import hashlib
import json
import random
import subprocess
import audit
import reference
from audit import ROOT, BASE, SCRATCH, require

MORE = ct.CFUNCTYPE(ct.c_int, ct.c_void_p, ct.POINTER(ct.c_void_p), ct.c_int)
TARGETS = {1: [1], 2: [2, 4], 3: [3, 4], 4: [3, 4], 5: [5]}


def bindings():
    SCRATCH.mkdir(parents=True, exist_ok=True)
    ref = audit.build_reference()
    encode = ref.quic_reference_encode
    encode.argtypes = [ct.c_int, ct.c_int, ct.c_int, ct.c_void_p, ct.c_size_t,
                       ct.POINTER(ct.c_void_p), ct.POINTER(ct.c_size_t)]
    ref.audit_free.argtypes = [ct.c_void_p]
    native = SCRATCH / 'stream-reference.dylib'
    subprocess.run(['xcrun', 'clang', '-dynamiclib', '-O2',
                    str(BASE / 'Validation/stream_reference.c'), '-I',
                    str(ROOT / 'pkg'), str(reference.object_file()), '-o', str(native)], check=True)
    c = ct.CDLL(str(native)).audit_native_decode
    c.argtypes = [ct.c_void_p, ct.c_size_t, ct.c_uint, ct.c_int, ct.c_void_p,
                  ct.c_int, ct.c_void_p]
    z = ct.CDLL(str(audit.build_zig(ROOT / 'pkg/quic/experiment.zig', 'stream')))
    z.zig_quic_context_create.restype = ct.c_void_p
    z.zig_quic_context_destroy.argtypes = [ct.c_void_p]
    z.zig_quic_begin.argtypes = [ct.c_void_p, ct.c_void_p, ct.c_size_t, MORE,
                                ct.c_void_p, ct.c_void_p]
    z.zig_quic_finish.argtypes = [ct.c_void_p, ct.c_int, ct.c_void_p, ct.c_size_t, ct.c_int64]
    return ref, encode, c, z


def encoded(ref, encode, kind, w, h, pixels):
    pointer, count = ct.c_void_p(), ct.c_size_t()
    require(encode(kind, w, h, pixels, len(pixels), ct.byref(pointer), ct.byref(count)) == 0, 'C encode')
    try:
        return ct.string_at(pointer, count.value)
    finally:
        ref.audit_free(pointer)


def main():
    ref, encode, c, z = bindings()
    rng = random.Random(audit.SEED + 1)
    context = z.zig_quic_context_create()
    count = rejected = 0
    try:
        for kind in range(1, 6):
            for w, h in [(1, 1), (1, 19), (19, 1), (31, 17), (2049, 7), (16384, 1), (32769, 2)]:
                for pattern in range(3):
                    raw = rng.randbytes(w*h*4) if pattern == 0 else bytes([pattern*63])* (w*h*4)
                    payload = encoded(ref, encode, kind, w, h, raw)
                    for target in TARGETS[kind]:
                        bpp = min(target, 4)
                        for padding in [0, 8 if target == 2 else 7]:
                            for sign in [1, -1]:
                                pitch = w*bpp + padding
                                stride = sign*pitch
                                size = pitch*h
                                for chunk in [1, 2, 5, 17, len(payload)//4]:
                                    # Keep each returned block alive until the next callback.
                                    source = ct.create_string_buffer(payload)
                                    position = min(chunk*4, len(payload))
                                    rows = []
                                    @MORE
                                    def more(_, out, completed):
                                        nonlocal position
                                        rows.append(completed)
                                        n = min(chunk*4, len(payload)-position)
                                        out[0] = ct.addressof(source)+position
                                        position += n
                                        return n//4
                                    initial = min(chunk*4, len(payload))
                                    metadata = (ct.c_int*3)()
                                    require(z.zig_quic_begin(context, source, initial, more, None, metadata) == 0, 'begin')
                                    require(list(metadata) == [kind, w, h], 'metadata')
                                    invalid = next(k for k in range(1, 6) if k not in TARGETS[kind])
                                    out = ct.create_string_buffer(b'\xa5'*(size+64))
                                    require(z.zig_quic_finish(context, invalid, ct.byref(out, 32), size, stride) == -1, 'invalid conversion')
                                    require(z.zig_quic_finish(context, target, ct.byref(out, 32), size, w*bpp-1) == -1, 'short stride')
                                    require(z.zig_quic_finish(context, target, ct.byref(out, 32), (h-1)*pitch+w*bpp-1, stride) == -1, 'short output')
                                    rejected += 3
                                    # Upstream run copies do not define the RGB padding byte;
                                    # zero active pixels, while keeping row/end guards poisoned.
                                    for y in range(h):
                                        ct.memset(ct.addressof(out)+32+y*pitch, 0, w*bpp)
                                    oracle = ct.create_string_buffer(out.raw, len(out.raw))
                                    require(z.zig_quic_finish(context, target, ct.byref(out, 32), size, stride) == 0, 'finish')
                                    require(c(source, len(payload), chunk, target, ct.byref(oracle, 32), stride, metadata) == 0, 'C decode')
                                    require(out.raw == oracle.raw, f'pixels/guards {kind}->{target} {w}x{h} stride {stride} chunk {chunk}')
                                    require(rows == sorted(rows) and all(0 <= r <= h for r in rows), 'row progress')
                                    require(z.zig_quic_finish(context, target, ct.byref(out, 32), size, stride) == -1, 'double body')
                                    count += 1
            print(f'full decoder type {kind}: passed', flush=True)
        # A 1x1 RGBA body needs the final lookahead word: every proper word
        # prefix must fail, whether failure is reached in begin or finish.
        payload = encoded(ref, encode, 5, 1, 1, bytes(4))
        for cut in range(0, len(payload), 4):
            source = ct.create_string_buffer(payload[:cut])
            position = min(4, cut)
            @MORE
            def truncated(_, out, completed):
                nonlocal position
                n = min(4, cut-position)
                out[0] = ct.addressof(source)+position
                position += n
                return n//4
            metadata = (ct.c_int*3)()
            status = z.zig_quic_begin(context, source, min(4, cut), truncated, None, metadata)
            output = ct.create_string_buffer(4)
            if status == 0:
                status = z.zig_quic_finish(context, 5, output, 4, 4)
            require(status == -1, 'chunk exhaustion')
            rejected += 1
        # Header failures invalidate old state, and the same context remains reusable.
        for length in range(24):
            payload = bytes(length)
            @MORE
            def exhausted(_, out, rows):
                out[0] = None
                return 0
            metadata = (ct.c_int*3)()
            require(z.zig_quic_begin(context, payload, length, exhausted, None, metadata) == -1, 'truncated header')
            rejected += 1
    finally:
        z.zig_quic_context_destroy(context)
    report = {'decodedCases': count, 'invalidArguments': rejected,
              'sourceSHA256': hashlib.sha256((ROOT/'pkg/quic/codec.zig').read_bytes()).hexdigest(),
              'scope': 'eight conversions; signed/padded strides; chunked input; reused context; exact C pixels and guards'}
    (ROOT/'.build/quic-audit/full-decoder.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
