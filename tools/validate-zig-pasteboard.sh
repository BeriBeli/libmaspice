#!/usr/bin/env bash
# Private named pasteboards only; never reads/writes the user's general clipboard.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-pasteboard.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/pasteboard"
mkdir -p "$WORK_DIR"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
C_FLAGS=(-std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include -fobjc-arc -fblocks -I include)
xcrun clang "${C_FLAGS[@]}" -c src/platform/apple/pasteboard_bridge.m -o "$WORK_DIR/bridge.o"
xcrun clang "${C_FLAGS[@]}" -c test/native/pasteboard_probe.m -o "$WORK_DIR/probe.o"
swiftc -parse-as-library -warnings-as-errors -package-name SwiftSpice -module-cache-path "$WORK_DIR/swift-cache" -emit-library test/oracle/swift/SwiftSpice/SpicePasteboardBridge.swift test/native/pasteboard-oracle.swift -o "$WORK_DIR/libpasteboard-oracle.dylib"
zig test -L "$WORK_DIR" -lpasteboard-oracle -rpath "$WORK_DIR" "$WORK_DIR/bridge.o" "$WORK_DIR/probe.o" -lc -F "$SDK_PATH/System/Library/Frameworks" -L "$SDK_PATH/usr/lib" -framework AppKit -framework Foundation -framework CoreFoundation --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" -O ReleaseSafe -target aarch64-macos.26.0 --dep spice -Mroot=test/native/pasteboard_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig 2>&1 | tee "$WORK_DIR/tests.log"
xcrun clang "${C_FLAGS[@]}" --analyze -Xanalyzer -analyzer-output=text src/platform/apple/pasteboard_bridge.m
xcrun clang "${C_FLAGS[@]}" -fsanitize=address,undefined -fno-omit-frame-pointer -g src/platform/apple/pasteboard_bridge.m test/native/pasteboard-consumer.m -framework AppKit -framework Foundation -o "$WORK_DIR/consumer"
"$WORK_DIR/consumer" | tee "$WORK_DIR/sanitizers.log"
