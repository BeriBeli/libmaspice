#!/usr/bin/env python3
"""Independent C-encoded functional audit; optional pre-optimization Zig source."""
import argparse
import ctypes as ct
import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess
import sys
import reference

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / "test/quic"
SCRATCH = ROOT / ".build/quic-audit"
SEED = 0x71E45706


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def build_zig(source, name):
    output = SCRATCH / (name + ".dylib")
    subprocess.run([
        "zig", "build-lib", str(source), "-O", "ReleaseSafe", "-target",
        "aarch64-macos.26.0", "-dynamic", "-femit-bin=" + str(output),
        "--cache-dir", str(SCRATCH / "cache"),
        "--global-cache-dir", str(SCRATCH / "global-cache"),
    ], check=True)
    return output


def build_reference():
    wrapper = SCRATCH / "reference.c"
    wrapper.write_text('''#include <quic/shim.h>
int audit_decode(const uint8_t *p, size_t n, size_t w, size_t h,
                 uint8_t *o, size_t z) {
    int type, width, height;
    return spice_swift_quic_decode(p, n, (int)w, (int)h, o, z,
                                  &type, &width, &height);
}
void audit_free(void *p) { free(p); }
''')
    output = SCRATCH / "reference.dylib"
    subprocess.run([
        "xcrun", "clang", "-dynamiclib", "-O2", "-mmacosx-version-min=26.0",
        str(wrapper), str(BASE / "Reference/QUICReference.c"),
        "-I", str(BASE / "Reference/include"),
        "-I", str(ROOT / "pkg"), str(reference.object_file()), "-o", str(output),
    ], check=True)
    return ct.CDLL(str(output))


def build_production():
    output = SCRATCH / "production.dylib"
    subprocess.run([
        "xcrun", "clang", "-dynamiclib", "-O2", "-mmacosx-version-min=26.0",
        str(SCRATCH / "reference.c"), "-I", str(ROOT / "pkg"),
        str(ROOT / "pkg/apple/artifacts/CSpiceQUIC.xcframework/macos-arm64/CSpiceQUIC.framework/Versions/A/CSpiceQUIC"),
        "-o", str(output),
    ], check=True)
    return ct.CDLL(str(output))


def decoder(library, name):
    function = getattr(library, name)
    function.argtypes = [ct.c_void_p, ct.c_size_t, ct.c_size_t, ct.c_size_t,
                         ct.c_void_p, ct.c_size_t]
    function.restype = ct.c_int
    return function


