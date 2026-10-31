# Validation status — 2026-10-31

This is an unreleased local extraction of the production Zig library into
`/Users/beribeli/Workarea/libmaspice`. It does not publish or replace spice-swift
0.4.4. The old library and Maspice checkout/editable dependency are unchanged.
The project uses Zig 0.17.0 ReleaseSafe, Xcode 27.2 / Swift 6.4.2, arm64 and a
macOS 26 deployment target. Tests ran on the current macOS 27.2 host.

## Fresh results in this repository

- Pinned-source native rebuild: JPEG 3.2.1, usbredir 0.15.0, libusb 1.0.30,
  production Zig QUIC, and the owned core. No old `.build` was copied.
- Complete installed C static archive: Release and ASan/UBSan consumers exercise
  foundational ABI, Security ticket encryption and mixed wire/Desktop/Source
  ownership. Release dependency closure passes. CSpiceZig and CSpiceQUIC retain
  every old public export; the foundational API is additionally installed.
- Actual SwiftPM Release consumers: session/reconnect, native MJPEG, audio,
  Agent, USB, WebDAV and SwiftUI. Graph and linked-symbol checks exclude all old
  Swift runtime modules. Public API executable and both Swift Surface tests pass.
- Native source aggregate: 101 root Zig tests, generated/colocated tests,
  protocol/pixel and Swift differential tests, real authenticated loopback
  TCP/TLS, cancellation, semi/seamless/switch-host migration, C ABI sanitizer
  consumers, service/allocation/ownership checks and the standalone Swift ASan
  boundary. The pixel Data copy isolation and retired Main sender regressions
  remain included.
- Graphics: 31 Zig tests cover Surface transactions, generation fencing, failed
  publication, ring slots, retained IOSurface/Metal leases and GPU completion.
  Nine MPS pattern comparisons have **zero channel difference** from the
  independent Swift Lanczos oracle. Native graphics ASan/UBSan checks pass.
- VideoToolbox decoder fixtures: H.264 Baseline/High and H.265 Main each report
  actual hardware sessions (software/query-failure paths rejected), with maximum
  channel deltas 1/4/2 against the existing pixel tolerance. Three retained frames
  survive each decoder's destruction; parameter changes rebuild three sessions.
  Forty synthetic conversions match Swift exactly, 11 video/scheduler tests and
  36 native valid/truncated AVCC ASan/UBSan ownership cases pass. This validates
  the local decoder/Surface fixture path, not packaged end-to-end advanced video
  from a real peer through physical presentation.
- QUIC: 3,360 decoder cases, 10,111 invalid arguments, 880 byte-identical encoder
  comparisons, unchanged upstream-header C ABI/allocation/callback checks,
  840 additional images, 4,198 truncations and 20,000 mutations. The independent
  C oracle is freshly downloaded from the pinned hash, not an old build cache.
- JPEG: 20 fresh ASan scalar/Neon comparisons, including exact pixels, guards,
  padding and alpha, pass with the pinned source archive from this rebuild.

The independent clean directory was populated only from Git-index files, with an
empty Zig global cache and no copied `.build` or `.git`. Its installed C consumers
and Swift PublicAPIConsumer pass. QUIC archives are byte-identical across the two
roots, and the core application's object plus every native bridge object match.
The bundled `compiler_rt.o` differs between isolated compiler caches, so the
combined core archive is not claimed byte-for-byte reproducible across caches.
Source rebuildability and relocatability are verified; each actual archive is
bound to its own SHA-256 in provenance.

The final aggregate's **388** source/oracle/fixture hashes match. All imported
production/generator/reference code checked by the migration audit (292 files)
is byte-identical after normalizing the one relocated QUIC include. The new
unified C entrypoint is separately recorded. Full-import whitespace checks show
11 pre-existing source/vendor files; their original bytes are retained. New build
and tooling code passes the whitespace check.

Full runtime logs stay in `.build/migration/`; reproducible commands are in the
README. `docs/migration/validation.json` records final source/artifact/log hashes,
command outcomes and precise limits. Historical old-layout reports are separately
labeled under `docs/history` and are not used as fresh verification.

## Instrumentation and external boundaries

Zig uses ReleaseSafe checks; it is **not** claimed ASan-instrumented. The standalone
boundary gate compiles Swift with ASan and C/Objective-C with ASan/UBSan. Prebuilt
native dependencies are unsanitized in those runs. The actual SwiftPM Release
consumers are unsanitized. Installed-archive sanitizer tests instrument the C
consumer, not the archive. The separate JPEG gate freshly instruments both scalar
and Neon builds. QUIC reports distinguish instrumented source-built adapters from
unsanitized shipped adapters. No blanket coverage percentage is asserted.

The old 727 Swift tests / 75.63% coverage primarily tested original Swift
reference/oracle modules. They are preserved as history, not new Zig coverage.

Physical on-screen presentation with nonzero `presentedTime`, successful full
advanced-video hardware decoding, real SPICE peers and live migration, physical
USB/smartcard/audio devices, clean macOS 26, production signing/notarization and
performance improvements remain unaccepted. GPU completion, generated peer
fixtures and framework linkage do not close those gates. No screen wake/unlock,
general clipboard operation or physical USB/microphone access was used.
