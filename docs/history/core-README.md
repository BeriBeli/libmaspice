# Parallel Zig library core

This directory is an **incomplete parallel migration**, not the library currently
consumed by Maspice. See [the contract ledger](../../docs/ZIG_MIGRATION.md) for
implemented behavior, remaining modules and exact validation limits.

- `root.zig` exposes the Zig modules. Build with Zig 0.17.0, ReleaseSafe,
  arm64/macOS 26. Run `../../Scripts/validate-zig.sh` from this directory or
  `./Scripts/validate-zig.sh` from the repository root.
- `spice_zig.h` describes the foundational C ABI. `spice_zig_desktop.h` adds the
  real supervised desktop, immutable events/frames and native presenter. `spice_zig_agent.h` adds optional Agent desktop services. These adapt
  ownership and arguments; parsing, channel policy and Agent state live in Zig.
- `network_bridge.m` only adapts Apple Network/Security objects and callbacks.
  TCP/TLS policy, DER parsing, bounds, deadlines, cancellation and ownership are
  in Zig. No GTK/GLib dependency is introduced.
- `Sources/CSpiceQUIC` remains the production QUIC implementation. Do not fork it
  into this directory. Its existing licenses and artifact evidence still apply.

A session owns connecting and authenticated connections, a processed-serial
barrier and a continuous multimedia clock. Each channel has one receive/handler
worker, with an explicit `complete` after the handler's work finishes. Sends are
serialized across the entire frame, including any bounded transport chunks.
Main is a typed service on a session-owned Main connection; Agent producers may
send concurrently through its FIFO gate. Active messages retain the old channel
across replacement until their last fragment completes.

Cancellation is thread-safe. It interrupts native connection/read/write work and
wakes explicit waiters. Cancel and **join all callers before destroying** a
session/service/token; Main services must be destroyed before their session.
Read the header's lifetime contract for each handle. Returned events own their
immutable bytes and may outlive their channel or session. No background worker
is detached or implicitly owned by a borrowed handle.

`Session` is the ownership/factory layer. `Supervisor(Child)` adds bounded
parallel child handshakes, joined receive/control workers, transactional target
preparation and semi/seamless/switch-host handoff. The supplied test child is an
integration fixture, not a production no-op service.

`display.zig` executes the existing drawing subset through shared image-cache,
GLZ and Surface transactions. Native frames retain IOSurface/Metal ownership
and shared allocation charges until their final lease is released. Run
`./Scripts/validate-zig-graphics.sh` from the repository root to exercise the
actual local Metal/MPS path, pixel-quality oracle and native sanitizers.

`video.zig` owns parameter sets, hardware-only VideoToolbox sessions, immutable
CVPixelBuffer frames and the existing integer CPU conversion. The native bridge
owns only Apple calls and callback adaptation. `stream_decoder.zig` combines
persistent JPEG/VT decoding with Surface sequencing, native composition and CPU
fallback; `stream_scheduler.zig` owns two joined workers, bounded retained input
and cancellable run/event lifetimes. MJPEG replaces only pending work; advanced
input retains FIFO order. `display_service.zig` dispatches drawing, streams,
arrival reports and owned monitor events. It keeps advanced-frame physical
completion serial, as in the existing Swift service.

Run `./Scripts/validate-zig-video.sh` for local hardware, pixel-quality,
allocation-failure and native sanitizer gates. `display_child.zig` is a real
Display-only bundle for `Supervisor`. `desktop_child.zig` assembles real Display,
Inputs, Cursor, RAW S16 Playback/Record, Smartcard, USB VMC and WebDAV mux services. Typed sends pin state until
old child writes drain before handoff; cursor/PCM events own immutable bytes.
Unknown channel kinds fail explicitly. `frame_publisher.zig` provides bounded
parallel preparation, ordered publication, explicit demand/consumption gating
and lifecycle-owned damage restoration. `surface.zig` shares canonical memory
across Display channels and reuses native ring slots only after all external
leases release. Failed GPU candidates are discarded.

`Supervisor(desktop_child).createConfigured` retains an optional native context;
its groups retain that context through channel lifetime and migration. The
caller may release its own context after creation. A caller-supplied native
Budget must still outlive every retained frame. Host peripherals/filesystems,
live audio/device-route acceptance, native window presentation and
the application adapter remain open work. This ABI must not
be advertised as full SwiftSpice parity or packaged as a release.

