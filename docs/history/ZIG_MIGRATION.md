# Full-library Zig migration

Work started 2026-10-30 against the existing, dirty local checkout. The
working-tree SwiftPM product and Maspice's local editable dependency now use the
Zig core. This is an **unreleased local replacement**, not fresh live-peer or
physical-device acceptance. Original Swift implementations remain test oracles;
their presence alone is not evidence of Zig parity.

## Current delivery status (2026-10-31)

Supervised sessions, child-channel migration, Display/image cache, GLZ,
Surface/GPU, host presentation, audio, Agent, USB and WebDAV use the Zig core
through the Swift compatibility boundary. `CSpiceZig.xcframework` contains the
ReleaseSafe core and narrow native bridges. Its source/header/archive hashes,
arm64 architecture, macOS deployment target and license texts are verified by
the native closure gate. Viewer offline drawing now uses the same Zig Surface
and immutable publication path; Probe recording goes through the native session.

The actual SwiftPM Release consumers passed independent TCP/session, native MJPEG,
audio, Agent, USB, WebDAV and SwiftUI integration. The production dependency graph
contains the four static native artifacts plus the shader build plugin, and the
linked consumer and Maspice executable contain the Zig session symbol without
old Swift core module symbols. `SwiftSpiceReference` and its supporting targets
remain test-only. Maspice's exact release requirement stays at 0.4.4; its existing
editable local dependency selects this checkout. No tag/release was published.

The final aggregate native gate passed; all 383 source/oracle/fixture fingerprints
matched before archiving `packaged-final/validation.json` and `delivery.json`.

The 727 Swift tests and the 75.63% line coverage below primarily cover retained
Swift reference/oracle modules, plus the Swift boundary. They are not Zig-core
coverage. The new core's evidence is its independent Zig tests, C ABI/Swift
boundary checks and actual packaged consumers. The SwiftPM Release consumers
are not ASan/UBSan-instrumented; the separate `validate-zig-swift.sh` build uses
Swift ASan and C/Objective-C ASan/UBSan. Prebuilt native dependencies and Zig
itself are not sanitizer-instrumented; Zig retains ReleaseSafe checks.

Full Swift regression and ASan runs passed 727 tests each. The unchanged coverage
gate passed at 75.63% (62% floor). The public API executable, Release library build,
55 Maspice tests, four session-logic tests and local Release app assembly/closure/
ad-hoc signature checks passed. Original reference shader tests retain their
assertions and now locate their renamed SwiftPM resource bundle correctly.

Local clipboard publication now borrows caller-owned text until the joined worker
consumes it; oversized text is never copied into the bounded Agent queue. Native
snapshots retain only size/change metadata above the wire cap. A 33 MiB private
named-pasteboard write, limits before/at/after the boundary, repeated snapshots,
disable/re-enable and stop/cancellation checks passed. The snapshot metadata path
matches the original Swift state machine for old ownership, requests and stale
guest data. Remote protocol and owned-byte limits are unchanged.

Physical screen visibility/nonzero presented timestamps, successful advanced-video
hardware decoding, real SPICE servers/migration/devices, clean macOS 26 and
production signing/notarization remain external gates. GPU completion and injected
test visibility do not satisfy physical presentation. No end-to-end performance
gain or full interoperability parity is claimed.

Evidence is under `.build/zig-migration/` (local, not committed):
`swiftpm-all.log`, `package-asan.log`, `package-coverage.log`,
`package-integration.log`, `public-package.log`, `package-build-lib.log`,
`packaged-analysis.log` and `packaged-core-final.log`. Reproduce native source
checks with `Scripts/validate-zig.sh` and packaged runtime checks with
`Scripts/validate-zig-package.sh`. Historical sections below describe their
individual milestones; this section supersedes earlier pending integration items.

## Source and ownership boundary

`Sources/SpiceZig/` is the production core implementation. `Sources/CSpiceQUIC/` remains
the sole production QUIC source: do not fork or replace it with the benchmark
prototype. Its LGPL-2.1-or-later, Red Hat and Zig MIT notices remain required.
The new library sources use the repository MIT license.

Protocol parsing, state machines, scheduling, resource accounting, codecs and
rendering policy belong in Zig. C/Objective-C adapters may expose Apple APIs,
block callbacks and Objective-C message sends; they must not contain channel or
session policy. Swift remains the public consumer/concurrency and SwiftUI boundary. The old
Swift core is retained only for independent tests, not application runtime. A C
ABI alone would not establish migration; the packaged consumers exercise it.

All new Zig validation/build commands use Zig 0.17.0 ReleaseSafe with boundary
and integer checks. The local compiler and installed standard library are the
build API authority; language reference:
<https://ziglang.org/documentation/0.17.0/>. No ReleaseFast or runtime-safety
override is allowed to substitute for optimization evidence. C ASan/UBSan does
not imply Zig ASan instrumentation.

Wire framers have one serialized owner. Received byte storage is immutable and
reference counted; returned batches retain ownership beyond framer reset or
destruction. Synchronous readers only borrow while the owner lives. Cross-task
work must retain an owned slice, generation and cancellation context. Allocator
ownership is explicit and allocation failures must preserve a retryable queue.
The C ABI uses opaque handles and copies input chunks; only batch lifetime owns
returned body pointers. Native verification blocks retain immutable TLS policy independently; transport state/read/write callbacks are drained before their owners are destroyed. Session callers must cancel and join active workers before destruction.

## Migration contract ledger

`Pending` means the capability is **not implemented in the new Zig library**.
Swift source paths below are under `Sources/`; evidence names refer to `Tests/`.
Existing Swift evidence is a behavioral oracle, not proof of Zig parity.

