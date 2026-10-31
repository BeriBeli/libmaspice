//! Cancellation registrations borrow stack-owned wait state. Register BEFORE
//! locking a wait's mutex; unregister AFTER unlocking it. cancel calls callbacks
//! under this token's mutex, so callback contexts remain live until unregister.
const std = @import("std");
const sync = @import("sync.zig");
pub const Registration = struct { next: ?*Registration = null, context: *anyopaque, wake: *const fn (*anyopaque) void };
pub const Token = struct {
    mutex: sync.Mutex = .{},
    cancelled: std.atomic.Value(bool) = .init(false),
    head: ?*Registration = null,
    pub fn check(self: *Token) !void {
        if (self.cancelled.load(.acquire)) return error.Cancelled;
    }
    pub fn register(self: *Token, registration: *Registration) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        registration.next = self.head;
        self.head = registration;
        if (self.cancelled.load(.acquire)) registration.wake(registration.context);
    }
    pub fn unregister(self: *Token, registration: *Registration) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var slot = &self.head;
        while (slot.*) |current| {
            if (current == registration) {
                slot.* = current.next;
                return;
            }
            slot = &current.next;
        }
        unreachable;
    }
    pub fn cancel(self: *Token) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cancelled.swap(true, .acq_rel)) return;
        var current = self.head;
        while (current) |registration| : (current = registration.next) registration.wake(registration.context);
    }
    pub fn deinit(self: *Token) void {
        std.debug.assert(self.head == null);
        self.mutex.deinit();
    }
};
