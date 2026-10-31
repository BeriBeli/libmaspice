//! Bounded FIFO with explicit ownership transfer and cancellable shutdown.
//! T supplies weight() and deinit(); push takes ownership only on success.
const std = @import("std");
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
pub fn Mailbox(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        slots: []?T,
        maximum_bytes: usize,
        mutex: sync.Mutex = .{},
        changed: sync.Condition = .{},
        head: usize = 0,
        count: usize = 0,
        bytes: usize = 0,
        closed: bool = false,
        pub fn create(allocator: std.mem.Allocator, capacity: usize, maximum_bytes: usize) !*Self {
            if (capacity == 0) return error.InvalidConfiguration;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const slots = try allocator.alloc(?T, capacity);
            @memset(slots, null);
            self.* = .{ .allocator = allocator, .slots = slots, .maximum_bytes = maximum_bytes };
            return self;
        }
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.changed.broadcast();
        }
        /// Only after every external producer/consumer has joined and queued
        /// values have been drained. Keeps the bounded allocation for reuse.
        pub fn reopen(self: *Self) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.closed or self.count != 0) return error.InvalidState;
            std.debug.assert(self.bytes == 0);
            self.head = 0;
            self.closed = false;
        }
        pub fn destroy(self: *Self) void {
            for (self.slots) |slot| {
                if (slot) |value| value.deinit();
            }
            self.allocator.free(self.slots);
            self.changed.deinit();
            self.mutex.deinit();
            self.allocator.destroy(self);
        }
        fn wake(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.changed.broadcast();
        }
        pub fn push(self: *Self, value: T) !void {
            return self.pushCancellable(value, null);
        }
        pub fn pushCancellable(self: *Self, value: T, token: ?*cancel.Token) !void {
            var registration: cancel.Registration = .{ .context = self, .wake = wake };
            if (token) |t| t.register(&registration);
            defer if (token) |t| t.unregister(&registration);
            const weight = value.weight();
            if (weight > self.maximum_bytes) return error.MessageTooLarge;
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.closed and (self.count == self.slots.len or weight > self.maximum_bytes - self.bytes)) {
                if (token) |t| try t.check();
                self.changed.wait(&self.mutex);
            }
            if (self.closed) return error.Cancelled;
            if (token) |t| try t.check();
            const index = (self.head + self.count) % self.slots.len;
            self.slots[index] = value;
            self.count += 1;
            self.bytes += weight;
            self.changed.broadcast();
        }
        pub fn next(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.closed and self.count == 0) self.changed.wait(&self.mutex);
            if (self.count == 0) return null;
            const value = self.slots[self.head].?;
            self.slots[self.head] = null;
            self.head = (self.head + 1) % self.slots.len;
            self.count -= 1;
            self.bytes -= value.weight();
            self.changed.broadcast();
            return value;
        }
    };
}
