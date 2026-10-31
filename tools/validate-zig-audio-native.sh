#!/usr/bin/env bash
# Offline AVAudioConverter and render-buffer checks; never opens audio devices.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-audio-native.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/audio-native"
mkdir -p "$WORK_DIR"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
C_FLAGS=(-std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include -fobjc-arc -fblocks -I include)
xcrun clang "${C_FLAGS[@]}" -c src/platform/apple/audio_bridge.m -o "$WORK_DIR/bridge.o"
xcrun clang "${C_FLAGS[@]}" -c test/native/audio_probe.m -o "$WORK_DIR/probe.o"
python3 - <<'PY'
from pathlib import Path
source=Path('test/oracle/swift/SwiftSpice/SpiceAudioCaptureSource.swift').read_text()
# Exact original processor, diagnostics and persistent input-provider classes.
source=source[source.index('package struct AudioCaptureProcessorDiagnostics:'):]
Path('.build/zig-migration/audio-native/CaptureProcessor.swift').write_text('import AVFAudio\nimport Foundation\nimport Synchronization\n'+source)
PY
swiftc -parse-as-library -warnings-as-errors -package-name SwiftSpice -module-cache-path "$WORK_DIR/swift-cache" -emit-library test/oracle/swift/SwiftSpice/PreallocatedAudioPacketRing.swift test/oracle/swift/SwiftSpice/RecordCaptureBuffer.swift "$WORK_DIR/CaptureProcessor.swift" test/native/audio-capture-oracle.swift -o "$WORK_DIR/libaudio-oracle.dylib"
zig test -L "$WORK_DIR" -laudio-oracle -rpath "$WORK_DIR" "$WORK_DIR/bridge.o" "$WORK_DIR/probe.o" -lc -F "$SDK_PATH/System/Library/Frameworks" -L "$SDK_PATH/usr/lib" -framework AVFAudio -framework AudioToolbox -framework Foundation --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" -O ReleaseSafe -target aarch64-macos.26.0 --dep spice -Mroot=test/native/audio_native_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig 2>&1 | tee "$WORK_DIR/tests.log"
xcrun clang "${C_FLAGS[@]}" --analyze -Xanalyzer -analyzer-output=text src/platform/apple/audio_bridge.m
xcrun clang "${C_FLAGS[@]}" -fsanitize=address,undefined -fno-omit-frame-pointer -g test/native/audio-native-consumer.m test/native/audio_probe.m -framework AVFAudio -framework AudioToolbox -framework Foundation -o "$WORK_DIR/consumer"
"$WORK_DIR/consumer" | tee "$WORK_DIR/sanitizers.log"
