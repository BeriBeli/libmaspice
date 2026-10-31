#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-native-presentation.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/native-presentation"
mkdir -p "$WORK_DIR"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
FLAGS=(-std=c17 -Wall -Wextra -Werror -arch arm64 -isysroot "$SDK_PATH" -mmacosx-version-min=26.0 -I include -fobjc-arc -fblocks -I include)
sh bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh resources/shaders/compositor.metal "$WORK_DIR/compositor.air" "$WORK_DIR/compositor.metallib"
sh bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh resources/shaders/presentation.metal "$WORK_DIR/presenter.air" "$WORK_DIR/presenter.metallib"
xcrun clang "${FLAGS[@]}" -fsanitize=address,undefined -fno-omit-frame-pointer -g test/native/presentation-observer-native.m src/platform/apple/graphics_bridge.m -framework AppKit -framework QuartzCore -framework Metal -framework MetalKit -framework MetalPerformanceShaders -framework IOSurface -framework CoreVideo -o "$WORK_DIR/observer-native"
ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$WORK_DIR/observer-native" "$WORK_DIR/compositor.metallib" "$WORK_DIR/presenter.metallib"
xcrun clang "${FLAGS[@]}" --analyze src/platform/apple/graphics_bridge.m -o "$WORK_DIR/graphics-analysis.plist"
python3 - "$WORK_DIR/graphics-analysis.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f:assert not plistlib.load(f)['diagnostics']
PY
