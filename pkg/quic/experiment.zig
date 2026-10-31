// SPDX-License-Identifier: LGPL-2.1-or-later
// Exports used only by opt-in validation and benchmark harnesses.
const codec = @import("codec.zig");
comptime {
    @export(&codec.zig_quic_decode, .{ .name = "zig_quic_decode" });
    @export(&codec.zig_quic_context_create, .{ .name = "zig_quic_context_create" });
    @export(&codec.zig_quic_context_destroy, .{ .name = "zig_quic_context_destroy" });
    @export(&codec.zig_quic_begin, .{ .name = "zig_quic_begin" });
    @export(&codec.zig_quic_finish, .{ .name = "zig_quic_finish" });
    @export(&codec.zig_quic_encode, .{ .name = "zig_quic_encode" });
}
