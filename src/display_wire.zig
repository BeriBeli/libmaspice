//! Display drawing payloads. Parsed values borrow the immutable message; only
//! bounded clip/palette arrays use the per-command arena. No native layouts.
const std = @import("std");
const wire = @import("bytes.zig");
const Rect = @import("region.zig").Rect;
const barrier = @import("barrier.zig");
pub const Point = struct { x: i32, y: i32 };
pub const Base = struct { surface: u32, box: Rect, clips: ?[]const Rect };
pub const Descriptor = struct { id: u64, kind: u8, flags: u8, width: u32, height: u32 };
pub const Palette = union(enum) { cached: u64, inline_data: struct { id: u64, entries: []const u32 } };
pub const Image = struct { descriptor: Descriptor, payload: union(enum) { raw: struct { format: u8, flags: u8, stride: u32, data: []const u8 }, quic: []const u8, jpeg: []const u8, lz: []const u8, glz: []const u8, zlib_glz: struct { size: u32, data: []const u8 }, lz_palette: struct { flags: u8, palette: Palette, data: []const u8 }, surface: u32, cached: bool } };
pub const Mask = struct { flags: u8, position: Point, image: ?Image };
pub const Brush = union(enum) { none, solid: u32, pattern: struct { image: Image, position: Point } };
pub const Command = union(enum) {
    create: struct { id: u32, width: u32, height: u32, format: u32, flags: u32 },
    destroy: u32,
    reset,
    invalidate: []const u64,
    invalidate_all: []const barrier.Requirement,
    invalidate_palette: u64,
    invalidate_palettes,
    copy_bits: struct { base: Base, source: Point },
    fill: struct { base: Base, brush: Brush, rop: u16, mask: Mask },
    copy: struct { base: Base, source: Image, area: Rect, rop: u16, scale: u8, mask: Mask },
    unknown: u16,
};
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    command: Command,
    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};
