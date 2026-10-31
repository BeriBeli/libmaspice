//! PC XT input encoding and server events. Sends serialize button transitions
//! through the actual write; the supervisor lease pins state across migration.
const std = @import("std");
const sync = @import("sync.zig");
const p = @import("generated.zig");
pub const Button = enum(u8) { left = 1, middle = 2, right = 3, scroll_up = 4, scroll_down = 5, side = 6, extra = 7 };
pub const Input = union(enum) { key_down: u32, key_up: u32, lock_modifiers: u16, motion: struct { dx: i32, dy: i32 }, position: struct { x: u32, y: u32, display_id: u8 }, press: Button, release: Button };
pub const Event = union(enum) { initialized: u16, modifiers: u16, motion_ack };
pub fn decode(id: u16, bytes: []const u8) !?Event {
    return switch (id) {
        101 => .{ .initialized = (try p.SpiceMsgInputsInit.decodeExact(bytes)).keyboardModifiers },
        102 => .{ .modifiers = (try p.SpiceMsgInputsKeyModifiers.decodeExact(bytes)).modifiers },
        111 => blk: {
            _ = try p.SpiceMsgInputsMouseMotionAck.decodeExact(bytes);
            break :blk .motion_ack;
        },
        else => null,
    };
}
pub fn scanCode(code: u32, release: bool) !u32 {
    if (code == 0 or code > 0x37f) return error.InvalidScanCode;
    const value = code | @as(u32, if (release) 0x80 else 0);
    if (value < 0x100) return value;
    return @byteSwap(@as(u16, 0xe000) | @as(u16, @intCast(value - 0x100)));
}
pub const Packet = struct { kind: u16, bytes: [11]u8 = undefined, length: usize };
pub fn encode(event: Input, buttons: *u16) !Packet {
    var result: Packet = .{ .kind = undefined, .length = undefined };
    switch (event) {
        .key_down, .key_up => |code| {
            result.kind = if (event == .key_up) 102 else 101;
            result.length = 4;
            std.mem.writeInt(u32, result.bytes[0..4], try scanCode(code, event == .key_up), .little);
        },
        .lock_modifiers => |mods| {
            result.kind = 103;
            result.length = 2;
            std.mem.writeInt(u16, result.bytes[0..2], mods, .little);
        },
        .motion => |m| {
            result.kind = 111;
            result.length = 10;
            std.mem.writeInt(i32, result.bytes[0..4], m.dx, .little);
            std.mem.writeInt(i32, result.bytes[4..8], m.dy, .little);
            std.mem.writeInt(u16, result.bytes[8..10], buttons.*, .little);
        },
        .position => |pos| {
            result.kind = 112;
            result.length = 11;
            std.mem.writeInt(u32, result.bytes[0..4], pos.x, .little);
            std.mem.writeInt(u32, result.bytes[4..8], pos.y, .little);
            std.mem.writeInt(u16, result.bytes[8..10], buttons.*, .little);
            result.bytes[10] = pos.display_id;
        },
        .press, .release => |button| {
            const mask = @as(u16, 1) << @as(u4, @intCast(@backingInt(button) - 1));
            if (event == .press) buttons.* |= mask else buttons.* &= ~mask;
            result.kind = if (event == .press) 113 else 114;
            result.length = 3;
            result.bytes[0] = @backingInt(button);
            std.mem.writeInt(u16, result.bytes[1..3], buttons.*, .little);
        },
    }
    return result;
}
pub const State = struct {
    mutex: sync.Mutex = .{},
    buttons: u16 = 0,
    keyboard_modifiers: std.atomic.Value(u16) = .init(0),
    pub fn deinit(self: *State) void {
        self.mutex.deinit();
    }
    pub fn receive(self: *State, id: u16, bytes: []const u8) !?Event {
        const event = try decode(id, bytes);
        if (event) |v| switch (v) {
            .initialized, .modifiers => |mods| self.keyboard_modifiers.store(mods, .release),
            .motion_ack => {},
        };
        return event;
    }
    pub fn send(self: *State, connection: anytype, input: Input) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const packet = try encode(input, &self.buttons);
        try connection.send(packet.kind, packet.bytes[0..packet.length]);
    }
};
