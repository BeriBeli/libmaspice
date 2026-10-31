//! Ordered bounded VSC control operations. A result retires exactly one request;
//! immutable APDU/capability events can outlive the channel. No host reader is
//! selected or opened by this protocol service.
const std = @import("std");
const wire = @import("bytes.zig");
const card = @import("smartcard_wire.zig");
const sync = @import("sync.zig");
pub const Event = union(enum) {
    initialized: struct { version: u32, capabilities: wire.Slice },
    completed: struct { request: card.Kind, reader: u32, code: u32 },
    apdu: struct { reader: u32, data: wire.Slice },
    flush: u32,
    pub fn deinit(self: Event) void {
        switch (self) {
            .initialized => |v| v.capabilities.release(),
            .apdu => |v| v.data.release(),
            else => {},
        }
    }
    pub fn weight(self: Event) usize {
        return switch (self) {
            .initialized => |v| v.capabilities.retainedBytes(),
            .apdu => |v| v.data.retainedBytes(),
            else => 0,
        };
    }
};
const Pending = struct { kind: card.Kind, body: wire.Slice };
pub const State = struct {
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    pending: [64]?Pending = @splat(null),
    head: usize = 0,
    count: usize = 0,
    in_flight: ?card.Kind = null,
    pub fn init(a: std.mem.Allocator) State {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *State) void {
        for (self.pending) |entry| if (entry) |v| v.body.release();
        self.mutex.deinit();
    }
    // The lock orders queued control effects with server results. Cancellation
    // closes the socket without this lock, unblocking any bounded control write.
    pub fn send(self: *State, connection: anytype, message: card.Message) !void {
        const queued = switch (message.kind) {
            .reader_add, .reader_remove, .atr, .card_remove => true,
            .apdu, .result, .flush_complete => false,
            else => return error.ServerOnlyMessage,
        };
        const body = try card.encode(self.allocator, message);
        var owned = true;
        defer if (owned) body.release();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!queued) {
            try connection.send(101, body.bytes());
            return;
        }
        if (self.count + @as(usize, @intFromBool(self.in_flight != null)) >= 64) return error.SmartcardQueueFull;
        // Queue ownership is committed before draining; failure leaves it owned
        // by this state while the terminal connection is torn down.
        self.pending[(self.head + self.count) % 64] = .{ .kind = message.kind, .body = body };
        self.count += 1;
        owned = false;
        self.drain(connection) catch |err| {
            connection.cancel();
            return err;
        };
    }
    fn drain(self: *State, connection: anytype) !void {
        if (self.in_flight != null or self.count == 0) return;
        const next = self.pending[self.head].?;
        self.pending[self.head] = null;
        self.head = (self.head + 1) % 64;
        self.count -= 1;
        defer next.body.release();
        self.in_flight = next.kind;
        try connection.send(101, next.body.bytes());
    }
    pub fn apply(self: *State, connection: anytype, message: card.Message) !Event {
        try card.validate(message);
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (message.kind) {
            .initialize => blk: {
                const v = try card.initialization(message);
                if (v.version != 2) return error.UnsupportedSmartcardVersion;
                break :blk .{ .initialized = .{ .version = v.version, .capabilities = try wire.Slice.copy(self.allocator, v.capabilities) } };
            },
            .result => blk: {
                const request = self.in_flight orelse return error.UnsolicitedSmartcardResult;
                const code = std.mem.readInt(u32, message.bytes[0..4], .little);
                self.in_flight = null;
                self.drain(connection) catch |err| {
                    connection.cancel();
                    return err;
                };
                break :blk .{ .completed = .{ .request = request, .reader = message.reader, .code = code } };
            },
            .apdu => blk: {
                if (message.reader == card.undefined_reader) return error.UndefinedReader;
                break :blk .{ .apdu = .{ .reader = message.reader, .data = try wire.Slice.copy(self.allocator, message.bytes) } };
            },
            .flush => blk: {
                if (message.reader == card.undefined_reader) return error.UndefinedReader;
                break :blk .{ .flush = message.reader };
            },
            else => error.ClientOnlyMessage,
        };
    }
};
