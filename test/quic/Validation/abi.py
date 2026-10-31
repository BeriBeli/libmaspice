#!/usr/bin/env python3
"""Compile one C consumer against upstream quic.h; link it unchanged twice."""
import argparse
import hashlib
import json
import os
import subprocess
import audit
import reference
from audit import BASE, ROOT, SCRATCH


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', action='store_true')
    parser.add_argument('--artifact', action='store_true', help='link the checked-in product archive')
    args = parser.parse_args()
    SCRATCH.mkdir(parents=True, exist_ok=True)
    source = reference.prepare()
    oracle = reference.object_file(args.sanitize)
    flags = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if args.sanitize else []
    suffix = ('-asan' if args.sanitize else '') + ('-artifact' if args.artifact else '')
    consumer = SCRATCH / ('consumer'+suffix+'.o')
    subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    '-O1', '-g', '-I', str(source), '-c', str(BASE/'Validation/abi_consumer.c'),
                    '-o', str(consumer), *flags], check=True)
    adapter = SCRATCH / ('adapter'+suffix+'.o')
    library = SCRATCH / 'abi.a'
    if not args.artifact:
        subprocess.run(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-O2', '-g', '-c', str(ROOT/'pkg/quic/adapter.c'), '-o', str(adapter), *flags], check=True)
        subprocess.run(['zig','build-lib',str(ROOT/'pkg/quic/abi.zig'),'-O','ReleaseSafe',
            '-target','aarch64-macos.26.0','-static','-femit-bin='+str(library),
            '--cache-dir',str(SCRATCH/'cache'),'--global-cache-dir',str(SCRATCH/'global-cache')],check=True)
    product = ROOT/'pkg/apple/artifacts/CSpiceQUIC.xcframework/macos-arm64/CSpiceQUIC.framework/Versions/A/CSpiceQUIC'
    for backend, objects in [('c', [oracle]), ('zig', [product] if args.artifact else [adapter, library])]:
        executable = SCRATCH / ('consumer-'+backend+suffix)
        subprocess.run(['xcrun','clang',str(consumer),*map(str,objects),'-o',str(executable),*flags],check=True)
        subprocess.run([str(executable),str(SCRATCH/(backend+suffix+'.bin')),*(['strict'] if backend=='zig' else [])],check=True, env={**os.environ, 'UBSAN_OPTIONS':'halt_on_error=1:print_stacktrace=1', 'ASAN_OPTIONS':'halt_on_error=1:detect_stack_use_after_return=1'})
    c = (SCRATCH/('c'+suffix+'.bin')).read_bytes()
    z = (SCRATCH/('zig'+suffix+'.bin')).read_bytes()
    if c != z:
        raise RuntimeError('C consumer produced different encoded/decoded bytes')
    report = {'identicalConsumerBytes':len(c),'consumerOutputSHA256':hashlib.sha256(c).hexdigest(),
        'upstreamRevision':reference.REVISION,
        'implementationSHA256':{name:hashlib.sha256((ROOT/'pkg/quic'/name).read_bytes()).hexdigest() for name in ['codec.zig','random.zig','abi.zig','adapter.c','quic.h','shim.h']},'consumerSHA256':hashlib.sha256((BASE/'Validation/abi_consumer.c').read_bytes()).hexdigest(),
        'zigMode':'ReleaseSafe','cAddressAndUndefinedSanitizers':args.sanitize,
        'zigASanInstrumented':False,
        'adapterASanInstrumented':args.sanitize and not args.artifact,
        'artifactSHA256':hashlib.sha256(product.read_bytes()).hexdigest() if args.artifact else None,
        'scope':'same upstream-header C consumer object linked unchanged to C and Zig; pixel/guard, allocator and fatal longjmp checks'}
    (ROOT/'.build/quic-audit'/('c-abi'+suffix+'.json')).write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':
    main()
