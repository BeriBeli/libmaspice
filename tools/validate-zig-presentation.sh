#!/usr/bin/env bash
# Desktop aggregation and platform-independent presentation policies.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-presentation.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/presentation"
mkdir -p "$WORK_DIR"
ZIG_SDK_PATH="$(xcrun --show-sdk-path)"
CLANG="$(xcrun --find clang)"
"$CLANG" -std=c17 -Wall -Wextra -Werror -arch arm64 -isysroot "$ZIG_SDK_PATH" -mmacosx-version-min=26.0 -I include -I include -fobjc-arc -fblocks -c src/platform/apple/graphics_bridge.m -o "$WORK_DIR/graphics_bridge.o"
zig test "$WORK_DIR/graphics_bridge.o" -lc -O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" \
  -F "$ZIG_SDK_PATH/System/Library/Frameworks" -L "$ZIG_SDK_PATH/usr/lib" \
  -framework Foundation -framework CoreVideo -framework IOSurface -framework Metal -framework QuartzCore -framework MetalPerformanceShaders \
  --dep spice -Mroot=test/native/desktop_presentation_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig build-lib -dynamic -lc -O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" \
  --dep spice -Mroot=test/native/presentation_policy_fixture.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig -femit-bin="$WORK_DIR/libpolicy-fixture.dylib"
python3 test/native/presentation-policy-differential.py "$WORK_DIR" | tee "$WORK_DIR/policy-differential.json"
