# Current implementation and validation status

Reviewed against the working tree on 2026-10-31. `VERSION` identifies **0.4.4**;
the Zig QUIC backend, JPEG/MJPEG Neon backend and stream-feedback work below are **unreleased**.
The validation results recorded here come from those implementation tasks;
their test counts describe those runs, before retiring the remote experiment tooling.

For setup, use the [README](../README.md). Stable design rules live in
[ARCHITECTURE.md](ARCHITECTURE.md). This page records implementation and known
validation limits; it is not a queue of inherited development tasks.

## Zig core package switch (2026-10-31)

The working-tree `SwiftSpice` product now uses `Sources/SpiceZigSwift` and the
owned `CSpiceZig` static archive. Original Swift modules are independent test
references, absent from the production dependency graph and checked linked
consumer/Maspice runtime symbols. Viewer offline rendering uses native Surface;
local oversized clipboard publication preserves the wire and queue bounds.

- 727 Swift tests passed normally and under ASan. Coverage is 75.63% against the
  unchanged 62% threshold. These totals primarily include retained Swift
  reference/oracle modules, not Zig-core coverage. The original reference
  rendering tests remain enabled.
- Actual SwiftPM Release consumers passed TCP/session, native MJPEG, optional
  services and SwiftUI checks; public API execution and Release library/closure
  checks passed. These Release consumers are not sanitizer-instrumented.
  Independent Zig tests and dedicated C ABI/Swift boundary sanitizer builds
  provide separate evidence for the new core; see the migration ledger.
- Maspice's existing editable checkout passed 55 application and four session
  logic tests, Release app assembly, relocatability and local ad-hoc signing.
  The published release pin stays 0.4.4; this work has not been released.
- The earlier live-server/hardware results below are historical Swift evidence.
  Fresh Zig live-peer/device, visible-screen timestamps, successful advanced video
  hardware, clean macOS 26 and distribution signing/notarization remain pending.

See [the migration ledger](ZIG_MIGRATION.md) for paths, reproductions and the
source/packaged-runtime distinction. Local unit or GPU-completion checks are not
physical presentation evidence.

## Toolchain and dependency refresh (2026-10-30)

The package and public API consumer now require Swift tools 6.4. Local checks
used Xcode 27.1 / Apple Swift 6.4 on the M4 Pro host. CI selects the same Xcode
on the `xcode-27` hosted image; that remote CI run has not been performed here.
libjpeg-turbo is now 3.2.1; the Zig QUIC port is based on spice-common commit
`71e45706981973014eaab3d4b533d35d79e19ffa`, without downloading spice-gtk.
usbredir 0.15.0, libusb 1.0.30 and the optional benchmark 1.38.1 remain current.
The libusb build disables the SDK 27-only `pipe2` probe to retain macOS 26 support.

- The complete `make all` baseline passed: warnings-as-errors library/public API
  builds, generated-source consistency, C analysis, native closure, all **725**
  current tests, all 725 under AddressSanitizer, and coverage (**80.52%** lines,
  above the unchanged 62% floor). The smaller count than the historical 908-test
  run below reflects the retired remote campaign targets.
- Fresh ASan-instrumented libjpeg-turbo 3.2.1 scalar and Neon builds passed all
  **20** exact-pixel/guard/padding/alpha comparisons.
- Maspice's 55 application tests passed against this local checkout as well as
  the pinned 0.4.4 release. Its latest Sparkle 2.10.1 Release app assembly,
  relocatability audit and ad hoc signature verification passed.
- The independent [Swift/Zig QUIC experiments](../Benchmarks/QUICExperiment/README.md)
  passed their differential and malformed-input checks. After bit-reader and
  compile-time specialization changes, Zig ReleaseSafe used 13–15% less CPU
  time than C on 1080p synthetic gradients in three repeated runs, and was also
  faster on the measured flat/noise cases. These are synthetic results; neither
  benchmark is evidence of complete-library or live-peer performance. The
  production replacement is recorded separately below. No new live-server or
  clean macOS 26 validation is claimed.

## Zig QUIC production integration (2026-10-30)

The [complete Zig codec](../Sources/CSpiceQUIC/README.md) is now packaged in the
existing arm64/macOS 26+ CSpiceQUIC artifact. Decoding, encoding and C ABI gates
were completed in that order before application integration. The C layer only
adapts the ABI/errors; it does not call the upstream C algorithm. ReleaseSafe
checks and the application resource limits remain enabled.

- 3,360 independent-C full-decoder comparisons, including all eight conversions,
  chunking, signed/padded strides, metadata and context reuse.
- 880 encoder cases produced identical C bitstreams and original pixels in both
  cross-decoder directions, including `more_lines` and one-word output chunks.