`presenter.zig` retains frame leases until actual GPU completion and limits each
view submitter to two in-flight commands. Hosts supply textures/drawables during
their draw cycle; the existing nearest shader and direct MPS Lanczos policy are
preserved. GPU completion is not an onscreen timestamp. Public native frame
pixels are materialized only on demand, once per publication, with concurrent
reader serialization. The embedded desktop ABI preserves host signal-stack
ownership, including ASan's stack, without disabling ReleaseSafe checks.


`agent_services_wire.zig`, `clipboard.zig`, `monitor_config.zig` and
`file_transfer.zig` implement negotiated clipboard/layout/upload behavior.
`agent_manager.zig` combines them in bounded pump turns; `agent_session.zig`
checks stable session identity and Agent incarnation before any send. Migration
preserves work; switch-host and Agent restart retire it. `file_source.zig` pins
read-only regular-file descriptors through late reads. No guest payload can
create a host file. `spice_zig_agent.h` documents the optional public manager,
explicit host writer callback, owned events and serialized lifetime contract.
Run `./Scripts/validate-zig-agent-services.sh` for independent Swift protocol,
Unicode, clipboard and layout comparisons. The aggregate also exercises the
public C manager with authenticated peers and native sanitizers.

`pasteboard.zig` and `pasteboard_bridge.m` adapt owned, cancellable main-thread
NSPasteboard operations. `agent_runner.zig` optionally owns the manager worker,
periodic polling, token-backpressure retry and bounded command/output queues.
Clipboard access is explicit and can be revoked while main is blocked. General
pasteboard selection is explicit; tests use unique named boards only. The public
runner accepts ordered Desktop observations and must be destroyed before Desktop.
Its output events remain owned beyond both lifetimes. See `spice_zig_agent.h` for
threading, asynchronous file admission and borrowed-event access contracts.
`./Scripts/validate-zig-pasteboard.sh` checks Swift/AppKit text equivalence,
queued cancellation and native ASan/UBSan lifetime behavior.


`audio_ring.zig` and `audio_buffer.zig` own bounded preallocated PCM queues,
startup/overflow/underrun policy, dequeue leases and capture reporting.
`audio_native.zig` owns validated conversion chunks and timestamps; `audio_bridge.m`
is the narrow AVAudioConverter/AVAudioEngine and callback lifetime boundary.
`audio_runner.zig` optionally owns the joined playback/capture executor, automatic
record sending and delay reports. Both device options default off, and enabled
hardware opens only for its channel START. `spice_zig_audio.h` documents event,
permission and lifetime contracts. Record writes are fenced by guest identity and
START epoch; cancelled uncertain writes close the pinned transport.

`./Scripts/validate-zig-audio-buffers.sh` compares 105,000 ring operations with
unchanged Swift and tests allocation, cancellation and epoch ownership.
`./Scripts/validate-zig-audio-native.sh` compares exact offline converter output,
renders through AVAudioEngine in manual/offline mode, and checks native callback
leases with ASan/UBSan. Apple component registration and the aggregate's Security
checks require the normal host environment. These gates do not open a microphone
or audible output and do not claim live device/route or guest acceptance.


WebDAV host components include `webdav_http.zig` (owned HTTP requests),
`webdav_queue.zig` (atomic bounded admission and retired-owner barriers),
`webdav_path.zig` (explicit root, URL conversion and descriptor-relative access),
`webdav_fs.zig` (the existing read-only/read-write HTTP method subset), and
`webdav_runner.zig` (joined filesystem and response execution).
`spice_zig_webdav.h` exposes the optional backend: select an authorized root,
feed ordered Desktop events, inspect failures, and destroy it before Desktop.
Default access is read-only. Two filesystem operations can run concurrently;
blocked sends release that permit while retaining per-client ordering and byte
reservations. There is one bounded worker per request slot (default/maximum 64).
Closing a client cancels pending sends and joins owners before destruction;
already-entered regular-file syscalls can complete and are never retried.

Same-guest migration preserves incomplete HTTP bytes. Each admitted response
keeps its submission's transport generation, so retired sends cannot be credited
to a replacement connection. Switching guests or closing the port resets clients.
`./Scripts/validate-zig-webdav.sh` covers 23 Zig tests, 3,118 parser comparisons,
604 full-server comparisons and native ASan/UBSan. The aggregate additionally
runs `webdav-api-integration.py` through the public C API, authenticated loopback
peers, all three migration modes and exact multi-chunk responses. All filesystem
writes use owned temporary roots. These checks do not claim live guest mounting;
no SwiftPM or application consumer has switched to this parallel library.

