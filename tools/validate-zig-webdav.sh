#!/usr/bin/env bash
# HTTP/WebDAV migration validation. File fixtures live only in owned temp roots.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-webdav.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/webdav"
mkdir -p "$WORK_DIR"
ZIG_SDK_PATH="$(xcrun --show-sdk-path)"
ZIG_FLAGS=(-lc -O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" -F "$ZIG_SDK_PATH/System/Library/Frameworks" -L "$ZIG_SDK_PATH/usr/lib" -framework CoreFoundation)
zig test "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/webdav_http_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig test "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/webdav_queue_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig test "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/webdav_runner_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
CLANG="$(xcrun --find clang)"
C_FLAGS=(-std=c17 -Wall -Wextra -Werror -arch arm64 -isysroot "$ZIG_SDK_PATH" -mmacosx-version-min=26.0 -I include -fobjc-arc -fblocks -I include)
"$CLANG" "${C_FLAGS[@]}" -c src/platform/apple/webdav_bridge.m -o "$WORK_DIR/webdav_bridge.o"
zig test "$WORK_DIR/webdav_bridge.o" -framework Foundation "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/webdav_path_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig test "$WORK_DIR/webdav_bridge.o" -framework Foundation "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/webdav_fs_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig test "$WORK_DIR/webdav_bridge.o" -framework Foundation "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/webdav_server_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
"$CLANG" "${C_FLAGS[@]}" --analyze -Xanalyzer -analyzer-output=text src/platform/apple/webdav_bridge.m
zig build-lib -dynamic "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/webdav_http_fixture.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig -femit-bin="$WORK_DIR/libwebdav-http.dylib"
python3 - <<'PY'
from pathlib import Path
s=Path('test/oracle/swift/SwiftSpice/SpiceWebDAVServer.swift').read_text()
# Copy exact production declarations and routines; only visibility is relaxed in
# this test-only standalone wrapper so no filesystem work is needed to inspect HTTP.
parts=[s[s.index('public enum SpiceWebDAVServerError'):s.index('package enum SpiceWebDAVPipelineError')],s[s.index('    private struct Request:'):s.index('    private struct Submission:')],s[s.index('    private func nextRequest('):s.index('    private func runClient(')],s[s.index('    private func retainedByteCount('):s.index('    private func sumInputRetainedBytes(')]]
body='\n'.join(parts[1:]).replace('private ','')
Path('.build/zig-migration/webdav/HTTPOracle.swift').write_text('import Foundation\n'+parts[0]+'\nstruct HTTPOracle {\nlet maximumHeaderBytes:Int\nlet maximumBodyBytes:Int\nstatic let maximumGeneratedResponseHeaderBytes=4096\ninit(header:Int,body:Int){maximumHeaderBytes=header;maximumBodyBytes=body}\n'+body+'\n}')
PY
swiftc -parse-as-library -warnings-as-errors -module-cache-path "$WORK_DIR/swift-cache" "$WORK_DIR/HTTPOracle.swift" test/native/webdav-http-oracle.swift -o "$WORK_DIR/webdav-http-oracle"
python3 test/native/webdav-http-differential.py "$WORK_DIR" | tee "$WORK_DIR/http-differential.json"

zig build-lib "$WORK_DIR/webdav_bridge.o" -framework Foundation -dynamic "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/webdav_fs_fixture.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig -femit-bin="$WORK_DIR/libwebdav-fs.dylib"
swiftc -parse-as-library -warnings-as-errors -package-name SwiftSpice -module-cache-path "$WORK_DIR/swift-cache" test/oracle/swift/SwiftSpice/SpiceFilesystemTaskExecutor.swift test/oracle/swift/SwiftSpice/SpiceWebDAVServer.swift test/native/webdav-fs-oracle.swift -o "$WORK_DIR/webdav-fs-oracle"
python3 test/native/webdav-fs-differential.py "$WORK_DIR" | tee "$WORK_DIR/fs-differential.json"

"$CLANG" "${C_FLAGS[@]}" -fsanitize=address,undefined -fno-omit-frame-pointer -g test/native/webdav-native-consumer.m src/platform/apple/webdav_bridge.m -framework Foundation -o "$WORK_DIR/webdav-native-consumer"
"$WORK_DIR/webdav-native-consumer"
