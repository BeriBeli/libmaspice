//! Session multimedia clock on Mach continuous time (including system sleep).
//! Waiters re-evaluate on clock resets/playback synchronization and cancellation.
const std = @import("std");
const sync = @import("sync.zig");
extern "c" fn pthread_cond_timedwait_relative_np(*std.c.pthread_cond_t, *std.c.pthread_mutex_t, *const std.c.timespec) std.c.E;
/// Absolute Mach continuous timestamp shared by diagnostics across services.
pub fn nanoseconds(timebase: std.c.mach_timebase_info_data) u64 {
    return @intCast(@as(u128, std.c.mach_continuous_time()) * timebase.numer / timebase.denom);
}
pub const Token = struct { cancelled: bool = false };
pub fn margin(current: u32, target: u32) i32 {
    return @bitCast(target -% current);
}
pub const Clock = struct {
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    timebase: std.c.mach_timebase_info_data,
    anchor_ticks: u64,
    anchor_time: u32 = 0,
    playback_delay: ?u32 = null,
    stopped: bool = false,
    pub fn init() !Clock {
        var timebase: std.c.mach_timebase_info_data = undefined;
        if (std.c.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) return error.ClockUnavailable;
        return .{ .timebase = timebase, .anchor_ticks = std.c.mach_continuous_time() };
    }
    pub fn deinit(self: *Clock) void {
        self.changed.deinit();
        self.mutex.deinit();
    }
    fn currentLocked(self: *Clock) u32 {
        const ticks = std.c.mach_continuous_time() -| self.anchor_ticks;
        const ms = @as(u128, ticks) * self.timebase.numer / self.timebase.denom / 1_000_000;
        return self.anchor_time +% @as(u32, @truncate(ms));
    }
    pub fn current(self: *Clock) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.currentLocked();
    }
    pub fn reset(self: *Clock, time: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.anchor_ticks = std.c.mach_continuous_time();
        self.anchor_time = time;
        self.changed.broadcast();
    }
    pub fn resetCallback(ctx: *anyopaque, time: u32) void {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        self.reset(time);
    }
    pub fn synchronize(self: *Clock, time: u32, delay: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.anchor_ticks = std.c.mach_continuous_time();
        self.anchor_time = time -% delay;
        self.playback_delay = delay;
        self.changed.broadcast();
    }
    pub fn playbackDelay(self: *Clock) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.playback_delay;
    }
    pub fn stopPlayback(self: *Clock) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.playback_delay = null;
    }
    pub fn cancel(self: *Clock) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopped = true;
        self.changed.broadcast();
    }
    pub fn cancelWait(self: *Clock, token: *Token) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        token.cancelled = true;
        self.changed.broadcast();
    }
    pub fn wait(self: *Clock, target: u32, token: *Token) !i32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.stopped or token.cancelled) return error.Cancelled;
            const delay = margin(self.currentLocked(), target);
            if (delay <= 0) return delay;
            const timeout: std.c.timespec = .{ .sec = @divTrunc(delay, 1000), .nsec = @as(c_long, @rem(delay, 1000)) * 1_000_000 };
            const result = pthread_cond_timedwait_relative_np(&self.changed.value, &self.mutex.value, &timeout);
            if (result != .SUCCESS and result != .TIMEDOUT) return error.ClockUnavailable;
        }
    }
};
