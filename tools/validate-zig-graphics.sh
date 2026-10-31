#!/usr/bin/env bash
# Local native graphics acceptance gate; requires an actual Apple Metal device.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
WORK_DIR="$ROOT_DIR/.build/zig-migration"
mkdir -p "$WORK_DIR"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -fobjc-arc -fblocks -c src/platform/apple/graphics_bridge.m -o "$WORK_DIR/graphics_bridge.o"
sh bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh \
  resources/shaders/compositor.metal \
  "$WORK_DIR/compositor.air" "$WORK_DIR/compositor.metallib"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -I pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Headers \
  -c src/platform/apple/codec_bridge.c -o "$WORK_DIR/codec_bridge.o"
sh bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh resources/shaders/presentation.metal "$WORK_DIR/presentation.air" "$WORK_DIR/presentation.metallib"
export SPICE_ZIG_TEST_PRESENTATION_METALLIB="$WORK_DIR/presentation.metallib"
export SPICE_ZIG_TEST_METALLIB="$WORK_DIR/compositor.metallib"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -fobjc-arc -fblocks -c test/native/graphics_probe.m -o "$WORK_DIR/graphics_probe.o"
zig test "$WORK_DIR/graphics_bridge.o" "$WORK_DIR/graphics_probe.o" "$WORK_DIR/codec_bridge.o" \
  -F pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64 -framework CTurboJPEG \
  -F pkg/apple/artifacts/CSpiceQUIC.xcframework/macos-arm64 -framework CSpiceQUIC -lc -lz \
  -F "$SDK_PATH/System/Library/Frameworks" -L "$SDK_PATH/usr/lib" \
  -framework QuartzCore -framework CoreVideo -framework Foundation -framework IOSurface -framework Metal -framework MetalPerformanceShaders \
  --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" \
  -O ReleaseSafe -target aarch64-macos.26.0 \
  --dep spice -Mroot=test/native/graphics_tests.zig \
  -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig \
  2>&1 | tee "$WORK_DIR/graphics-tests.log"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -fobjc-arc -fblocks --analyze -Xanalyzer -analyzer-output=text src/platform/apple/graphics_bridge.m

swiftc -parse-as-library -warnings-as-errors -module-cache-path "$WORK_DIR/swift-cache" \
  test/native/mps-reference.swift -o "$WORK_DIR/mps-reference"
zig build-lib "$WORK_DIR/graphics_bridge.o" -dynamic -lc \
  -F "$SDK_PATH/System/Library/Frameworks" -L "$SDK_PATH/usr/lib" \
  -framework QuartzCore -framework CoreVideo -framework Foundation -framework IOSurface -framework Metal -framework MetalPerformanceShaders \
  --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" \
  -O ReleaseSafe -target aarch64-macos.26.0 --dep spice -Mroot=test/native/graphics_fixture.zig \
  -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig \
  -femit-bin="$WORK_DIR/libgraphics-fixture.dylib"
python3 test/native/graphics-differential.py "$WORK_DIR" | tee "$WORK_DIR/graphics-differential.json"
python3 test/native/damage-differential.py "$WORK_DIR" | tee "$WORK_DIR/damage-differential.json"

xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -fsanitize=address,undefined -fno-omit-frame-pointer -g -fobjc-arc -fblocks \
  -I include -I pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Headers \
  test/native/graphics-consumer.c src/platform/apple/graphics_bridge.m src/platform/apple/codec_bridge.c \
  -F pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64 -framework CTurboJPEG \
  -F pkg/apple/artifacts/CSpiceQUIC.xcframework/macos-arm64 -framework CSpiceQUIC \
  -framework QuartzCore -framework CoreVideo -framework Foundation -framework IOSurface -framework Metal -framework MetalPerformanceShaders \
  -o "$WORK_DIR/graphics-consumer"
"$WORK_DIR/graphics-consumer" "$SPICE_ZIG_TEST_METALLIB" "$SPICE_ZIG_TEST_PRESENTATION_METALLIB" | tee "$WORK_DIR/graphics-sanitizers.log"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -I pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Headers \
  --analyze -Xanalyzer -analyzer-output=text src/platform/apple/codec_bridge.c
