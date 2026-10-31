const std = @import("std");
const wire = @import("bytes.zig");
pub const undefined_reader = std.math.maxInt(u32);
pub const maximum_payload = 64 * 1024 + 16;
pub const Kind = enum(u32) { initialize = 1, result = 2, reader_add = 3, reader_remove = 4, atr = 5, card_remove = 6, apdu = 7, flush = 8, flush_complete = 9 };
pub const Message = struct { kind: Kind, reader: u32, bytes: []const u8 = &.{} };
pub fn validate(message: Message) !void {
    const n = message.bytes.len;
    if (n > maximum_payload) return error.MessageTooLarge;
    switch (message.kind) {
        .initialize => {
            if (message.reader != undefined_reader or n < 8 or n % 4 != 0) return error.InvalidSize;
        },
        .result => {
            if (n != 4) return error.InvalidSize;
        },
        .reader_add => {
            if (message.reader != undefined_reader or n == 0 or n > 255 or std.mem.indexOfScalar(u8, message.bytes, 0) != null or !std.unicode.utf8ValidateSlice(message.bytes)) return error.InvalidReaderName;
        },
        .reader_remove, .card_remove, .flush, .flush_complete => {
            if (n != 0) return error.TrailingBytes;
        },
        .atr => {
            if (n == 0 or n > 40) return error.InvalidSize;
        },
        .apdu => {
            if (n == 0 or n > 64 * 1024 + 8) return error.InvalidSize;
        },
    }
}
pub fn decode(bytes: []const u8) !Message {
    var r = try wire.Reader.init(bytes, 0);
    const kind = std.enums.fromInt(Kind, try r.read(u32)) orelse return error.InvalidEnum;
    const reader = try r.read(u32);
    const size = try r.read(u32);
    if (size > maximum_payload) return error.MessageTooLarge;
    if (r.remaining() != size) return error.InvalidSize;
    const message: Message = .{ .kind = kind, .reader = reader, .bytes = try r.take(size) };
    try validate(message);
    return message;
}
pub fn encode(a: std.mem.Allocator, message: Message) !wire.Slice {
    try validate(message);
    var output: wire.Writer = .{ .allocator = a, .limit = maximum_payload + 12 };
    defer output.deinit();
    try output.write(u32, @backingInt(message.kind));
    try output.write(u32, message.reader);
    try output.write(u32, @intCast(message.bytes.len));
    try output.append(message.bytes);
    return wire.Slice.copy(a, output.bytes.items);
}
pub fn initialization(message: Message) !struct { version: u32, capabilities: []const u8 } {
    if (message.kind != .initialize) return error.InvalidEnum;
    try validate(message);
    var r = try wire.Reader.init(message.bytes, 0);
    if (try r.read(u32) != 0x44435356) return error.InvalidMagic;
    return .{ .version = try r.read(u32), .capabilities = try r.take(r.remaining()) };
}
