//! Bounded SPICE LZ RGB/alpha and palette decoding. One decoded allocation;
//! palette bytes expand backwards in that same allocation. Result publication
//! is transactional: the caller only receives an image after exact consumption.
const std = @import("std");
const wire = @import("bytes.zig");
pub const Limits = struct {
    dimension: usize = 16384,
    encoded: usize = 64 * 1024 * 1024,
    decoded: usize = 256 * 1024 * 1024,
    palette_entries: usize = 256,
};
pub const Diagnostics = struct {
    output_allocations: u64 = 1,
    output_bytes: u64,
    temporary_decoded_allocations: u64 = 0,
    copy_calls: u64 = 0,
    copy_bytes: u64 = 0,
    palette_expansions: u64 = 0,
    palette_pixels: u64 = 0,
};
pub const Image = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    top_down: bool,
    has_alpha: bool,
    pixels: []u8,
    diagnostics: Diagnostics,
    pub fn deinit(self: Image) void {
        self.allocator.free(self.pixels);
    }
};
const Plane = enum {
    color,
    rgb16,
    alpha,
    packed_value,
    fn bias(self: Plane) usize {
        return switch (self) {
            .color => 1,
            .rgb16 => 2,
            .alpha, .packed_value => 3,
        };
    }
    fn unitSize(self: Plane) usize {
        return if (self == .packed_value) 1 else 4;
    }
};
fn readBE(reader: *wire.Reader) !u32 {
    return @byteSwap(try reader.read(u32));
}

pub fn decode(allocator: std.mem.Allocator, payload: []const u8, width: usize, height: usize, palette: ?[]const u32, limits: Limits) !Image {
    if (payload.len == 0) return error.EmptyPayload;
    if (payload.len > limits.encoded) return error.EncodedImageTooLarge;
    if (palette) |entries| {
        if (entries.len == 0 or entries.len > limits.palette_entries) return error.UnsupportedFormat;
    }
    var reader = try wire.Reader.init(payload, 0);
    if (try readBE(&reader) != 0x20205a4c or try readBE(&reader) != 0x00010001) return error.InvalidHeader;
    const kind = try readBE(&reader);
    if (palette != null) {
        if (kind < 1 or kind > 5) return error.UnsupportedFormat;
    } else if (kind < 6 or kind > 11) return error.UnsupportedFormat;
    const image_width = try readBE(&reader);
    const image_height = try readBE(&reader);
    const stride = try readBE(&reader);
    const top_down = try readBE(&reader);
    if (top_down > 1) return error.InvalidHeader;
    if (image_width == 0 or image_height == 0 or image_width > limits.dimension or image_height > limits.dimension) return error.InvalidDimensions;
    if (image_width != width or image_height != height) return error.DimensionMismatch;
    const pixels = std.math.mul(usize, width, height) catch return error.IntegerOverflow;
    const output_size = std.math.mul(usize, pixels, 4) catch return error.IntegerOverflow;
    if (output_size > limits.decoded) return error.DecodedImageTooLarge;
    const per_byte: usize = switch (kind) {
        1, 2 => 8,
        3, 4 => 2,
        else => 1,
    };
    const expected_stride = if (palette != null) (width + per_byte - 1) / per_byte else std.math.mul(usize, width, switch (kind) {
        6 => @as(usize, 2),
        7 => 3,
        11 => 1,
        else => 4,
    }) catch return error.IntegerOverflow;
    if (stride != expected_stride) return error.InvalidHeader;
    if (palette) |entries| {
        if (kind <= 2 and entries.len < 2) return error.MalformedPayload;
    }
    const output = try allocator.alloc(u8, output_size);
    errdefer allocator.free(output);
    var diagnostics: Diagnostics = .{ .output_bytes = output_size };
    if (palette) |entries| {
        const packed_size = try std.math.mul(usize, stride, height);
        try decodePlane(.packed_value, &reader, output, packed_size, &diagnostics);
        try reader.finish();
        // Full byte lookup preserves the existing 4-bit modulo-palette rule,
        // packed row tails and cross-row references without a second backing.
        var lookup: [256][32]u8 = @splat(@splat(0));
        for (0..256) |packed_value| {
            for (0..per_byte) |pixel| {
                const index = paletteIndex(kind, packed_value, pixel, entries.len);
                if (index < entries.len) {
                    const entry = entries[index];
                    lookup[packed_value][pixel * 4] = @truncate(entry);
                    lookup[packed_value][pixel * 4 + 1] = @truncate(entry >> 8);
                    lookup[packed_value][pixel * 4 + 2] = @truncate(entry >> 16);
                }
            }
        }
        var row = height;
        while (row > 0) {
            row -= 1;
            var column: usize = stride;
            while (column > 0) {
                column -= 1;
                const packed_value = output[row * stride + column];
                if (kind == 5 and packed_value >= entries.len) return error.MalformedPayload;
                const first = column * per_byte;
                const count = @min(per_byte, width - first);
                const destination = (row * width + first) * 4;
                @memcpy(output[destination..][0 .. count * 4], lookup[packed_value][0 .. count * 4]);
                diagnostics.palette_expansions +|= 1;
                diagnostics.palette_pixels +|= count;
            }
        }
    } else {
        if (kind >= 10) @memset(output, 0);
        switch (kind) {
            6 => try decodePlane(.rgb16, &reader, output, pixels, &diagnostics),
            7, 8 => try decodePlane(.color, &reader, output, pixels, &diagnostics),
            9 => {
                try decodePlane(.color, &reader, output, pixels, &diagnostics);
                try decodePlane(.alpha, &reader, output, pixels, &diagnostics);
            },
            10, 11 => try decodePlane(.alpha, &reader, output, pixels, &diagnostics),
            else => unreachable,
        }
        try reader.finish();
    }
    return .{ .allocator = allocator, .width = width, .height = height, .top_down = top_down == 1, .has_alpha = kind >= 9, .pixels = output, .diagnostics = diagnostics };
}

