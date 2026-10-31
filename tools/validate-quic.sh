#!/usr/bin/env bash
# Independent-source and shipped-artifact acceptance for the Zig QUIC port.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$(zig version)" == "0.17.0" ]] || { echo "Zig 0.17.0 is required" >&2; exit 1; }
./tools/verify-native-closure.sh --artifacts-only
zig test pkg/quic/codec.zig -O ReleaseSafe \
    --cache-dir .build/zig-quic/cache --global-cache-dir .build/zig-quic/global-cache
python3 test/quic/Validation/stream.py
python3 test/quic/Validation/encoder.py
python3 test/quic/Validation/abi.py --sanitize
python3 test/quic/Validation/abi.py --artifact --sanitize
python3 test/quic/Validation/audit.py | tee .build/quic-audit/production-audit.json
