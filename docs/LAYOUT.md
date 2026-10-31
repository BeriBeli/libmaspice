# Project layout reference

Inspected the official `ghostty-org/ghostty` main branch at
`fbed180a5f181915c92a8f2f561903a6e4645b5a` (2026-10-30T20:45:24Z), retrieved
2026-10-31. Its root build.zig imports src/build/main.zig and assembles separate
library, executable, resource and test steps. build.zig.zon pins package identity,
Zig 0.17.0 and dependencies. include holds public headers/module maps; pkg holds
support packages; src/build holds archive/Metal/XCFramework helpers; test holds
external harnesses, with colocated Zig tests also present. macos/platform code
and resources sit outside the terminal core.

libmaspice adopts the root Zig build/manifest, public include directory, pkg
boundary, src/build helpers, explicit native platform layer and independent test
assets. Ghostty is a mature reference, not the only standard for Zig projects.
No terminal UI, terminal protocol, font, GTK, Wayland, translations, app packaging,
remote dependency graph or unrelated build complexity was copied.

The default graph compiles the complete C ABI through `src/lib.zig` and QUIC
through `pkg/quic/abi.zig` using std.Build, compiles
native bridges with Xcode clang, combines deterministic archives with Apple
libtool, and compiles/install shaders. The `xcframework` step packages exactly
those graph outputs. Python/bash are narrowly used for Apple packaging and the
existing mixed-language differential/ABI harnesses; they do not select a second
production implementation.

The production Swift package has no old-core/reference targets at all. Tests
compile the required source oracles explicitly from test/oracle/swift. Resources
and fixtures are repository-owned. Test logs and all compiler caches go under
ignored .build/.zig-cache/zig-out; they are not inputs copied from spice-swift.
