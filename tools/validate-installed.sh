#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
PREFIX="${1:-$ROOT_DIR/zig-out}"
WORK_DIR="$ROOT_DIR/.build/installed-consumers"
mkdir -p "$WORK_DIR"
FRAMEWORKS=(MetalKit IOKit AVFAudio AudioToolbox AppKit Security CoreFoundation Foundation Network QuartzCore CoreVideo CoreMedia VideoToolbox IOSurface Metal MetalPerformanceShaders)
FLAGS=()
for framework in "${FRAMEWORKS[@]}"; do FLAGS+=(-framework "$framework"); done
for mode in release sanitized; do
    mkdir -p "$WORK_DIR/$mode"
    INSTRUMENTATION=(-O2)
    if [[ "$mode" == sanitized ]]; then INSTRUMENTATION+=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
    for consumer in abi-consumer ticket-consumer installed-consumer; do
        xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 \
            "${INSTRUMENTATION[@]}" -I "$PREFIX/include" \
            "test/native/$consumer.c" "$PREFIX/lib/libmaspice.a" "${FLAGS[@]}" -lz \
            -o "$WORK_DIR/$mode/$consumer"
        ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$WORK_DIR/$mode/$consumer"
    done
done
# Sanitizer executables intentionally load the compiler runtime. Audit the real
# release consumers for distributable closure, without rewriting load commands.
./tools/audit-dylib-links.sh "$WORK_DIR/release"
echo 'Installed C archive passed Release and ASan/UBSan consumers; library is ReleaseSafe, not sanitizer-instrumented'
