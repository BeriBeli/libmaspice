# libmaspice

Unreleased SPICE client library for Apple Silicon, extracted from the production
Zig implementation in spice-swift. Zig owns protocol, transport policy, sessions,
channels, codecs, rendering and bounded host services. Narrow Objective-C/C
bridges adapt Apple APIs. The optional Swift package preserves `import SwiftSpice`.

Requires Zig **0.17.0**, Apple Silicon, macOS **26+**, Xcode **27.1+** with the
Metal Toolchain, and Python 3. Local TCP/TLS test fixtures additionally use an
OpenSSL CLI supporting RSA OAEP/SHA-1 (this run used OpenSSL 4.1.0). Swift consumers require Swift tools **6.4**.
The extraction is validated with Xcode 27.2 / Swift 6.4.2. The core always builds
in **ReleaseSafe** (`.safe` in Zig 0.17's build API). It has no Swift runtime dependency.

```sh
zig build                   # zig-out/lib/libmaspice.a, include/, share/libmaspice/
zig build test              # Zig + C ABI + independent Swift comparisons + sanitizers
zig build test-installed    # C consumers against installed complete static archive
zig build xcframework       # refresh the local SwiftPM core + QUIC artifacts
zig build test-package      # real SwiftPM Release consumers, runtime graph/symbol checks
swift test --disable-sandbox --no-parallel -Xswiftc -warnings-as-errors
swift run --package-path test/PublicAPIConsumer --disable-sandbox PublicAPIConsumer
zig build test-quic          # pinned independent upstream C oracle; first run downloads source
```

`zig build` installs a complete static archive including QUIC, JPEG and USB native
dependencies, the C headers, two Metal libraries, and license notices. Apple system
frameworks and zlib must still be linked; `zig-out/lib/pkgconfig/libmaspice.pc`
records those flags. `libmaspice-core.a` and `libmaspice-quic.a` are also installed
for separate-component relinking. Supply explicit shader paths to the native APIs.
`tools/validate-installed.sh` is a working C linker example.

Swift consumers use `.package(path: "/path/to/libmaspice")` and
`.product(name: "SwiftSpice", package: "libmaspice")`. The Swift module/product
name stays `SwiftSpice`; the repository/package identity is `libmaspice`.
The checked-in XCFrameworks let Swift consumers build without a Zig compiler.
After changing native source, run `zig build xcframework` before SwiftPM builds.
The shader plugin builds resources from this repository, with no runtime path
back to the source checkout. This is a local development package, not the
published spice-swift 0.4.4 release.

The layout follows selected conventions from [Ghostty at the recorded commit](https://github.com/ghostty-org/ghostty/tree/fbed180a5f181915c92a8f2f561903a6e4645b5a),
adapted to a library. See [layout](docs/LAYOUT.md), [migration and contracts](docs/MIGRATION.md),
[validation status](docs/STATUS.md), and [licenses](THIRD_PARTY_NOTICES.md).

- `src/`: production Zig core; `src/platform/apple/`: narrow native bridges;
  `src/build/`: build graph helpers.
- `include/`: C contracts and Clang module; `bindings/swift/`: public Swift adapter.
- `pkg/quic/`: full production QUIC codec, not the benchmark prototype;
  `pkg/apple/artifacts/`: source-bound static dependencies for SwiftPM.
- `resources/`: protocol schema and Metal shaders; `tools/`: reproducible gates.
- `test/native/`, `test/swift/`, `test/fixtures/`, `test/quic/`, `test/oracle/`:
  owned tests, fixtures and independent references. Old Swift algorithms are test inputs only.

To rebuild JPEG 3.2.1, usbredir 0.15.0 and libusb 1.0.30 from pinned downloads:

```sh
./tools/build-native-dependencies.sh
zig build check-native
```

CMake, curl, make and the native toolchain are needed for this maintainer operation.
Source URL/SHA-256 checks, archive hashes, arm64/macOS 26, Neon symbols, licenses
and relocatability are retained. It does not use Homebrew runtime libraries.
QUIC and USB components retain LGPL-2.1-or-later obligations; sources and separate
archives are provided for modification and relinking.

Local tests do not establish real SPICE peer/device compatibility, successful
advanced-video hardware decode, physical screen presentation with nonzero
`presentedTime`, clean macOS 26 support, or distribution signing/notarization.
Those remain external acceptance gates. Default local gates do not wake or unlock the screen,
opening a physical USB device, recording a microphone, or using the general clipboard.
`test-video` is an explicit hardware acceptance command; failure remains a failure.
The retained native window/presentation scripts are manual acceptance tools and
are not run by `zig build test`; visible-screen setup remains user-controlled.
