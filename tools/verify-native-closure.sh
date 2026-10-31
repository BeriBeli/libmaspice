#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--artifacts-only" ) ]]; then
    echo "usage: verify-native-closure.sh [--artifacts-only]" >&2
    exit 2
fi

fail=0
check_macho() {
    local binary="$1"
    local architectures
    local file_kind
    file_kind="$(file "$binary")"
    # Static archives have no dyld load commands, but release inputs must still
    # be Apple Silicon-only so an Intel slice cannot re-enter the product.
    # A static framework's executable has no .a suffix, so inspect its file kind.
    if [[ "$binary" == *.a || "$file_kind" == *"current ar archive"* ]]; then
        local archive_architectures
        archive_architectures="$(lipo -archs "$binary" 2>/dev/null || true)"
        if [[ "$archive_architectures" != "arm64" ]]; then
            echo "error: expected an arm64-only static archive, got '$archive_architectures': $binary" >&2
            fail=1
        fi
        return
    fi
    if [[ "$file_kind" != *"Mach-O"* ]]; then
        return
    fi
    architectures="$(lipo -archs "$binary" 2>/dev/null || true)"
    if [[ "$architectures" != "arm64" ]]; then
        echo "error: expected an arm64-only Mach-O, got '$architectures': $binary" >&2
        fail=1
    fi
}

while IFS= read -r -d '' artifact; do
    check_macho "$artifact"
done < <(find "$ROOT_DIR/pkg/apple/artifacts" -type f -print0 2>/dev/null)
# These are the exact-quality decode kernels used by our arm64 JPEG/MJPEG
# boundary. Prevent a scalar-only rebuild from silently replacing the artifact.
jpeg_archive="$ROOT_DIR/pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Versions/A/CTurboJPEG"
jpeg_symbols="$(nm -gUj "$jpeg_archive")"
for module in CTurboJPEG CSpiceQUIC CUSBRedir; do
    archive="$ROOT_DIR/pkg/apple/artifacts/$module.xcframework/macos-arm64/$module.framework/Versions/A/$module"
    provenance="$ROOT_DIR/pkg/apple/artifacts/$module.xcframework/BUILD_PROVENANCE.txt"
    expected_hash="$(awk '/^Archive SHA-256: / {print $3}' "$provenance")"
    actual_hash="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [[ "$expected_hash" != "$actual_hash" ]]; then
        echo "error: $module archive does not match its build provenance" >&2
        fail=1
    fi
done
# The core archive is source-bound, not an opaque unverified local build.
python3 - "$ROOT_DIR" <<'PYZIG'
import hashlib,re,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]);base=root/'pkg/apple/artifacts/CSpiceZig.xcframework'
manifest=(base/'BUILD_PROVENANCE.txt').read_text().splitlines()
archive=base/'macos-arm64/CSpiceZig.framework/Versions/A/CSpiceZig'
expected=next(line.removeprefix('Archive SHA-256: ') for line in manifest if line.startswith('Archive SHA-256: '))
assert hashlib.sha256(archive.read_bytes()).hexdigest()==expected, 'CSpiceZig archive hash mismatch'
owned={}
for line in manifest:
 if line.startswith('Owned source SHA-256: '):
  digest,path=line.removeprefix('Owned source SHA-256: ').split(' ',1)
  owned[path]=digest
sys.path.insert(0,str(root/'tools'))
import importlib.util
spec=importlib.util.spec_from_file_location('packager',root/'tools/package-apple.py');packager=importlib.util.module_from_spec(spec);spec.loader.exec_module(packager)
required={str(p) for p in packager.core_inputs()}
assert set(owned)==required, 'CSpiceZig source manifest incomplete'
for path,digest in owned.items():
 assert hashlib.sha256((root/path).read_bytes()).hexdigest()==digest, f'CSpiceZig source changed; run tools/build-zig-native.sh: {path}'
for license in ['SwiftSpice-MIT','Zig-MIT']:
 assert (base/'Licenses'/license).stat().st_size>0
