# Third-party native dependencies

libmaspice contains these pinned native components:

- libjpeg-turbo 3.2.1: IJG, zlib and BSD-3-Clause licenses.
- Zig port of spice-common QUIC at commit `71e45706981973014eaab3d4b533d35d79e19ffa`:
  LGPL-2.1-or-later, including the Red Hat attribution in `pkg/quic`.
- Zig 0.17.0 standard library/runtime: MIT (Expat).
- usbredir 0.15.0 and libusb 1.0.30: LGPL-2.1-or-later.

Upstream source URLs, SHA-256 values and build flags are in
`tools/build-native-dependencies.sh`, `tools/package-apple.py` and each artifact's
`BUILD_PROVENANCE.txt`. Native license texts are under
`pkg/apple/artifacts/*/Licenses/`; the owned QUIC sources and corresponding texts
are in `pkg/quic/`. Rebuild dependencies with `tools/build-native-dependencies.sh`
and the owned Zig components with `zig build xcframework`.

The MIT-licensed core/native bridges are separate from the LGPL QUIC and USB
components. `zig-out/lib/libmaspice.a` combines all components; it is not solely
MIT-licensed. Installation copies third-party notices/license texts, as well as
separate core and QUIC archives. Source/build scripts and replaceable native
artifacts allow recipients to modify and relink LGPL components. Porting QUIC
from C to Zig does not remove its license obligations. Test-only copies of the
original Swift implementation retain the project license, and the independent
QUIC reference retains its upstream LGPL notice.
