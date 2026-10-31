//! VMC raw payload validation. Compression is not negotiated by this library.
const wire = @import("bytes.zig");
const std = @import("std");
pub fn validate(bytes: []const u8) !void {
    if (bytes.len == 0) return error.InvalidSize;
    if (bytes.len > 1024 * 1024) return error.MessageTooLarge;
}
pub fn decode(a: std.mem.Allocator, kind: u16, bytes: []const u8) !wire.Slice {
    if (kind == 102) return error.UnnegotiatedCompression;
    if (kind != 101) return error.UnsupportedMessage;
    try validate(bytes);
    return wire.Slice.copy(a, bytes);
}
pub fn send(connection: anytype, bytes: []const u8) !void {
    try validate(bytes);
    try connection.send(101, bytes);
}