fn paletteIndex(kind: u32, byte: usize, pixel: usize, count: usize) usize {
    return switch (kind) {
        1 => (byte >> @as(u6, @intCast(pixel))) & 1,
        2 => (byte >> @as(u6, @intCast(7 - pixel))) & 1,
        3 => ((byte >> @as(u6, @intCast(pixel * 4))) & 15) % count,
        4 => ((byte >> @as(u6, @intCast((1 - pixel) * 4))) & 15) % count,
        5 => byte,
        else => unreachable,
    };
}

fn decodePlane(comptime plane: Plane, reader: *wire.Reader, output: []u8, count: usize, diagnostics: *Diagnostics) !void {
    var position: usize = 0;
    while (position < count) {
        const control: usize = try reader.read(u8);
        if (control < 32) {
            const length = control + 1;
            if (length > count - position) return error.MalformedPayload;
            for (0..length) |_| {
                const offset = position * plane.unitSize();
                switch (plane) {
                    .packed_value => output[offset] = try reader.read(u8),
                    .alpha => output[offset + 3] = try reader.read(u8),
                    .color => {
                        @memcpy(output[offset..][0..3], try reader.take(3));
                        output[offset + 3] = 0;
                    },
                    .rgb16 => {
                        const red = try reader.read(u8);
                        const blue = try reader.read(u8);
                        var green = ((red << 6) | (blue >> 2)) & ~@as(u8, 7);
                        green |= green >> 5;
                        output[offset] = (blue << 3) | ((blue >> 2) & 7);
                        output[offset + 1] = green;
                        output[offset + 2] = ((red << 1) & ~@as(u8, 7)) | ((red >> 4) & 7);
                        output[offset + 3] = 0;
                    },
                }
                position += 1;
            }
        } else {
            var length = (control >> 5) - 1;
            if (length == 6) {
                while (true) {
                    const extra = try reader.read(u8);
                    length = std.math.add(usize, length, extra) catch return error.IntegerOverflow;
                    if (length > count - position) return error.MalformedPayload;
                    if (extra != 255) break;
                }
            }
            const low: usize = try reader.read(u8);
            var distance = ((control & 31) << 8) + low;
            if (distance == 8191) {
                distance = @as(usize, try reader.read(u8)) << 8;
                distance += try reader.read(u8);
                distance += 8191;
            }
            distance += 1;
            length = std.math.add(usize, length, plane.bias()) catch return error.IntegerOverflow;
            if (distance > position or length > count - position) return error.MalformedPayload;
            copyReference(plane, output, position - distance, position, length, diagnostics);
            position += length;
        }
    }
}