const Parser = struct {
    allocator: std.mem.Allocator,
    body: []const u8,
    fn rect(reader: *wire.Reader) !Rect {
        const top = try reader.read(i32);
        const left = try reader.read(i32);
        const bottom = try reader.read(i32);
        const right = try reader.read(i32);
        return .{ .x = left, .y = top, .width = @as(i64, right) - left, .height = @as(i64, bottom) - top };
    }
    fn point(reader: *wire.Reader) !Point {
        return .{ .x = try reader.read(i32), .y = try reader.read(i32) };
    }
    fn base(self: Parser, reader: *wire.Reader) !Base {
        const id = try reader.read(u32);
        const box = try rect(reader);
        const kind = try reader.read(u8);
        const clips: ?[]const Rect = if (kind == 0) null else if (kind == 1) blk: {
            const count = try reader.read(u32);
            if (count > 4096 or count > reader.remaining() / 16) return error.InvalidSize;
            const items = try self.allocator.alloc(Rect, count);
            for (items) |*item| item.* = try rect(reader);
            break :blk items;
        } else return error.InvalidEnum;
        return .{ .surface = id, .box = box, .clips = clips };
    }
    const MaskHeader = struct { flags: u8, position: Point, offset: u32 };
    fn maskHeader(reader: *wire.Reader) !MaskHeader {
        return .{ .flags = try reader.read(u8), .position = try point(reader), .offset = try reader.read(u32) };
    }
    const ImageAt = struct { image: Image, range: wire.Range };
    fn data(reader: *wire.Reader) ![]const u8 {
        const size = try reader.read(u32);
        if (size > 64 * 1024 * 1024) return error.MessageTooLarge;
        return reader.take(size);
    }
    fn image(self: Parser, offset: u32, minimum: usize) !ImageAt {
        if (offset < minimum) return error.InvalidOffset;
        var reader = try wire.Reader.init(self.body, offset);
        const descriptor: Descriptor = .{ .id = try reader.read(u64), .kind = try reader.read(u8), .flags = try reader.read(u8), .width = try reader.read(u32), .height = try reader.read(u32) };
        if (descriptor.flags & ~@as(u8, 7) != 0) return error.InvalidEnum;
        const payload: @TypeOf(@as(Image, undefined).payload) = switch (descriptor.kind) {
            0 => blk: {
                const format = try reader.read(u8);
                const flags = try reader.read(u8);
                const width = try reader.read(u32);
                const height = try reader.read(u32);
                const stride = try reader.read(u32);
                if (flags & 2 != 0) {
                    _ = try reader.read(u64);
                } else if (try reader.read(u32) != 0) return error.UnsupportedRAWPalette;
                if (width != descriptor.width or height != descriptor.height) return error.DimensionMismatch;
                const size = try std.math.mul(usize, stride, height);
                if (size > 64 * 1024 * 1024) return error.MessageTooLarge;
                break :blk .{ .raw = .{ .format = format, .flags = flags, .stride = stride, .data = try reader.take(size) } };
            },
            1 => .{ .quic = try data(&reader) },
            103 => .{ .cached = false },
            104 => .{ .surface = try reader.read(u32) },
            105 => .{ .jpeg = try data(&reader) },
            106 => .{ .cached = true },
            107 => blk: {
                const size = try reader.read(u32);
                if (size == 0 or size > 64 * 1024 * 1024) return error.MessageTooLarge;
                break :blk .{ .zlib_glz = .{ .size = size, .data = try data(&reader) } };
            },
            100 => blk: {
                const flags = try reader.read(u8);
                if (flags & ~@as(u8, 7) != 0) return error.InvalidEnum;
                const size = try reader.read(u32);
                if (size > 64 * 1024 * 1024) return error.MessageTooLarge;
                var palette: Palette = undefined;
                var compressed: []const u8 = undefined;
                if (flags & 2 != 0) {
                    palette = .{ .cached = try reader.read(u64) };
                    compressed = try reader.take(size);
                } else {
                    const palette_offset = try reader.read(u32);
                    compressed = try reader.take(size);
                    if (palette_offset != reader.offset) return error.InvalidOffset;
                    const id = try reader.read(u64);
                    const count = try reader.read(u16);
                    if (count == 0 or count > 256 or count > reader.remaining() / 4) return error.InvalidSize;
                    const entries = try self.allocator.alloc(u32, count);
                    for (entries) |*entry| entry.* = try reader.read(u32);
                    palette = .{ .inline_data = .{ .id = id, .entries = entries } };
                }
                break :blk .{ .lz_palette = .{ .flags = flags, .palette = palette, .data = compressed } };
            },
            101 => .{ .lz = try data(&reader) },
            102 => .{ .glz = try data(&reader) },
            else => return error.UnsupportedImage,
        };
        return .{ .image = .{ .descriptor = descriptor, .payload = payload }, .range = .{ .start = offset, .end = reader.offset } };
    }
    fn mask(self: Parser, header: MaskHeader, minimum: usize, ranges: *std.ArrayList(wire.Range)) !Mask {
        const bitmap = if (header.offset == 0) null else blk: {
            const parsed = try self.image(header.offset, minimum);
            try ranges.append(self.allocator, parsed.range);
            break :blk parsed.image;
        };
        return .{ .flags = header.flags, .position = header.position, .image = bitmap };
    }
    fn finishReferences(self: Parser, minimum: usize, ranges: []wire.Range) !void {
        std.mem.sort(wire.Range, ranges, {}, struct {
            fn less(_: void, l: wire.Range, r: wire.Range) bool {
                return l.start < r.start;
            }
        }.less);
        var end = minimum;
        for (ranges) |range| {
            if (range.start < end or range.start - end > 3) return error.InvalidOffset;
            end = range.end;
        }
        if (end != self.body.len) return error.TrailingBytes;
    }
    fn decode(self: Parser, kind: u16) !Command {
        var reader = try wire.Reader.init(self.body, 0);
        var ranges: std.ArrayList(wire.Range) = .empty;
        const command: Command = switch (kind) {
            314 => .{ .create = .{ .id = try reader.read(u32), .width = try reader.read(u32), .height = try reader.read(u32), .format = try reader.read(u32), .flags = try reader.read(u32) } },
            315 => .{ .destroy = try reader.read(u32) },
            103 => .reset,
            105 => blk: {
                const count = try reader.read(u16);
                if (count > 4096 or count > reader.remaining() / 9) return error.InvalidSize;
                const ids = try self.allocator.alloc(u64, count);
                for (ids) |*id| {
                    if (try reader.read(u8) != 1) return error.InvalidEnum;
                    id.* = try reader.read(u64);
                }
                break :blk .{ .invalidate = ids };
            },
            106 => blk: {
                const count = try reader.read(u8);
                if (count > reader.remaining() / 10) return error.InvalidSize;
                const waits = try self.allocator.alloc(barrier.Requirement, count);
                for (waits) |*wait| wait.* = .{ .key = .{ .kind = try reader.read(u8), .id = try reader.read(u8) }, .serial = try reader.read(u64) };
                break :blk .{ .invalidate_all = waits };
            },
            107 => .{ .invalidate_palette = try reader.read(u64) },
            108 => .invalidate_palettes,
            104 => .{ .copy_bits = .{ .base = try self.base(&reader), .source = try point(&reader) } },
            302 => blk: {
                const command_base = try self.base(&reader);
                const brush = try reader.read(u8);
                var color: u32 = 0;
                var pattern: u32 = 0;
                var position: Point = .{ .x = 0, .y = 0 };
                switch (brush) {
                    0 => {},
                    1 => color = try reader.read(u32),
                    2 => {
                        pattern = try reader.read(u32);
                        position = try point(&reader);
                    },
                    else => return error.InvalidEnum,
                }
                const rop = try reader.read(u16);
                const header = try maskHeader(&reader);
                const minimum = reader.offset;
                const source: Brush = switch (brush) {
                    0 => .none,
                    1 => .{ .solid = color },
                    else => p: {
                        const parsed = try self.image(pattern, minimum);
                        try ranges.append(self.allocator, parsed.range);
                        break :p .{ .pattern = .{ .image = parsed.image, .position = position } };
                    },
                };
                const command_mask = try self.mask(header, minimum, &ranges);
                try self.finishReferences(minimum, ranges.items);
                reader.offset = self.body.len;
                break :blk .{ .fill = .{ .base = command_base, .brush = source, .rop = rop, .mask = command_mask } };
            },
            304 => blk: {
                const command_base = try self.base(&reader);
                const offset = try reader.read(u32);
                const area = try rect(&reader);
                const rop = try reader.read(u16);
                const scale = try reader.read(u8);
                const header = try maskHeader(&reader);
                const minimum = reader.offset;
                const source = try self.image(offset, minimum);
                try ranges.append(self.allocator, source.range);
                const command_mask = try self.mask(header, minimum, &ranges);
                try self.finishReferences(minimum, ranges.items);
                reader.offset = self.body.len;
                break :blk .{ .copy = .{ .base = command_base, .source = source.image, .area = area, .rop = rop, .scale = scale, .mask = command_mask } };
            },
            else => {
                reader.offset = self.body.len;
                return .{ .unknown = kind };
            },
        };
        try reader.finish();
        return command;
    }
};
pub fn decode(a: std.mem.Allocator, kind: u16, body: []const u8) !Parsed {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const parser: Parser = .{ .allocator = arena.allocator(), .body = body };
    const command = try parser.decode(kind);
    return .{ .arena = arena, .command = command };
}
