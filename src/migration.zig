//! Main migration control codec. Strings borrow the supplied owned frame.
const std = @import("std");
const wire = @import("bytes.zig");
pub const Destination = struct { port: u16, secure_port: u16, host: []const u8, subject: ?[]const u8 };
pub const Command = union(enum) {
    begin: Destination,
    begin_seamless: struct { destination: Destination, source_version: u32 },
    cancel,
    switch_host: Destination,
    end,
    accepted,
    rejected,
};
fn string(reader: *wire.Reader, allow_empty: bool) ![]const u8 {
    const size = try reader.read(u32);
    if (size > 4096) return error.MessageTooLarge;
    if (size == 0) return if (allow_empty) "" else error.InvalidSize;
    const bytes = try reader.take(size);
    if (bytes[size - 1] != 0) return error.InvalidString;
    const value = bytes[0 .. size - 1];
    if ((!allow_empty and value.len == 0) or std.mem.indexOfScalar(u8, value, 0) != null or !std.unicode.utf8ValidateSlice(value)) return error.InvalidString;
    return value;
}
fn destination(reader: *wire.Reader) !Destination {
    const port = try reader.read(u16);
    const secure_port = try reader.read(u16);
    if (port == 0 and secure_port == 0) return error.InvalidPort;
    const host = try string(reader, false);
    const subject = try string(reader, true);
    return .{ .port = port, .secure_port = secure_port, .host = host, .subject = if (subject.len == 0) null else subject };
}
pub fn decode(kind: u16, bytes: []const u8) !?Command {
    var reader = try wire.Reader.init(bytes, 0);
    const command: Command = switch (kind) {
        101 => .{ .begin = try destination(&reader) },
        116 => .{ .begin_seamless = .{ .destination = try destination(&reader), .source_version = try reader.read(u32) } },
        111 => .{ .switch_host = try destination(&reader) },
        102 => .cancel,
        112 => .end,
        117 => .accepted,
        118 => .rejected,
        else => return null,
    };
    try reader.finish();
    return command;
}
pub const Reply = union(enum) { connected, connect_error, end, do_seamless: u32, connected_seamless };
pub fn encode(reply: Reply, writer: *wire.Writer) !u16 {
    return switch (reply) {
        .connected => 102,
        .connect_error => 103,
        .end => 109,
        .connected_seamless => 111,
        .do_seamless => |version| blk: {
            try writer.write(u32, version);
            break :blk 110;
        },
    };
}
