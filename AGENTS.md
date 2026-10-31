# libmaspice agent instructions

Read README.md, docs/MIGRATION.md and docs/STATUS.md before changes. Preserve
existing user work. Keep production algorithms in src and pkg/quic; native Apple
bridges belong in src/platform/apple, public C contracts in include, and Swift
consumer adaptation in bindings/swift. Old Swift implementations in test/oracle
are independent test inputs and must never become runtime dependencies.

Preserve Zig 0.17.0 ReleaseSafe, boundary/integer checks, explicit cancellation
and joined destruction, resource accounting/backpressure, failure cleanup,
transactional Surface publication and leases through GPU completion. Do not
replace hardware-status queries or pixel oracles with linking/build-only claims.

Do not introduce developer absolute paths or untracked cache dependencies into
source/scripts/tests. Keep credentials, clipboard contents and live payloads out
of logs. Use explicit integration inputs and owned temporary roots.

Run checks appropriate to the change. Build graph/native ABI changes require
zig build, zig build test-installed, zig build check-native and relevant source/
consumer gates. Shared changes require zig build test and zig build test-package.
Swift changes use warnings-as-errors and Swift 6 concurrency. Do not weaken tests,
sanitizers or safety checks to pass. Physical display/hardware/real-peer results
must be distinguished from local fixture evidence. Preserve upstream licenses,
checksums and rebuildability. Do not publish, tag, create remotes or claim a release
without explicit user instruction.
