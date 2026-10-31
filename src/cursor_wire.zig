//! Borrowed cursor wire commands. All payload sizes match the existing Swift
//! contract, including row-padded mono/color4 and unsupported color8/color24.
const wire = @import("bytes.zig");
pub const Position = struct { x: i16 = 0, y: i16 = 0 };
pub const Header = struct { unique: u64, kind: u8, width: u16, height: u16, hot_x: u16, hot_y: u16 };
pub const Payload = struct { flags: u16, header: ?Header = null, data: []const u8 = &.{} };
pub const Shape = struct { position: Position, visible: bool, payload: Payload };
pub const Trail = struct { length: u16, frequency: u16 };
pub const Command = union(enum) {
    initialize: struct { shape: Shape, trail: Trail },
    reset,
    set: Shape,
    move: Position,
    hide,
    trail: Trail,
    invalidate_one: u64,
    invalidate_all,
};
pub fn decode(id: u16, bytes: []const u8) !Command {
    var r = try wire.Reader.init(bytes, 0);
    const command: Command = switch (id) {
        101 => blk: {
            const p = try position(&r);
            const t = try trail(&r);
            break :blk .{ .initialize = .{ .shape = .{ .position = p, .visible = try boolean(&r), .payload = try payload(&r) }, .trail = t } };
        },
        102 => .reset,
        103 => .{ .set = .{ .position = try position(&r), .visible = try boolean(&r), .payload = try payload(&r) } },
        104 => .{ .move = try position(&r) },
        105 => .hide,
        106 => .{ .trail = try trail(&r) },
        107 => .{ .invalidate_one = try r.read(u64) },
        108 => .invalidate_all,
        else => return error.UnsupportedMessage,
    };
    try r.finish();
    return command;
}
fn position(r: *wire.Reader) !Position {
    return .{ .x = try r.read(i16), .y = try r.read(i16) };
}
fn trail(r: *wire.Reader) !Trail {
    return .{ .length = try r.read(u16), .frequency = try r.read(u16) };
}
fn boolean(r: *wire.Reader) !bool {
    return switch (try r.read(u8)) {
        0 => false,
        1 => true,
        else => error.InvalidEnum,
    };
}
pub fn dataSize(kind: u8, width: usize, height: usize) !usize {
    if (width == 0 or height == 0 or width > 1024 or height > 1024) return error.InvalidSize;
    const pixels = width * height;
    const mask = (pixels + 7) / 8;
    return switch (kind) {
        0 => pixels * 4,
        1 => ((width + 7) / 8) * height * 2,
        2 => ((width + 1) / 2) * height + 64 + mask,
        4 => pixels * 2 + mask,
        6 => pixels * 4 + mask,
        3, 5 => error.UnsupportedFormat,
        else => error.InvalidEnum,
    };
}
fn payload(r: *wire.Reader) !Payload {
    const flags = try r.read(u16);
    if (flags & ~@as(u16, 7) != 0) return error.InvalidEnum;
    if (flags & 1 != 0) {
        try r.finish();
        return .{ .flags = flags };
    }
    const h: Header = .{ .unique = try r.read(u64), .kind = try r.read(u8), .width = try r.read(u16), .height = try r.read(u16), .hot_x = try r.read(u16), .hot_y = try r.read(u16) };
    if (h.kind > 6) return error.InvalidEnum;
    if (h.width == 0 or h.height == 0 or h.width > 1024 or h.height > 1024 or h.hot_x > h.width or h.hot_y > h.height) return error.InvalidSize;
    const bytes = try r.take(r.remaining());
    if (bytes.len > 4 * 1024 * 1024) return error.MessageTooLarge;
    if (flags & 4 != 0) {
        if (bytes.len != 0) return error.TrailingBytes;
    } else if (bytes.len != try dataSize(h.kind, h.width, h.height)) return error.InvalidSize;
    return .{ .flags = flags, .header = h, .data = bytes };
}
