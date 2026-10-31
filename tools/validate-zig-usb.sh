#!/usr/bin/env bash
# Exact native backend tests never select a physical USB device.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-usb.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/usb"
mkdir -p "$WORK_DIR"
ZIG_SDK_PATH="$(xcrun --show-sdk-path)"
USB_FRAMEWORK="$ROOT_DIR/pkg/apple/artifacts/CUSBRedir.xcframework/macos-arm64"
CLANG="$(xcrun --find clang)"
C_FLAGS=(-std=c17 -Wall -Wextra -Werror -arch arm64 -isysroot "$ZIG_SDK_PATH" -mmacosx-version-min=26.0 -I include -F "$USB_FRAMEWORK" -I test/oracle/swift/CUSBRedirShim/include)
"$CLANG" "${C_FLAGS[@]}" -c test/oracle/swift/CUSBRedirShim/USBRedirShim.c -o "$WORK_DIR/oracle.o"
"$CLANG" "${C_FLAGS[@]}" -c test/native/usb-abi-check.c -o "$WORK_DIR/abi-check.o"
ZIG_FLAGS=(-lc -O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" -F "$ZIG_SDK_PATH/System/Library/Frameworks" -L "$ZIG_SDK_PATH/usr/lib" -F "$USB_FRAMEWORK" -framework CUSBRedir -framework CoreFoundation -framework IOKit -framework Security -lobjc)
zig test "$WORK_DIR/oracle.o" "$WORK_DIR/abi-check.o" "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/usb_host_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig test "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/usb_runner_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
"$CLANG" "${C_FLAGS[@]}" -c test/native/usb-native-faults.c -o "$WORK_DIR/faults.o"
zig test "$WORK_DIR/faults.o" -lc -O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" -L "$ZIG_SDK_PATH/usr/lib" --dep spice -Mroot=test/native/usb_native_failure_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig build-lib src/usb_host_abi.zig -static -lc -O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache" -femit-bin="$WORK_DIR/libusb-host.a"
"$CLANG" "${C_FLAGS[@]}" -I include -fsanitize=address,undefined -fno-omit-frame-pointer -g test/native/usb-host-consumer.c test/oracle/swift/CUSBRedirShim/USBRedirShim.c "$WORK_DIR/libusb-host.a" -framework CUSBRedir -framework IOKit -framework Security -framework CoreFoundation -o "$WORK_DIR/usb-host-consumer"
"$WORK_DIR/usb-host-consumer"
"$CLANG" "${C_FLAGS[@]}" -dynamiclib test/oracle/swift/CUSBRedirShim/USBRedirShim.c -framework CUSBRedir -framework IOKit -framework Security -framework CoreFoundation -o "$WORK_DIR/libusb-oracle.dylib"