def decode(function, payload, width, height):
    size = width * height * 4
    output = ct.create_string_buffer(b'\xa5' * 32 + b'\0' * size + b'\xa5' * 32)
    status = function(payload, len(payload), width, height, ct.byref(output, 32), size)
    require(output.raw[:32] == b'\xa5' * 32 and
            output.raw[32 + size:64 + size] == b'\xa5' * 32, "output guard changed")
    return status, output.raw[32:32 + size] if status == 0 else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, help="old quic.zig, with random.zig beside it")
    args = parser.parse_args()
    SCRATCH.mkdir(parents=True, exist_ok=True)
    source = ROOT / "pkg/quic/codec.zig"
    current = ct.CDLL(str(build_zig(source.with_name("experiment.zig"), "current")))
    current_decode = decoder(current, "zig_quic_decode")
    old_decode = None
    if args.baseline:
        baseline = ct.CDLL(str(build_zig(args.baseline.resolve(), "baseline")))
        old_decode = decoder(baseline, "zig_quic_decode")
    reference = build_reference()
    c_decode = decoder(reference, "audit_decode")
    production_decode = decoder(build_production(), "audit_decode")
    encode = reference.quic_reference_encode
    encode.argtypes = [ct.c_int, ct.c_int, ct.c_int, ct.c_void_p, ct.c_size_t,
                       ct.POINTER(ct.c_void_p), ct.POINTER(ct.c_size_t)]
    encode.restype = ct.c_int
    reference.audit_free.argtypes = [ct.c_void_p]
    rng = random.Random(SEED)
    counts = {"validImages": 0, "truncatedInputs": 0, "mutatedInputs": 0,
              "acceptedMutations": 0}
    # New seeds and dimensions; first rows span all adaptation windows, and
    # tall one-pixel images exercise the specialized row/column boundaries.
    boundary_sizes = [(1, 16384), (16384, 1), (16384, 3), (2047, 7),
                      (2048, 7), (2049, 7), (4097, 5), (127, 129)]
    mutation_seeds = []
    for kind in range(1, 6):
        sizes = boundary_sizes + [(rng.randint(1, 96), rng.randint(1, 96)) for _ in range(48)]
        for case, (width, height) in enumerate(sizes):
            for pattern in range(3):
                expected = bytearray(rng.randbytes(width * height * 4))
                for y in range(height):
                    for x in range(width):
                        i = (y * width + x) * 4
                        if pattern == 1:
                            # Long runs interrupted by sharp changes, including
                            # changes around the 2048-symbol adaptation boundary.
                            value = ((x // 2047 + y // 2) * 97) & 255
                            expected[i:i+4] = bytes([value, value ^ 85, value ^ 170, (x + y) & 255])
                        elif pattern == 2:
                            # Independent alpha runs with nonconstant RGB.
                            expected[i:i+4] = bytes([(x + y * 13) & 255, (x * 3 + y) & 255,
                                                     (x * 7 + y * 5) & 255, (y // 3 * 83) & 255])
                        if kind == 1:
                            expected[i+1:i+3] = bytes([expected[i], expected[i]])
                        if kind == 2:
                            for c in range(3):
                                value = expected[i+c] >> 3
                                expected[i+c] = (value << 3) | (value >> 2)
                        if kind != 5:
                            expected[i+3] = 0
                expected = bytes(expected)
                pointer, count = ct.c_void_p(), ct.c_size_t()
                require(encode(kind, width, height, expected, len(expected),
                               ct.byref(pointer), ct.byref(count)) == 0, "C encoding failed")
                try:
                    payload = ct.string_at(pointer, count.value)
                finally:
                    reference.audit_free(pointer)
                label = f"type={kind}, {width}x{height}, pattern={pattern}"
                require(decode(c_decode, payload, width, height) == (0, expected), "C oracle: " + label)
                require(decode(current_decode, payload, width, height) == (0, expected), "Zig: " + label)
                require(decode(production_decode, payload, width, height) == (0, expected), "production: " + label)
                if old_decode:
                    require(decode(old_decode, payload, width, height) == (0, expected), "baseline: " + label)
                counts["validImages"] += 1
                # Trailing padding can be redundant; compare acceptance and
                # all successful pixels instead of assuming every cut is invalid.
                cuts = {0, 20, max(0, len(payload)-4), len(payload)//2, len(payload)-1}
                for cut in cuts:
                    shortened = payload[:cut]
                    after = decode(current_decode, shortened, width, height)
                    product = decode(production_decode, shortened, width, height)
                    require((after[0] == 0, after[1]) == (product[0] == 0, product[1]), "production truncation: " + label)
                    if old_decode:
                        require(after == decode(old_decode, shortened, width, height), "truncation regression: " + label)
                    counts["truncatedInputs"] += 1
                if case == 8:
                    mutation_seeds.append((payload, width, height))
        print(f"format {kind}: passed", file=sys.stderr, flush=True)
    # Never feed arbitrary malformed bodies into the C oracle: the complete
    # ABI and bounded validation entry points must agree and preserve guards.
    # Optional historical-source comparison also checks exact legacy statuses.
    for iteration in range(20000):
        payload, width, height = mutation_seeds[iteration % len(mutation_seeds)]
        data = bytearray(payload)
        if iteration % 2:
            data = data[:20] + bytearray(rng.randbytes(4 * rng.randint(1, 256)))
        else:
            for _ in range(rng.randint(1, 5)):
                index = rng.randrange(20, len(data))
                data[index] ^= 1 << rng.randrange(8)
        after = decode(current_decode, bytes(data), width, height)
        product = decode(production_decode, bytes(data), width, height)
        require((after[0] == 0, after[1]) == (product[0] == 0, product[1]), f"production mutation {iteration}")
        if old_decode:
            require(after == decode(old_decode, bytes(data), width, height), f"mutation regression {iteration}")
        counts["mutatedInputs"] += 1
        counts["acceptedMutations"] += after[0] == 0
    report = {"seed": SEED, "buildMode": "ReleaseSafe", **counts,
              "zigSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
              "auditSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "baselineSHA256": hashlib.sha256(args.baseline.read_bytes()).hexdigest() if args.baseline else None,
              "scope": "Independent C-encoded full pixels in five formats; production artifact versus bounded Zig entry point on truncation/mutations; guarded outputs; optional exact legacy comparison. Not exhaustive fuzzing."}
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
