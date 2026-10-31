#!/usr/bin/env bash
# Independent Swift histogram, trace record and pixel marker contracts.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-diagnostics.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/diagnostics"
mkdir -p "$WORK_DIR"
zig test -lc -O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" \
 --dep spice -Mroot=test/native/diagnostics_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig build-lib -dynamic -lc -O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" \
 --dep spice -Mroot=test/native/diagnostics_fixture.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig -femit-bin="$WORK_DIR/libdiagnostics-fixture.dylib"
python3 test/native/diagnostics-differential.py "$WORK_DIR" | tee "$WORK_DIR/differential.json"
