//! Agent desktop-service payloads. Decoded byte views borrow the input message;
//! fixed-size capability/type arrays are copied. Encoders return owned messages.
const std = @import("std");
const wire = @import("bytes.zig");
const agent = @import("agent.zig");
pub const Capabilities = struct {
    words: [16]u32 = @splat(0),
    count: usize = 0,
    pub fn contains(self: Capabilities, bit: usize) bool {
        return bit / 32 < self.count and (self.words[bit / 32] & (@as(u32, 1) << @as(u5, @intCast(bit % 32)))) != 0;
    }
    pub fn desktop(clipboard: bool) Capabilities {
        var result: Capabilities = .{ .count = 1 };
        for ([_]u5{ 1, 2, 7, 12, 14 }) |bit| result.words[0] |= @as(u32, 1) << bit;
        if (clipboard) result.words[0] |= (1 << 3) | (1 << 5);
        return result;
    }
};
pub const Types = struct {
    values: [64]u32 = @splat(0),
    count: usize = 0,
    pub fn utf8() Types {
        var result: Types = .{ .count = 1 };
        result.values[0] = 1;
        return result;
    }
    pub fn hasText(self: Types) bool {
        return std.mem.indexOfScalar(u32, self.values[0..self.count], 1) != null;
    }
};
pub const Clipboard = union(enum) {
    capabilities: struct { reply: bool, values: Capabilities },
    grab: Types,
    request: u32,
    data: struct { kind: u32, bytes: []const u8 },
    release,
};
pub fn decodeClipboard(protocol: u32, kind: u32, bytes: []const u8) !?Clipboard {
    if (protocol != 1) return null;
    var r = try wire.Reader.init(bytes, 0);
    switch (kind) {
        6 => {
            const reply = try r.read(u32) != 0;
            if (r.remaining() % 4 != 0 or r.remaining() / 4 > 16) return error.InvalidSize;
            var caps: Capabilities = .{ .count = r.remaining() / 4 };
            for (caps.words[0..caps.count]) |*v| v.* = try r.read(u32);
            return .{ .capabilities = .{ .reply = reply, .values = caps } };
        },
        7 => {
            if (r.remaining() == 0 or r.remaining() % 4 != 0 or r.remaining() / 4 > 64) return error.InvalidSize;
            var types: Types = .{ .count = r.remaining() / 4 };
            for (types.values[0..types.count]) |*v| v.* = try r.read(u32);
            return .{ .grab = types };
        },
        8 => {
            const value = try r.read(u32);
            try r.finish();
            return .{ .request = value };
        },
        4 => {
            const value = try r.read(u32);
            return .{ .data = .{ .kind = value, .bytes = try r.take(r.remaining()) } };
        },
        9 => {
            try r.finish();
            return .release;
        },
        else => return null,
    }
}
fn message(a: std.mem.Allocator, kind: u32, w: *wire.Writer, opaque_id: u64) !agent.Message {
    return .{ .kind = kind, .opaque_id = opaque_id, .data = try wire.Slice.copy(a, w.bytes.items) };
}
pub fn encodeClipboard(a: std.mem.Allocator, command: Clipboard, opaque_id: u64) !agent.Message {
    var w: wire.Writer = .{ .allocator = a, .limit = 16 * 1024 * 1024 };
    defer w.deinit();
    const kind: u32 = switch (command) {
        .capabilities => |v| blk: {
            if (v.values.count > 16) return error.InvalidSize;
            try w.write(u32, @intFromBool(v.reply));
            for (v.values.words[0..v.values.count]) |word| try w.write(u32, word);
            break :blk 6;
        },
        .grab => |v| blk: {
            if (v.count == 0 or v.count > 64) return error.InvalidSize;
            for (v.values[0..v.count]) |value| try w.write(u32, value);
            break :blk 7;
        },
        .request => |v| blk: {
            try w.write(u32, v);
            break :blk 8;
        },
        .data => |v| blk: {
            try w.write(u32, v.kind);
            try w.append(v.bytes);
            break :blk 4;
        },
        .release => 9,
    };
    return message(a, kind, &w, opaque_id);
}
pub const FileResult = enum(u32) { can_send = 0, cancelled = 1, failed = 2, success = 3, no_space = 4, locked = 5, disconnected = 6, disabled = 7 };
pub const FileDetail = union(enum) { glib_io: u32, free_space: u64 };
pub const FileStatus = struct { id: u32, result: FileResult, detail: ?FileDetail = null };
pub const FileCommand = union(enum) { start: struct { id: u32, metadata: []const u8 }, status: FileStatus, data: struct { id: u32, bytes: []const u8 } };
pub const FileLimits = struct { metadata: usize = 4096, chunk: usize = 16000 };
pub fn decodeFile(protocol: u32, kind: u32, bytes: []const u8, limits: FileLimits) !?FileCommand {
    if (protocol != 1) return null;
    var r = try wire.Reader.init(bytes, 0);
    switch (kind) {
        10 => {
            const id = try r.read(u32);
            if (r.remaining() == 0 or r.remaining() > @max(1, limits.metadata)) return error.InvalidSize;
            return .{ .start = .{ .id = id, .metadata = try r.take(r.remaining()) } };
        },
        11 => {
            const id = try r.read(u32);
            const result = std.enums.fromInt(FileResult, try r.read(u32)) orelse return error.InvalidEnum;
            var detail: ?FileDetail = null;
            if (r.remaining() != 0) switch (result) {
                .failed => {
                    if (try r.read(u8) != 0) return error.InvalidEnum;
                    detail = .{ .glib_io = try r.read(u32) };
                },
                .no_space => detail = .{ .free_space = try r.read(u64) },
                else => {},
            };
            try r.finish();
            return .{ .status = .{ .id = id, .result = result, .detail = detail } };
        },
        12 => {
            const id = try r.read(u32);
            const size = try r.read(u64);
            if (size > @max(1, limits.chunk) or size != r.remaining()) return error.InvalidSize;
            return .{ .data = .{ .id = id, .bytes = try r.take(@intCast(size)) } };
        },
        else => return null,
    }
}
// Foundation's CharacterSet.whitespacesAndNewlines uses this same system set.
// Keep Unicode basename policy aligned with the host rather than an ASCII trim.
extern "c" fn CFCharacterSetGetPredefined(isize) *const anyopaque;
extern "c" fn CFCharacterSetIsLongCharacterMember(*const anyopaque, u32) u8;
fn validateName(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.UnsafeBasename;
    var it = (std.unicode.Utf8View.init(name) catch return error.InvalidUTF8).iterator();
    var first: ?u21 = null;
    var last: u21 = 0;
    while (it.nextCodepoint()) |scalar| {
        if (scalar < 0x20 or scalar == 0x7f or scalar == '/' or scalar == '\\') return error.UnsafeBasename;
        if (first == null) first = scalar;
        last = scalar;
    }
    const whitespace = CFCharacterSetGetPredefined(3);
    if (CFCharacterSetIsLongCharacterMember(whitespace, first.?) != 0 or CFCharacterSetIsLongCharacterMember(whitespace, last) != 0) return error.UnsafeBasename;
}
pub fn encodeFileStart(a: std.mem.Allocator, id: u32, name: []const u8, size: u64, limits: FileLimits) !agent.Message {
    // Reject huge input before Unicode traversal or allocation.
    if (name.len > @max(1, limits.metadata)) return error.MessageTooLarge;
    try validateName(name);
    var metadata: wire.Writer = .{ .allocator = a, .limit = @max(1, limits.metadata) };
    defer metadata.deinit();
    try metadata.append("[vdagent-file-xfer]\nname=");
    try metadata.append(name);
    try metadata.append("\nsize=");
    var digits: [20]u8 = undefined;
    try metadata.append(try std.fmt.bufPrint(&digits, "{d}", .{size}));
    try metadata.append("\n\x00");
    var w: wire.Writer = .{ .allocator = a, .limit = try std.math.add(usize, metadata.bytes.items.len, 4) };
    defer w.deinit();
    try w.write(u32, id);
    try w.append(metadata.bytes.items);
    return message(a, 10, &w, 0);
}
pub fn encodeFileStatus(a: std.mem.Allocator, id: u32, result: FileResult) !agent.Message {
    var w: wire.Writer = .{ .allocator = a, .limit = 8 };
    defer w.deinit();
    try w.write(u32, id);
    try w.write(u32, @backingInt(result));
    return message(a, 11, &w, 0);
}
pub fn encodeFileData(a: std.mem.Allocator, id: u32, bytes: []const u8, limits: FileLimits) !agent.Message {
    if (bytes.len > @max(1, limits.chunk)) return error.MessageTooLarge;
    var w: wire.Writer = .{ .allocator = a, .limit = try std.math.add(usize, bytes.len, 12) };
    defer w.deinit();
    try w.write(u32, id);
    try w.write(u64, bytes.len);
    try w.append(bytes);
    return message(a, 12, &w, 0);
}
pub const Monitor = struct { width: u32, height: u32, depth: u32, x: i32 = 0, y: i32 = 0 };
pub fn encodeMonitors(a: std.mem.Allocator, monitors: []const Monitor, positions: bool, sparse: bool) !agent.Message {
    if (monitors.len == 0 or monitors.len > 256) return error.InvalidSize;
    for (monitors) |m| if (!(m.width > 0 and m.height > 0) and !(sparse and m.width == 0 and m.height == 0)) return error.InvalidSize;
    var w: wire.Writer = .{ .allocator = a, .limit = 8 + 20 * monitors.len };
    defer w.deinit();
    try w.write(u32, @intCast(monitors.len));
    try w.write(u32, @intFromBool(positions));
    for (monitors) |m| {
        try w.write(u32, m.height);
        try w.write(u32, m.width);
        try w.write(u32, m.depth);
        try w.write(i32, m.x);
        try w.write(i32, m.y);
    }
    return message(a, 2, &w, 0);
}
pub fn decodeMonitorReply(protocol: u32, kind: u32, bytes: []const u8) !?bool {
    if (protocol != 1 or kind != 3) return null;
    var r = try wire.Reader.init(bytes, 0);
    const replied = try r.read(u32);
    const status = try r.read(u32);
    try r.finish();
    if (replied != 2) return null;
    return switch (status) {
        1 => true,
        2 => false,
        else => error.InvalidEnum,
    };
}
