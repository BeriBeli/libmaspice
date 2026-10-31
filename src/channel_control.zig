//! Shared server control messages for typed child services. Completion remains
//! the caller's responsibility so LIST ACKs count physical batches only once.
const std = @import("std");
const p = @import("generated.zig");
const wire = @import("bytes.zig");
const channel = @import("channel.zig");
pub fn handle(a: std.mem.Allocator, connection: *channel.Channel, kind: u16, body: []const u8) !bool {
    switch (kind) {
        3 => {
            const ack = try p.SpiceMsgSetAck.decodeExact(body);
            connection.configureAck(ack.generation, ack.window);
            try send(a, connection, p.SpiceMsgcAckSync{ .generation = ack.generation });
        },
        4 => {
            var reader = try wire.Reader.init(body, 0);
            // Servers pad PING bodies for bandwidth measurements. Echo only
            // the defined header, as the existing Main/Swift handlers do.
            const ping = try p.SpiceMsgPing.decode(&reader);
            try send(a, connection, p.SpiceMsgcPong{ .id = ping.id, .time = ping.time });
        },
        6 => {
            _ = try p.SpiceMsgDisconnect.decodeExact(body);
            return error.ConnectionClosed;
        },
        else => return false,
    }
    return true;
}
fn send(a: std.mem.Allocator, connection: *channel.Channel, value: anytype) !void {
    var output: wire.Writer = .{ .allocator = a, .limit = 64 };
    defer output.deinit();
    try value.encode(&output);
    try connection.send(@TypeOf(value).message_id.?, output.bytes.items);
}
