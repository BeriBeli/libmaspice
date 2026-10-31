//! Stable-address POSIX synchronization. Service send locks may serialize state
//! transitions across writes; socket cancellation must unblock those writes.
const std = @import("std");
pub const Mutex = struct {
    value: std.c.pthread_mutex_t = .{},
    pub fn lock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.value) == .SUCCESS);
    }
    pub fn unlock(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.value) == .SUCCESS);
    }
    pub fn deinit(self: *Mutex) void {
        std.debug.assert(std.c.pthread_mutex_destroy(&self.value) == .SUCCESS);
    }
};
pub const Condition = struct {
    value: std.c.pthread_cond_t = .{},
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        std.debug.assert(std.c.pthread_cond_wait(&self.value, &mutex.value) == .SUCCESS);
    }
    pub fn broadcast(self: *Condition) void {
        std.debug.assert(std.c.pthread_cond_broadcast(&self.value) == .SUCCESS);
    }
    pub fn deinit(self: *Condition) void {
        std.debug.assert(std.c.pthread_cond_destroy(&self.value) == .SUCCESS);
    }
};
