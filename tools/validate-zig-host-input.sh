#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-host-input.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/host-input"
mkdir -p "$WORK_DIR"
FLAGS=(-lc -O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache")
zig test "${FLAGS[@]}" --dep spice -Mroot=test/native/host_input_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig build-lib -dynamic "${FLAGS[@]}" --dep spice -Mroot=test/native/host_input_fixture.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig -femit-bin="$WORK_DIR/libhost-input-fixture.dylib"
python3 test/native/host-input-differential.py "$WORK_DIR" | tee "$WORK_DIR/differential.json"
