#!/usr/bin/env python3
"""Deterministic Swift-source oracle vs the real Zig C ABI. No codec speed claims."""
import ctypes as c
import json
from pathlib import Path
import random
import struct
import subprocess
import sys

work = Path(sys.argv[1]).resolve()
lib = c.CDLL(str(work / 'libspicezig.dylib'))
ptr = c.c_void_p
size = c.c_size_t
u8p = c.POINTER(c.c_uint8)
signatures = {
    'wire_create': ([c.c_uint8, size, size, size], ptr),
    'wire_destroy': ([ptr], None),
    'wire_append': ([ptr, u8p, size], c.c_int),
    'wire_next': ([ptr, size, c.POINTER(ptr)], c.c_int),
    'wire_buffered': ([ptr], size),
    'batch_destroy': ([ptr], None),
    'batch_count': ([ptr], size),
    'batch_serial': ([ptr, c.POINTER(c.c_uint64)], c.c_int),
    'batch_message': ([ptr, size, c.POINTER(c.c_uint16), c.POINTER(u8p), c.POINTER(size)], c.c_int),
}
for name, (args, result) in signatures.items():
    fn = getattr(lib, 'spice_zig_' + name)
    fn.argtypes, fn.restype = args, result
    globals()[name] = fn

def frame(mode, kind, body, offset=0, serial=0x0102030405060708):
    header = struct.pack('<HI', kind, len(body))
    return (struct.pack('<Q', serial) + header + struct.pack('<I', offset) if mode == 0 else header) + body

def list_body(main, subs, order):
    start = len(main) + 2 + 4 * len(subs)
    payload, offsets = b'', []
    for kind, body in subs:
        offsets.append(start + len(payload))
        payload += struct.pack('<HI', kind, len(body)) + body
    return main + struct.pack('<H', len(subs)) + b''.join(struct.pack('<I', offsets[i]) for i in order) + payload

rng = random.Random(0x5350494345)
cases = []
for mode in (0, 1):
    for length in (0, 1, 7, 256):
        wire = frame(mode, 101, rng.randbytes(length))
        for split in range(len(wire) + 1):
            cases.append(dict(mode=mode, chunks=[list(wire[:split]), list(wire[split:])], maximum=4096))
valid = []
for n in (0, 1, 2, 7, 32):
    order = list(range(n)); rng.shuffle(order)
    for main in (b'', b'\xaa\xbb\xcc'):
        body = list_body(main, [(200+i, rng.randbytes(i % 9)) for i in range(n)], order)
        wire = frame(0, 103 if main else 8, body, len(main))
        valid.append(wire)
        for split in range(len(wire) + 1):
            cases.append(dict(mode=0, chunks=[list(wire[:split]), list(wire[split:])], maximum=4096))
        for end in range(len(wire)):
            cases.append(dict(mode=0, chunks=[list(wire[:end])], maximum=4096))
        cases.append(dict(mode=0, chunks=[[x] for x in wire], maximum=max(0, n-1)))
for _ in range(6000):
    wire = bytearray(rng.choice(valid))
    for _ in range(rng.randint(1, 4)):
        wire[rng.randrange(len(wire))] = rng.randrange(256)
    split = rng.randrange(len(wire)+1)
    cases.append(dict(mode=0, chunks=[list(wire[:split]), list(wire[split:])], maximum=4096))
# Header-boundary errors and real configured maxima, without allocating 128MiB.
for mode in (0, 1):
    for length in (64*1024*1024, 64*1024*1024+1, 0xffffffff):
        wire = (struct.pack('<Q', 1) if mode == 0 else b'') + struct.pack('<HI', 103, length) + (struct.pack('<I', 0) if mode == 0 else b'')
        cases.append(dict(mode=mode, chunks=[list(wire)], maximum=4096))

expected = json.loads(subprocess.run([str(work/'wire-oracle')], input=json.dumps(cases).encode(), stdout=subprocess.PIPE, check=True).stdout)
for index, (case, want) in enumerate(zip(cases, expected, strict=True)):
    handle = wire_create(case['mode'], 64*1024*1024, 128*1024*1024, 4096)
    assert handle
    batch = ptr()
    try:
        for chunk in case['chunks']:
            data = (c.c_uint8 * len(chunk))(*chunk)
            result = wire_append(handle, data, len(chunk))
            if result < 0:
                break
        else:
            result = wire_next(handle, case['maximum'], c.byref(batch))
        got = dict(status=result, messages=[], buffered=wire_buffered(handle))
        if result == 1:
            serial = c.c_uint64()
            if batch_serial(batch, c.byref(serial)) == 1:
                got['serial'] = serial.value
            for i in range(batch_count(batch)):
                kind, data, count = c.c_uint16(), u8p(), size()
                assert batch_message(batch, i, c.byref(kind), c.byref(data), c.byref(count)) == 0
                got['messages'].append(dict(type=kind.value, body=list(c.string_at(data, count.value))))
        assert got == want, (index, case, want, got)
        if result < 0:
            # Repeating malformed parse cannot consume/reallocate the body.
            again = ptr()
            assert wire_next(handle, case['maximum'], c.byref(again)) == result
            assert not again
            assert wire_buffered(handle) == got['buffered']
    finally:
        batch_destroy(batch)
        wire_destroy(handle)
print(json.dumps({'wire_differential_cases': len(cases), 'mutation_cases': 6000, 'oracle': 'unchanged local Swift SpiceWire', 'result': 'passed'}, indent=2))
