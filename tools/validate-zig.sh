#!/usr/bin/env bash
# Parallel full-library migration gate. Does not replace SwiftPM artifacts.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig.sh' >&2; exit 2; }
[[ "$(zig version)" == '0.17.0' ]] || { echo 'Zig 0.17.0 required' >&2; exit 1; }
WORK_DIR="$ROOT_DIR/.build/zig-migration"
mkdir -p "$WORK_DIR"
ZIG_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
ZIG_FLAGS=(-O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache")
SDK_FLAGS=(-F "$ZIG_SDK_PATH/System/Library/Frameworks" -L "$ZIG_SDK_PATH/usr/lib" -framework Security -framework CoreFoundation -framework Foundation -framework Network)
C_FLAGS=(-std=c17 -Wall -Wextra -Werror -arch arm64 -isysroot "$ZIG_SDK_PATH" -mmacosx-version-min=26.0 -I include -I include)
SWIFT_FLAGS=(-parse-as-library -warnings-as-errors -module-cache-path "$WORK_DIR/swift-cache")
swiftc "${SWIFT_FLAGS[@]}" tools/protocol-generator/main.swift -o "$WORK_DIR/protocol-generator"
"$WORK_DIR/protocol-generator" --schema resources/protocol/spice-0.14.5.json --output test/oracle/swift/SpiceProtocol/GeneratedMessages.swift --check
"$WORK_DIR/protocol-generator" --schema resources/protocol/spice-0.14.5.json --output src/generated.zig --zig --check
"$CLANG" "${C_FLAGS[@]}" -c src/platform/apple/security.c -o "$WORK_DIR/security.o"
"$CLANG" "${C_FLAGS[@]}" -fobjc-arc -fblocks -c src/platform/apple/network_bridge.m -o "$WORK_DIR/network_bridge.o"
NATIVE_OBJECTS=("$WORK_DIR/security.o" "$WORK_DIR/network_bridge.o")
zig test "${NATIVE_OBJECTS[@]}" -lc "${SDK_FLAGS[@]}" "${ZIG_FLAGS[@]}" \
    --dep spice -Mroot=test/native/root.zig -O ReleaseSafe -target aarch64-macos.26.0 \
    -Mspice=src/root.zig 2>&1 | tee "$WORK_DIR/zig-tests.log"
# Zig does not collect tests inside imported dependency modules. Exercise each
# module's colocated tests explicitly, including every generated declaration.
for unit in generated ticket lz; do
    zig test "src/$unit.zig" "${NATIVE_OBJECTS[@]}" -lc "${SDK_FLAGS[@]}" "${ZIG_FLAGS[@]}" \
        2>&1 | tee "$WORK_DIR/$unit-tests.log"
done
# Compile the existing production QUIC source, never the benchmark prototype.
zig test pkg/quic/codec.zig "${ZIG_FLAGS[@]}" 2>&1 | tee "$WORK_DIR/quic-tests.log"
zig build-lib src/abi.zig -static -lc "${ZIG_FLAGS[@]}" -femit-bin="$WORK_DIR/libspicezig-core.a"
zig build-lib src/abi.zig "${NATIVE_OBJECTS[@]}" -dynamic -lc "${SDK_FLAGS[@]}" "${ZIG_FLAGS[@]}" -femit-bin="$WORK_DIR/libspicezig.dylib"
swiftc "${SWIFT_FLAGS[@]}" -package-name SwiftSpice test/oracle/swift/SpiceWire/*.swift test/native/wire-oracle.swift -o "$WORK_DIR/wire-oracle"
python3 test/native/differential.py "$WORK_DIR" | tee "$WORK_DIR/wire-differential.json"
mkdir -p "$WORK_DIR/CSpicePixelOps"
python3 - <<'PY'
import json
from pathlib import Path
header=Path('test/oracle/swift/CSpicePixelOps/include/CSpicePixelOps.h').resolve()
Path('.build/zig-migration/CSpicePixelOps/module.modulemap').write_text(
    'module CSpicePixelOps { header '+json.dumps(str(header))+' export * }\n')
PY
"$CLANG" "${C_FLAGS[@]}" -O2 -I test/oracle/swift/CSpicePixelOps/include -c test/oracle/swift/CSpicePixelOps/SpicePixelOps.c -o "$WORK_DIR/pixel-ops.o"
swiftc "${SWIFT_FLAGS[@]}" -package-name SwiftSpice -I "$WORK_DIR/CSpicePixelOps" \
    test/oracle/swift/SpiceCodecs/SpiceImageDecoder.swift test/oracle/swift/SpiceCodecs/AdvancedVideoDecoder.swift \
    test/oracle/swift/SpiceCodecs/LZDecoder.swift test/native/lz-oracle.swift "$WORK_DIR/pixel-ops.o" -o "$WORK_DIR/lz-oracle"
python3 test/native/lz-differential.py "$WORK_DIR" | tee "$WORK_DIR/lz-differential.json"
"$CLANG" "${C_FLAGS[@]}" -I pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Headers \
    -c src/platform/apple/codec_bridge.c -o "$WORK_DIR/codec_bridge.o"
zig build-lib "$WORK_DIR/codec_bridge.o" \
    -F pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64 -framework CTurboJPEG \
    -F pkg/apple/artifacts/CSpiceQUIC.xcframework/macos-arm64 -framework CSpiceQUIC \
    -dynamic -lc -lz -L "$ZIG_SDK_PATH/usr/lib" "${ZIG_FLAGS[@]}" \
    --dep spice -Mroot=test/native/glz_fixture.zig -O ReleaseSafe -target aarch64-macos.26.0 \
    -Mspice=src/root.zig -femit-bin="$WORK_DIR/libglz-fixture.dylib"
swiftc "${SWIFT_FLAGS[@]}" -package-name SwiftSpice -I "$WORK_DIR/CSpicePixelOps" \
    test/oracle/swift/SpiceCodecs/SpiceImageDecoder.swift test/oracle/swift/SpiceCodecs/AdvancedVideoDecoder.swift \
    test/oracle/swift/SpiceCodecs/SpiceCodecTaskExecutor.swift test/oracle/swift/SpiceCodecs/GLZDecoder.swift \
    test/native/glz-oracle.swift "$WORK_DIR/pixel-ops.o" -o "$WORK_DIR/glz-oracle"
python3 test/native/glz-differential.py "$WORK_DIR" | tee "$WORK_DIR/glz-differential.json"
swiftc "${SWIFT_FLAGS[@]}" -package-name SwiftSpice test/oracle/swift/SpiceCodecs/SpiceImageDecoder.swift \
    test/oracle/swift/SpiceCodecs/AdvancedVideoDecoder.swift test/native/annexb-oracle.swift -o "$WORK_DIR/annexb-oracle"
python3 test/native/annexb-differential.py "$WORK_DIR" | tee "$WORK_DIR/annexb-differential.json"

python3 test/native/native-codec-fixtures.py "$WORK_DIR" | tee "$WORK_DIR/native-codec-fixtures.json"
swiftc "${SWIFT_FLAGS[@]}" -package-name SwiftSpice -emit-library -emit-module \
    -module-name SpiceWire test/oracle/swift/SpiceWire/*.swift -o "$WORK_DIR/libSpiceWireOracle.dylib" \
    -emit-module-path "$WORK_DIR/SpiceWire.swiftmodule"
swiftc "${SWIFT_FLAGS[@]}" -package-name SwiftSpice -I "$WORK_DIR" -L "$WORK_DIR" \
    -lSpiceWireOracle -Xlinker -rpath -Xlinker "$WORK_DIR" test/oracle/swift/SpiceProtocol/DisplayProtocol.swift test/oracle/swift/SpiceProtocol/DisplayMonitorProtocol.swift \
    test/native/display-oracle.swift -o "$WORK_DIR/display-oracle"
python3 test/native/display-differential.py "$WORK_DIR" | tee "$WORK_DIR/display-differential.json"
# C adapters and consumers are instrumented; Zig retains ReleaseSafe checks.
"$CLANG" "${C_FLAGS[@]}" -fobjc-arc -fblocks -fsanitize=address,undefined -fno-omit-frame-pointer -g \
    -c src/platform/apple/network_bridge.m -o "$WORK_DIR/network_bridge-sanitized.o"
for consumer in abi-consumer ticket-consumer network-consumer; do
    "$CLANG" "${C_FLAGS[@]}" -fsanitize=address,undefined -fno-omit-frame-pointer -g \
        "test/native/$consumer.c" src/platform/apple/security.c "$WORK_DIR/network_bridge-sanitized.o" "$WORK_DIR/libspicezig-core.a" \
        -framework CoreFoundation -framework Security -framework Foundation -framework Network -o "$WORK_DIR/$consumer"
    "$WORK_DIR/$consumer"
done
"$CLANG" "${C_FLAGS[@]}" --analyze -Xanalyzer -analyzer-output=text src/platform/apple/security.c
"$CLANG" "${C_FLAGS[@]}" -fobjc-arc -fblocks --analyze -Xanalyzer -analyzer-output=text src/platform/apple/network_bridge.m
# Test-only child handler observes real native supervision; it is not Display.
# Link the already loaded native bridge to avoid duplicate Objective-C classes.
zig build-lib -dynamic -lc -L "$WORK_DIR" -lspicezig "${ZIG_FLAGS[@]}" \
    --dep spice -Mroot=test/native/supervisor_fixture.zig -O ReleaseSafe -target aarch64-macos.26.0 \
    -Mspice=src/root.zig -femit-bin="$WORK_DIR/libsupervisor-fixture.dylib"
"$CLANG" "${C_FLAGS[@]}" -fobjc-arc -fblocks -c src/platform/apple/video_bridge.m -o "$WORK_DIR/video_bridge.o"
sh bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh resources/shaders/compositor.metal "$WORK_DIR/compositor.air" "$WORK_DIR/compositor.metallib"
"$CLANG" "${C_FLAGS[@]}" -fobjc-arc -fblocks -c src/platform/apple/graphics_bridge.m -o "$WORK_DIR/graphics_bridge.o"
zig build-lib "$WORK_DIR/video_bridge.o" "$WORK_DIR/graphics_bridge.o" "$WORK_DIR/codec_bridge.o" -dynamic -lc -lz -L "$WORK_DIR" -lspicezig "${SDK_FLAGS[@]}" "${ZIG_FLAGS[@]}" \
    -F pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64 -framework CTurboJPEG \
    -F pkg/apple/artifacts/CSpiceQUIC.xcframework/macos-arm64 -framework CSpiceQUIC \
    -framework QuartzCore -framework CoreVideo -framework CoreMedia -framework VideoToolbox -framework IOSurface -framework Metal -framework MetalPerformanceShaders \
    --dep spice -Mroot=test/native/display_fixture.zig -O ReleaseSafe -target aarch64-macos.26.0 \
    -Mspice=src/root.zig -femit-bin="$WORK_DIR/libdisplay-fixture.dylib"
# Public desktop ABI is an additional parallel archive; runtime artifacts stay untouched.
sh bindings/swift/Plugins/CompileMetalShaders/compile-metal.sh resources/shaders/presentation.metal "$WORK_DIR/presentation.air" "$WORK_DIR/presentation.metallib"
zig build-lib src/desktop_abi.zig -static -lc -fcompiler-rt "${ZIG_FLAGS[@]}" -femit-bin="$WORK_DIR/libspicezig-desktop.a"
zig build-lib src/host_view_native.zig -static -lc -fcompiler-rt "${ZIG_FLAGS[@]}" -femit-bin="$WORK_DIR/libspicezig-host.a"
"$CLANG" "${C_FLAGS[@]}" -fsanitize=address,undefined -fno-omit-frame-pointer -I pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Headers test/native/trace-marker-jpeg.c -F pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64 -framework CTurboJPEG -o "$WORK_DIR/trace-marker-jpeg"
# Link the public C consumer directly, instrumenting all native adapters.
for consumer in video-error-consumer reconnect-consumer desktop-consumer agent-consumer agent-runner-consumer webdav-consumer usb-consumer source-consumer diagnostics-consumer host-api-consumer; do
consumer_extension=c; [[ "$consumer" != agent-runner-consumer && "$consumer" != host-api-consumer ]] || consumer_extension=m
HOST_OBJECTS=(); [[ "$consumer" != host-api-consumer ]] || HOST_OBJECTS=(src/platform/apple/host_view_bridge.m "$WORK_DIR/libspicezig-host.a" -framework MetalKit)
"$CLANG" "${C_FLAGS[@]}" -fsanitize=address,undefined -fno-omit-frame-pointer -g -fobjc-arc -fblocks \
    -I pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64/CTurboJPEG.framework/Headers \
    "test/native/$consumer.$consumer_extension" test/native/desktop_presenter_consumer.m src/platform/apple/network_bridge.m src/platform/apple/security.c \
    src/platform/apple/video_bridge.m src/platform/apple/graphics_bridge.m src/platform/apple/pasteboard_bridge.m src/platform/apple/audio_bridge.m src/platform/apple/webdav_bridge.m src/platform/apple/codec_bridge.c ${HOST_OBJECTS[@]+"${HOST_OBJECTS[@]}"} "$WORK_DIR/libspicezig-desktop.a" \
    -F pkg/apple/artifacts/CTurboJPEG.xcframework/macos-arm64 -framework CTurboJPEG \
    -F pkg/apple/artifacts/CSpiceQUIC.xcframework/macos-arm64 -framework CSpiceQUIC \
    -F pkg/apple/artifacts/CUSBRedir.xcframework/macos-arm64 -framework CUSBRedir -framework IOKit \
    -framework AVFAudio -framework AudioToolbox -framework AppKit -framework Security -framework CoreFoundation -framework Foundation -framework Network -framework QuartzCore \
    -framework CoreVideo -framework CoreMedia -framework VideoToolbox -framework IOSurface -framework Metal -framework QuartzCore -framework MetalPerformanceShaders -lz \
    -o "$WORK_DIR/$consumer"
done
./tools/validate-zig-presentation.sh
./tools/validate-zig-host-input.sh
./tools/validate-zig-host-view.sh --core
"$WORK_DIR/host-api-consumer" "$WORK_DIR/compositor.metallib" "$WORK_DIR/presentation.metallib"
./tools/validate-zig-diagnostics.sh
python3 test/native/diagnostics-api-integration.py "$WORK_DIR" | tee "$WORK_DIR/diagnostics-api-integration.json"
python3 test/native/source-api-integration.py "$WORK_DIR" | tee "$WORK_DIR/source-api-integration.json"
python3 test/native/reconnect-api-integration.py "$WORK_DIR" | tee "$WORK_DIR/reconnect-api-integration.json"
./tools/validate-zig-video-errors.sh
python3 test/native/video-error-api-integration.py "$WORK_DIR" | tee "$WORK_DIR/video-error-api-integration.json"
./tools/validate-zig-usb.sh
python3 test/native/usb-api-integration.py "$WORK_DIR" | tee "$WORK_DIR/usb-api-integration.json"
python3 test/native/webdav-api-integration.py "$WORK_DIR" | tee "$WORK_DIR/webdav-api-integration.json"
python3 test/native/desktop-api-integration.py "$WORK_DIR" | tee "$WORK_DIR/desktop-api-integration.json"
python3 test/native/agent-api-integration.py "$WORK_DIR" | tee "$WORK_DIR/agent-api-integration.json"
python3 test/native/agent-api-integration.py "$WORK_DIR" --native-runner | tee "$WORK_DIR/agent-runner-api-integration.json"
swiftc "${SWIFT_FLAGS[@]}" -package-name SwiftSpice -I "$WORK_DIR" -L "$WORK_DIR" \
    -lSpiceWireOracle -Xlinker -rpath -Xlinker "$WORK_DIR" test/oracle/swift/SpiceProtocol/CursorProtocol.swift \
    test/native/cursor-oracle.swift -o "$WORK_DIR/cursor-oracle"
python3 test/native/cursor-differential.py "$WORK_DIR" | tee "$WORK_DIR/cursor-differential.json"
swiftc "${SWIFT_FLAGS[@]}" -package-name SwiftSpice -I "$WORK_DIR" -L "$WORK_DIR" \
    -lSpiceWireOracle -Xlinker -rpath -Xlinker "$WORK_DIR" test/oracle/swift/SpiceProtocol/PlaybackProtocol.swift test/oracle/swift/SpiceProtocol/RecordProtocol.swift \
    test/native/audio-oracle.swift -o "$WORK_DIR/audio-oracle"
python3 test/native/audio-differential.py "$WORK_DIR" | tee "$WORK_DIR/audio-differential.json"
swiftc "${SWIFT_FLAGS[@]}" -package-name SwiftSpice -I "$WORK_DIR" -L "$WORK_DIR" \
    -lSpiceWireOracle -Xlinker -rpath -Xlinker "$WORK_DIR" test/oracle/swift/SpiceProtocol/SmartcardProtocol.swift test/oracle/swift/SpiceProtocol/SpiceVMCProtocol.swift test/oracle/swift/SpiceProtocol/WebDAVProtocol.swift \
    test/native/peripheral-oracle.swift -o "$WORK_DIR/peripheral-oracle"
python3 test/native/peripheral-differential.py "$WORK_DIR" | tee "$WORK_DIR/peripheral-differential.json"
./tools/validate-zig-agent-services.sh
./tools/validate-zig-pasteboard.sh
./tools/validate-zig-audio-buffers.sh
./tools/validate-zig-audio-native.sh
./tools/validate-zig-webdav.sh
python3 test/native/network-integration.py "$WORK_DIR" | tee "$WORK_DIR/network-integration.json"
./tools/validate-zig-swift.sh
python3 - <<'PY'
import hashlib,json,subprocess
from pathlib import Path
paths=sorted([*Path('src').rglob('*'),*Path('include').glob('*'),*Path('resources/shaders').glob('*'),*Path('bindings/swift/SpiceZigSwift').glob('*.swift'),*Path('test/native').glob('*'),Path('tools/protocol-generator/main.swift'),Path('tools/validate-zig.sh'),Path('tools/validate-zig-agent-services.sh'),Path('tools/validate-zig-pasteboard.sh'),Path('tools/validate-zig-audio-buffers.sh'),Path('tools/validate-zig-audio-native.sh'),Path('tools/validate-zig-webdav.sh'),Path('tools/validate-zig-usb.sh'),Path('tools/validate-zig-presentation.sh'),Path('tools/validate-zig-diagnostics.sh'),Path('tools/validate-zig-host-input.sh'),Path('tools/validate-zig-host-view.sh'),Path('tools/validate-zig-video-errors.sh'),Path('tools/validate-zig-swift.sh'),Path('tools/validate-zig-native-presentation.sh'),Path('resources/protocol/spice-0.14.5.json')])
evidence={'configuration':'Zig 0.17.0 ReleaseSafe; arm64 macOS 26 target',
          'checks':['public Swift WebDAV facade: supplied shared server, standalone parser prefix and typed errors, shared client limits, two-channel response ownership, readonly and symlink policy, opt-in writes, released caller and reconnect; native shared worker ordering/cancellation and allocation cleanup','public Swift USB facade retains supplied native parser, exact bounded output and joined reconnect ownership; no physical devices','public Swift Agent facade: late attachment, explicit disabled clipboard policy, layout ACK, file size error/details and exact bytes, identity across restart, reconnect barriers and lifetime metrics','public Swift audio facades: ordered late attachment, unused stream draining, reconnect, duplicate start and joined stop; no hardware START','Swift 6 compatibility boundary: async reconnect/cancellation, native mutable pixel isolation, metrics and SwiftUI view ownership; independent Swift ASan consumer','migration subject/source version and bounded caller-owned pixel copy C ABI','typed video failure categories validated against SDK constants and actual CoreMedia errors through public supervised sessions','public stable Runtime reconnect, auth failure recovery, terminal clearing and stale Source fencing','58 pipeline counters/gauges and 8 timing summaries, retired/adopted channel accounting and actual native MJPEG metrics','Zig host view lifecycle, allocation failures, reentrant input teardown and actual public Desktop/Source ownership','generated Swift and Zig consistency','Zig tests including allocation failures','production QUIC tests','Swift wire differential','LZ independent upstream pixels, truncations and Swift differential','C ABI and actual Security encryption/decryption with C ASan/UBSan','C static analysis','loopback TCP/TLS cancellation and actual Zig Link handshake','session/channel/Main/Agent C ABI integration','64MiB full and mini outbound bodies','Main/Agent allocation failures, epochs and rebind','native transport C ABI ASan/UBSan lifecycles','Swift cursor wire differential','real Display/Inputs/Cursor TCP state and semi/seamless migration','Swift Playback/Record wire differential and real TCP audio state migration','Swift Smartcard/VMC/Port differential and real TCP peripheral protocol state migration','real demand publication and native GPU desktop migration','public desktop C ABI with native ASan/UBSan consumer; retained events and frames, concurrent lazy readback, typed sends and independent presenter lifetime','WebDAV parser/filesystem oracle, joined native executor and public TCP migration','desktop source subscriptions, ready latch, callback contexts, 12000 existing-Swift presentation-policy steps and six public TCP migration cases with CPU drawing and optional Metal context','diagnostics histogram/record/ROI/causal-state Swift differential, cancellation and atomic JSONL, public CPU and MJPEG native IOSurface trace lifecycle','12 USB Zig tests, 64 native C oracle/sanitizer cycles and public TCP native parser migration without physical device attachment'],
          'not_claimed':['full interoperability parity','Zig ASan instrumentation','live SPICE peer','Apple video hardware','clean macOS 26','published release','performance improvement'],
          'source_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()},
          'oracle_source_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted([*Path('test/oracle/swift/SpiceWire').glob('*.swift'),Path('test/oracle/swift/SpiceChannels/SpiceTimingDiagnostics.swift'),Path('test/oracle/swift/SwiftSpice/SpicePresentationDiagnostics.swift'),Path('test/oracle/swift/SwiftSpice/SpiceInteractionCausalTrace.swift'),Path('test/oracle/swift/SwiftSpice/SpiceInteractionTraceCollector.swift'),Path('test/oracle/swift/SwiftSpice/SpiceDesktopSource.swift'),Path('test/oracle/swift/SwiftSpice/SpiceDesktopView.swift'),Path('test/oracle/swift/SwiftSpice/SpiceMetalPresenter.swift'),Path('test/oracle/swift/SpiceProtocol/SmartcardProtocol.swift'),Path('test/oracle/swift/SpiceProtocol/SpiceVMCProtocol.swift'),Path('test/oracle/swift/SpiceProtocol/WebDAVProtocol.swift'),Path('test/oracle/swift/SpiceProtocol/CursorProtocol.swift'),Path('test/oracle/swift/SpiceProtocol/PlaybackProtocol.swift'),Path('test/oracle/swift/SpiceProtocol/RecordProtocol.swift'),Path('test/oracle/swift/SpiceCodecs/LZDecoder.swift'),Path('test/oracle/swift/SpiceCodecs/SpiceImageDecoder.swift'),Path('test/oracle/swift/SpiceCodecs/AdvancedVideoDecoder.swift'),Path('test/oracle/swift/CSpicePixelOps/SpicePixelOps.c')])},
          'fixture_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path('test/fixtures/SpiceCodecsTests').glob('lz*.json'))},
          'sdk':subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-version'],text=True).strip()}
Path('.build/zig-migration/validation.json').write_text(json.dumps(evidence,indent=2)+'\n')
print('Zig migration gates passed; evidence: .build/zig-migration/validation.json')
PY
