# Apple native dependency boundary

`artifacts/` contains one arm64/macOS 26+ static named-framework slice per native
component. Package.swift consumes CSpiceZig, CSpiceQUIC, CTurboJPEG and CUSBRedir.
No Homebrew runtime, GLib or spice-gtk library is linked. The source-built complete
C archive in zig-out combines these components and still needs Apple frameworks
and zlib. `libmaspice.pc` records those system link flags.

Run `zig build xcframework` for the core/QUIC and
`tools/build-native-dependencies.sh` from repository root for all dependencies.
The latter downloads checksum-pinned JPEG 3.2.1, usbredir 0.15.0 and libusb 1.0.30.
CMake enables/requires Neon, and libusb's SDK-27-only pipe2 probe stays disabled
for the macOS 26 deployment target. Archive metadata is deterministic.

`zig build check-native` checks source/archive/header hashes, deployment target,
arm64 architecture, public QUIC exports, absent prototype exports, JPEG accurate
IDCT/fancy upsampling/colour conversion Neon symbols, licenses and relocatability.
The core manifest also binds build helpers and shader resources. Ordinary SwiftPM
consumers need no Zig compiler; native source edits require artifact regeneration.

The dedicated JPEG correctness/sanitizer reproduction takes a verified source
archive, e.g. after a native rebuild retained under an explicitly configured
`SWIFTSPICE_NATIVE_WORK_DIR`:

```sh
python3 tools/validate-jpeg-simd.py .build/native-rebuild/downloads/libjpeg-turbo-3.2.1.tar.gz --asan --output .build/jpeg-asan.json
```

The archive argument is an explicit input, not an implicit dependency on another
repository's cache. Licenses and relinking boundaries are in
[the notices](../../THIRD_PARTY_NOTICES.md).