fn copyReference(comptime plane: Plane, output: []u8, source: usize, destination: usize, length: usize, diagnostics: *Diagnostics) void {
    var copied = @min(destination - source, length);
    copyUnits(plane, output, source, destination, copied, diagnostics);
    while (copied < length) {
        const next = @min(copied, length - copied);
        copyUnits(plane, output, destination, destination + copied, next, diagnostics);
        copied += next;
    }
    if (plane == .alpha) {
        diagnostics.copy_calls +|= 1;
        diagnostics.copy_bytes +|= length;
    }
}
fn copyUnits(comptime plane: Plane, output: []u8, source: usize, destination: usize, count: usize, diagnostics: *Diagnostics) void {
    if (plane == .alpha) {
        var i: usize = 0;
        // Disjoint periods permit native vector loads without changing the
        // other BGRA channels. Doubling keeps overlapping LZ matches exact.
        while (count - i >= 4) : (i += 4) {
            const s: *align(1) const @Vector(4, u32) = @ptrCast(output[(source + i) * 4 ..][0..16].ptr);
            const d: *align(1) @Vector(4, u32) = @ptrCast(output[(destination + i) * 4 ..][0..16].ptr);
            const mask: @Vector(4, u32) = @splat(0xff000000);
            d.* = (d.* & ~mask) | (s.* & mask);
        }
        while (i < count) : (i += 1) output[(destination + i) * 4 + 3] = output[(source + i) * 4 + 3];
    } else {
        const size = plane.unitSize();
        @memcpy(output[destination * size ..][0 .. count * size], output[source * size ..][0 .. count * size]);
        diagnostics.copy_calls +|= 1;
        diagnostics.copy_bytes +|= count * size;
    }
}

test "LZ periods alpha preservation bounds trailing bytes and allocator failure" {
    const t = std.testing;
    try t.checkAllAllocationFailures(t.allocator, allocationTest, .{});
    const header = [_]u8{ 0x20, 0x20, 0x5a, 0x4c, 0, 1, 0, 1, 0, 0, 0, 7, 0, 0, 0, 8, 0, 0, 0, 1, 0, 0, 0, 24, 0, 0, 0, 1 };
    const payload = header ++ [_]u8{ 0, 1, 2, 3, 0xe0, 0, 0 }; // one literal, seven-pixel overlap
    const image = try decode(t.allocator, &payload, 8, 1, null, .{});
    defer image.deinit();
    for (0..8) |pixel| try t.expectEqualSlices(u8, &.{ 1, 2, 3, 0 }, image.pixels[pixel * 4 ..][0..4]);
    try t.expectEqual(@as(u64, 28), image.diagnostics.copy_bytes);
    for (0..payload.len) |end| {
        if (decode(t.allocator, payload[0..end], 8, 1, null, .{})) |unexpected| {
            unexpected.deinit();
            return error.AcceptedTruncation;
        } else |_| {}
    }
    try t.expectError(error.TrailingBytes, decode(t.allocator, &(payload ++ [_]u8{0}), 8, 1, null, .{}));
    try t.expectError(error.DimensionMismatch, decode(t.allocator, &payload, 7, 1, null, .{}));
    try t.expectError(error.DecodedImageTooLarge, decode(t.allocator, &payload, 8, 1, null, .{ .decoded = 31 }));
    var pixels: [32 * 4]u8 = @splat(0x55);
    pixels[3] = 7;
    var diagnostics: Diagnostics = .{ .output_bytes = pixels.len };
    copyReference(.alpha, &pixels, 0, 1, 31, &diagnostics);
    for (0..32) |pixel| try t.expectEqualSlices(u8, &.{ 0x55, 0x55, 0x55, 7 }, pixels[pixel * 4 ..][0..4]);
}
fn allocationTest(allocator: std.mem.Allocator) !void {
    const payload = [_]u8{ 0x20, 0x20, 0x5a, 0x4c, 0, 1, 0, 1, 0, 0, 0, 11, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 42 };
    const image = try decode(allocator, &payload, 1, 1, null, .{});
    defer image.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 42 }, image.pixels);
}
