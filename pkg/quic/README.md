# Zig SPICE QUIC codec

This is the production QUIC image codec in `CSpiceQUIC.xcframework`. It ports
`common/quic.c`, `quic_tmpl.c` and `quic_family_tmpl.c` from spice-common commit
`71e45706981973014eaab3d4b533d35d79e19ffa` to Zig 0.17.0. It does not implement
the network protocol named QUIC, or the rest of spice-common/spice-gtk.

The algorithm and sampling table remain **LGPL-2.1-or-later**, including the
Red Hat attribution and [COPYING](COPYING). Zig standard-library/runtime code
retains its [MIT notice](ZIG-LICENSE). Removing the C codec binary does not
remove the upstream license obligations. Sources and rebuild scripts are
provided so recipients can modify the codec and relink the static artifact.

## Implementation boundary

- `codec.zig`: header/bit I/O, adaptive models, predictors, run coding, five-format
  encoder and decoder, signed strides, streaming and allocation-failure tests.
- `random.zig`: upstream model-sampling table.
- `abi.zig`: checked C argument conversion and the user callback allocator.
- `adapter.c`: the five public C functions and warning/fatal callback dispatch.
  It contains no codec algorithm. Zig returns a status and runs its cleanup
  before this C frame invokes `usr->error`; a caller's `longjmp` therefore does
  not cross an active Zig codec frame. I/O callbacks signal exhaustion/failure
  through their return values, as in the upstream contract.
- `quic.h`: upstream-compatible public declarations with standalone standard
  includes/macros. `shim.h` retains SwiftSpice's bounded BGRA bridge.
- `experiment.zig`: validation-only exports; excluded from the product archive.

Production and validation use **ReleaseSafe**, with checked slice access,
integer arithmetic, residual ranges and run bounds. No safety override or
benchmark-specific codec path is used. The contiguous RGB16→RGB32,
RGB24/RGB32→RGB32 and RGBA→RGBA decoder paths retain the full-buffer loop.
Other layouts use independently allocated normalized rows and channel models
with O(width) workspace. Each row allocation fits the signed C allocator size
even at the upstream maximum width.
All state is context-local; different contexts can operate concurrently.
A single context and its user callbacks must not be used concurrently.

## Public C contract

`quic_create`, `quic_destroy`, `quic_encode`, `quic_decode_begin` and `quic_decode`
have the upstream enums, callback layout, C parameter ABI and success/error
conventions. `quic_create` validates every required callback and returns NULL
on allocation failure. `quic_destroy(NULL)` is harmless. All codec allocations
use the caller's malloc/free callbacks; requests cannot truncate the callback's
signed `int` size. Allocation failure returns `QUIC_ERROR` after cleanup.

`quic_decode_begin` reads metadata and retains the unread bitstream. A fresh
begin resets prior state. After a completed or failed body, call begin again.
Unsupported output format or invalid stride is rejected before consuming body
state, allowing a corrected decode call. The complete conversion matrix is:

| Source | Legal output |
| --- | --- |
| GRAY | GRAY |
| RGB16 | RGB16, RGB32 |
| RGB24 | RGB24, RGB32 |
| RGB32 | RGB24, RGB32 |
| RGBA | RGBA |

Input/output chunks contain whole little-endian 32-bit words. Decode begin
requires at least one initial word; encoder output may start empty. A callback may
reuse the previous chunk's storage; buffered unread bits are retained internally.
`more_space` receives the number of fully completed rows. Null, zero-length or
negative callback results fail without reading or writing the reported block.

Both codec directions accept positive/negative byte strides and row padding.
The C pointer identifies the logical **first row**, including for negative
stride. Padding is not touched. RGB16 ignores the high unused input bit; RGB32
ignores its unused input byte. Native RGB16 output clears its high unused bit;
RGB32 output clears its padding byte. RGB16 is read/written bytewise, including
odd strides, without unaligned `uint16_t` accesses.

Encoding supports initially empty row batches and `more_lines`. As required by
upstream, the last row of the previous batch must remain valid when that callback
returns. The codec saves its normalized previous row before requesting another
batch, so older batches need not remain alive. Successful encoding returns the
number of 32-bit words written, including final padding.

Dimensions are positive signed C ints, and width×height is at most
512×1024×1024−1, matching the pinned upstream decoder. Encoding enforces the same
bound before arithmetic. Stride/layout arithmetic is checked. The C API has no
buffer-capacity argument: caller pointers and callback lengths must describe
valid memory. Invalid strides return an error rather than relying on upstream
assertions. The validation-only API also checks explicit output capacity.

SwiftSpice's application decoder separately retains its 16384-axis, 64 MiB
encoded-input and 256 MiB output defaults. The experimental BGRA entry point
retains those same historical limits. They are application policies, not new
full-library compatibility limits. The bridge expands grayscale backwards in
its existing output allocation, with no temporary buffer to leak on `longjmp`.

## Build and verification

Ordinary SwiftPM consumers need no Zig installation. Maintainers rebuild the
arm64/macOS 26+ static artifact with Xcode and Zig 0.17.0:

```sh
zig build xcframework
zig build test-quic
zig build test
```

`build-quic-native.sh` records upstream provenance, owned source hashes,
toolchain, configuration, license texts and archive hash. The native closure
gate checks those hashes, architecture, required C/Zig symbols, absence of
experimental exports and relocatable links. Full native rebuilds call the same
QUIC builder. No spice-gtk, GTK or GLib is downloaded or linked for production
QUIC. Debug symbols are stripped; runtime safety remains enabled.

The independent C oracle is fetched from the pinned, checksum-verified archive
by `test/quic/Validation/reference.py`. Its codec sources and
public header are unchanged; only platform macro headers are supplied locally.
The oracle does not link the production artifact. C assertions remain enabled.

Local acceptance covers:

- 3,360 full-decoder cases: eight conversions, signed/padded strides, word-sized
  input chunks, metadata, invalid arguments, guards and continuous context reuse,
  including actual 32,769-pixel-wide images beyond the application default.
- 880 encoder cases: five formats, signed/padded input, output chunks and row
  batches, exact C bitstreams and both cross-decoder pixel comparisons. Bitstream
  identity is established for this corpus, not asserted as a universal proof.
- One C consumer compiled against the **unchanged upstream header** and linked
  unchanged to C and Zig: 864 pixel/guard cases, 96 allocation-failure trials,
  truncation, callback failures, fatal `longjmp`, cleanup and context reuse.
  Source-built C adapters/consumers run under ASan/UBSan. Zig is checked with
  ReleaseSafe, guards and injected allocator failures, not claimed ASan-instrumented.
- The same consumer against the shipped archive, including sanitizer checks on
  the consumer. This gate requires no Zig compiler and runs in `zig build test-quic`.
- 840 further valid images compared with original pixels and independent C;
  4,198 truncations and 20,000 mutations compare the actual product bridge with
  the bounded Zig entry point, including every accepted mutation's pixels.
- Seven Zig unit tests, including failure at every model/row allocation,
  bit-reservoir lookahead, output exhaustion and missing rows.

Records and reproducible tools are in
`test/quic/` (new runs) and `docs/history/` (historical extraction records).
The C oracle's RGB16 scalar accesses require two-byte row alignment under UBSan;
its aligned layouts form the independent C comparison. Zig's additional odd
RGB16 strides and negative partial row batches are verified separately. No
sanitizer was disabled to accommodate the upstream implementation.

These are local codec and application-build checks, not a real SPICE server,
installed-app display/orientation, or clean-machine acceptance result. No release
or tag is implied by the local Maspice editable-dependency integration.
