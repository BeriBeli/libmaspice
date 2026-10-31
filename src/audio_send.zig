//! Per-write cancellation borrows a pinned connection. A cancelled in-flight
//! write cannot be retried safely, so its transport is closed. An already
//! cancelled operation never enters the connection or closes an idle channel.
const cancellation = @import("cancel.zig");
const sync = @import("sync.zig");
pub fn Cancellable(comptime Connection: type) type {
    return struct {
        const Self = @This();
        connection: *Connection,
        token: *cancellation.Token,
        const Pending = struct {
            connection: *Connection,
            mutex: sync.Mutex = .{},
            active: bool = false,
            cancelled: bool = false,
            fn wake(raw: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(raw));
                self.mutex.lock();
                defer self.mutex.unlock();
                self.cancelled = true;
                if (self.active) self.connection.cancel();
            }
        };
        pub fn send(self: *Self, kind: u16, bytes: []const u8) !void {
            try self.token.check();
            var pending: Pending = .{ .connection = self.connection };
            defer pending.mutex.deinit();
            var registration: cancellation.Registration = .{ .context = &pending, .wake = Pending.wake };
            self.token.register(&registration);
            defer self.token.unregister(&registration);
            pending.mutex.lock();
            if (pending.cancelled) {
                pending.mutex.unlock();
                return error.Cancelled;
            }
            pending.active = true;
            pending.mutex.unlock();
            defer {
                pending.mutex.lock();
                pending.active = false;
                pending.mutex.unlock();
            }
            try self.connection.send(kind, bytes);
            try self.token.check();
        }
        pub fn cancel(self: *Self) void {
            self.connection.cancel();
        }
    };
}
