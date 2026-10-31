# Roadmap

Build a dependable SPICE client library for Apple Silicon, expand compatibility
with real SPICE deployments, and make efficient use of the native rendering
pipeline. The first release should support a clearly documented set of guest
configurations; broader spice-gtk compatibility can grow through independently
validated additions.

This document records direction, sequencing, and completion criteria. Issues
track individual changes, and [STATUS.md](STATUS.md) records verification results.
The priorities below are proposed engineering priorities, with no committed
release dates.

## Baseline

Reviewed on **October 31, 2026**, against
[`libmaspice@4fe2aab6`][lib-baseline] and
[`spice-gtk 0.43`][gtk-display]. The comparison covers the production Zig core,
Apple bridges, and public C/Swift integration. The older Swift implementations
under `test/oracle` remain independent test inputs.

| Area | Existing foundation | Remaining work |
| --- | --- | --- |
| Desktop drawing | `DRAW_FILL`, `DRAW_COPY`, and `COPY_BITS`; FILL is limited to a solid brush, no mask, and PUT, while COPY requires PUT, no mask, and equal source/destination dimensions. | Additional drawing families, masks, brushes, raster operations, protocol scaling, and more bitmap/surface formats. See the [display dispatcher][display] and [wire decoder][display-wire]. |
| Image codecs | Production QUIC, JPEG, LZ RGB/palette, GLZ, zlib-wrapped GLZ, caches, and surface references. | JPEG with alpha, optional LZ4, and wider raw bitmap compatibility. Wire recognition and successful drawing need separate coverage. See [image decoding][display-wire] and [QUIC][quic]. |
| Apple acceleration | JPEG NEON; opt-in H.264/H.265 VideoToolbox decoding with actual hardware-session checks; IOSurface/Metal video composition; native-backed presentation with MPS scaling. | Ordinary drawing still takes the CPU-backed presentation path. Full-surface copies, offscreen GPU waits, and advanced-video scheduling remain the focus of [#1][rendering-issue]. |
| Video policy | MJPEG is the default. H.264 or H.265 can be selected explicitly with MJPEG. | Validate each policy through a real peer and physical display. VP8/VP9 decoding and software advanced-video fallback are separate compatibility choices. See [codec policy][video-policy] and [decoder dispatch][stream-decoder]. |
| Sessions and host services | Ticket authentication over TCP/TLS, migration state machines, text clipboard, host-to-guest file upload, RAW audio, explicit USB redirection, smartcard messages, and a bounded WebDAV implementation. | Session edge cases, richer host integration, deployment-specific transports/authentication, and live interoperability evidence. See [preserved contracts][contracts]. |

spice-gtk registers 13 `DRAW_*` families plus `COPY_BITS`; the three libmaspice
entry points above are an operation inventory, not an overall completion score.
Both implementation depth and supported combinations matter. Optional upstream
features also depend on build configuration and installed backends.

## Delivery sequence

| Phase | Priority | Outcome | Dependency |
| --- | --- | --- | --- |
| 0. Session reliability and compatibility baseline | P0 | Supported desktop sessions remain usable when optional features are absent. | Start immediately. |
| 1. Display semantics and cursor compatibility | P0 for the first supported guest profile; P1 for broader coverage | Correct pixels and cursors for an explicit operation/format matrix. | Use Phase 0 peer traces and fixtures; ship in small increments. |
| 2. Apple Silicon rendering and video scheduling | P1 | Lower copy traffic and scheduling stalls, supported by measurements. | Establish a baseline first; can run alongside Phase 1. Detailed work is in [#1][rendering-issue]. |
| 3. Daily desktop integration | P1/P2 according to the supported profile | Usable clipboard, audio, file, and port workflows. | Build on stable channel and lifecycle behavior. |
| 4. Deployment and peripheral coverage | P2, driven by concrete use cases | Broader authentication, transport, migration, device, and guest-client support. | Select a target deployment before implementation. |

Real-peer and hardware acceptance starts in Phase 0 and continues throughout.
An initial release can target a narrower supported profile while optional
deployment features remain open. Broad spice-gtk compatibility requires the
wider display and integration matrix to be completed explicitly.

## Phase 0 — Session reliability and a reproducible baseline

- [ ] **Define channel admission policy.** Distinguish required, supported
  optional, disabled, and unsupported channels during initial connection and
  migration. A server advertising General Port or an unknown optional channel
  must not prevent an otherwise supported desktop session from connecting.
  Keep validation strict for channels that are accepted.
- [ ] **Implement input motion flow control.** Honor motion ACKs with a bounded
  outstanding-motion policy consistent with SPICE ACK batching. Bound pending
  input, coalesce absolute positions, preserve relative movement with defined overflow behavior, and
  retain button/key ordering and release events. Reset state on reconnect and
  generation changes.
- [ ] **Make unsupported display behavior explicit.** Record unsupported
  operations and parameter combinations with a documented caller-visible
  outcome. Do not silently count an ignored draw as a successful render. Keep
  Surface and cache state consistent when a command cannot be executed.
- [ ] **Record a small real-peer baseline.** Identify server, guest OS, guest
  agent, display configuration, client build, and enabled features. Cover
  connection, reconnect, input, resize, and the host services enabled in the
  first supported profile. Separate pass, fail, and unsupported results.

**Why first:** the current channel list is forwarded to child creation, but
General Port has no child implementation. The resulting error can propagate out
of connection establishment. This is a source-derived failure path that still
needs a peer reproduction; implementing Port itself is not required to fix
admission. Motion ACKs are currently received without a corresponding send
window. See [channel admission][channel-admission], [child creation][children],
[session establishment][supervisor], and [input handling][inputs].

**Completion criteria:** exercise optional-channel offers through connection
and migration, delayed/batched input ACKs, sustained motion with button
transitions, and reconnect/cancellation. Demonstrate that a supported desktop
remains functional and that queues and cleanup stay bounded. Capture a
reproducible real-peer baseline before describing that profile as supported.

## Phase 1 — Display semantics and cursor compatibility

- [ ] **Expand existing operations.** Preserve existing clipping and add masks,
  pattern brushes, raster operations, and protocol-level scaling to FILL/COPY.
  Preserve overlapping `COPY_BITS`, source/cache ownership, and transactional publication.
- [ ] **Add missing drawing families in reviewable groups.** Start with
  `BLACKNESS`, `WHITENESS`, and `INVERS`; then implement `OPAQUE`, `BLEND`,
  `TRANSPARENT`, and `ALPHA_BLEND`; follow with `ROP3`, `COMPOSITE`, `STROKE`,
  and `TEXT`. Reorder these groups when real workloads establish a different
  need. Track each operation's supported combinations explicitly.
- [ ] **Expand image and Surface formats.** Add JPEG-with-alpha and the raw
  bitmap, palette, alpha-only, and lower-bit-depth formats required by the
  selected guests. Evaluate LZ4 against an explicit server configuration.
  Keep compressed-image support separate from raw bitmap and Surface support.
- [ ] **Complete native cursor conversion.** Render MONO, COLOR4, COLOR16, and
  COLOR32 payloads in the built-in view, including hotspot and transparency
  semantics. These formats are parsed today; the native-view policy currently
  selects the custom image path only for ALPHA cursors.
- [ ] **Maintain a compatibility matrix.** Distinguish parsing, decoding,
  drawing execution, and built-in-view presentation. Optional capabilities must
  reflect complete, validated paths; base drawing operations still need
  deliberate unsupported-case behavior because they are not all negotiated.

**Completion criteria:** compare pixels with a pinned independent upstream
renderer for each implemented operation and its declared combinations. Include
clipping, masks, raster operations, scaling, alpha, cache references, overlapping
copies, and mixed command sequences where relevant. Check retained snapshots
and failed candidates as well as final pixels. Cursor acceptance includes an
actual native-view result. Update the matrix with each addition.

The first supported guest profile must pass its complete required subset.
Claiming broad drawing parity additionally requires all 14 entry families and
their supported semantics to be accounted for. MPS window scaling does not
implement SPICE drawing-command scaling. See [upstream dispatch][gtk-display],
[local dispatch][display], [image formats][display-wire],
[cursor decoding][cursor-wire], and [cursor presentation policy][cursor-policy].

## Phase 2 — Apple Silicon rendering and video scheduling

Use [#1: Reduce Surface copies and GPU stalls, and improve native rendering and
video scheduling][rendering-issue] as the detailed implementation and acceptance
plan. Keep its progress linked here instead of duplicating its full task list.

- [ ] **Establish comparable ReleaseSafe measurements.** Record hardware,
  build, codec policy, resolution, scaling, refresh rate, and workload. Retain
  the existing pixel-quality and resource-lifetime contracts.
- [ ] **Complete the copy and native-presentation work in #1.** Begin with
  copy elision for verified full-coverage, opaque, write-only operations with no
  dependency on previous destination pixels, and batch offscreen GPU work. Extend
  ordinary drawing to native backing without introducing a full-frame upload
  on every publication. Add conservative candidate revision tracking before
  selective synchronization.
- [ ] **Complete receive/decode/presentation separation in #1.** Preserve
  reference-frame order, bounded frame/byte queues, cancellation, migration
  acknowledgements, and Surface mutation barriers. Verify progress through the
  production Display receive path, including future-PTS video followed by
  control and drawing messages.
- [ ] **Evaluate further optimizations from profiling.** Direct NV12
  presentation/overlays, additional regional synchronization, static JPEG
  decoder pooling, and scaling-cache strategies need a measured bottleneck,
  bounded memory cost, and correct composition/readback transitions.

**Completion criteria:** show comparable before/after results for the relevant
workloads: scrolling, small updates, a small video region on a large desktop,
fullscreen video, mixed drawing/video, fractional scaling, and hide/resume.
Report copy/materialization bytes, allocation pressure, GPU submissions and
waits, queueing, and latency distributions. Separate publication, GPU completion,
and physical presentation evidence. Run the subset affected by each change.

The current acceleration foundation should be preserved: JPEG NEON, verified
VideoToolbox hardware sessions, IOSurface/Metal leases, MPS scaling, stream
reports, and demand-driven presentation. These mechanisms do not by themselves
establish an end-to-end performance advantage over spice-gtk. VideoToolbox
software fallback and automatic renegotiation to MJPEG are not current behavior;
any fallback policy needs its own design and acceptance criteria.

## Phase 3 — Daily desktop integration

Select independently shippable additions according to the first supported
desktop profile.

- [ ] **Extend clipboard interoperability.** Preserve UTF-8 text behavior;
  implement the selection/ownership/serial semantics actually exposed to
  consumers. Start image support with a named format such as PNG, then add
  further formats as needed. Validate bidirectional transfer, ownership races,
  release, payload limits, and disconnect. File-list clipboard integration is
  a separate workflow from Agent file upload.
- [ ] **Add Opus audio where needed.** Negotiate only implemented playback and
  recording paths. Cover supported sample rates/channels, restarts,
  reconfiguration, bounded buffering, cancellation, and continued RAW support.
  Close end-to-end acceptance with a real peer and playback/capture devices.
- [ ] **Implement General Port for a named consumer.** Provide bounded data
  and event APIs, initialization/open/close state, cancellation, and teardown.
  Verify at least one real consumer. Keep disabled or unsupported Port safe to
  omit through the Phase 0 admission policy.
- [ ] **Validate existing host services.** Exercise text clipboard,
  host-to-guest upload, RAW audio, and the documented shared-folder subset
  against the selected guests. Track discovered defects individually.

**Completion criteria:** each enabled workflow has a documented public API,
negotiation policy, limits, cancellation behavior, and a recorded real-peer
result. Existing implemented services should be improved from evidence rather
than treated as missing. The current scope and test boundaries are recorded in
[MIGRATION.md][contracts] and [STATUS.md](STATUS.md).

## Phase 4 — Deployment and peripheral coverage

Create scoped implementation issues when a concrete deployment requires these
capabilities. They can be prioritized independently.

| Workstream | Scope and completion criteria |
| --- | --- |
| Migration destination trust | Support the currently rejected destination certificate-subject offer with an explicit trust policy. Verify match/mismatch, target failure, cancellation, channel adoption, and a real live migration while preserving TLS verification. Existing semi/seamless/switch-host machinery remains the foundation. See [destination configuration][endpoint]. |
| Authentication and transports | Define required SASL mechanisms/security layers before implementation. Treat proxy, Unix socket, and supplied-fd integration as separate targets. Verify the selected mode with a real server, cancellation, ownership cleanup, and unchanged TLS guarantees. |
| USB device management | Add public discovery, hotplug events, and selection policy over the existing native redirection backend. Make automatic connection opt-in and filtered. Cover removal, address reuse, detach, shutdown, migration ownership, and a documented physical device class. |
| Smartcard host integration | Connect the existing Reader/ATR/APDU protocol APIs to a chosen host-reader backend. Verify insertion, APDU round trips, removal, failure, and teardown with an actual reader/card. Scope software-card support separately if needed. |
| WebDAV interoperability | Publish the supported method subset and limits. Select guest clients, add the methods they require, and introduce bounded streaming for large files where necessary. Add locking/property support against a concrete client requirement. |
| Additional video compatibility | Evaluate VP8/VP9 or an advanced-video software fallback only against a named deployment. Align advertised codecs with available decoders and verify ordering, limits, failure behavior, and real-peer playback. |

Linux-specific integration such as DMA-BUF/EGL scanout and desktop policy
services is outside the initial Apple Silicon target. Shared SPICE semantics
and user-visible workflows remain the compatibility benchmark.

## Acceptance and release readiness

Apply these gates to the features included in a release profile. Optional
deployment work may remain open with its status documented.

1. **Implementation evidence:** production paths, capability declarations,
   public APIs, and limits agree. Use the source, ABI, package, sanitizer, and
   differential checks appropriate to the change, as required by
   [AGENTS.md](../AGENTS.md). Preserve ReleaseSafe, cancellation with joined
   destruction, resource budgets, failure-atomic Surface publication, and GPU
   leases through actual completion.
2. **Interoperability evidence:** run the declared server/guest matrix with
   the selected features, including reconnect and applicable migration modes.
   Record versions and reproducible workloads. Fixture peers and local codec
   tests have their own status.
3. **Hardware and display evidence:** verify enabled video policies from real
   peers through the application to the physical display. Record actual
   hardware-decoder status and nonzero `presentedTime` where applicable.
   Validate enabled USB, smartcard, clipboard, and audio workflows on the
   corresponding host facilities.
4. **Performance evidence:** establish baselines and report latency,
   memory/copy traffic, CPU/GPU cost, and regressions for representative
   workloads. A speed comparison with spice-gtk must name its build/backends
   and use a comparable environment and workload.
5. **Consumer and distribution readiness:** exercise installed C and SwiftPM
   consumers on the minimum supported macOS version and a current version.
   Verify application adoption separately from library extraction, preserve
   dependency provenance and relinking materials, and complete applicable
   consumer-app signing/notarization checks before distribution claims.

The repository already records substantial local codec, graphics, ownership,
ABI, loopback, and hardware-decoder fixture validation. Its
[current external acceptance boundaries][status-baseline] remain open until
corresponding results are recorded. A documentation update does not close them.

## Keeping the roadmap current

- Update this document through pull requests when scope, dependencies, or
  completion criteria change.
- Link concrete implementation issues and pull requests from the relevant
  phase. The existing rendering workstream is [#1][rendering-issue].
- Use GitHub Projects for status, ownership, and dependency views when active
  work needs a board; use Milestones for agreed release scopes.
- Record implementation status and external acceptance separately in
  [STATUS.md](STATUS.md). Assign dates only after scope and capacity are agreed.

[lib-baseline]: https://github.com/BeriBeli/libmaspice/commit/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3
[gtk-display]: https://gitlab.freedesktop.org/spice/spice-gtk/-/blob/f028f45a573926736223548887e18ac65dabb50b/src/channel-display.c#L2242-2282
[display]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/src/display.zig#L135-L188
[display-wire]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/src/display_wire.zig#L75-L125
[quic]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/pkg/quic/README.md
[video-policy]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/bindings/swift/SpiceZigSwift/SpiceSessionTypes.swift#L14-L29
[stream-decoder]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/src/stream_decoder.zig#L114-L132
[contracts]: MIGRATION.md
[channel-admission]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/src/child_connections.zig#L25-L42
[children]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/src/desktop_child.zig#L57-L69
[supervisor]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/src/supervisor.zig#L309-L347
[inputs]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/src/inputs.zig#L66-L86
[cursor-wire]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/src/cursor_wire.zig#L52-L64
[cursor-policy]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/src/presentation_policy.zig#L32-L41
[endpoint]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/src/endpoint.zig#L43-L58
[status-baseline]: https://github.com/BeriBeli/libmaspice/blob/4fe2aab6cc06ff12cba4fb97fbbbdb7300b3cfd3/docs/STATUS.md#L79-L84
[rendering-issue]: https://github.com/BeriBeli/libmaspice/issues/1
