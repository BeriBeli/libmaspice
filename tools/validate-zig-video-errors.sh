#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-video-errors.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/video-errors"
mkdir -p "$WORK_DIR"
ZIG_FLAGS=(-O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache")
zig test "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/video_failure_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig build-lib -fcompiler-rt "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/video_failure_fixture.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig -femit-bin="$WORK_DIR/libfixture.a"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include -fsanitize=address,undefined -fno-omit-frame-pointer -g test/native/video-failure-native.c "$WORK_DIR/libfixture.a" -o "$WORK_DIR/compatibility"
ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$WORK_DIR/compatibility"
