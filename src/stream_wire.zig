//! Stream and monitor messages borrow encoded frame bytes and own only bounded
//! metadata in an arena. Codec selection is policy, separate from wire parsing.
const std = @import("std");
const wire = @import("bytes.zig");
const Rect = @import("region.zig").Rect;
const generated = @import("generated.zig");
pub const Codec = enum(u8) { mjpeg = 1, vp8 = 2, h264 = 3, vp9 = 4, h265 = 5 };
pub const Create = struct { surface: u32, id: u32, top_down: bool, codec: Codec, stamp: u64, width: u32, height: u32, source_width: u32, source_height: u32, destination: Rect, clips: ?[]const Rect };
pub const Sizing = struct { width: u32, height: u32, destination: Rect };
pub const Data = struct { id: u32, time: u32, sizing: ?Sizing, bytes: []const u8 };
pub const Monitor = struct { id: u32, surface: u32, width: u32, height: u32, x: u32, y: u32, flags: u32 };
pub const Command = union(enum) { create: Create, data: Data, clip: struct { id: u32, clips: ?[]const Rect }, destroy: u32, destroy_all, report: generated.SpiceMsgDisplayStreamActivateReport, monitors: struct { maximum: u16, heads: []const Monitor } };
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    command: Command,
    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};
fn id(reader: *wire.Reader) !u32 {
    const value = try reader.read(u32);
    if (value >= 64) return error.InvalidStreamID;
    return value;
}
fn rect(reader: *wire.Reader) !Rect {
    const top = try reader.read(i32);
    const left = try reader.read(i32);
    const bottom = try reader.read(i32);
    const right = try reader.read(i32);
    return .{ .x = left, .y = top, .width = @as(i64, right) - left, .height = @as(i64, bottom) - top };
}
fn destination(reader: *wire.Reader) !Rect {
    const value = try rect(reader);
    if (value.width <= 0 or value.height <= 0) return error.InvalidGeometry;
    return value;
}
fn dimensions(width: u32, height: u32) !void {
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidDimensions;
}
fn clip(a: std.mem.Allocator, reader: *wire.Reader) !?[]const Rect {
    switch (try reader.read(u8)) {
        0 => return null,
        1 => {
            const count = try reader.read(u32);
            if (count > 4096 or count > reader.remaining() / 16) return error.InvalidSize;
            const items = try a.alloc(Rect, count);
            for (items) |*item| item.* = try rect(reader);
            return items;
        },
        else => return error.InvalidEnum,
    }
}
pub fn decode(a: std.mem.Allocator, kind: u16, body: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var reader = try wire.Reader.init(body, 0);
    const command: Command = switch (kind) {
        122 => blk: {
            const surface = try reader.read(u32);
            const stream = try id(&reader);
            const flags = try reader.read(u8);
            if (flags & ~@as(u8, 1) != 0) return error.InvalidEnum;
            const codec = std.enums.fromInt(Codec, try reader.read(u8)) orelse return error.InvalidEnum;
            const stamp = try reader.read(u64);
            const w = try reader.read(u32);
            const h = try reader.read(u32);
            const sw = try reader.read(u32);
            const sh = try reader.read(u32);
            try dimensions(w, h);
            try dimensions(sw, sh);
            if (sw > w or sh > h) return error.InvalidDimensions;
            break :blk .{ .create = .{ .surface = surface, .id = stream, .top_down = flags == 1, .codec = codec, .stamp = stamp, .width = w, .height = h, .source_width = sw, .source_height = sh, .destination = try destination(&reader), .clips = try clip(alloc, &reader) } };
        },
        123, 316 => blk: {
            const stream = try id(&reader);
            const time = try reader.read(u32);
            var sizing: ?Sizing = null;
            if (kind == 316) {
                const w = try reader.read(u32);
                const h = try reader.read(u32);
                try dimensions(w, h);
                sizing = .{ .width = w, .height = h, .destination = try destination(&reader) };
            }
            const size = try reader.read(u32);
            if (size > 64 * 1024 * 1024) return error.MessageTooLarge;
            break :blk .{ .data = .{ .id = stream, .time = time, .sizing = sizing, .bytes = try reader.take(size) } };
        },
        124 => .{ .clip = .{ .id = try id(&reader), .clips = try clip(alloc, &reader) } },
        125 => .{ .destroy = try id(&reader) },
        126 => .destroy_all,
        319 => .{ .report = try generated.SpiceMsgDisplayStreamActivateReport.decode(&reader) },
        317 => blk: {
            const count = try reader.read(u16);
            const maximum = try reader.read(u16);
            if (count > 256 or maximum > 256 or (maximum != 0 and count > maximum) or reader.remaining() != @as(usize, count) * 28) return error.InvalidSize;
            const heads = try alloc.alloc(Monitor, count);
            var seen: [256]bool = @splat(false);
            for (heads) |*head| {
                head.* = .{ .id = try reader.read(u32), .surface = try reader.read(u32), .width = try reader.read(u32), .height = try reader.read(u32), .x = try reader.read(u32), .y = try reader.read(u32), .flags = try reader.read(u32) };
                if (head.id >= 256 or seen[head.id]) return error.InvalidMonitorID;
                seen[head.id] = true;
                if (head.width == 0 or head.height == 0) return error.InvalidDimensions;
                _ = try std.math.add(u32, head.x, head.width);
                _ = try std.math.add(u32, head.y, head.height);
            }
            break :blk .{ .monitors = .{ .maximum = maximum, .heads = heads } };
        },
        else => return error.UnsupportedMessage,
    };
    try reader.finish();
    return .{ .arena = arena, .command = command };
}
