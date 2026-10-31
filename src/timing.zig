//! Bounded content-free latency histograms. Buckets and percentile rounding
//! preserve SpiceTimingHistogram; timestamps use the host continuous clock.
const std = @import("std");
pub const Summary = struct { sample_count: u64 = 0, p95_ms: ?f64 = null, maximum_ms: ?f64 = null };
pub const Histogram = struct {
    pub const upper_ms = [_]f64{ 0.25, 0.5, 1, 2, 4, 8, 12, 16, 20, 24, 33, 50, 67, 100, 150, 250, 500, 1000, 2000, 5000 };
    buckets: [upper_ms.len + 1]u64 = @splat(0),
    count: u64 = 0,
    maximum: ?f64 = null,
    pub fn record(self: *Histogram, milliseconds: f64) void {
        const ms = if (std.math.isFinite(milliseconds)) @max(0, milliseconds) else 0;
        var index: usize = 0;
        while (index < upper_ms.len and ms > upper_ms[index]) : (index += 1) {}
        self.buckets[index] +%= 1;
        self.count +%= 1;
        self.maximum = @max(self.maximum orelse ms, ms);
    }
    pub fn duration(self: *Histogram, seconds: i64, attoseconds: i64) void {
        self.record(@as(f64, @floatFromInt(seconds)) * 1000 + @as(f64, @floatFromInt(attoseconds)) / 1_000_000_000_000_000);
    }
    pub fn nanoseconds(self: *Histogram, ns: u64) void {
        self.record(@as(f64, @floatFromInt(ns)) / 1_000_000);
    }
    pub fn interval(self: *Histogram, start: u64, end: u64) void {
        self.nanoseconds(end -| start);
    }
    pub fn accumulate(self: *Histogram, other: Histogram) void {
        for (&self.buckets, other.buckets) |*b, n| b.* +%= n;
        self.count +%= other.count;
        if (other.maximum) |m| self.maximum = @max(self.maximum orelse m, m);
    }
    pub fn summary(self: Histogram) Summary {
        if (self.count == 0) return .{};
        const maximum = self.maximum orelse return .{};
        const rank: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(self.count)) * 0.95));
        var accumulated: u64 = 0;
        for (self.buckets, 0..) |n, index| {
            accumulated +%= n;
            if (accumulated >= rank) return .{ .sample_count = self.count, .maximum_ms = maximum, .p95_ms = if (index < upper_ms.len) @min(upper_ms[index], maximum) else maximum };
        }
        return .{ .sample_count = self.count, .maximum_ms = maximum, .p95_ms = maximum };
    }
};
/// Calibrate a CoreAnimation timestamp at callback time; a lifetime offset is
/// incorrect across system sleep. `now_ns` must use the same clock as frames.
pub fn mediaTimestamp(media: f64, media_now: f64, now_ns: u64) ?u64 {
    if (!std.math.isFinite(media) or !std.math.isFinite(media_now) or media <= 0 or media_now < media) return null;
    const elapsed = @round((media_now - media) * 1_000_000_000);
    if (!std.math.isFinite(elapsed) or elapsed < 0 or elapsed >= 18446744073709551616.0) return null;
    const ns: u64 = @intFromFloat(elapsed);
    if (ns > now_ns) return null;
    return now_ns - ns;
}
