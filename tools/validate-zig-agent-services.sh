#!/usr/bin/env bash
# Independent Swift protocol/state comparisons; no clipboard/file host effects.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-agent-services.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-migration/agent-services"
mkdir -p "$WORK_DIR"
ZIG_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ZIG_FLAGS=(-O ReleaseSafe -target aarch64-macos.26.0 --cache-dir "$WORK_DIR/cache" --global-cache-dir "$WORK_DIR/global-cache")
SDK_FLAGS=(-F "$ZIG_SDK_PATH/System/Library/Frameworks" -L "$ZIG_SDK_PATH/usr/lib" -framework CoreFoundation)
SWIFT_FLAGS=(-parse-as-library -warnings-as-errors -package-name SwiftSpice -module-cache-path "$WORK_DIR/swift-cache")
zig test -lc "${SDK_FLAGS[@]}" "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/agent_services_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig test -lc "${SDK_FLAGS[@]}" "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/agent_runner_tests.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig
zig build-lib -dynamic -lc "${SDK_FLAGS[@]}" "${ZIG_FLAGS[@]}" --dep spice -Mroot=test/native/agent_services_fixture.zig -O ReleaseSafe -target aarch64-macos.26.0 -Mspice=src/root.zig -femit-bin="$WORK_DIR/libagent-services.dylib"
swiftc "${SWIFT_FLAGS[@]}" -emit-library -emit-module -module-name SpiceWire test/oracle/swift/SpiceWire/*.swift -o "$WORK_DIR/libSpiceWire.dylib" -emit-module-path "$WORK_DIR/SpiceWire.swiftmodule"
swiftc "${SWIFT_FLAGS[@]}" -I "$WORK_DIR" -L "$WORK_DIR" -lSpiceWire -Xlinker -rpath -Xlinker "$WORK_DIR" -emit-library -emit-module -module-name SpiceProtocol test/oracle/swift/SpiceProtocol/AgentProtocol.swift test/oracle/swift/SpiceProtocol/ClipboardProtocol.swift test/oracle/swift/SpiceProtocol/FileTransferProtocol.swift test/oracle/swift/SpiceProtocol/MonitorProtocol.swift -o "$WORK_DIR/libSpiceProtocol.dylib" -emit-module-path "$WORK_DIR/SpiceProtocol.swiftmodule"
# Copy unchanged public value declarations needed by ClipboardStateMachine.
# This avoids linking the entire Swift networking/session runtime into an oracle.
python3 - <<'PY'
from pathlib import Path
source=Path('test/oracle/swift/SwiftSpice/SpiceSession.swift').read_text()
blocks=[]
for declaration in ['public enum SpiceVideoCodec:', 'public enum SpiceVideoCodecFailureReason:', 'public struct SpiceVideoCodecFailure:', 'public enum SpiceError:']:
 start=source.index(declaration);body=source.index('{',start);depth=1;end=body+1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}');end+=1
 blocks.append(source[start:end])
Path('.build/zig-migration/agent-services/SessionValues.swift').write_text('import Foundation\n'+'\n'.join(blocks)+'\n')
manager=Path('test/oracle/swift/SwiftSpice/SpiceClipboardManager.swift').read_text()
start=manager.index('    private func makeWireDisplayConfiguration(');body=manager.index('{',start);depth=1;end=body+1
while depth:
 depth+=(manager[end]=='{')-(manager[end]=='}');end+=1
layout='import Foundation\nimport SpiceProtocol\nstruct LayoutOracleHost { let state: ClipboardStateMachine\n'+manager[start:end]+'\n func encode(_ c: SpiceDisplayConfiguration) throws -> Data { try VDAgentMonitorCodec.encode(makeWireDisplayConfiguration(c)).data }\n}\n'
Path('.build/zig-migration/agent-services/LayoutOracleHost.swift').write_text(layout)

PY
swiftc "${SWIFT_FLAGS[@]}" -I "$WORK_DIR" -L "$WORK_DIR" -lSpiceWire -lSpiceProtocol -Xlinker -rpath -Xlinker "$WORK_DIR" "$WORK_DIR/SessionValues.swift" "$WORK_DIR/LayoutOracleHost.swift" test/oracle/swift/SwiftSpice/SpiceDisplayConfiguration.swift test/oracle/swift/SwiftSpice/ClipboardStateMachine.swift test/native/agent-services-oracle.swift -o "$WORK_DIR/agent-services-oracle"
python3 test/native/agent-services-differential.py "$WORK_DIR" | tee "$WORK_DIR/differential.json"
