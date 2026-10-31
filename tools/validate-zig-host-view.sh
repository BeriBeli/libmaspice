#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 || ( "$#" -eq 1 && "$1" == --core ) ]] || { echo 'usage: validate-zig-host-view.sh [--core]' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/host-view"
mkdir -p "$WORK_DIR"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include -fobjc-arc -fblocks -c src/platform/apple/graphics_bridge.m -o "$WORK_DIR/graphics.o"
zig test "$WORK_DIR/graphics.o" -lc -F "$SDK_PATH/System/Library/Frameworks" -L "$SDK_PATH/usr/lib" \
  -framework QuartzCore -framework CoreVideo -framework Foundation -framework IOSurface -framework Metal -framework MetalPerformanceShaders \
  --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" -O ReleaseSafe -target aarch64-macos.26.0 \
  --dep spice -Mroot=test/native/host_view_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
[[ "${1:-}" != --core ]] || exit 0
FLAGS=(-std=c17 -Wall -Wextra -Werror -arch arm64 -isysroot "$SDK_PATH" -mmacosx-version-min=26.0 -I include -fobjc-arc -fblocks -I include)
zig build-lib -lc -fcompiler-rt -O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" src/host_view_native.zig -femit-bin="$WORK_DIR/libhost.a"
zig build-lib -lc -fcompiler-rt -O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" --dep spice -Mroot=test/native/host_view_native_fixture.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig -femit-bin="$WORK_DIR/libfixture.a"
sh bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh resources/shaders/compositor.metal "$WORK_DIR/compositor.air" "$WORK_DIR/compositor.metallib"
sh bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh resources/shaders/presentation.metal "$WORK_DIR/presenter.air" "$WORK_DIR/presenter.metallib"
xcrun clang "${FLAGS[@]}" -fsanitize=address,undefined -fno-omit-frame-pointer -g test/native/host-view-native.m src/platform/apple/host_view_bridge.m src/platform/apple/graphics_bridge.m "$WORK_DIR/libhost.a" "$WORK_DIR/libfixture.a" -framework AppKit -framework QuartzCore -framework Metal -framework MetalKit -framework MetalPerformanceShaders -framework IOSurface -framework CoreVideo -o "$WORK_DIR/host-native"
SPICE_ZIG_HOST_CAPTURE="$WORK_DIR/cpu.png" ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 "$WORK_DIR/host-native" "$WORK_DIR/compositor.metallib" "$WORK_DIR/presenter.metallib"
xcrun clang "${FLAGS[@]}" --analyze src/platform/apple/host_view_bridge.m -o "$WORK_DIR/host-analysis.plist"
python3 - "$WORK_DIR/host-analysis.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f:assert not plistlib.load(f)['diagnostics']
PY
