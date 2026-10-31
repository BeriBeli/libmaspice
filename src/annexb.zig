//! One-pass Annex-B descriptors followed by one AVCC sample allocation. NALs
//! borrow the caller's immutable input; parameter storage is a decoder concern.
const std = @import("std");
pub const Codec = enum { h264, h265 };
pub const Limits = struct { encoded: usize = 64 * 1024 * 1024, units: usize = 1024, nal_bytes: usize = 32 * 1024 * 1024 };
pub const NAL = struct { kind: u8, bytes: []const u8, parameter: bool };
pub const Unit = struct {
    allocator: std.mem.Allocator,
    nals: []NAL,
    sample: []u8,
    picture: bool,
    random_access: bool,
    pub fn deinit(self: Unit) void {
        self.allocator.free(self.nals);
        self.allocator.free(self.sample);
    }
};
fn start(bytes: []const u8, offset: usize) usize {
    if (offset > bytes.len or bytes.len - offset < 3 or bytes[offset] != 0 or bytes[offset + 1] != 0) return 0;
    if (bytes.len - offset >= 4 and bytes[offset + 2] == 0 and bytes[offset + 3] == 1) return 4;
    return if (bytes[offset + 2] == 1) 3 else 0;
}
fn describe(codec: Codec, bytes: []const u8) !NAL {
    if (bytes.len == 0) return error.EmptyNAL;
    if (bytes[0] & 0x80 != 0) return error.ForbiddenBit;
    const kind: u8 = switch (codec) {
        .h264 => bytes[0] & 0x1f,
        .h265 => blk: {
            if (bytes.len < 2 or bytes[1] & 7 == 0) return error.InvalidHEVCHeader;
            break :blk (bytes[0] >> 1) & 0x3f;
        },
    };
    return .{ .kind = kind, .bytes = bytes, .parameter = switch (codec) {
        .h264 => kind == 7 or kind == 8 or kind == 13,
        .h265 => kind >= 32 and kind <= 34,
    } };
}
pub fn parse(a: std.mem.Allocator, codec: Codec, bytes: []const u8, limits: Limits) !Unit {
    if (bytes.len == 0) return error.EmptyPayload;
    if (bytes.len > limits.encoded) return error.EncodedImageTooLarge;
    var begin = start(bytes, 0);
    if (begin == 0) return error.NotAnnexB;
    var cursor = begin;
    var nals: std.ArrayList(NAL) = .empty;
    defer nals.deinit(a);
    var size: usize = 0;
    var picture = false;
    var random = false;
    while (true) {
        const prefix = if (cursor < bytes.len) start(bytes, cursor) else 0;
        if (cursor == bytes.len or prefix != 0) {
            var end = cursor;
            while (end > begin and bytes[end - 1] == 0) end -= 1;
            if (end - begin > limits.nal_bytes or nals.items.len >= limits.units) return error.NALLimit;
            const nal = try describe(codec, bytes[begin..end]);
            try nals.append(a, nal);
            if (!nal.parameter) {
                if (nal.bytes.len > std.math.maxInt(u32)) return error.Overflow;
                size = try std.math.add(usize, size, try std.math.add(usize, nal.bytes.len, 4));
                picture = picture or switch (codec) {
                    .h264 => nal.kind >= 1 and nal.kind <= 5,
                    .h265 => nal.kind <= 31,
                };
                random = random or switch (codec) {
                    .h264 => nal.kind == 5,
                    .h265 => nal.kind >= 16 and nal.kind <= 23,
                };
            }
            if (cursor == bytes.len) break;
            cursor += prefix;
            begin = cursor;
            if (begin == bytes.len) return error.EmptyNAL;
        } else cursor += 1;
    }
    const sample = try a.alloc(u8, size);
    errdefer a.free(sample);
    var output: usize = 0;
    for (nals.items) |nal| if (!nal.parameter) {
        std.mem.writeInt(u32, sample[output..][0..4], @intCast(nal.bytes.len), .big);
        output += 4;
        @memcpy(sample[output..][0..nal.bytes.len], nal.bytes);
        output += nal.bytes.len;
    };
    return .{ .allocator = a, .nals = try nals.toOwnedSlice(a), .sample = sample, .picture = picture, .random_access = random };
}
