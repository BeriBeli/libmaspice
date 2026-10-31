//! Borrowed bounded RAW audio wire commands; codec negotiation and stream
//! lifecycle are enforced by audio.zig, separately from wire acceptance.
const wire = @import("bytes.zig");
pub const maximum_packet = 256 * 1024;
pub const Configuration = struct { channels: u32, frequency: u32 };
pub const Start = struct { configuration: Configuration, time: u32 = 0, epoch: u64 = 0 };
pub const Packet = struct { time: u32, bytes: []const u8 };
pub const Volume = struct { count: u8, values: [32]u16 = undefined };
pub const Command = union(enum) { packet: Packet, mode: struct { time: u32, kind: u16, bytes: []const u8 }, start: Start, stop, volume: Volume, mute: bool, latency: u32 };
fn start(r: *wire.Reader) !Configuration {
    const channels = try r.read(u32);
    if (try r.read(u16) != 1) return error.UnsupportedFormat;
    return .{ .channels = channels, .frequency = try r.read(u32) };
}
fn volume(r: *wire.Reader) !Volume {
    const count = try r.read(u8);
    if (count == 0 or count > 32 or r.remaining() != @as(usize, count) * 2) return error.InvalidSize;
    var result: Volume = .{ .count = count };
    for (result.values[0..count]) |*v| v.* = try r.read(u16);
    return result;
}
fn mute(r: *wire.Reader) !bool {
    return switch (try r.read(u8)) {
        0 => false,
        1 => true,
        else => error.InvalidEnum,
    };
}
pub fn playback(id: u16, bytes: []const u8) !Command {
    var r = try wire.Reader.init(bytes, 0);
    const command: Command = switch (id) {
        101 => blk: {
            const time = try r.read(u32);
            if (r.remaining() == 0 or r.remaining() > maximum_packet) return error.InvalidSize;
            break :blk .{ .packet = .{ .time = time, .bytes = try r.take(r.remaining()) } };
        },
        102 => blk: {
            const time = try r.read(u32);
            const kind = try r.read(u16);
            if (kind < 1 or kind > 3) return error.InvalidEnum;
            if (r.remaining() > 64 * 1024) return error.MessageTooLarge;
            break :blk .{ .mode = .{ .time = time, .kind = kind, .bytes = try r.take(r.remaining()) } };
        },
        103 => .{ .start = .{ .configuration = try start(&r), .time = try r.read(u32) } },
        104 => .stop,
        105 => .{ .volume = try volume(&r) },
        106 => .{ .mute = try mute(&r) },
        107 => .{ .latency = try r.read(u32) },
        else => return error.UnsupportedMessage,
    };
    try r.finish();
    return command;
}
pub fn record(id: u16, bytes: []const u8) !Command {
    var r = try wire.Reader.init(bytes, 0);
    const command: Command = switch (id) {
        101 => .{ .start = .{ .configuration = try start(&r) } },
        102 => .stop,
        103 => .{ .volume = try volume(&r) },
        104 => .{ .mute = try mute(&r) },
        else => return error.UnsupportedMessage,
    };
    try r.finish();
    return command;
}
pub fn validate(config: Configuration) !void {
    if (config.channels == 0 or config.channels > 8 or config.frequency < 8000 or config.frequency > 192000) return error.InvalidAudioConfiguration;
}
pub fn validatePCM(config: Configuration, bytes: []const u8) !void {
    try validate(config);
    if (bytes.len == 0 or bytes.len > maximum_packet) return error.InvalidSize;
    if (bytes.len % (@as(usize, config.channels) * 2) != 0) return error.MisalignedPCM;
}
