# Production extraction into libmaspice

The baseline is the existing dirty working tree of spice-swift, not its last
commit and not a benchmark prototype. `migration/spice-swift-before.json` and
`migration/spice-mac-before.json` record Git HEAD/status before extraction.
`migration/source-map.json` records individual old/new paths and SHA-256 values
at copy time. The extraction leaves both old repositories and their local
editable consumption settings untouched. Subsequent Zig core work belongs here.

## Source mapping and preserved contracts

All production `Sources/SpiceZig/*.zig` moved to `src/` unchanged. C/Objective-C
bridges moved to `src/platform/apple/`; their sole source adjustment is the QUIC
header include path in `codec_bridge.c`. Headers/module map moved to `include/`;
the module map additionally exposes the existing foundational header. All Swift
facade files moved unchanged to `bindings/swift/SpiceZigSwift/`. The complete
production QUIC implementation moved unchanged to `pkg/quic/`, including its
validation-only exports, LGPL-2.1-or-later, Red Hat and Zig MIT notices.

In the table, original core filenames were under `Sources/SpiceZig/`; new core
filenames are under `src/`. Native bridges were beside the old core and are now
under `src/platform/apple/`. All old `Tests/SpiceZigTests` tests/harnesses are in
`test/native`. Gates are in `tools` (formerly `Scripts`).

| Contract | Production modules / new location | Reproducible validation |
| --- | --- | --- |
| Wire, protocol, generated schema | bytes, framer, generated; `resources/protocol`; `tools/protocol-generator` | `zig build test`: generator checks, root Zig tests, independent wire differential and C ABI |
| TCP/TLS, certificate policy, ticket authentication | transport, endpoint, ticket, link; network_bridge.m, security.c | root tests, Security encryption/decryption C consumers, TCP/TLS loopback, cancellation and failures |
| Session/channel cancellation, Main/Agent, migration | session, channel, main_channel, supervisor, migration_coordinator, child_connections, desktop_child | session/network/supervisor integration, semi/seamless/switch-host peers, delayed sender cleanup and allocation failures |
| Display, codecs/cache, GLZ, Surface | display*, image*, glz, lz, native_codecs, surface, frame_publisher; `pkg/quic` | image fixtures, Swift pixel/protocol oracles, root/graphics tests, `zig build test-quic` |
| Apple GPU/leases and presentation | graphics, presenter, damage, desktop_source*, presentation_policy; graphics_bridge.m; `resources/shaders` | `zig build test` graphics/MPS exact comparisons, Surface transaction/failed publication tests and native C sanitizer consumer |
| Video and generations | video, stream_decoder, stream_scheduler, video_failure; video_bridge.m | deterministic failure/typed-error, stream/reference lifetime and MJPEG tests in aggregate; `zig build test-video` is explicit hardware acceptance |
| Playback/Record | audio*, audio_route, audio_ring, audio_buffer, audio_native, audio_runner; audio_bridge.m | independent wire/ring/converter oracles, offline engine, callback/epoch/cancellation, TCP migration and Swift facade |
| Clipboard/files/monitor Agent | agent*, clipboard, file_source, file_transfer, monitor_config, pasteboard; pasteboard_bridge.m | Agent wire/state/oracle comparisons, explicit named pasteboard, allocation/limits, C/Swift authenticated loopback and file bytes |
| WebDAV | webdav*, webdav_path, webdav_fs, webdav_server; webdav_bridge.m | parser/filesystem oracles, symlink/explicit-root policy, shared admission and sender ownership, TCP migration and Swift facade |
| Smartcard/USB | smartcard*, vmc, usb*, usb_shared_backend; `pkg/apple/artifacts/CUSBRedir.xcframework` | peripheral wire differential, native parser cycles, allocation/callback failures, TCP migration; no physical device opening |
| C API | *_abi.zig, `include/` | source ABI consumers and `zig build test-installed` against the complete installed archive |
| Swift public consumption | `bindings/swift/SpiceZigSwift`; root Package.swift | `zig build test-package`, dedicated Swift boundary ASan in aggregate, `swift test`, `test/PublicAPIConsumer` |

The pixel `Data` copy-on-write regression remains in
`test/native/swift-session-consumer.swift`; sender rebind/drain and cross-group
migration cleanup remain in the imported session/Main and public TCP regression
harnesses. No production algorithm was rewritten during extraction. The new `src/lib.zig`
imports the foundational, Desktop and host ABIs into one compilation unit. This
avoids duplicate shared ticket exports when a C client uses both APIs; the new
installed-consumer test links and destroys both through the complete archive.

The Apple path retains hardware-only VideoToolbox status queries and explicit
failure, format/reference/generation fencing, CVPixelBuffer/IOSurface/Metal
leases until GPU completion, Surface mutation barriers and failure-not-published
behavior, nearest filtering for integer scaling and direct MPS Lanczos for
fractional scaling. JPEG retains accurate integer DCT, smooth/fancy upsampling
and the arm64 Neon kernels. ReleaseSafe, integer/boundary checks, resource caps,
backpressure, cancellation and joined cleanup stay intact. These properties are
validated only to each gate's actual scope; a successful link is not acceptance.

## Test assets and native dependencies

Original Swift algorithms are repository-owned differential inputs under
`test/oracle/swift/`; fixtures from the old codec/video/core test bundles are
under `test/fixtures/`. They are absent from Package.swift and all library build
inputs. The independent QUIC C oracle lives in `test/quic`; it fetches the pinned
upstream archive and checks SHA-256, rather than reading the old build cache.
The JPEG scalar/Neon harness is in `test/jpeg` and `tools/validate-jpeg-simd.py`.
No `.git`, old `.build`, credentials or old absolute runtime paths were copied.

`pkg/apple/artifacts` preserves the static named-framework boundary for SwiftPM.
The new build graph compiles and packages CSpiceZig/CSpiceQUIC from this repository.
`tools/build-native-dependencies.sh` rebuilds JPEG/USB from exact upstream
versions/hashes and then invokes the same graph. `tools/package-apple.py` records
source/header/build/shader hashes and archive hashes. The closure gate validates
arm64, deployment target, source correspondence, required exports, JPEG Neon,
license content and relocatability. The complete installed archive includes
LGPL components; separate archives and sources support modification/relinking.

The repository version is `0.1.0-dev` solely as an unreleased package identity.
No remote, tag or release is created. The old Maspice editable checkout remains
usable and unchanged; its earlier app evidence is preserved as historical, not
reattributed to this new repository. The old repository continues to own the Probe and Viewer consumer applications;
this repository publishes the library product and owns independent C/Swift
consumer fixtures. An application can adopt the new path in a
separate local configuration change after this handoff.