headers=base/'macos-arm64/CSpiceZig.framework/Versions/A/Headers'
for source in (root/'include').glob('*.h'):
 assert source.read_bytes()==(headers/source.name).read_bytes(), f'stale native header: {source.name}'
module=base/'macos-arm64/CSpiceZig.framework/Versions/A/Modules/module.modulemap'
assert module.read_text()==(root/'include/module.modulemap').read_text().replace('module CSpiceZig','framework module CSpiceZig',1)
commands=subprocess.check_output(['otool','-l',str(archive)],text=True)
versions=re.findall(r'\bminos (\d+(?:\.\d+)*)',commands)
assert versions and all(tuple(map(int,v.split('.'))) <= (26,0,0) for v in versions), 'core archive raises macOS deployment target'
# All dependency artifacts carry complete license files and compatible targets.
for name in ['CSpiceQUIC','CTurboJPEG','CUSBRedir']:
 dependency=root/'pkg/apple/artifacts'/(name+'.xcframework')
 assert any(p.is_file() and p.stat().st_size>0 for p in (dependency/'Licenses').iterdir()), name+' licenses missing'
 binary=dependency/'macos-arm64'/(name+'.framework')/'Versions/A'/name
 commands=subprocess.check_output(['otool','-l',str(binary)],text=True)
 versions=re.findall(r'\bminos (\d+(?:\.\d+)*)',commands)
 assert versions and all(tuple(map(int,v.split('.'))) <= (26,0,0) for v in versions), name+' deployment target raised'
assert (root/'pkg/quic/COPYING').read_bytes()==(root/'pkg/apple/artifacts/CSpiceQUIC.xcframework/Licenses/spice-common-COPYING').read_bytes()
print('Zig core archive, headers, deployment target and source provenance verified')
PYZIG
quic_archive="$ROOT_DIR/pkg/apple/artifacts/CSpiceQUIC.xcframework/macos-arm64/CSpiceQUIC.framework/Versions/A/CSpiceQUIC"
quic_provenance="$ROOT_DIR/pkg/apple/artifacts/CSpiceQUIC.xcframework/BUILD_PROVENANCE.txt"
quic_symbols="$(nm -gUj "$quic_archive")"
for symbol in _quic_create _quic_destroy _quic_encode _quic_decode_begin _quic_decode _spice_quic_zig_decode; do
    if ! /usr/bin/grep -qx "$symbol" <<<"$quic_symbols"; then
        echo "error: missing QUIC ABI/implementation symbol: $symbol" >&2
        fail=1
    fi
done
if /usr/bin/grep -q '^_zig_quic_' <<<"$quic_symbols"; then
    echo "error: experimental QUIC ABI leaked into the production artifact" >&2
    fail=1
fi
source_count=0
while read -r expected_hash source; do
    source_count=$((source_count + 1))
    actual_hash="$(shasum -a 256 "$ROOT_DIR/$source" | awk '{print $1}')"
    if [[ "$expected_hash" != "$actual_hash" ]]; then
        echo "error: QUIC artifact source changed; rebuild with tools/build-quic-native.sh: $source" >&2
        fail=1
    fi
done < <(awk '/^Owned source SHA-256: / {print $4, $5}' "$quic_provenance")
if [[ "$source_count" -ne 8 ]]; then
    echo "error: incomplete QUIC source provenance" >&2
    fail=1
fi
for symbol in _jsimd_idct_islow_neon _jsimd_h2v2_fancy_upsample_neon _jsimd_ycc_extbgrx_convert_neon; do
    if ! /usr/bin/grep -qx "$symbol" <<<"$jpeg_symbols"; then
        echo "error: missing JPEG Neon kernel: $symbol" >&2
        fail=1
    fi
done
"$ROOT_DIR/tools/audit-dylib-links.sh" "$ROOT_DIR/pkg/apple/artifacts"

if [[ "$fail" -ne 0 ]]; then
    exit 1
fi
echo "Relocatable native artifact closure verified"
