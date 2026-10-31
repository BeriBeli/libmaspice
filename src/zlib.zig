//! Exact bounded zlib envelope, using the platform's existing libz backend.
const std = @import("std");
const cancel = @import("cancel.zig");
extern "z" fn uncompress2(destination: [*]u8, destination_len: *c_ulong, source: [*]const u8, source_len: *c_ulong) c_int;
pub const Limits = struct { encoded: usize = 64 * 1024 * 1024, decoded: usize = 256 * 1024 * 1024 };
pub fn inflate(a: std.mem.Allocator, payload: []const u8, exact: usize, limits: Limits, token: *cancel.Token) ![]u8 {
    try token.check();
    if (payload.len == 0) return error.EmptyPayload;
    if (payload.len > limits.encoded) return error.EncodedImageTooLarge;
    if (exact == 0 or exact > limits.decoded) return error.DecodedImageTooLarge;
    const output = try a.alloc(u8, exact);
    errdefer a.free(output);
    var written: c_ulong = exact;
    var consumed: c_ulong = payload.len;
    const status = uncompress2(output.ptr, &written, payload.ptr, &consumed);
    try token.check();
    if (status != 0) return error.InflateFailed;
    if (written != exact) return error.SizeMismatch;
    if (consumed != payload.len) return error.TrailingInput;
    return output;
}
