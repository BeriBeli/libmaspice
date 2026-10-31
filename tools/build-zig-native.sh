#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$#" -eq 0 ]] || { echo 'usage: build-zig-native.sh ' >&2; exit 2; }
zig build xcframework
./tools/verify-native-closure.sh --artifacts-only
