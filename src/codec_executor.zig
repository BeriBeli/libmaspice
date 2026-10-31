//! FIFO admission for caller-owned codec workers, matching the shared Swift
//! executor's two active/64 pending/256 MiB queued defaults. No detached tasks.
const std = @import("std");
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
pub const Limits = struct { active: usize = 2, pending: usize = 64, queued_bytes: usize = 256 * 1024 * 1024 };
pub const Executor = struct {
    const Waiter = struct { next: ?*Waiter = null };
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    limits: Limits = .{},
    closed: bool = false,
    active: usize = 0,
    pending: usize = 0,
    queued_bytes: usize = 0,
    head: ?*Waiter = null,
    tail: ?*Waiter = null,
    fn wake(p: *anyopaque) void {
        const self: *Executor = @ptrCast(@alignCast(p));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.changed.broadcast();
    }
    pub fn acquire(self: *Executor, bytes: usize, token: *cancel.Token) !void {
        var registration: cancel.Registration = .{ .context = self, .wake = wake };
        token.register(&registration);
        defer token.unregister(&registration);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.limits.active == 0) return error.InvalidLimits;
        try token.check();
        if (self.closed) return error.Closed;
        if (self.active < self.limits.active and self.head == null) {
            self.active += 1;
            return;
        }
        if (self.pending >= self.limits.pending) return error.TooManyPendingJobs;
        if (bytes > self.limits.queued_bytes - self.queued_bytes) return error.QueuedRetainedBytesExceeded;
        var waiter: Waiter = .{};
        if (self.tail) |tail| tail.next = &waiter else self.head = &waiter;
        self.tail = &waiter;
        self.pending += 1;
        self.queued_bytes += bytes;
        defer {
            self.remove(&waiter);
            self.pending -= 1;
            self.queued_bytes -= bytes;
            self.changed.broadcast();
        }
        while (true) {
            try token.check();
            if (self.closed) return error.Closed;
            if (self.head == &waiter and self.active < self.limits.active) {
                self.active += 1;
                return;
            }
            self.changed.wait(&self.mutex);
        }
    }
    fn remove(self: *Executor, waiter: *Waiter) void {
        var previous: ?*Waiter = null;
        var slot = &self.head;
        while (slot.*) |item| {
            if (item == waiter) {
                slot.* = item.next;
                if (self.tail == item) self.tail = previous;
                return;
            }
            previous = item;
            slot = &item.next;
        }
        unreachable;
    }
    pub fn finish(self: *Executor) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.active > 0);
        self.active -= 1;
        self.changed.broadcast();
    }
    pub fn close(self: *Executor) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.changed.broadcast();
    }
    pub fn deinit(self: *Executor) void {
        std.debug.assert(self.active == 0 and self.pending == 0);
        self.changed.deinit();
        self.mutex.deinit();
    }
};