- An unchanged C consumer object compiled against upstream quic.h passed 864
  pixel/guard cases, 96 allocation-failure trials, callback failures and fatal
  `longjmp` cleanup checks. C adapters/consumers passed ASan/UBSan; Zig is
  ReleaseSafe and guard/allocation tested, not claimed ASan-instrumented.
- The shipped artifact passed the same C consumer gate, plus 840 valid images,
  4,198 truncations and 20,000 mutations through the actual application bridge.
- SwiftSpice's full `make all` passed again: 725 tests, ASan, public API/build,
  C analysis, native closure and 80.53% line coverage. The artifact's C ABI
  sanitizer gate is now also in `make all` and CI; remote CI has not run here.
- Maspice passed 55 application tests and 4 session-logic tests with this local
  editable checkout. Its final Release app passed native closure and ad hoc
  signature verification, and contains the Zig decode symbol and bundled
  license notices. Its `exact 0.4.4` release requirement and original resolved
  file are preserved. This is local integration, not a published dependency.

Detailed reproducible records are linked from the
[QUIC validation guide](../Benchmarks/QUICExperiment/README.md). Full-library
performance on real images, live-server display/orientation and clean-machine
acceptance remain pending; historical synthetic decoder timings are not those
acceptance results. No version/tag has been published.

## Feature evidence

| Area | Recorded evidence | Still pending |
| --- | --- | --- |
| Main, TCP/TLS, ticket authentication, Display, Cursor, Inputs | Local tests and live QEMU/SPICE desktop and trusted-TLS checks | Fresh peer checks use an externally supplied SPICE endpoint |
| JPEG, LZ, GLZ, ZLIB-GLZ, QUIC, MJPEG | Bounded decoders, independent golden fixtures, transactional Surface tests; latest JPEG and feedback evidence below | Installed-app QUIC orientation check and actual-session MJPEG quality/latency validation |
| H.264/H.265 | Explicit opt-in VideoToolbox decode and Rocky yuv420p native-Metal interoperability on M4 Pro | Broader profiles/resolutions and real-window hardware matrix; MJPEG remains the default |
| IOSurface/Metal desktop | Revisioned publication, bounded native composition, focused tests and M4 Pro window evidence | M1, real 1080p/4K, fixed 60 Hz/ProMotion, resize/occlusion and fresh comparative performance |
| Agent | Rich-guest clipboard, file transfer and monitor-layout checks | Fresh peer validation requires a guest with Agent support |
| Playback/Record | Local protocol, preallocated rings and deterministic host-adapter tests | Audible playback, route switching and physical microphone capture |
| WebDAV | Earlier Rocky direct GET and davfs2 mount/read evidence; bounded executor changes tested locally | The executor path has not been revalidated against a live guest |
| Smartcard, USB, migration | Local protocol/state-machine tests | Real devices and live semi-seamless/seamless migration |
| Distribution | Recorded arm64 packaging, closure and ad hoc signing checks | Developer ID, notarization, Gatekeeper and a clean Apple Silicon macOS 26 host |

Local implementation, deterministic tests, live interoperability, hardware
validation, and performance measurements are separate claims. A passing result
for an earlier implementation does not verify every subsequent release.

## Local performance tooling

The opt-in `SpiceBenchmarks` executable replaces remote benchmark orchestration
with fixed local codec, wire, protocol, and Surface workloads. See the
[benchmark guide](../Benchmarks/BENCHMARKS.md) for measurement boundaries and
same-machine baseline comparisons. `spice-probe`, viewer presentation diagnostics,
and local frame-correlation tests remain available for live-session investigation.
Local timings do not establish end-to-end interaction latency or peer interoperability.

## JPEG/MJPEG Neon backend (2026-10-30)

The first follow-up batch to the 0.4.4 source comparison enables and requires
libjpeg-turbo 3.2.0's arm64 Neon backend. The historical `WITH_SIMD=OFF` setting
has no recorded failure rationale; the current arm64-only target builds the
upstream intrinsics without NASM/Yasm. Source version/checksum, quality flags,
headers, license and minimum macOS 26.0 target are unchanged. QUIC and USB
artifacts, stream scheduling, generation/order checks and Surface mutation
barriers are unchanged. The preceding STREAM_REPORT work is preserved.

The native build now supports `--jpeg-only`, pins upstream's date-dependent
build string, normalizes archive timestamps/uid/gid and records source,
compiler/SDK/configuration and archive SHA-256. Independent build directories
produced byte-identical artifact files/symlinks. Closure checks verify the hash
and exact-quality Neon kernels; an isolated replacement with the old scalar
archive was rejected. See [the complete source investigation, raw measurements
and reproduction commands](../Benchmarks/NativeJPEG/README.md).

