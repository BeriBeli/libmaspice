//! Session-scoped completed serials. Waits do not count received-but-unhandled
//! frames. Fixed key space avoids allocation failure while terminating channels.
//! Cancel/join every waiter before destroy. A cancelled wait token is never reused.
const std = @import("std");
const sync = @import("sync.zig");
pub const Key = packed struct(u16) {
    kind: u8,
    id: u8,
    pub fn index(self: Key) u16 {
        return @bitCast(self);
    }
};
pub const Requirement = struct { key: Key, serial: u64 };
pub const Token = struct { cancelled: bool = false }; // protected by Barrier.mutex
pub const Barrier = struct {
    allocator: std.mem.Allocator,
    serials: []u64,
    terminated: std.StaticBitSet(65536) = .empty,
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    cancelled: bool = false,
    pub fn create(allocator: std.mem.Allocator) !*Barrier {
        const self = try allocator.create(Barrier);
        errdefer allocator.destroy(self);
        const serials = try allocator.alloc(u64, 65536);
        @memset(serials, 0);
        self.* = .{ .allocator = allocator, .serials = serials };
        return self;
    }
    pub fn destroy(self: *Barrier) void {
        self.changed.deinit();
        self.mutex.deinit();
        const allocator = self.allocator;
        allocator.free(self.serials);
        allocator.destroy(self);
    }
    pub fn record(self: *Barrier, key: Key, serial: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.terminated.isSet(key.index())) self.serials[key.index()] = @max(self.serials[key.index()], serial);
        self.changed.broadcast();
    }
    pub fn terminate(self: *Barrier, key: Key) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.terminated.set(key.index());
        self.changed.broadcast();
    }
    pub fn cancel(self: *Barrier, token: *Token) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        token.cancelled = true;
        self.changed.broadcast();
    }
    pub fn cancelAll(self: *Barrier) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cancelled = true;
        self.changed.broadcast();
    }
    fn checkLocked(self: *Barrier, requirements: []const Requirement) !bool {
        var satisfied = true;
        for (requirements) |r| {
            if (self.serials[r.key.index()] >= r.serial) continue;
            if (self.terminated.isSet(r.key.index())) return error.ChannelTerminated;
            satisfied = false;
        }
        return satisfied;
    }
    pub fn check(self: *Barrier, requirements: []const Requirement) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.checkLocked(requirements);
    }
    pub fn wait(self: *Barrier, requirements: []const Requirement, token: *Token) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            // A fulfilled serial remains fulfilled even when its channel closed.
            if (try self.checkLocked(requirements)) return;
            if (self.cancelled or token.cancelled) return error.Cancelled;
            self.changed.wait(&self.mutex);
        }
    }
};