| Area / required behavior | Current source | Zig location / state | Acceptance evidence / outstanding work |
| --- | --- | --- | --- |
| Checked scalar endian reads/writes, relative addresses, truncation without cursor movement | SpiceWire/ByteReader.swift, ByteWriter.swift, SpanByteReader.swift, SpiceAddressResolver.swift | SpiceZig/bytes.zig; implemented | Reader/writer/address tests; 9,328 wire Swift differential cases |
| Immutable receive owners; full/mini headers; 64 MiB message, 128 MiB queue, 4096 segments; coalesce once; no byte compaction | SpiceWire/OwnedBytes.swift, MessageFramer.swift, WireError.swift | SpiceZig/bytes.zig, framer.zig; implemented | All split boundaries; owner survival after reset/destroy; limits; allocation-failure enumeration |
| LIST ordering, main prefix last, nonoverlap/metadata checks, one physical ACK even empty list; malformed retry never consumes | SpiceWire/MessageFramer.swift | SpiceZig/framer.zig; implemented | InboundMessageBatchTests contract port; 9,328 Swift differential cases, 6,000 mutations |
| Schema generation, generated link/common/Main/Inputs/Display records | SpiceProtocolGenerator/main.swift, SpiceProtocol/GeneratedMessages.swift; ProtocolSchema/spice-0.14.5.json | SpiceZig/generated.zig, protocol_support.zig; all 35 schema declarations implemented; maintainer generator is still Swift | Same generator with --zig, unchanged Swift output, stale checks; all records encode/decode/truncation/trailing tests; exact link/report fixtures; porting the generator tool itself remains pending |
| Hand-written Display/Cursor/Agent/clipboard/file/monitor/audio/WebDAV/smartcard/VMC/migration parsing | SpiceProtocol/*Protocol.swift, ServerMessageDecoder.swift, ProtocolConstants.swift | SpiceZig/agent.zig, migration.zig, display_wire.zig and stream_wire.zig implement Agent stream, Main migration, Display draw/stream/monitor payloads; cursor_wire.zig, audio_wire.zig, smartcard_wire.zig, vmc.zig and webdav.zig implement Cursor/audio/peripheral protocols; agent_services_wire.zig implements clipboard/file/monitor Agent payloads | Existing SpiceProtocolTests and malformed/golden fixtures; no unknown enum acceptance |
| TCP exact reads/writes, backpressure, close/cancel unblocks pending I/O | SpiceTransport/*, SpiceTransportNetwork/NetworkSpiceTransport.swift | SpiceZig/transport.zig with thin network_bridge.m; implemented | Loopback fragmented TCP/EOF, blocked read/backpressured write cancellation, TLS timeout, concurrent handshake cancellation; native callback ASan/UBSan |
| TLS system trust, custom CA with hostname/SAN/EKU, virt-viewer full ordered subject and chain/validity, insecure only explicit testing | SpiceTransportNetwork/* | SpiceZig/tls.zig, subject.zig and native Security adaptation; implemented | 13 TLS policy fixtures: DER/PEM/escaped PEM, trusted CA, wrong hostname/EKU, ordered complete subject, expiry, system rejection, explicit insecure; native verification owns policy independently |
| Ticket public-key parsing, RSA encryption, authenticated link, capabilities | SpiceCryptoSecurity/SecurityTicketEncryptor.swift, SpiceCore/LinkHandshake.swift | SpiceZig/ticket.zig, security.c, link.zig; exact-I/O state machine connected to native TCP/TLS | Real RSA-1024 OAEP-SHA1 decrypt comparison for SPKI/PKCS1, empty/6/60-byte passwords; 162 truncations, NUL/length/2048-bit rejection; allocation/cancel/transcript tests |
| Channel serial barriers, ACK windows, physical-batch accounting, ordered writes, reset/cancel | SpiceCore/ChannelConnection.swift, AckController.swift, ChannelSerialBarrier.swift, ChannelFactory.swift | SpiceZig/flow.zig, channel.zig, barrier.zig; physical completion, concurrent ordered sends, migration flush/data, retirement and cancellable serial waits implemented | LIST/empty LIST and SET_ACK batch exclusion, no serial publication after failed ACK, retirement, generation reset, allocator failures; real authenticated full/mini multi-channel peer |
| Session and child lifetimes, generation, event mailbox/backpressure, disconnect/reconnect | SwiftSpice/SpiceSession.swift, SpiceSessionEventMailbox.swift; SpiceChannels/ManagedChannel.swift | SpiceZig/supervisor.zig, child_connections.zig, mailbox.zig implement four-way preparation, joined receivers/control worker, terminal failure and bounded events; desktop_child.zig supplies real Display/Inputs/Cursor/Playback/Record/Smartcard/USB/WebDAV services | Authenticated independent multi-channel peer; sibling drain, backpressure cancellation, stale generation filtering, fresh session handles; no detached workers |
| Main discovery, multimedia time, Agent tokens | SpiceChannels/MainChannel.swift, MultimediaClock.swift | SpiceZig/main_channel.zig, agent.zig, clock.zig; implemented core bootstrap, controls, Agent FIFO send/receive, clock and rebind | Real TCP authenticated bootstrap/Agent exchange, padded PING, ACK, mouse confirmation, event/token bounds, epoch changes, prefix failure, active send cancellation/rebind, continuous-time wrap/reset/wait cancellation; session-level coordinator and handoff implemented as described below |
| Display command dispatch, image cache, cross-channel invalidation, GLZ dependency order | SpiceChannels/DisplayChannel.swift, DisplayImageCache.swift | SpiceZig/display_service.zig joins existing drawing core, shared cache/GLZ, stream dispatch and owned monitors; desktop_child.zig integrates the desktop child protocols; frame_publisher.zig implements demand/consumption gating and restorable damage | RAW/GLZ/cache-to-Surface pixels, transactional rollback, every allocation failure, shared FIFO mutation/lookup cancellation; wire differential below |
| LZ six RGB/alpha and five palette formats, orientation, limits, one output allocation, overlapping references | SpiceCodecs/LZDecoder.swift | SpiceZig/lz.zig; implemented | 11 independent upstream fixtures, 23 extended-reference/modulo/alpha cases, 573 truncations, 6,600 mutations; 7,240 Swift comparisons including accepted pixels; allocation failure tests |
| RAW, GLZ dictionary and ZLIB-GLZ | SpiceCodecs/{SpiceImageDecoder,GLZDecoder,ZlibInflator}.swift; SpiceChannels/DisplayChannel.swift | SpiceZig/glz.zig, zlib.zig, display.zig; existing RAW 32-bit formats, dictionary windows, dependencies, executor and transactional decode implemented | Four upstream images; 4,427 Swift GLZ comparisons, 40 zlib cases, future dependencies/reset/cancel, rollback and allocation failures |
| QUIC five formats, all eight conversions, encode/decode, streaming callbacks, C ABI | CSpiceQUIC/{codec,random,abi}.zig, adapter.c | Existing production Zig, reuse unchanged | Scripts/validate-quic.sh; existing independent upstream C evidence; new Display drawing core calls the existing production artifact |
| JPEG/MJPEG accurate DCT, fancy upsampling, Neon, persistent handle and IOSurface output | SpiceCodecs/TurboJPEGDecoder.swift, SpiceCodecInterop/TurboJPEGInterop.swift | SpiceZig/native_codecs.zig and codec_bridge.c reuse 3.2.1; persistent JPEG decoder supports caller-owned padded native output; stream_decoder.zig and stream_scheduler.zig integrate MJPEG with bounded latest-pending scheduling | Six JPEG and five QUIC pixel fixtures, 7,624 truncations and 11 dimension rejections; C bridge sanitizer and analysis |
| Video admission/sequence/generation and Surface mutation barriers; H.264/H.265 reference frames; STREAM_REPORT | SpiceChannels/DisplayChannel.swift, DisplayStreamReportWindow.swift; SpiceCodecs/AdvancedVideoDecoder.swift | SpiceZig/stream_decoder.zig, stream_scheduler.zig, flow.zig and surface.zig implement bounded scheduling, global per-Surface sequence, mutation barriers, reports and cancellation; Display retains existing serial advanced-frame completion | Real JPEG/H264 scheduling, late-reference decode, late-MJPEG skip, stream retirement/rebind, Surface guard tests; exact reports, timeouts/wrap; no reference-coded latest-only policy |
| VideoToolbox H.264/H.265 conversion, real hardware query and query/software failure | SpiceVideoToolbox/VideoToolboxDecoder.swift | SpiceZig/video.zig and video_bridge.m implement parameter/session replacement, retained CVPixelBuffer and native AVCC owner; actual hardware property required | Three real hardware codec fixtures, existing pixel tolerance <=4, replacement retry, software/query rejection, allocation failures, native sanitizers; no software fallback |
| Surface clipping/ROP/copy/fill, transactional cache/pixel commit, revision/damage journals | SpiceRenderer/{SurfaceStore,PixelRegion,SurfaceBacking}.swift; CSpicePixelOps | SpiceZig/surface.zig and region.zig implement existing fill/copy/copy-bits subset and disjoint clips with immutable revision publication; native and CPU video paths, lifecycle damage journals, native slot reuse and demand publication integrated | Exact pixels, bottom-up/alpha, cross-Surface/cache, malformed geometry, cancellation and allocation failure rollback |
| IOSurface/CVPixelBuffer immutable leases, three slots, 256 MiB shared budget; GPU retains until completion | SpiceIOSurface/* | SpiceZig/graphics.zig, graphics_bridge.m implement IOSurface frame leases, shared aligned-byte budget and per-Surface frame limit; video.zig owns retained CVPixelBuffer and CoreMedia sample lifetimes | Destruction/recreation with retained snapshots; allocation rollback; submitted GPU cancellation; lease survives context destruction |
| Metal native composition and presentation, failed candidates never publish, native shader resource | SpiceMetalCompositor/*, SwiftSpice/SpiceMetalPresenter.swift, SpiceMetalCompositor/Shaders/SpiceVideoCompositor.metal | SpiceZig/graphics.zig, graphics_bridge.m and surface.zig implement IOSurface/BGRA/NV12 Metal composition with immutable candidates and CPU fallback; native host view implemented, physical presentation validation pending | 31 local graphics/Surface/publication/presenter tests plus native video integration, crop/flip/clip equality, GPU resource lifetimes and native sanitizers; existing shader reused; generation/mutation/sequence checks |
| MPS Lanczos/nearest quality | SwiftSpice/SpiceMetalPresenter.swift uses MPSImageLanczosScale directly into drawable for noninteger scaling, nearest for 1:1/integer magnification | SpiceZig/graphics.zig and native adapter implement existing nearest/Lanczos policy; bounded native presenter and host view/drawable lifecycle implemented (see native desktop view evidence below) | Nine independent Swift MPS patterns match exactly; actual local Metal device, no performance claim |
| Frame demand/coalescing, lifecycle generations, immutable public BGRA and lazy CPU readback | SpiceChannels/DisplayFramePublisher.swift; SwiftSpice/SpiceDesktopSource.swift, SpiceDesktopView.swift | SpiceZig/frame_publisher.zig, damage.zig and surface.zig implement bounded coalescing, parallel snapshots with ordered emission, demand/consumption gates, lifecycle damage leases and sparse damage union; desktop_source.zig, desktop_snapshot.zig, desktop_source_session.zig and presentation_policy.zig now implement multi-subscriber state, latest-ready aggregation and presentation policies; native view integration is implemented below | 1,503 exact Swift damage comparisons; Source/latch/policy unit and allocation tests, 12,000 exact Swift policy steps, six public C TCP migration cases using CPU drawing with optional Metal context; actual native MJPEG cases are separate |
| Cursor formats/cache, pointer modes; physical keyboard/mouse ordering and motion ACK | SpiceChannels/CursorChannel.swift, InputsChannel.swift; SpiceProtocol/CursorProtocol.swift | SpiceZig/cursor_wire.zig, cursor.zig, inputs.zig and desktop_child.zig implement exact payload bounds, cache/snapshot ownership, ordered PC XT/button sends and ACK events | 7,334 unchanged Swift wire comparisons; allocation failures, cache invalidation/reset/lifetime, real TCP semi/seamless preserved cursor and mouse state; host NSCursor/key mapping implemented with the native view and AppKit oracle below |
| Playback/Record protocol, multimedia clock, duration budgets, volume/mute | SpiceChannels/PlaybackChannel.swift, RecordChannel.swift | SpiceZig/audio_wire.zig and audio.zig implement RAW S16 configuration/order/alignment, owned PCM, MODE/START_MARK sends, volume/mute, delay-to-clock feedback; integrated in desktop_child.zig | 3,887 unchanged Swift wire comparisons, allocation failures, partial begin failure cancellation, real TCP semi/seamless audio state preservation and STOP feedback cleanup; host buffering/device executor implemented below; real device/route acceptance external |
| Host playback/capture, preallocated rings, underrun/overflow/permission/device errors | SwiftSpice/SpiceAudioPlaybackSink.swift, SpiceAudioCaptureSource.swift, PlaybackBufferController.swift, RecordCaptureBuffer.swift, PreallocatedAudioPacketRing.swift | SpiceZig/audio_ring.zig, audio_buffer.zig, audio_native.zig and audio_runner.zig implement preallocated queues, startup/overflow, chunked AVAudioConverter capture, native AVAudioEngine boundary and joined session executor; spice_zig_audio.h exposes explicit device opt-in | 105,000 unchanged-Swift ring operations; six offline converter format/rate comparisons with exact PCM/timestamps, native offline AVAudioEngine render, allocation/cancel/epoch tests and native ASan/UBSan; actual audible/microphone and route gates external |
| Agent token accounting, bounded assembly, UTF-8 clipboard ownership/grab/request/release | SpiceProtocol/AgentProtocol.swift, ClipboardProtocol.swift; SwiftSpice/SpiceClipboardManager.swift, ClipboardStateMachine.swift, SpiceAgentEventMailbox.swift | Agent packet/message stream and token lifecycle implemented in SpiceZig/agent.zig and main_channel.zig; clipboard.zig, agent_manager.zig and agent_session.zig implement clipboard negotiation, owned actions, bounded pumping, callbacks and generation-fenced desktop binding; native pasteboard boundary and joined polling executor implemented with explicit host opt-in | SpiceProtocolTests/AgentProtocolTests and ClipboardStateMachineTests; explicit pasteboard opt-in; no payload logs |
| File transfer, cancellation, selected regular file only; monitor layout | SwiftSpice/SpiceFileTransfer.swift, SpiceDisplayConfiguration.swift; SpiceProtocol/FileTransferProtocol.swift, MonitorProtocol.swift, DisplayMonitorProtocol.swift | file_transfer.zig, file_source.zig and monitor_config.zig implement uploads, read-only pinned regular files, cancellation, sparse layouts and reply coalescing; connected via public Agent manager ABI | Allocation failures, truncated files, late reads, independent Swift layout/coordinator comparisons and authenticated migration peers; byte and operation budgets |
| WebDAV bounded streams/executor, explicit root/read-only default, traversal/symlink protection, cancel/close | SpiceChannels/WebDAVChannel.swift; SwiftSpice/SpiceWebDAVServer.swift, SpiceFilesystemTaskExecutor.swift | SpiceZig/webdav.zig and desktop_child.zig implement bounded port/mux protocol and fragmented state preservation; HTTP parser, atomic admission ledger, descriptor-relative filesystem and joined host executor implemented below; spice_zig_webdav.h binds ordered Desktop observations | 3,692 peripheral wire comparisons plus 3,118 HTTP and 604 full-server comparisons; 23 WebDAV Zig tests, public C ABI authenticated TCP and three migration modes; traversal/symlink, allocation and native sanitizer checks; live mount pending |
| Smartcard and USB explicit host selection, VMC bounded payload, resources/cancel | SpiceChannels/SmartcardChannel.swift, USBRedirectionChannel.swift; SwiftSpice/SpiceUSBRedirectionHost.swift; CUSBRedirShim | SpiceZig/smartcard.zig, smartcard_wire.zig and vmc.zig implement bounded control queue, APDU/ATR/version handling and USB VMC; usb_host.zig and usb_runner.zig implement explicit native device selection, bounded buffers and joined session execution; spice_zig_usb.h exposes standalone and session owners | Queue/send allocation failures, bidirectional APDU/VMC; 12 USB tests and 64 public C native-oracle cycles; real TCP semi/seamless native-parser continuity and switch-host retirement; physical device gates pending |
| Semi-seamless/seamless migration, isolated preparation, preserve source on failure, authenticated target adoption, no TLS downgrade | SwiftSpice/SpiceMigration.swift; SpiceCore/ChannelConnection.swift; SpiceProtocol/*MigrationProtocol.swift | SpiceZig/migration_coordinator.zig, endpoint.zig and supervisor.zig implement target preparation, semi/seamless and switch-host handoff, preserved child state and source rollback | Independent authenticated TCP peer covers all-channel payload forwarding, partial cancel in both cross-channel orders, obsolete target preparation, fresh switch-host bootstrap and retiring Main Agent drain; live peer pending; destination subject offer remains explicit unsupported gate |
| Public session/events/frames/input/diagnostics/host integration; Swift adapter and Maspice consumer | SwiftSpice/*; Tests/PublicAPIConsumer; ../spice-mac | desktop_abi.zig and spice_zig_desktop.h expose the real supervised desktop, owned events/frames, typed sends, demand, lazy readback and native presenter; host_view.zig/host_view_native.zig and host_view_bridge.m implement native NSView presentation/input with Source ownership; public Swift adapter and local SwiftPM/Maspice switch implemented | C ABI lifetime tests; packaged public consumers, Maspice 55 + session 4 tests and local Release closure passed; external gates above remain |
| Viewer, Probe and optional host UX | SpiceViewer/*, SpiceProbe/main.swift; ../spice-mac | App UI retained; offline Surface and Probe recording integrated through Zig | Probe live handshake/channel path, viewer host adapter checks; UI is not core Zig migration |
| Native packaging, relocatability, provenance, licenses, arm64/macOS 26 | Scripts/build-native-dependencies.sh, verify-native-closure.sh; Artifacts | CSpiceZig ReleaseSafe archive, source/header provenance, resource packaging and local closure implemented | ReleaseSafe static core plus allowed native dependencies; QUIC/JPEG notices; clean macOS 26 and signed distribution external |

## Completion gates and capability gaps

A slice must compile and validate before consumer switching. No stub/no-op may
stand in for pending behavior. Complete migration requires every implemented
Swift behavior above to be ported and exercised through Zig, then the public
API and Maspice to use that core. Runtime Swift core dependence is a failed
completion gate even if Zig exports a complete-looking API.

Historical spice-gtk differences (additional drawing/RAW/cursor compatibility,
input motion ACK behavior, codec policy visibility) are a separate compatibility
workstream; the prior comparison is not current evidence of either missing or
completed features. Preservation of the existing MPS Lanczos quality is not inferred from
language choice. Preserve current accurate pixels and security checks first.

External gates: live SPICE peers/Agent/migration, actual USB/smartcard/audio,
M1 and real 1080p/4K windows, clean macOS 26, signing/notarization and end-to-end
performance. Continue deterministic implementation while these are unavailable;
do not label them passed based on local unit tests or synthetic QUIC timings.

## Local evidence

The initial baseline inventory and hashes of pre-existing modified files are
saved locally in `.build/zig-migration/baseline.json`. Existing user changes,
SwiftPM manifests/resolved files and native artifacts are not rewritten by
this migration slice. Evidence/build output stays in `.build/zig-migration/`.

Run the complete new-slice gate (Xcode/Swift 6.4 and Zig 0.17.0):

```sh
./Scripts/validate-zig.sh
```

This is an explicit local migration gate; it is not yet included in `make all`
or remote CI. The script builds the unchanged Swift wire/LZ sources as independent oracles,
checks both generated outputs, compiles the arm64/macOS 26 Zig module, builds
preliminary static ABI and local differential dylib outputs, runs C sanitizers
and analyzes the narrow Security and Network.framework adapters. It does not update any XCFramework,
SwiftPM manifest, release requirement, resolved file, installed application or
version. The generated output can be refreshed with the built generator:

```sh
.build/zig-migration/protocol-generator --schema ProtocolSchema/spice-0.14.5.json --output Sources/SpiceZig/generated.zig --zig
```

- 69 cross-module ReleaseSafe tests cover wire/handshake/flow behavior; three
  additional module tests cover all 35 generated declarations, ticket policy/
  DER and LZ overlap/allocation safety. Imported dependency tests are run
  explicitly, because Zig does not collect them from the root test module.
- 9,328 wire differential cases against the unchanged Swift sources, including
  6,000 mutations, every split and malformed retry without consumption.
- Actual 128 MiB buffered-byte and 4,096-segment boundaries, 64 MiB header
  acceptance/rejection, 4,096 submessages, immutable owner lifetime after
  reset/destroy, every append/coalesce/batch/writer/handshake allocation failure.
- All 11 existing upstream LZ fixtures are pixel-identical. 23 synthesized
  reference cases cover far distances, extended lengths, overlap, alpha and
  palette modulo/tails. 573 truncations and 6,600 mutations are included in
  7,240 Swift differential comparisons, including exact accepted pixels.
- Seven existing production QUIC module tests rerun unchanged. The larger
  independent QUIC acceptance corpus was not rerun for this slice; its
  production sources and artifact were not changed.
- C ABI consumers verify message/image lifetime and actual Apple Security RSA
  encryption/decryption. Native network consumer additionally exercises 32 TCP/TLS
  cancellation lifecycles and 32 session/wait lifecycles. C consumers, Security
  and Network.framework adapters use ASan/UBSan. Static C/ObjC analysis passes. Zig itself is ReleaseSafe, not ASan-instrumented.
- Native TCP/TLS peers verify 13 trust policies, fragmented exact I/O, EOF,
  25 TLS cancellation cycles, blocked read/backpressured write cancellation,
  real RSA-authenticated Link exchanges over TCP and custom-CA TLS, and
  multi-channel serial/ACK semantics. Main bootstrap and Agent exchange execute
  through the exported C ABI; retained Agent data survives service/session teardown.
- Full and mini frames each send an exact 64 MiB body over real native TCP.
  Header bytes are split under the same writer lock so individual writes respect
  the transport budget; oversized bodies emit nothing and preserve serials.
  Unit tests also verify terminal cancellation on a failed suffix write.
- Main/Agent tests cover allocation failure enumeration, 64-event queue bounds,
  FIFO packet ordering, full-message token reservation, epoch restart, partial
  failure and cancellation, retired-connection drain and new-connection rebind.
  The session clock uses mach_continuous_time with reset/cancel wakeups.
- SwiftPM warnings-as-errors build of SpiceProtocolGenerator and the repository
  protocol plugin --check passed; the new --zig mode leaves Swift output exact.
  Existing 725 Swift/Maspice tests were not rerun because their runtime sources
  and linked artifacts were not changed or switched to this implementation.
- Apple Security ephemeral key generation returned error -50 under the execution
  sandbox; the same isolated test and aggregate gate passed outside that sandbox.
  Keys are in-memory test material, never persisted or taken from credentials.
- `validation.json`, wire/LZ differential JSON and test logs record the local
  gate; source/oracle/fixture hashes identify what was tested. This is neither
  full-library acceptance, hardware display validation nor a performance claim.

The supervisor is a real Zig generic service runtime, with an intentionally
explicit child-service contract. Its test fixture is not a production Display
implementation. `desktop_child.zig` assembles real Display, Inputs, Cursor, Playback and Record
services plus Smartcard, USB VMC and WebDAV mux. Host device/filesystem backends and the public Swift API remain pending.

Additional local validation in this stage:

- 31 Surface/graphics/publication/presenter tests run on the local Metal device via
  `./Scripts/validate-zig-graphics.sh`. They cover immutable old snapshots,
  exact fill/copy/clip/orientation pixels, failure rollback, cancelled submitted
  GPU commands, stale Surface generations and sequence/mutation barriers.
- Native frames share a process-wide 256 MiB budget charged by the actual
  IOSurface-aligned allocation, with three frames per Surface namespace/ID.
  Retained frames continue charging across destruction and recreation; a failed
  allocation leaves published pixels and revisions unchanged.
- Nine checker, thin-line and alpha/color-edge patterns at noninteger up/down
  scales match an independent Swift MPSImageLanczosScale reference byte-for-byte.
  Integer nearest and fractional Lanczos policy is preserved. This is local GPU
  correctness evidence, not a window-presentation or performance result.
- The new graphics/codec adapters and an independent C consumer pass
  ASan/UBSan lifecycle checks and Clang static analysis. Zig is ReleaseSafe,
  not ASan-instrumented. Native/CPU fallback is now integrated in the stream renderer.
- 8,565 drawing/stream/monitor parsing cases match unchanged Swift decoders,
  including 2,099 truncations and 6,400 mutations. Stream report windows cover
  arrival-time semantics, timeout, three consecutive late frames and wraparound.
  Stream/monitor payload modules and service dispatch are implemented. 10,887 Annex-B comparisons (5,882 truncations and 5,000 mutations)
  against Swift include three H.264/H.265 fixtures, exact AVCC bytes, every
  borrowed NAL range and picture/random-access flags. VideoToolbox integration
  is covered by the separate native hardware gate below.

Native video and integrated Display evidence:

- `./Scripts/validate-zig-video.sh` requires actual VideoToolbox and Metal access.
  H.264 baseline/high and H.265 main fixtures report hardware sessions, with
  maximum pixel errors 1/4/2 within the existing Swift tolerance of 4. Retained
  CVPixelBuffers remain readable across decoder replacement and destruction.
- Forty synthetic full/video-range NV12 inputs, including odd dimensions,
  BT601/709 and missing/unknown matrix metadata, match the unchanged Swift CPU
  conversion byte-for-byte. Supported native inputs match independent shader
  color equations within one channel unit; odd/unknown inputs explicitly use
  CPU fallback instead of silently relabeling metadata.
- Eleven native-video test entries (ten behavioral tests and one import entry)
  cover allocation failures, rejected software/query states, failed session
  replacement and retry, dimensions/limits/cancel, actual NV12 Surface
  crop/flip/clips, immutable snapshots, and global per-Surface video ordering.
  Late H.264 input still decodes; late MJPEG input skips decode. Queue tests
  verify latest-pending MJPEG, ordered reference input, cancellation, stream
  retirement and decoder preservation across run rebinding.
- Native C/ObjC ownership is checked with ASan/UBSan and Clang analysis. Zig is
  ReleaseSafe. CoreMedia sample ownership is released exactly once on error and
  success; no extra AVCC copy is introduced after Annex-B conversion. These are
  lifecycle/correctness observations, not an end-to-end performance claim.
- The aggregate TCP gate now runs the real Display service, not only a counting
  child fixture: exact DISPLAY_INIT, ACK, report and monitor handling, JPEG
  pixels, Surface destruction, and continued rendering after semi/seamless
  target adoption without recreating streams or Surfaces. Optional asynchronous
  child event sinks are generation-scoped and drained before worker destruction.
- The scheduler has two joined workers, at most 64 retained jobs and a 256 MiB
  queue budget per Display service. Shared codec execution remains bounded.
  MJPEG reception continues during decode and timer waits. The concrete Display
  service drains advanced video before physical message completion to preserve
  the current Swift reference-frame/migration boundary; full H.264/H.265 receive
  and presentation decoupling is not claimed.

`video-validation.json` records local native source/oracle/fixture hashes and
`video-integration.json` records measured pixel deltas. `validation.json` covers
the broader protocol/session/Display loopback gate. Neither gate is a real
external SPICE deployment or an application presentation benchmark.

Next dependency work: clipboard/file/monitor host integration,
audio device/buffering paths, native window presentation and the public consumer switch.
No pending item is replaced by a stub or advertised as complete. The migrated
session/Display/Surface runtime remains parallel to the application's Swift core.


Desktop channel extension (local validation, 2026-10-30):

- `./Scripts/validate-zig.sh` passes with 69 root tests, 7,334 Cursor and
  3,887 Playback/Record differential cases. The concrete TCP fixture now uses
  `Supervisor(desktop_child)` rather than a Display-only bundle.
- Inputs preserves physical PC XT encoding, button state, keyboard modifier
  events and motion ACKs. Cursor snapshots retain immutable pixel owners across
  cache invalidation/reset and service destruction; repeated INIT resets cache.
- Typed child sends acquire service leases. Migration cancels and drains old
  child sends before moving state; Main Agent's independent drain is preserved.
- RAW S16 playback synchronizes the shared multimedia clock only with reported
  sink delay. STOP clears feedback. Record enforces MODE/START_MARK before PCM;
  a partially sent begin is not silently retried after failure.
- Independent authenticated peers verify semi/seamless preservation of cursor
  cache, mouse buttons, active audio configuration, record mark and clock delay.
  Native audio output/capture, physical devices and public consumer use are not
  covered by these protocol tests.


Surface publication and peripheral extension (local validation, 2026-10-31):

- Smartcard, USB VMC and WebDAV mux have 3,692 differential cases against the
  unchanged Swift wire parsers. Authenticated TCP tests exercise bidirectional
  traffic, partial WebDAV headers spanning semi/seamless handoff, queue state,
  port close and explicit unnegotiated-compression rejection.
- Surface canonical bytes share a session-wide 256 MiB budget across Displays.
  Native IOSurface allocation accounting remains a separate shared budget.
- Damage journals preserve sparse rectangles and exact lossless merges, promote
  to full at half-frame union coverage or after 64 rectangles, and match Swift
  in 1,503 independent comparisons. Publication owns a restorable damage lease;
  discarded snapshots restore damage only to their original live Surface.
- The publisher owns two joined snapshot workers and an ordered coordinator,
  retains at most 16 pending surfaces, coalesces revisions, and supports hidden
  demand, consumer acknowledgments and full redraw after resume/rebind. Six
  focused tests cover cancellation, parallel preparation, exact replacement
  timing, same-ID recreation and every allocator failure. Display uses explicit
  demand and consumption gating; source timing records receive and ready points in the integrated service.
  Resumed/rebound publications have no invented source timestamp.
- Real TCP tests verify hidden draws take no snapshots, ACK gates the next
  publication, resume redraws without mutation, and explicit demand survives
  migration and recreation. Public frame leases can outlive their Store.
- The native Surface ring reuses only unreferenced slots, keeps at most three
  charged frames per Surface namespace/ID, and retires slots on destruction.
  Failed/cancelled commands discard their candidates. A 12-frame test retains
  the first snapshot, allocates only three destinations and reuses nine times
  while preserving its original pixels. This allocation count is not a timing
  or end-to-end performance claim.


Native desktop and consumer boundary (local validation, 2026-10-31):

- Configured desktop sessions retain the optional native context independently
  of its caller and through child handoff. Actual CPU/native TCP tests verify
  exact JPEG pixels, native publications and continued GPU rendering after
  semi/seamless migration.
- `presenter.zig` owns the two-command limit, epoch fencing and GPU frame leases.
  The ObjC adapter submits the existing fullscreen nearest shader or direct MPS
  Lanczos into a host-supplied texture/drawable. GPU completion is explicitly
  distinct from an onscreen presentation timestamp. Three tests verify exact
  nearest/Lanczos pixels, hidden stale callbacks, source/Store/context teardown,
  and allocator failures; native sanitizer coverage includes asynchronous work.
- `spice_zig_desktop.h` is an unreleased consumer ABI, not a claim of full public
  Swift API parity. Independent C/ObjC consumers exercise the real authenticated
  desktop, bootstrap metadata, typed sends, monitors, immutable frame/Cursor/PCM
  ownership, and retained presenter use after desktop destruction. Public pixel
  access borrows CPU storage or caches a single thread-safe native readback.
- The desktop library preserves the host's alternate signal stack using
  `std_options.signal_stack_size = null`. A debugger trace established that the
  Zig 0.17 thread default overwrote ASan's alternate stack with TLS storage,
  causing ASan to unmap that non-mapping at thread exit. The C library owns no
  process-level signal policy; ReleaseSafe checks and native ASan/UBSan remain
  enabled. The same public consumer passed after this ownership fix.
- This does not yet switch Maspice, provide the Swift consumer adapter, create a
  native window, implement clipboard/file/layout management or host peripherals,
  or validate a live SPICE deployment. The static desktop archive is a local
  parallel output; published artifacts and dependency requirements are unchanged.


Final gates for this slice: `validate-zig.sh` completed with 69 root tests and
all listed protocol oracles, native peers and public C consumers;
`validate-zig-graphics.sh` completed with 31 entries, 1,503 damage comparisons,
nine exact MPS references and native ASan/UBSan. The additional graphics entry
enumerates all lazy-readback allocation failures and checks cached pixel
identity after Surface destruction. `validate-zig-video.sh` also passed its 11
entries and hardware/native sanitizer corpus after native ring integration.


### Agent services and frame metadata (2026-10-31)

- Display publications now carry Mach continuous receive/ready nanoseconds from
  the actual message/render path. Surface snapshots mark H.264/H.265 revisions;
  static mutations clear the marker atomically and stale frames cannot change it.
  Public FrameInfo includes advanced_video; CPU fallback preserves that marker.
- agent_services_wire.zig and clipboard.zig match the unchanged Swift sources in
  3,573 protocol inputs, 126,991 Unicode basename boundaries and 10,013 state
  transitions. Guest UTF-8 decoding consumes one leading BOM, matching Foundation.
  System CoreFoundation supplies the exact Unicode whitespace predicate.
- monitor_config.zig validates enabled/disabled heads, IDs, signed positions,
  sparse capabilities and range bounds. 4,000 layout encodings and 5,000 queued/
  in-flight/reply/disconnect transitions match the unchanged Swift implementation.
- file_transfer.zig owns bounded upload phases and incarnation-fenced read/send
  work. file_source.zig opens only selected regular files read-only and pins their
  descriptors through pending reads. Chunks are at most 16,000 bytes; limits default
  to four files and 8 GiB each. Cancellation, early SUCCESS, source truncation,
  no-byte token admission and all allocation failures are covered.
- agent_manager.zig performs bounded, serialized pump turns for clipboard actions,
  layouts and fair file progress. Explicit clipboard disable revokes pending failed
  host-write actions. Transport errors retire the epoch rather than retrying an
  uncertain send. agent_session.zig binds this manager to the real Supervisor.
- Stable session identity survives migration and changes on switch-host. Main
  events and bootstrap expose an independent Agent incarnation; send admission
  checks both under their owning locks. Old work is rejected without tokens/bytes,
  including fresh guests whose Agent incarnation counter happens to match.
- spice_zig_agent.h exposes the optional manager, typed layouts/files, bounded
  owned events and an explicit host text-writer callback. Events survive manager
  and Desktop teardown. The manager borrows Desktop and has one serialized owner;
  the owner delivers desktop events and schedules bounded pump/poll turns.
- The full validate-zig.sh gate passed 79 root tests plus the existing module,
  protocol, native TCP/TLS and public C sanitizer suites (agent-api-current.log).
  A follow-up public C gate passed switch-host retirement and identity rejection
  (agent-switch-host.log), in addition to semi/seamless migration with a 40,192-byte
  upload, cancellation, clipboard demand/ownership and sparse monitor replies.
  C/native adapters run ASan/UBSan; Zig runs ReleaseSafe, not Zig ASan.

At this stage the manager test used a synthetic text-writer callback and a
selected temporary file. The following slice adds the actual AppKit boundary.
Audio devices, WebDAV filesystem serving, host USB/smartcard, native window
integration, the Swift consumer adapter and final packaging remain open.
Maspice has not switched libraries; no release exists.


### Native pasteboard and autonomous Agent executor (2026-10-31)

- `pasteboard_bridge.m` adapts NSPasteboard, UTF-8/NSString conversion and main-queue
  operations. Policy, cancellation waits and ownership remain in `pasteboard.zig`.
  Native text roundtrips match the unchanged Swift pasteboard bridge, including
  initial BOM processing, embedded NUL, empty strings and Unicode. Oversized
  snapshots return metadata without materializing the UTF-8 payload.
- Queued cancellation claims completion atomically before AppKit may begin.
  Callback pointers and text are released before cancellation returns; at most
  one queued block per context remains until main drains it. Running AppKit effects
  finish before their caller can tear down the wait state. Contexts and results
  have independent owned lifetimes; caller contexts may be released before drain.
- `agent_runner.zig` owns a joined worker, 64-entry command/event queues with
  32 MiB payload bounds, 250 ms default polling (minimum 10 ms) and bounded pump
  turns. Token backpressure is retried without requiring a new public event.
  Main-thread host access requires explicit enablement. Disable cancels queued
  reads/writes immediately; policy commands preserve event order, and later
  re-enabling cannot resurrect an old guest-write action. Queue overflow and
  allocation failure remain explicit; uncertain transport effects are not retried.
- The native executor is exposed through `spice_zig_agent.h`. It retains its
  pasteboard context, borrows Desktop, and accepts ordered Desktop observations.
  Display/audio payloads are not retained in the Agent queue. File admission is
  asynchronous and returns a caller-correlated incarnation key. Owned output
  events survive executor and Desktop teardown.
- The final aggregate gate passed 84 root tests, the unchanged Swift protocol/
  state oracles and all prior native peers. Public ASan/UBSan C/ObjC consumers
  exercised the actual named pasteboard, a 40,192-byte selected file, layout ACKs,
  semi/seamless migration, switch-host retirement and Agent restart. Eight native
  pasteboard/executor tests included destroying the worker on main while a read
  was queued; 32 native cancellation cycles freed callback state before drain.
  The policy-allocation-failure test also passed terminal cleanup.

All pasteboard verification uses private unique names, never the user's general
clipboard. The general-pasteboard selection path is exposed but was not exercised.
These are local deterministic/native checks, not live SPICE interoperability,
clean-system acceptance, performance measurements or a completed library migration.


### Audio storage, native conversion and session executor (2026-10-31)

- `audio_ring.zig` preserves the original 16 MiB queue / 16 MiB staging limits,
  262,144 metadata-slot limit, whole-prefix overflow policy, saturating diagnostics,
  partial reads and zero-fill. Staged playback copies run outside the render gate;
  publication changes only metadata or the backing-bank selection. Async dequeue
  pins the head while allocating/copying outside the state lock. Reset/close defer
  reclamation through that lease; allocation failure releases it without losing
  the pending packet. All Zig callback paths use preallocated storage.
- `audio_buffer.zig` implements startup latency, underflow rearming, atomic overflow
  publication, and capture drain/drop/failure reporting. A partial drain allocation
  failure returns its already-owned prefix and leaves the failed packet queued.
  No fallible shrink occurs after dequeue. The inactive legacy player-node
  `PlaybackBufferController` remains reference-only; the current source-node
  playback path uses the migrated ring and render gate.
- `audio_native.zig` owns input validation, chunk copying, output bounds, wrapping
  timestamps, fixed capture buffers and typed failures. `audio_bridge.m` only
  adapts AVAudioFormat/AVAudioPCMBuffer, AVAudioConverter and AVAudioEngine calls.
  The persistent input block supplies each chunk once, matching the Swift input
  provider. The native gate prevents new callback borrows and joins active ones
  before Zig context release. Late native closures can retain the closed gate.
- `audio_runner.zig` consumes ordered Desktop observations on one joined worker.
  It owns native devices, automatic capture drain/send (2 ms), periodic playback
  delay reports (50 ms default), volume/mute, underrun/overflow notifications and
  stream cleanup. Both device options default off. Only explicitly enabled START
  opens a device; microphone declarations and consent remain the embedding app's
  responsibility. Input retention is bounded at 64 observations / 32 MiB by
  default; output keeps newest 32 notifications, matching the Swift public sinks.
- Record START now carries a local stream epoch. Admission checks that epoch and
  the stable logical session identity before starting an old capture write.
  Semi/seamless migration preserves the stream; switch-host changes identity.
  A cancelled in-flight write closes its exact transport because partial framing
  cannot safely be reused; a pre-cancelled send does not close an idle transport.
  `spice_zig_audio.h` exposes actual executor create/observe/stop/next/statistics,
  with fixed caller-owned notification records and explicit lifetime contracts.
- `Scripts/validate-zig-audio-buffers.sh` passed five memory/queue tests, four
  executor tests and 105,000 operations across 700 randomized sequences against
  unchanged Swift ring source. Two additional protocol tests cover epoch rejection
  before output and actual blocked-write cancellation. Native converter tests
  compare exact PCM, every packet timestamp and six diagnostic counters against
  the extracted unchanged Swift processor for six supported format/rate pairs,
  including split callbacks, malformed storage/format and recovery.
- `Scripts/validate-zig-audio-native.sh` passed three Zig/native tests, C static
  analysis, actual offline AVAudioEngine source-node conversion with exact output,
  and 32 native ASan/UBSan converter/callback lifetime cycles. It never starts a
  microphone or audible device. The first sandboxed aggregate stopped at the
  existing Security ephemeral-key test; Apple audio component registration also
  required the normal host environment. The complete host run passed 95 root
  tests and every previous oracle, native peer, migration and public C ABI gate
  (`audio-final.log`, `validation.json`). Public C consumers verify disabled audio
  execution alongside actual Desktop traffic; native device execution is covered
  separately offline. Zig remains ReleaseSafe; no Zig ASan claim is made.

Real device routing, audible playback, microphone capture, live SPICE guests and
performance remain external gates. WebDAV filesystem serving, host USB, native
window/source integration, the full public Swift adapter, maintainer generator
and packaging remain unfinished. The application has not switched libraries and
no release/tag has been created.


### WebDAV HTTP, admission and filesystem components (2026-10-31)

- `webdav_http.zig` owns parsed requests and preserves bounded fragmentation,
  Unicode whitespace/case/canonical header equality, Character separator rules,
  leading BOM behavior, signed decimal lengths, duplicate/transfer-encoding
  rejection, sequence checks and generated response ordering. Native Unicode
  conversion uses CoreFoundation; framing and ownership are Zig.
- `webdav_queue.zig` atomically admits an entire batch or leaves its prior
  buffer/sequence unchanged. Client, request and retained-byte limits include
  response reservations through delivery. Independent clients can advance while
  an earlier response blocks one client. Close/reuse retains active filesystem
  and send owners until completion, discards retired filesystem output and
  prevents later mutations after failed response delivery. External workers must
  finish their borrows and join before queue destruction.
- `webdav_path.zig` pins the explicit root and walks canonical directories with
  `O_SEARCH | O_NOFOLLOW`, preserving traversal-only directory access. Leaf
  metadata uses `fstatat` without requiring content-read permission. Native URL
  conversion is a small Foundation adapter; containment and descriptor ownership
  are Zig. Symlink replacement between canonicalization and open is refused;
  descriptor pinning is not a claim of a transactional snapshot against every
  concurrent directory rename.
- `webdav_fs.zig` implements OPTIONS, GET/HEAD, depth 0/1 PROPFIND (4,096 child
  bound, sorted XML and body budget), atomic PUT, MKCOL, recursive DELETE, file
  COPY and MOVE, read-only default and explicit write opt-in. Existing leaf-link
  behavior, permissions, missing-file errors and response ordering are retained.
  Atomic PUT replaces links; regular-file modes survive replacement, while fresh
  inode metadata follows the existing Foundation behavior. COPY retains native
  metadata and bounded data reads. Growing files cannot exceed the body ceiling;
  special files are never opened for blocking data reads. Same-inode COPY/MOVE
  returns 409 instead of the old implementation deleting its source before
  failing; this deliberate data-preservation difference is covered separately.
- `./Scripts/validate-zig-webdav.sh` passed 15 Zig tests (including allocation
  failures, close/reuse and symlink substitution), 3,118 exact parser comparisons
  and 604 response-byte comparisons against unchanged production Swift. The
  latter also checks final mutation trees, leaf links, mode bits, unreadable-file
  metadata/MOVE/PUT and COPY timestamps. Native URL/date conversion passes static
  analysis and 256 ASan/UBSan cycles. Zig remains ReleaseSafe, not ASan-instrumented.
- This initial component acceptance is extended by the joined executor below.
  Real guest mounting remains an external gate; no package or application consumer
  has switched.


### WebDAV joined executor and public host binding (2026-10-31)

- `webdav_runner.zig` owns bounded joinable workers and defaults to two simultaneous
  filesystem calls. Response sending releases the filesystem permit. Each client
  still waits for delivery before its next mutation, while independent clients
  advance. The synchronous native transport uses one worker per admitted-job slot
  (default/maximum 64); this is bounded ownership, not a performance claim.
- Close/reuse and stop preserve in-flight syscall/send storage until completion.
  Queued requests are discarded; entered filesystem effects may finish and are
  never retried. Cancellation interrupts an active pinned network write by closing
  that channel, preserving wire framing. Idle cancellation does not close a socket.
  Destruction joins workers before freeing the explicit filesystem root.
- Same-guest semi/seamless migration retains incomplete HTTP input. A completed
  request captures its submission generation; finishing an earlier prefix uses
  the completing submission's generation. Old delivery failures retire their
  client without failing the new backend. Switch-host and port close reset client
  state. `Supervisor.sendWebDAVAt` pins the exact transport, rechecks generation
  after writes and classifies source-retirement errors as stale.
- `spice_zig_webdav.h` exposes create/observe/stop/destroy/status/diagnostics with
  an explicit authorized root, read-only default, optional write access, request
  and retained-byte ceilings. The caller feeds observations in receive order,
  handles terminal backend status and destroys the backend before Desktop.
- Eight executor tests cover bounded filesystem concurrency, blocked-send client
  independence, FIFO mutations, retired syscall and sender reuse, allocation
  failure cleanup, failure propagation, guest-switch reset and same-guest prefix
  continuity with stale-response fencing. Together with the existing components,
  `validate-zig-webdav.sh` now contains 23 Zig tests plus the unchanged Swift
  parser/server differential gates and native sanitizer checks.
- The public C consumer verifies read-only and writable roots, exact 70,144-byte
  GET/HEAD with 65,535-byte mux chunks, fragmented HTTP/mux, PUT and traversal
  rejection, confirmed partial-request preservation across semi/seamless handoff,
  switch-host reset, client-close reuse and joined destruction. Its native bridges
  and consumer run with ASan/UBSan; the Zig library remains ReleaseSafe.
- Live guest mount acceptance remains pending. Public Swift adaptation, USB host
  migration, source/window integration and complete-library packaging remain
  subsequent work; this does not mark the full rewrite complete.

The full `Scripts/validate-zig.sh` run passed after these changes (95 root tests
plus the component suites, all existing protocol/codec comparisons, public C
consumers, TCP/TLS/migration, native GPU and offline audio checks). As in the prior
accepted run, macOS Security key generation and native integration used normal
host permissions; the restricted run stopped at Security error -50. Evidence is
`webdav-api-integration.json`, `webdav/validation.json`, `validation.json` and
`webdav-final.log` under `.build/zig-migration/`. Documentation alone changed after
this pass; production and test fingerprints were checked unchanged.

### Native USB host and joined execution (2026-10-31)

`usb_host.zig` now owns libusb and usbredirhost lifetime, bounded input/output
storage, native error codes, guest-filter checks and exact device selection.
It links the existing licensed CUSBRedir artifact directly; the previous C shim
is only an independent test oracle for this implementation. Stable ownership
covers callbacks during open and close. Device handles transfer to usbredirhost
exactly once, including failed attachment. No device is selected automatically.

`usb_runner.zig` serializes native calls on one joined worker, with 64 queued
commands and a separately bounded retained-input budget (default 16 MiB).
It pumps native completions every 10 ms when idle. Device commands complete to
their caller; they must run off the Desktop event-reading thread. Same-guest
handoff retains native parser/device state. Switching guests or disconnecting
stops this owner and closes any selected device; a new guest requires explicit
backend enablement and device selection. Stop cancels blocked sends, and destroy
joins both the worker and native USB cleanup. Native calls already entered may
finish before that join; cancellation does not pretend to undo device effects.

`Supervisor.sendUSBAt` pins a channel lease and logical guest identity. Only
handoff rejection before wire entry may defer a packet. A failed entered write
is terminal and is never replayed on a replacement transport. This preserves
framing and avoids duplicating an uncertain USB operation.

`spice_zig_usb.h` exposes both the standalone serialized host (matching the
existing public Swift host behavior) and optional session executor. The executor
must exclusively own its selected channel's traffic. Explicit attachment returns
selection/native errors to its caller; consumers poll status for asynchronous
failures and terminate the associated session. Source errors and queue overflows
are not silently ignored.

Validation:

- 12 Zig tests: native hello/fragmented-input comparison to unchanged C,
  allocation failures, buffer limits, injected native initialization/filter/open/
  ownership failures, exact native error codes, FIFO execution, migration,
  cancellation, bounded queues, blocked device callers and no uncertain replay.
- 64 public C standalone lifecycle cycles compare exact native bytes and output
  chunk bounds. The C consumer/oracle use ASan/UBSan; Zig uses ReleaseSafe and
  the prebuilt native USB framework is unchanged, not newly instrumented.
- The public session consumer connects through authenticated loopback TCP peers.
  It checks exact 8-byte output chunks, native configuration responses, partial
  USB packet continuation across semi/seamless handoff and switch-host cleanup.
- Test device selection uses impossible USB address 255 or a test-only native
  replacement. No physical device is opened; actual device/guest interoperability
  remains an external acceptance gate. No performance improvement is claimed.

The focused gates are `Scripts/validate-zig-usb.sh` and
`Tests/SpiceZigTests/usb-api-integration.py`; both are included in the aggregate.
Public Swift adaptation, desktop-source/window integration, maintainer tooling,
complete native packaging and consumer migration remain incomplete.

The full migration gate passed after the USB implementation and public boundary
changes: 95 root tests plus all component, oracle, native, TCP/TLS and migration
checks. Evidence is in `usb/validation.json`, `usb-api-integration.json`,
`usb-final.log` and `validation.json` under `.build/zig-migration/`. As with prior
native phases, loopback listeners and macOS Security services used normal host
permissions. Production and test fingerprints were verified unchanged after the
pass. Original unrelated modifications remain preserved.

### Desktop source, subscriptions and presentation policy (2026-10-31)

`desktop_source.zig` owns canonical frame/cursor/pointer state, per-surface
visibility, stream coalescing, retained handler contexts and frame acknowledgments.
Last-hidden subscriptions release canonical real-session frames and wait for a
fresh publication on return. Additional visible subscribers receive a full
retained frame. Synthetic desktops preserve their retained frame. Handlers run
outside the source lock, can cancel their subscription, and require explicit
ACK; stream-only groups ACK automatically. Subscriptions retain the source;
owned snapshots and extracted frames survive adapter and session destruction.
Source key/subscription counts and canonical frame bytes have explicit bounds.
Consumer-retained snapshots are separately owned, not counted as canonical bytes.

`desktop_snapshot.zig` merges damage while preserving the newest cursor, pointer,
frame identity and original frame delivery sequence. Its ready latch keeps a
watermark through take/discard and accepts restoration only when empty and
non-stale. CPU and IOSurface references remain immutable and do not read back
pixels just to aggregate state. `presentation_policy.zig` implements display-link
pacing, framebuffer revision selection, native/overlay cursor selection, drawable
sizing, bounded Metal retry/CPU fallback and drawable-drop retry policy. Window,
NSCursor, drawable acquisition and SwiftUI integration still remain pending.

`desktop_source_session.zig` consumes ordered supervised events, retains the
static desktop across same-guest migration, clears it on guest switch/disconnect,
and replays desired demand after handoff. Hook operations pin the logical guest
before modifying a publisher: an old ACK cannot release a new guest's prepared
frame even if local Surface lifecycle/revision numbers repeat. Old event epochs
and cursor-cache-only invalidations do not produce desktop updates. Publisher
hooks run under the source mutex and only enqueue demand/ACK; user handlers run
after unlock. There is no reverse Runtime/Publisher-to-Source lock acquisition.

`spice_zig_source.h` exposes the real adapter, subscriptions, retained callback
contexts, immutable snapshots, exact merged frame damage and the ready latch.
Destroy the adapter before its borrowed Desktop; subscriptions can outlive both.
Do not mix raw Desktop demand/ACK calls with a Source owning the same channels.
The C handler receives a borrowed snapshot and can clone it for later use.

Local evidence includes `Scripts/validate-zig-presentation.sh`, source/snapshot
and policy tests (allocation failures, concurrent cancel/demand, blocked stream
cancellation, generation fences, handler reentry and retained backing lifetime),
12,000 deterministic commands against exact extracted existing Swift value-policy
definitions, and six public C integration cases using CPU drawing with/without a native context and
semi-seamless, seamless and switch-host migration. The latter also check hidden
resume, cursor-only damage, handler and ready-latch ownership, stale-event replay
and exact retained pixels after Desktop destruction. C consumers/native adapters
use ASan/UBSan; Zig uses ReleaseSafe. This does not establish native window UI,
real SPICE peer, clean-system, distribution or performance acceptance.

The complete migration gate passed with this Source boundary: 95 root tests,
21 focused Source/snapshot/policy tests, 12,000 Swift policy comparisons and six
public migration cases with CPU drawing and optional Metal context, plus all existing codec, native, audio, Agent,
WebDAV, USB, TCP/TLS and supervision checks. Local evidence is
`.build/zig-migration/source-final.log`, `presentation/validation.json`,
`presentation/policy-differential.json`, `source-api-integration.json` and the
aggregate `validation.json`. Source/test/script fingerprints were checked
unchanged after completion. Original unrelated modifications remain preserved.

### Presentation diagnostics and causal interaction tracing (2026-10-31)

`timing.zig` preserves the 21-bucket histogram, percentile rounding, duration
normalization and accumulation behavior. `presentation_diagnostics.zig` stores
content-free counters, fallback categories and four separate latency summaries.
Explicit reset advances an epoch so old asynchronous callbacks cannot pollute a
new measurement. Source migration retains counters, matching the Swift session;
a consumer resets at the start of a new connection attempt.

`interaction_record.zig`, `interaction_marker.zig`, `interaction_trace.zig`,
`interaction_waiter.zig`, `interaction_writer.zig` and `interaction_capture.zig`
implement schema-2 evidence validation/canonical JSON, bounded pixel ROI scanning,
causal stage correlation, cancellable single waits, and opt-in atomic JSONL output.
Trace strings are owned, frame observations are capped at 16 and retired surface
keys at 4096. Markerless frames cannot complete a wait; known drawable drops may
retry the same identity. Retired lifecycles, duplicate stages, ambiguous markers
and replacement are preserved as evidence failures. Host and guest clocks are
validated independently. Continuous host nanoseconds are shared with publishers;
CoreAnimation timestamp conversion uses a callback-local calibration.

Source records each publication before delivering it to handlers; snapshots keep
original frame sequence and receive/ready timing through cursor-only updates.
Native marker inspection maps immutable IOSurface bytes read-only, without a full
frame readback allocation. Source retirement also covers hidden frames whose
canonical backing has been released. Tracing errors invalidate the capture rather
than breaking desktop rendering. Captures survive Source/Desktop destruction.

`spice_zig_diagnostics.h` exposes retained diagnostics, metric epochs, owned
capture/record handles, cancellation, and explicit native-host presentation stages.
Only finish writes a file. Capture detaches before freezing, serializes append,
and keeps the same record after failure; successful finish cannot be repeated.
Output is limited to 64 KiB per line and 16 MiB per file, validates existing
canonical evidence, rejects symlinks/special files, uses a process mutex plus the
existing POSIX lock-file protocol, and fsyncs a mode-0600 temporary inode before
rename and directory fsync. An exact existing line is an idempotent retry.
The static desktop archive now bundles compiler-rt (`-fcompiler-rt`) for JSON
numeric conversion; ordinary Clang consumers link without external Zig runtime
libraries. The existing Zig MIT runtime license applies.

Focused gates passed 13 diagnostics tests, 22 Source/policy tests, 3,000 exact
Swift histogram steps, 1,545 record constructions, 1,664 record decodes, 240 marker
frames and 802 causal traces (15,685 operations), plus 12,000 presentation-policy
commands. Two public C TCP cases pass with CPU backing and actual MJPEG-to-Metal
IOSurface backing respectively, including final JSONL and retained handle cleanup.
C consumers/native adapters use ASan/UBSan; Zig retains ReleaseSafe checks.
Host input/guest timestamps and drawable presentation stages in these two cases
are fixture inputs; these are not physical-display or live-guest latency results.

Evidence correction: the earlier six Source migration cases enabled a Metal
context in half the cases, but their raw fill drawing was CPU backed. They prove
context/session ownership and Source contracts, not GPU-backed publication. The
new diagnostics native case explicitly asserts IOSurface backing. Earlier native
MJPEG composition and GPU migration tests remain separate evidence.

The complete aggregate gate passed (`.build/zig-migration/diagnostics-final.log`);
all recorded source/test/script fingerprints were verified unchanged. Dedicated
evidence is in `diagnostics/validation.json` and `diagnostics/differential.json`.
Native host view event/render wiring,
remaining session-wide metric instrumentation, public Swift compatibility adapters,
application dependency switching and packaging acceptance remain unfinished.

### Native host input and presentation observation (2026-10-31)

`host_input.zig` now owns the macOS virtual-key to XT mapping, synthesized decimal
exception, side-specific modifier reconciliation, repeat events, Caps Lock toggles,
and held-key release. It returns bounded owned event batches; native delivery
cannot observe a partially updated keyboard state. It also owns aspect-fit
geometry, edge-exclusive absolute coordinates, rounded/clamped relative motion,
button/scroll mapping and balanced pointer-capture state. AppKit system calls stay
behind synchronous capture callbacks. Nonfinite geometry, scrolling deltas and
saved cursor positions are rejected instead of entering invalid native conversions.

`validate-zig-host-input.sh` passed three focused behavior/safety tests and an
independent AppKit oracle using exact existing Swift declarations: 11,073 keyboard
operations (real NSEvent values) and 2,006 geometry cases. The focus-release oracle
compares sets because the existing Swift Set traversal order is unspecified.

The presenter accepts an optional independently retained observation context.
Native GPU-completion and drawable-outcome events are queued on the main thread;
observed submissions require that thread so commit evidence is established before
observation delivery. The context can outlive presenter destruction. GPU frame
leases remain tied to completion; queued presentation observers never borrow the
GPU job or freed presenter. `wait_idle` joins GPU completion, not queued main-thread
observations. Callback-local CA and continuous-clock samples allow Zig timestamp
calibration without confusing GPU completion with screen presentation.

The existing native graphics/presenter gate passed, including exact MPS pixels,
damage differential and C ASan/UBSan. The new native observation harness passed
ASan/UBSan and static analysis for nearest/Lanczos submissions, dropped drawable
callbacks, offscreen command-only observations, failure cleanup and independent
native ownership. **Actual nonzero screen-presentation timestamps remain pending:**
the host reported its display asleep; both an independent Metal clear/present probe
and the adapter returned zero `presentedTime`. The harness does not count those as
presented frames, does not wake the display, and requires nonzero timestamps when
the display is awake throughout a case. This is no end-to-end latency result.

Complete aggregate regression passed (`host-input-final.log`), and all recorded
source/test/script fingerprints were verified unchanged. Dedicated evidence is in
`host-input/validation.json`. Native NSView input,
subscription, display-link and rendering wiring still remains to be implemented;
these input policies and native callbacks alone do not complete the host view.


### Native desktop view controller (2026-10-31)

`host_view.zig` now composes the previously validated Source, ready latch, host
input, pacing, recovery and diagnostics contracts into the real main-thread view
controller. It coalesces publications, ACKs selected revisions, retries a missing
drawable or busy GPU with the original ready timestamp, requests authoritative
redraws after resize/resume, and distinguishes GPU completion from actual drawable
presentation. CPU fallback holds its own accepted frame lease while a newer GPU
attempt is pending. Allocation failure in attempt bookkeeping falls back to CPU;
Source failures retain their fixed error category. Contexts remain owned across
reentrant input callbacks, queued delivery and native presentation callbacks.

`host_view_bridge.m` supplies NSView/MTKView/display-link events, native cursor and
CALayer drawing, actual drawable acquisition and synchronous CoreGraphics drawing.
It contains no subscription, frame-selection or recovery policy. Its weak view box
prevents controller/view cycles. Window changes cancel demand and invalidate the
old display link; hide, focus loss and destruction balance held keys/capture. The
optional `spice_zig_host_view.h` returns a retained NSView and exposes idempotent
close plus a fixed error category. Source and its Desktop may be destroyed before
the view, after their event readers have joined. Host input callbacks enqueue
application sends; they do not introduce blocking network work on the main thread.

Three ReleaseSafe controller tests passed: coalescing/selection/resume and queued
teardown, input callback destruction during a modifier batch, and all creation
allocation-failure points. The native ASan/UBSan harness and Clang static analysis
passed. The CPU NSView bitmap matched an independent Cocoa implementation of the
existing Swift NSImage drawing contract exactly, including orientation, letterbox
and display color management. Native GPU commits/completion, real NSEvent key
routing/decimal exception/focus release, explicit close, automatic deallocation,
and Source-before-view destruction passed with independently balanced callbacks.

The display was asleep. The native harness confirmed production occlusion kept
frame demand off, then injected a visible occlusion state in a **test-only NSWindow
subclass** to exercise rendering and resource lifetimes. Actual screen visibility,
physical display-link refresh, nonzero presented timestamps and end-to-end latency
are not accepted by this test. The separate native presentation gate's pending
physical condition remains unchanged. No screen wake or unlock was performed.

The aggregate gate now includes controller tests and a consumer of the actual
public Desktop/Source/host archives. Complete aggregate regression passed under
Xcode 27.2 / macOS SDK 27.2 after installing its Metal component; all recorded
fingerprints matched. The native window gate passed again on that toolchain.
Evidence: `.build/zig-migration/host-view/validation.json` and the two
`host-view[-native]-final.log` files.
The optional host has no texture-import cache because every native frame already
owns its texture, so old texture-cache hit/miss/eviction counters remain zero.
Session-wide pipeline diagnostics, full public Swift adapters, packaging and the
Maspice switch remain pending; this phase does not complete the library rewrite.

### Session pipeline metrics (2026-10-31)

The publisher records actual snapshot/emission work, CPU/native classification,
coalescing, demand, pending/prepared gauges, empty flushes and eight bounded
histograms. Receive-to-ready starts after framing. Snapshot and callback durations
are measured outside the publisher lock; instrumentation preserves ordering,
consumption ACKs and damage ownership.

Surface metrics count committed damage, completed full CPU copies, native uploads,
GPU copies/failures, pool exhaustion and cached native readback. A separately
retained recorder survives Store destruction with each immutable Publication;
concurrent lazy materialization still happens once. Pool samples include actual
padded allocation bytes. Metal memory values come from the device. Transactional
CPU candidates currently copy complete frames, so partial-copy bytes remain zero.

Stream statistics publish after completed render attempts, including failures;
readers never race a decoder's mutable counters. Retired streams retain cumulative
counts. MJPEG concurrency is measured only after obtaining a decode permit; native
input-buffer peaks track actual owned buffers. Advanced-video hardware-query and
session statistics come from the existing VideoToolbox decoder. This phase did
not rerun the separate H.264/H.265 hardware gate.

The supervisor counts adopted Display channels only. Semi/seamless handoff moves
the existing state without counting it twice; switch-host archives the old
channel's final sample. Failed/preparing targets are excluded. Component snapshots
are synchronized but the aggregate is best effort, not atomic. Retired gauges are
last samples, and readbacks after retirement do not retroactively alter them.
Active World Surface usage and the configured limit are sampled separately;
default-context IOSurface bytes remain a process-wide live quantity.

`spice_zig_pipeline.h` exposes 58 fixed-width scalars and eight timing summaries,
without payloads, individual timestamps or native handles. Existing Source and
presentation diagnostics remain separate, allowing the Swift boundary to combine
them into its public snapshot.

The complete aggregate gate passed, and source/oracle/fixture fingerprints matched.
Focused native checks passed 31 tests including allocation failures, exact
Surface/publisher counts and cached readback; nine MPS patterns matched exactly
and 1,503 damage cases matched the unchanged Swift oracle. Public C consumers
checked CPU and real native MJPEG statistics, six migration cases, rejected target
preparation, retired-channel preservation, live Surface budgets and first lazy
readback after Desktop destruction. C/ObjC ASan/UBSan and native static analysis
passed; Zig retains ReleaseSafe checks. Evidence:
`.build/zig-migration/pipeline/validation.json`, `pipeline-metrics-final.log` and
`metrics-graphics.log`.

Public Swift compatibility, reconnect ownership, packaging and the Maspice switch
remain unfinished. This phase does not complete the full-library rewrite.

### Reconnect ownership and typed video failures (2026-10-31)

A cancelled Desktop can now be joined and reset without changing its address or
native context. The same Source and subscriptions retain their demand across
reconnection. Reset drains abandoned owned payloads, clears metrics and failure
context, and advances the guest lifecycle. Live or connecting sessions reject
reset. Callers must join their external operations and feed terminal events to
Source before resetting; the public C header documents this ownership boundary.

Video failures preserve the actual codec, failure reason and optional native
status through scheduler teardown and the supervised terminal event. Categories
match the existing Swift policy; allocation/backend failures remain generic.
No codec advertisement, hardware requirement or decoding policy was relaxed.

The complete aggregate gate passed and all recorded fingerprints matched. The
public C consumer reconnects twice with an authentication rejection between runs,
checks old frame ownership and stale-event fencing, terminal clearing and fresh
metrics. A separate SDK oracle checked 182 classification cases; two real malformed
H.264/H.265 CoreMedia inputs preserved their exact status through the public event.
Native C/ObjC ASan/UBSan and Zig ReleaseSafe remain enabled. This error test does
not claim successful hardware decoding. Evidence:
`.build/zig-migration/reconnect/validation.json` and `reconnect-final.log`.

The Swift compatibility boundary is now being implemented separately. SwiftPM
and Maspice still use their existing implementation until that boundary and its
packaging and consumer gates are complete.

### Swift consumption boundary (2026-10-31)

The separate `Sources/SpiceZigSwift` module now supplies session streams, native
frames, subscriptions, metrics and the SwiftUI host view through the C ABI.
First Swift pixel access writes into Swift-owned Data, preserving copy-on-write
isolation from immutable native publications. Concurrent getters share that
wrapper's cache. No Swift protocol, renderer or presentation scheduler is used.

The aggregate ReleaseSafe/native sanitizer gate passed with matching source,
oracle and fixture fingerprints. Independent public Swift consumers exercised
reconnection, failed authentication, cancellation, retained frames, actual MJPEG
IOSurface pixels, statistics and SwiftUI replacement/dismantle. Evidence:
`.build/zig-migration/swift-boundary/validation.json`. Successful advanced video
hardware decoding and physical onscreen presentation are not claimed by these
checks. Optional service facades and packaging are still unfinished; SwiftPM
and Maspice still select the original implementation.

### Public audio services and migration cleanup (2026-10-31)

Swift playback/capture facades now own optional Zig audio executors. A bounded
native replay cache orders late attachment against incoming events, preserving
the application's connect-before-start flow. Stop detaches observations and
joins native work before releasing Runtime; final playback counts remain readable.
The original public streams are consumed by the facades, so an unused duplicate
Record queue cannot terminate an otherwise active audio service.

The full gate exposed an intermittent cancellation cleanup panic after a
semi/seamless handoff. Main had moved to the target, while an old send still
leased the source group. Cleanup now cancels Main senders and waits for all group
leases before destroying transferred services; joining the old wire-drain thread
alone was insufficient. The network integration and then the complete aggregate
gate passed after the fix, with matching source/oracle/fixture fingerprints.
Evidence: `.build/zig-migration/audio-facades/validation.json` and
`audio-facades-fixed-final.log`; the initial failure remains in
`audio-facades-final.log`.

Seven executor tests cover late retained PCM, bounded unused replay, joined final
statistics and full UInt32 delay intervals. A public Swift consumer handles 40
ordered controls on each of two TCP connections, late attachment, duplicate
start and reacquisition. It sends no START and opens no audio device; separate
existing offline AVAudioEngine/AVAudioConverter sanitizer checks also passed.
Agent/USB/WebDAV facades and packaging remain outstanding.

### Public Agent service (2026-10-31)

The Swift Agent facade now uses the native executor for clipboard policy, monitor
configuration, file transfer, completion and diagnostics. Ordered native replay
supports start before or after connection. Stop joins the worker, preserves the
next public file identifier and accumulates content-free diagnostic counts.
Reconnect-boundary waits can be cancelled without cancelling the session.

The full aggregate gate passed with matching source/oracle/fixture fingerprints;
evidence is `.build/zig-migration/agent-facades/validation.json` and
`agent-facades-final.log`. Public Swift tests cover two TCP connections, disabled
clipboard access, exact monitor acknowledgement and file bytes, typed file-size
errors, duplicate attachment and file identities across stop/start. Native tests
cover explicit operation completion, disabled automatic polling and policy
revocation. These tests do not access the general clipboard or attach USB devices.
USB/WebDAV facades, packaging and the application switch remain outstanding.

### Public USB service (2026-10-31)

The Swift USB facade and attached native runner retain the caller's exact native
host. Buffered parser prefixes and configured packet limits survive attachment;
all returned batches own their bytes. Attachment waits for initial output, device
commands remain explicit, and stop joins native work before releasing the host.
Attached traffic bypasses the unused public queue, matching the original session.

Native tests, 64 native sanitizer lifecycles, public Swift tests and the full
aggregate gate passed. All 375 source/oracle/fixture fingerprints matched before
archiving `.build/zig-migration/usb-facades/validation.json`. The final log is
`usb-facades-fixed-final.log`; an earlier ABI export compilation failure and its
repair are retained in the preceding logs. Public tests retain a partial parser
prefix across attachment, compare 40 replies per connection against the native
oracle, enforce 8-byte packet limits, release the caller's host while attached,
and reconnect the same session. No physical USB device was selected or opened.
WebDAV facade, packaging and the application switch remain outstanding.

### Public WebDAV service and shared ownership (2026-10-31)

The Swift WebDAV facade now retains a native server that owns the filesystem,
HTTP buffers and shared admission limits. Standalone calls and multiple attached
channels use this same object. Each queued request retains its originating
attachment and transport generation; workers cannot return responses through
another attachment. The shared executor gate bounds simultaneous filesystem
operations across attachments. Same-client ordering survives cancellation and
close/reuse, including old filesystem and sender owners.

The compatibility receive API retains incremental parsing and consumed-prefix
behavior, typed header/body/client errors and batches longer than the asynchronous
job limit. Failed attachment leaves the server's existing parser state intact.
Closing an attachment clears shared clients, while surviving owners may reuse the
server. Standalone responses own their bytes beyond server destruction. Default
access remains read-only; mutations require the caller's explicit access mode.

Focused native and public Swift checks passed, followed by the complete aggregate
gate with matching fingerprints. Evidence:
`.build/zig-migration/webdav-facades/validation.json` and
`webdav-facades-final.log`. New checks cover allocation cleanup, cross-attachment
cancellation and ordering, shared filesystem permits, standalone/parser state,
shared client limits, 70 exact responses across two channels, 70-request legacy
batches, typed limits, symlink escape denial, explicit writes, caller release and
reconnect cleanup. Existing 3,118 HTTP parser and 604 full-filesystem comparisons
also passed. All filesystem effects used owned temporary roots.

The existing PublicAPIConsumer and Maspice SpiceController type-check against the
new Swift module with Swift 6 strict concurrency and warnings as errors. This is
compile compatibility, not the completed SwiftPM/application switch. Packaging,
viewer offline rendering and an explicit large-local-clipboard behavior gap remain
under review; no production consumer or release artifact has switched yet.

### Final local package and application integration (2026-10-31)

The three implementation gaps from the preceding milestone are now closed:
explicit oversized local clipboard publishing, viewer offline rendering, and
native packaging/actual SwiftPM and Maspice local consumption. The final native
aggregate passed with 383 matching fingerprints. The checked-in core archive is
ReleaseSafe; native bridge sanitizer/static-analysis checks remain enabled.

`Scripts/validate-zig-package.sh` builds Release consumers through the real
SwiftPM product and runs the existing independent TCP and service scenarios.
It passed, including shader resources, SwiftUI lifecycle, native runtime symbol
presence and legacy-runtime absence. The first Debug closure attempt correctly
rejected SwiftPM's absolute development rpaths; the gate now checks Release
artifacts without rewriting their load commands. Its dependency assertion also
accounts for the build-only Metal shader plugin.

All 727 Swift tests passed normally, under ASan and in the coverage run (75.63%,
unchanged 62% floor). Reference presenter tests initially exposed the renamed
reference resource bundle; correcting its lookup retained every assertion.
Public API execution, Release library and source/header/native closure checks
passed. Maspice passed 55 application and four session-logic tests, local Release
assembly, relocatability and ad-hoc signature validation. The assembled executable
contains the Zig session entry point and no old Swift core module symbols.

Final manifests are `.build/zig-migration/packaged-final/validation.json` and
`delivery.json`; reproduction commands are in the current status above. The
schema generator and original Swift test oracles remain build/test tools, outside
the application runtime. No user edits were discarded and no release/tag was
published. Physical presentation, advanced-video hardware success, live peers,
real devices, clean macOS 26 and production distribution remain unpassed external
gates; they are not replaced by synthetic visibility or GPU completion evidence.

### Evidence-label correction (2026-10-31)

Shared Swift session/audio integration reports previously hardcoded the sanitizer
label from `validate-zig-swift.sh`, which was inaccurate when reused by the
uninstrumented SwiftPM Release driver. All shared Swift integration reports now
read an explicit build configuration from their driver; direct invocations with
no configuration assert no sanitizer coverage. The other C-only integration
labels were checked against their dedicated sanitizer build commands.

The existing Release JSON reports have a documented metadata-only correction;
original reports and logs remain preserved. `packaged-final/metadata-correction.json`
records before/after hashes and the limited syntax/metadata checks. Historical
runtime tests were not rerun or reattributed to the edited reporting scripts.
The 727-test count and 75.63% coverage primarily include old Swift reference/oracle
modules; they must not be interpreted as new Zig-core coverage. Native and
packaged-consumer evidence remains separate. No runtime behavior or outstanding
physical/live-peer/device gate changed.
