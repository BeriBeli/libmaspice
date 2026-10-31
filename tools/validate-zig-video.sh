#!/usr/bin/env bash
# Actual Apple hardware decode required; not a software fallback or remote gate.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-video.sh' >&2; exit 2; }
[[ "$(zig version)" == '0.17.0' ]] || { echo 'Zig 0.17.0 required' >&2; exit 1; }
WORK_DIR="$ROOT_DIR/.build/zig-migration"
mkdir -p "$WORK_DIR"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -fobjc-arc -fblocks -c src/platform/apple/video_bridge.m -o "$WORK_DIR/video_bridge.o"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -fobjc-arc -fblocks -c src/platform/apple/graphics_bridge.m -o "$WORK_DIR/graphics_bridge.o"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -fobjc-arc -fblocks -c test/native/video_probe.m -o "$WORK_DIR/video_probe.o"
sh bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh resources/shaders/compositor.metal "$WORK_DIR/compositor.air" "$WORK_DIR/compositor.metallib"
zig build-lib "$WORK_DIR/video_bridge.o" "$WORK_DIR/graphics_bridge.o" "$WORK_DIR/video_probe.o" -dynamic -lc \
  -F "$SDK_PATH/System/Library/Frameworks" -L "$SDK_PATH/usr/lib" \
  -framework IOSurface -framework Metal -framework QuartzCore -framework MetalPerformanceShaders -framework Foundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
  --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" \
  -O ReleaseSafe -target aarch64-macos.26.0 --dep spice -Mroot=test/native/video_fixture.zig \
  -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig \
  -femit-bin="$WORK_DIR/libvideo-fixture.dylib"
swiftc -parse-as-library -warnings-as-errors -package-name SwiftSpice -module-cache-path "$WORK_DIR/swift-cache" \
  -emit-library -emit-module -module-name SpiceCodecs test/oracle/swift/SpiceCodecs/SpiceImageDecoder.swift test/oracle/swift/SpiceCodecs/AdvancedVideoDecoder.swift \
  -emit-module-path "$WORK_DIR/SpiceCodecs.swiftmodule" -o "$WORK_DIR/libSpiceCodecs.dylib"
swiftc -parse-as-library -warnings-as-errors -package-name SwiftSpice -module-cache-path "$WORK_DIR/swift-cache" \
  -I "$WORK_DIR" -L "$WORK_DIR" -lSpiceCodecs -Xlinker -rpath -Xlinker "$WORK_DIR" \
  test/oracle/swift/SpiceVideoToolbox/VideoToolboxDecoder.swift test/native/video-oracle.swift -o "$WORK_DIR/video-oracle"
python3 test/native/video-integration.py "$WORK_DIR" | tee "$WORK_DIR/video-integration.json"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -fobjc-arc -fblocks --analyze -Xanalyzer -analyzer-output=text src/platform/apple/video_bridge.m

xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -fobjc-arc -fblocks -Dspice_zig_video_hardware=video_native_hardware -Dspice_zig_video_session=video_native_session \
  -c src/platform/apple/video_bridge.m -o "$WORK_DIR/video_policy_bridge.o"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -c test/native/video_failures.c -o "$WORK_DIR/video_failures.o"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -I pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Headers \
  -c src/platform/apple/codec_bridge.c -o "$WORK_DIR/codec_bridge.o"
export SPICE_ZIG_TEST_METALLIB="$WORK_DIR/compositor.metallib"
zig test "$WORK_DIR/video_policy_bridge.o" "$WORK_DIR/video_failures.o" "$WORK_DIR/graphics_bridge.o" "$WORK_DIR/video_probe.o" "$WORK_DIR/codec_bridge.o" -lc \
  -F pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64 -framework CTurboJPEG \
  -F pkg/apple/artifacts/CSpiceQUIC.xcframework/macos-arm64 -framework CSpiceQUIC \
  -F "$SDK_PATH/System/Library/Frameworks" -L "$SDK_PATH/usr/lib" \
  -framework IOSurface -framework Metal -framework QuartzCore -framework MetalPerformanceShaders -framework Foundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
  --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" \
  -O ReleaseSafe -target aarch64-macos.26.0 --dep spice --dep video_data -Mroot=test/native/video_tests.zig \
  -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig -Mvideo_data="$WORK_DIR/video_data.zig" \
  2>&1 | tee "$WORK_DIR/video-tests.log"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
  -fsanitize=address,undefined -fno-omit-frame-pointer -g -fobjc-arc -fblocks -I include \
  test/native/video-consumer.c src/platform/apple/video_bridge.m src/platform/apple/graphics_bridge.m \
  -framework IOSurface -framework Metal -framework QuartzCore -framework MetalPerformanceShaders -framework Foundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox \
  -o "$WORK_DIR/video-consumer"
"$WORK_DIR/video-consumer" "$WORK_DIR/compositor.metallib" "$WORK_DIR/h264-baseline-128x128.native" "$WORK_DIR/h264-high-128x128.native" "$WORK_DIR/h265-main-128x128.native" \
  | tee "$WORK_DIR/video-sanitizers.log"

python3 - <<'PY_EVIDENCE'
import hashlib,json
from pathlib import Path
work=Path('.build/zig-migration')
paths=[*Path('src').rglob('*'),*Path('include').glob('*'),*Path('resources/shaders').glob('*'),*Path('test/native').glob('video*'),Path('test/native/scheduler_tests.zig'),Path('tools/validate-zig-video.sh')]
report={'result':'passed','configuration':'Zig 0.17.0 ReleaseSafe, arm64/macOS 26 target, actual local Apple hardware','integration':json.loads((work/'video-integration.json').read_text()),'native_sanitizers':(work/'video-sanitizers.log').read_text().strip(),'source_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()},'oracle_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path('test/oracle/swift/SpiceVideoToolbox/VideoToolboxDecoder.swift'),Path('test/oracle/swift/SpiceCodecs/AdvancedVideoDecoder.swift')]},'fixture_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in Path('test/fixtures/SpiceVideoToolboxTests').glob('*.json')},'not_claimed':['Zig ASan instrumentation','real SPICE deployment','window presentation','performance improvement','complete library migration']}
(work/'video-validation.json').write_text(json.dumps(report,indent=2)+'\n')
PY_EVIDENCE
