//! Session-wide canonical Surface bytes. Stores borrow this stable object and
//! must release all live surfaces before their owning World destroys it.
const std = @import("std");
const sync = @import("sync.zig");
pub const Budget = struct {
    mutex: sync.Mutex = .{},
    maximum: usize = 256 * 1024 * 1024,
    used: usize = 0,
    pub fn reserve(self: *Budget, size: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (size > self.maximum - self.used) return error.SurfaceBudgetExceeded;
        self.used += size;
    }
    pub fn release(self: *Budget, size: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(size <= self.used);
        self.used -= size;
    }
    pub fn allocated(self: *Budget) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.used;
    }
    pub fn deinit(self: *Budget) void {
        std.debug.assert(self.used == 0);
        self.mutex.deinit();
    }
};