USB host support uses `usb_host.zig` and the existing CUSBRedir native artifact,
with explicit exact bus/address selection, guest filtering, bounded buffers and
native integer errors. `usb_runner.zig` owns serial native execution, bounded
observations, periodic pumping and joined cleanup. `spice_zig_usb.h` exposes
standalone and session-owned alternatives. Feed ordered Desktop events; invoke
blocking device commands off that event reader, inspect asynchronous status,
and destroy before Desktop. Same-guest handoff preserves parser/device state;
a different guest stops the owner and requires explicit re-enablement. Failed
entered writes are never replayed. The USB gate covers 12 Zig tests, 64 native
C/oracle sanitizer cycles and real TCP migration. It never opens a physical USB
device. Hardware interoperability and full SwiftPM consumer migration remain
pending.


Desktop aggregation and presentation policy are in `desktop_source.zig`,
`desktop_snapshot.zig`, `desktop_source_session.zig` and
`presentation_policy.zig`. `spice_zig_source.h` is the owned consumer boundary.
Feed ordered Desktop events into one Source adapter and let it own publisher
visibility/ACK. Its subscriptions and snapshots retain their storage; stop and
join adapter observation before destroying the adapter, then destroy Desktop.
Snapshot extraction preserves merged damage without forcing CPU readback.
Handlers execute outside Source's mutex, retain their callback context through
captured delivery, and explicitly acknowledge frames. The ready latch preserves
its generation/sequence watermark through discard and consumes no stale retry.
The focused gate is `Scripts/validate-zig-presentation.sh`; the aggregate gate
also exercises six public C TCP/migration cases (CPU drawing, with/without a Metal context). Native host-view and
Swift consumer adaptation are still pending.


Presentation metrics and causal traces use `spice_zig_diagnostics.h`. Acquire a
retained diagnostics handle from Source; reset it before a new connection attempt.
Feed actual selection/commit/drawable presentation/drop stages using copied trace
identities and the shared continuous clock. GPU completion and actual display are
separate observations. Source automatically supplies receive/ready timestamps,
marker ROI and lifecycle retirement. Trace capture is opt-in and creates no file
until finish; on append failure, retry finish with the same frozen evidence.
Cancel/join waits and all external calls before destroying a capture. Owned record
bytes survive capture destruction. Do not log clipboard/tickets or arbitrary input
content through diagnostics. The optional native host now supplies these stages automatically.

Run `Scripts/validate-zig-diagnostics.sh` for independent Swift contracts and
allocation/filesystem/cancellation tests. The aggregate gate adds public C TCP
CPU/MJPEG-into-IOSurface tracing. Its host/drawable stage times are fixture inputs,
not a physical presentation benchmark. Static desktop consumers need the archive
built with `-fcompiler-rt` (the aggregate script does this) and existing native
framework dependencies; no separately installed Zig runtime is needed.

`host_input.zig` provides bounded keyboard batches, macOS modifier/scan-code
mapping, capture state and geometry. Run `Scripts/validate-zig-host-input.sh` for
its AppKit differential. The optional public presenter observer in
`spice_zig_desktop.h` delivers native GPU/drawable events on the main queue with
independent retained context ownership. `wait_idle` does not drain that queue.
`Scripts/validate-zig-native-presentation.sh` checks actual native callbacks and
sanitizer lifetimes; a sleeping display yields drops and leaves actual on-screen
timestamp acceptance pending.


`spice_zig_host_view.h` is the optional main-thread AppKit consumer boundary.
`host_view.zig` owns Source subscriptions, one-slot coalescing, display-link pacing,
CPU frame leases, GPU retry/recovery, input/capture state and diagnostics. The
Objective-C bridge only handles NSView/MTKView/CALayer, scalar NSEvent values and
Apple drawing/cursor calls. It holds a weak view box, while queued observations
retain the Zig controller independently. Close removes subscriptions, balances
capture/keys and joins GPU leases; late main-queue callbacks cannot revive a view.
The input callback must enqueue sends rather than perform blocking network work.
Destroy Source before Desktop; either may be destroyed before the retained view.

Build the separate `host_view_native.zig` ReleaseSafe archive with `-fcompiler-rt`
and link `host_view_bridge.m`, the desktop archive and MetalKit (alongside existing
frameworks). The aggregate gate builds and checks this real public boundary.
`validate-zig-host-view.sh --core` tests controller contracts without a WindowServer;
the default invocation additionally checks native NSWindow rendering and ASan/UBSan.
On a sleeping display it first requires zero demand under actual occlusion, then
injects visibility only in the test NSWindow to exercise CPU/GPU and lifecycle
paths. This does not validate physical refresh or nonzero presentation timestamps.
Texture-cache diagnostics remain zero because the new host consumes textures
already owned by native frames; it does not recreate the old Swift texture cache.
Public Swift/SwiftUI adapters and the application switch are still pending.
