#!/usr/bin/env bash
# Compile the parallel Swift compatibility boundary without legacy Swift modules.
set -euo pipefail
# Report the actual configuration selected by this build driver.
export SWIFTSPICE_TEST_BUILD=swift-boundary-asan
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-swift.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/swift-boundary"
mkdir -p "$WORK_DIR"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --find clang)"
CLANG_RUNTIME="$($CLANG -print-resource-dir)/lib/darwin"
zig build-lib src/desktop_abi.zig -static -lc -fcompiler-rt -O ReleaseSafe -target aarch64-macos.26.0 \
    --cache-dir "$WORK_DIR/zig-cache" --global-cache-dir "$WORK_DIR/zig-global-cache" -femit-bin="$WORK_DIR/libdesktop.a"
zig build-lib src/host_view_native.zig -static -lc -fcompiler-rt -O ReleaseSafe -target aarch64-macos.26.0 \
    --cache-dir "$WORK_DIR/zig-cache" --global-cache-dir "$WORK_DIR/zig-global-cache" -femit-bin="$WORK_DIR/libhost.a"
RESOURCE_DIR="$WORK_DIR/SwiftSpice_SwiftSpice.bundle/Contents/Resources"
mkdir -p "$RESOURCE_DIR"
sh bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh resources/shaders/compositor.metal "$WORK_DIR/compositor.air" "$RESOURCE_DIR/SpiceZigCompositor.metallib"
sh bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh resources/shaders/presentation.metal "$WORK_DIR/presentation.air" "$RESOURCE_DIR/SpiceZigPresentation.metallib"
python3 - "$RESOURCE_DIR" <<'PYRESOURCE'
import plistlib,sys
from pathlib import Path
Path(sys.argv[1]).parent.joinpath('Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.swiftspice.boundary-resources','CFBundlePackageType':'BNDL'}))
PYRESOURCE
OBJECTS=()
for source in network_bridge.m security.c video_bridge.m graphics_bridge.m pasteboard_bridge.m audio_bridge.m webdav_bridge.m codec_bridge.c host_view_bridge.m; do
    OBJECT="$WORK_DIR/${source%.*}.o"
    "$CLANG" -Wall -Wextra -Werror -arch arm64 -isysroot "$SDK" -mmacosx-version-min=26.0 -I include \
        -fsanitize=address,undefined -fno-omit-frame-pointer -g -fobjc-arc -fblocks \
        -I include -I pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Headers \
        -c "src/platform/apple/$source" -o "$OBJECT"
    OBJECTS+=("$OBJECT")
done
SWIFT_FLAGS=(-swift-version 6 -strict-concurrency=complete -warnings-as-errors -package-name SwiftSpice -target arm64-apple-macos26.0 -module-cache-path "$WORK_DIR/swift-cache" -sanitize=address)
swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -emit-library -emit-module -module-name SwiftSpice \
    -emit-module-path "$WORK_DIR/SwiftSpice.swiftmodule" -I include bindings/swift/SpiceZigSwift/*.swift \
    "${OBJECTS[@]}" "$WORK_DIR/libhost.a" "$WORK_DIR/libdesktop.a" \
    -F pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64 -framework CTurboJPEG \
    -F pkg/apple/artifacts/CSpiceQUIC.xcframework/macos-arm64 -framework CSpiceQUIC \
    -F pkg/apple/artifacts/CUSBRedir.xcframework/macos-arm64 -framework CUSBRedir \
    -framework SwiftUI -framework MetalKit -framework IOKit -framework AVFAudio -framework AudioToolbox -framework AppKit -framework Security \
    -framework CoreFoundation -framework Foundation -framework Network -framework QuartzCore \
    -framework CoreVideo -framework CoreMedia -framework VideoToolbox -framework IOSurface -framework Metal -framework MetalPerformanceShaders -lz \
    -L "$CLANG_RUNTIME" -lclang_rt.ubsan_osx_dynamic \
    -o "$WORK_DIR/libSwiftSpice.dylib"
for consumer in session native view audio agent usb webdav; do
    swiftc "${SWIFT_FLAGS[@]}" -parse-as-library -I "$WORK_DIR" -I include -L "$WORK_DIR" -lSwiftSpice \
        -Xlinker -rpath -Xlinker "$WORK_DIR" "test/native/swift-$consumer-consumer.swift" -o "$WORK_DIR/$consumer-consumer"
done
export ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1
python3 test/native/swift-session-integration.py "$ROOT_DIR/.build/zig-migration" | tee "$WORK_DIR/session-integration.json"
python3 test/native/swift-native-integration.py "$ROOT_DIR/.build/zig-migration" | tee "$WORK_DIR/native-integration.json"
"$WORK_DIR/view-consumer" | tee "$WORK_DIR/view-integration.log"

python3 test/native/swift-audio-integration.py "$ROOT_DIR/.build/zig-migration" | tee "$WORK_DIR/audio-integration.json"

python3 test/native/swift-agent-integration.py "$ROOT_DIR/.build/zig-migration" | tee "$WORK_DIR/agent-integration.json"

python3 test/native/swift-usb-integration.py "$ROOT_DIR/.build/zig-migration" | tee "$WORK_DIR/usb-integration.json"

python3 test/native/swift-webdav-integration.py "$ROOT_DIR/.build/zig-migration" | tee "$WORK_DIR/webdav-integration.json"
