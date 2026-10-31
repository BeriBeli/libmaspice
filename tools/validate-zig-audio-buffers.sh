#!/usr/bin/env bash
# Fixed PCM storage gate; no microphone or audible output device is opened.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-audio-buffers.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/audio-ring"
mkdir -p "$WORK_DIR"
ZIG_FLAGS=(-lc -O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache")
zig test "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/audio_ring_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig test "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/audio_runner_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig build-lib -dynamic "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/audio_ring_fixture.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig -femit-bin="$WORK_DIR/libaudio-ring.dylib"
swiftc -parse-as-library -warnings-as-errors -package-name SwiftSpice -module-cache-path "$WORK_DIR/swift-cache" test/oracle/swift/SwiftSpice/PreallocatedAudioPacketRing.swift test/oracle/swift/SwiftSpice/RecordCaptureBuffer.swift test/native/audio-ring-oracle.swift -o "$WORK_DIR/audio-ring-oracle"
python3 test/native/audio-ring-differential.py "$WORK_DIR" | tee "$WORK_DIR/differential.json"
