//! One blocking presentation waiter with explicit cancellation. Completion and
//! finish are remembered, including when they precede registration. No callback
//! executes under the lock; the condition only wakes a waiting owner thread.
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
const Identity = @import("interaction_trace.zig").Identity;
pub const Waiter = struct {
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    waiting: bool = false,
    finished: bool = false,
    completed: ?Identity = null,
    pub fn deinit(self: *Waiter) void {
        @import("std").debug.assert(!self.waiting);
        self.changed.deinit();
        self.mutex.deinit();
    }
    fn wake(p: *anyopaque) void {
        const self: *Waiter = @ptrCast(@alignCast(p));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.changed.broadcast();
    }
    pub fn wait(self: *Waiter, token: *cancel.Token) !Identity {
        var registration: cancel.Registration = .{ .context = self, .wake = wake };
        token.register(&registration);
        defer token.unregister(&registration);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.completed) |id| return id;
        if (self.finished) return error.CaptureAlreadyFinished;
        if (self.waiting) return error.PresentationWaitAlreadyRegistered;
        self.waiting = true;
        defer self.waiting = false;
        while (true) {
            if (self.completed) |id| return id;
            if (self.finished) return error.CaptureAlreadyFinished;
            try token.check();
            self.changed.wait(&self.mutex);
        }
    }
    pub fn complete(self: *Waiter, identity: Identity) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.finished or self.completed != null) return;
        self.completed = identity;
        self.changed.broadcast();
    }
    pub fn finish(self: *Waiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.completed != null) return;
        self.finished = true;
        self.changed.broadcast();
    }
};