Validation completed:

- Warnings-as-errors build and all **908 serial tests** passed. The expanded
  MJPEG golden test exercises all six fixtures through IOSurface and forced
  Data paths, including CMYK, grayscale, progressive and ICC-bearing data,
  with a reused handle across format/geometry changes.
- The first full run had one untouched Remote Rocky script fixture timeout
  while other native checks were running. A subsequent complete serial run
  without those overlapping checks passed; no timeout or assertion was weakened.
- `Scripts/test-address-sanitizer.sh` passed all **908 tests**. Separately, fresh
  fully ASan-instrumented scalar/Neon native libraries and the C harness passed
  all **20** small/odd/1080p/4K format comparisons, guard, row-padding and alpha
  checks. These are distinct sanitizer boundaries.
- The shipped Release archive matched the scalar baseline byte-for-byte for
  all 20 synthetic cases. The separate upstream Neon Release build passed
  **332/332** CTest tests.
- `Scripts/build-lib.sh`, C-shim static analysis, standalone harness static
  analysis, native closure, and protocol generation consistency checks passed.
- On the measured M4 Pro host (macOS 27.2, Clang 21.0.0, SDK 27.0), quality-80
  4:2:0 full-frame decoding used median **7.436 → 4.304 CPU ms/frame** at
  1920×1080 and **30.208 → 17.594 CPU ms/frame** at 3840×2160. Five alternating
  trials each decoded 30 complete frames after warmup; exact same encoded
  inputs, accurate inverse DCT and fancy upsampling were used for both builds.
  Raw CPU/wall times, frame counts and image/artifact hashes are retained.

These are local codec results, not user-session latency, displayed FPS or
spice-gtk comparison claims. Actual-server quality recovery, M1 and real-window
1080p/4K validation remain pending. No installed Maspice application was
replaced/launched, and the current remote desktop was not operated or
reconnected. No push, tag or release was made. Drawing/RAW/cursor compatibility,
motion ACK flow control and codec-policy visibility remain later scoped work.

## Display stream feedback correction (2026-10-30)

SwiftSpice now advertises and implements `STREAM_REPORT`, following spice-gtk
0.43 arrival-margin accounting. See [the comparison](STREAM_FEEDBACK.md) for the
protocol contract and the spice-server 0.15.2 rate-control path that otherwise
cannot receive positive recovery feedback.

Validation completed:

- All 908 tests passed with `swift test --disable-sandbox --no-parallel
  -Xswiftc -warnings-as-errors`, including the existing admitted-late-frame,
  frame-order and Surface mutation-barrier regressions. The first parallel run
  encountered timeout failures in untouched filesystem/WebDAV and remote-script
  fixture tests; the repository CI/release serial invocation passed in full.
- Warnings-as-errors build and protocol generation consistency check passed.
- A task-isolated Linux container built the official spice-server 0.15.2
  `server/tests/test-display-streaming` peer. The built `spice-probe` connected
  over a loopback-only listener; the installed Maspice session was not used.
- The unmodified streaming scenario accepted feedback and the probe exited
  successfully after 25 seconds. A second 35-second scenario set the fixture's
  `sized` flag to 1 and `test->wakeup_ms` to 40 to extend continuous video.
  Both used `SPICE_BIT_RATE=1`, a low initial bandwidth estimate rather than
  an imposed network rate limit; the server encoder/feedback code was unmodified.
- In the extended scenario, the peer accepted 54 reports covering 270 arrivals,
  with zero reported late arrivals and no report-ID mismatch. It logged 12
  bitrate increases, from an initial stream allocation of 0.80 Mbps to 1.92
  Mbps. JPEG quality evaluation fell to 20 and ultimately selected 80.
  The client recorded 96 native video compositions and zero GPU errors, then
  disconnected successfully. This is protocol/rate-recovery evidence, not an
  end-to-end latency benchmark or a comparison against another client.

The remote server's version and reason for its initial quality downshift remain
unknown. Recovery in the user's actual session is still pending a separate test
build. No installed application was replaced, and no release was published.

## Verification entry points

[README build and test instructions](../README.md#build-and-test), the
[Makefile](../Makefile), and [CI workflow](../.github/workflows/ci.yml) define the
current local checks. `make all` runs the aggregate gate, including the public
API consumer, serial tests, C analysis, AddressSanitizer and coverage.

Performance and native dependency checks are documented separately:

- [Local benchmark suite](../Benchmarks/BENCHMARKS.md)
- [Native artifact provenance](../Artifacts/NATIVE_DEPENDENCIES.md)

Live validation uses an externally configured endpoint with `spice-probe` or
the actual client. Earlier passing runs do not prove current host or peer behavior.
