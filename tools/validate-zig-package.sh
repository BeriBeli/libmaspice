#!/usr/bin/env bash
# Run existing public integration consumers through the shipped SwiftPM product.
# Requires no Zig compiler. Uses private loopback peers and owned temporary roots.
set -euo pipefail
# Report the actual configuration selected by this build driver.
export SWIFTSPICE_TEST_BUILD=swiftpm-release
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: validate-zig-package.sh' >&2; exit 2; }
WORK_DIR="$ROOT_DIR/.build/zig-package-consumers"
mkdir -p "$WORK_DIR/usb"
./tools/verify-native-closure.sh --artifacts-only
python3 - "$WORK_DIR" <<'PYSETUP'
import json,shutil,sys
from pathlib import Path
work=Path(sys.argv[1]);names=['session','native','view','audio','agent','usb','webdav']
targets=[]
for name in names:
 destination=work/'Sources'/name;destination.mkdir(parents=True,exist_ok=True)
 shutil.copyfile(Path('test/native')/f'swift-{name}-consumer.swift',destination/'Consumer.swift')
 targets.append(f'.executableTarget(name: "{name}-consumer", dependencies: [.product(name: "SwiftSpice", package: "libmaspice")], path: "Sources/{name}")')
(work/'Package.swift').write_text('// swift-tools-version: 6.4\nimport PackageDescription\nlet package = Package(name: "ZigPackageConsumers", platforms: [.macOS(.v26)], dependencies: [.package(path: "../..")], targets: ['+',\n'.join(targets)+'], swiftLanguageModes: [.v6])\n')
PYSETUP
swift build --disable-sandbox -c release --package-path "$WORK_DIR" -Xswiftc -warnings-as-errors
BIN_PATH="$(swift build --disable-sandbox -c release --package-path "$WORK_DIR" --show-bin-path)"
ln -sfn "$BIN_PATH" "$WORK_DIR/swift-boundary"
xcrun clang -std=c17 -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=26.0 -I include \
    -F pkg/apple/artifacts/CUSBRedir.xcframework/macos-arm64 -I test/oracle/swift/CUSBRedirShim/include \
    -dynamiclib test/oracle/swift/CUSBRedirShim/USBRedirShim.c -framework CUSBRedir -framework IOKit \
    -framework Security -framework CoreFoundation -o "$WORK_DIR/usb/libusb-oracle.dylib"
for consumer in session native audio agent usb webdav; do
    python3 "test/native/swift-$consumer-integration.py" "$WORK_DIR" | tee "$WORK_DIR/$consumer.json"
done
"$BIN_PATH/view-consumer" | tee "$WORK_DIR/view.log"
./tools/audit-dylib-links.sh "$BIN_PATH"
swift package describe --type json > "$WORK_DIR/dependency-graph.json"
python3 - "$WORK_DIR" "$BIN_PATH" <<'PYCHECK'
import json,subprocess,sys
from pathlib import Path
work=Path(sys.argv[1]);binaries=Path(sys.argv[2]);graph=json.loads((work/'dependency-graph.json').read_text())
targets={t['name']:t for t in graph['targets']};visited=set()
def visit(name):
 if name in visited:return
 visited.add(name)
 for child in targets[name].get('target_dependencies',[]):visit(child)
visit('SwiftSpice')
assert visited=={'SwiftSpice','CSpiceZig','CTurboJPEG','CSpiceQUIC','CUSBRedir','CompileMetalShaders'},visited
# Symbols independently confirm the graph result in a linked executable.
symbols=subprocess.check_output(['nm','-gj',str(binaries/'session-consumer')],text=True)
assert '_spice_zig_desktop_connect' in symbols
for module in ['SwiftSpiceReference','SpiceCore','SpiceChannels','SpiceRenderer','SpiceTransportNetwork']:
 assert not any(line.startswith('_$s'+str(len(module))+module) for line in symbols.splitlines()),module
print('SwiftPM product uses Zig core; legacy runtime modules absent from graph and linked consumer')
PYCHECK
