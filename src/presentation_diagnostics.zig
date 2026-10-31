//! Stable-address recorder shared by desktop hosts and asynchronous GPU callbacks.
//! Reset fences callbacks from the previous desktop epoch. No pixel/input content
//! is retained. Caller joins all users before deinit.
const sync = @import("sync.zig");
const timing = @import("timing.zig");
pub const Counter = enum { metal_presented, advanced_video_presented, metal_errors, frames_superseded, drawable_misses, command_creation_failures, command_buffers_committed, texture_cache_hits, texture_cache_misses, texture_cache_evictions, gpu_busy_skips, display_link_wakeups, display_link_ticks, display_link_idle_pauses, immediate_selections };
pub const Latency = enum { ready_to_selection, view_update_to_commit, commit_to_completion, request_to_presented };
pub const Fallback = enum { metal_unavailable, missing_iosurface, iosurface_dimension_mismatch, pixel_format_mismatch, texture_creation_failed, metal_command_failure };
pub const Metrics = struct {
    counters: [@typeInfo(Counter).@"enum".field_names.len]u64 = @splat(0),
    histograms: [@typeInfo(Latency).@"enum".field_names.len]timing.Histogram = @splat(.{}),
    fallback_frames: u64 = 0,
    fallback_counts: [@typeInfo(Fallback).@"enum".field_names.len]u64 = @splat(0),
    last_fallback: ?Fallback = null,
    pub fn count(self: Metrics, counter: Counter) u64 {
        return self.counters[@backingInt(counter)];
    }
    pub fn latency(self: Metrics, kind: Latency) timing.Summary {
        return self.histograms[@backingInt(kind)].summary();
    }
};
pub const Recorder = struct {
    mutex: sync.Mutex = .{},
    metrics: Metrics = .{},
    epoch: u64 = 0,
    pub fn deinit(self: *Recorder) void {
        self.mutex.deinit();
    }
    pub fn currentEpoch(self: *Recorder) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.epoch;
    }
    pub fn snapshot(self: *Recorder) Metrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.metrics;
    }
    pub fn reset(self: *Recorder) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.epoch +%= 1;
        self.metrics = .{};
    }
    pub fn add(self: *Recorder, counter: Counter, amount: u64, epoch: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (epoch != null and epoch.? != self.epoch) return;
        self.metrics.counters[@backingInt(counter)] +%= amount;
    }
    pub fn presented(self: *Recorder, advanced: bool, epoch: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (epoch != null and epoch.? != self.epoch) return;
        self.metrics.counters[@backingInt(Counter.metal_presented)] +%= 1;
        if (advanced) self.metrics.counters[@backingInt(Counter.advanced_video_presented)] +%= 1;
    }
    pub fn record(self: *Recorder, kind: Latency, milliseconds: f64, epoch: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (epoch != null and epoch.? != self.epoch) return;
        self.metrics.histograms[@backingInt(kind)].record(milliseconds);
    }
    pub fn interval(self: *Recorder, kind: Latency, start_ns: u64, end_ns: u64, epoch: ?u64) void {
        self.record(kind, @as(f64, @floatFromInt(end_ns -| start_ns)) / 1_000_000, epoch);
    }
    pub fn fallback(self: *Recorder, reason: Fallback) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.metrics.fallback_frames +%= 1;
        self.metrics.fallback_counts[@backingInt(reason)] +%= 1;
        self.metrics.last_fallback = reason;
    }
};
