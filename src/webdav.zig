//! Port/VMC multiplexing only. Filesystem access and HTTP serving are separate.
//! Incomplete headers/bodies survive handoff. Complete pending mux frames drain
//! before another physical message, matching the Swift channel's event ordering.
const std = @import("std");
const wire = @import("bytes.zig");
const sync = @import("sync.zig");
const vmc = @import("vmc.zig");
pub const PortEvent = enum(u8) { opened = 0, closed = 1, break_signal = 2 };
pub fn portEvent(bytes: []const u8) !PortEvent {
    var r = try wire.Reader.init(bytes, 0);
    const event = std.enums.fromInt(PortEvent, try r.read(u8)) orelse return error.InvalidEnum;
    try r.finish();
    return event;
}
pub fn portInit(bytes: []const u8) !struct { name: []const u8, opened: bool } {
    var r = try wire.Reader.init(bytes, 0);
    const size = try r.read(u32);
    const offset = try r.read(u32);
    const opened = try r.read(u8);
    if (size < 2 or size > 4096) return error.InvalidSize;
    if (offset != r.offset) return error.InvalidOffset;
    if (opened > 1) return error.InvalidEnum;
    const name = try r.take(size);
    try r.finish();
    if (name[name.len - 1] != 0 or std.mem.indexOfScalar(u8, name[0 .. name.len - 1], 0) != null or !std.unicode.utf8ValidateSlice(name[0 .. name.len - 1])) return error.InvalidPortName;
    return .{ .name = name[0 .. name.len - 1], .opened = opened == 1 };
}
pub const Event = union(enum) {
    initialized: struct { name: wire.Slice, opened: bool },
    port: PortEvent,
    request: struct { client: i64, data: wire.Slice },
    closed: i64,
    pub fn deinit(self: Event) void {
        switch (self) {
            .initialized => |v| v.name.release(),
            .request => |v| v.data.release(),
            else => {},
        }
    }
    pub fn weight(self: Event) usize {
        return switch (self) {
            .initialized => |v| v.name.retainedBytes(),
            .request => |v| v.data.retainedBytes(),
            else => 0,
        };
    }
};
pub const State = struct {
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    name: ?wire.Slice = null,
    opened: bool = false,
    buffer: std.ArrayList(u8) = .empty,
    offset: usize = 0,
    pub fn init(a: std.mem.Allocator) State {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *State) void {
        if (self.name) |name| name.release();
        self.buffer.deinit(self.allocator);
        self.mutex.deinit();
    }
    pub fn next(self: *State) !?Event {
        const bytes = self.buffer.items[self.offset..];
        if (bytes.len < 10) return null;
        const client = std.mem.readInt(i64, bytes[0..8], .little);
        const size = std.mem.readInt(u16, bytes[8..10], .little);
        if (bytes.len - 10 < size) return null;
        const event: Event = if (size == 0) .{ .closed = client } else .{ .request = .{ .client = client, .data = try wire.Slice.copy(self.allocator, bytes[10..][0..size]) } };
        self.offset += 10 + @as(usize, size);
        if (self.offset == self.buffer.items.len) {
            self.buffer.clearRetainingCapacity();
            self.offset = 0;
        }
        return event;
    }
    pub fn handle(self: *State, kind: u16, bytes: []const u8) !?Event {
        switch (kind) {
            101 => {
                self.mutex.lock();
                const available = self.name != null and self.opened;
                self.mutex.unlock();
                if (!available) return error.PortClosed;
                try vmc.validate(bytes);
                const remaining = self.buffer.items.len - self.offset;
                if (bytes.len > 1024 * 1024 - remaining) return error.MessageTooLarge;
                if (self.offset != 0) {
                    std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[self.offset..]);
                    self.buffer.items.len = remaining;
                    self.offset = 0;
                }
                try self.buffer.appendSlice(self.allocator, bytes);
                return self.next();
            },
            102 => return error.UnnegotiatedCompression,
            201 => {
                const value = try portInit(bytes);
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.name != null) return error.DuplicatePortInit;
                const name = try wire.Slice.copy(self.allocator, value.name);
                self.name = name;
                self.opened = value.opened;
                return .{ .initialized = .{ .name = name.clone(), .opened = value.opened } };
            },
            202 => {
                const event = try portEvent(bytes);
                self.mutex.lock();
                defer self.mutex.unlock();
                switch (event) {
                    .opened => self.opened = true,
                    .closed => self.opened = false,
                    .break_signal => {},
                }
                return .{ .port = event };
            },
            else => return error.UnsupportedMessage,
        }
    }
    pub fn send(self: *State, connection: anytype, client: i64, bytes: []const u8) !void {
        self.mutex.lock();
        const available = self.name != null and self.opened;
        self.mutex.unlock();
        if (!available) return error.PortClosed;
        if (bytes.len > 65535) return error.MessageTooLarge;
        var output: wire.Writer = .{ .allocator = self.allocator, .limit = 65545 };
        defer output.deinit();
        try output.write(i64, client);
        try output.write(u16, @intCast(bytes.len));
        try output.append(bytes);
        try connection.send(101, output.bytes.items);
    }
};
