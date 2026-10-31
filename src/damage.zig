//! Allocation-free bounded damage journal. Merge only rectangular unions with
//! no added area; exact union coverage selects full redraw at half the surface.
const std = @import("std");
const Rect = @import("region.zig").Rect;
pub const Journal = struct {
    width: usize,
    height: usize,
    rectangles: [64]Rect = undefined,
    count: usize = 0,
    full: bool = false,
    pub fn init(width: usize, height: usize, full: bool) !Journal {
        if (width == 0 or height == 0 or width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return error.InvalidDimensions;
        return .{ .width = width, .height = height, .full = full };
    }
    pub fn clear(self: *Journal) void {
        self.count = 0;
        self.full = false;
    }
    pub fn markFull(self: *Journal) void {
        self.count = 0;
        self.full = true;
    }
    pub fn isEmpty(self: Journal) bool {
        return !self.full and self.count == 0;
    }
    fn contains(a: Rect, b: Rect) bool {
        return a.x <= b.x and a.y <= b.y and a.x + a.width >= b.x + b.width and a.y + a.height >= b.y + b.height;
    }
    fn lossless(a: Rect, b: Rect) ?Rect {
        if (a.y == b.y and a.height == b.height and a.x <= b.x + b.width and b.x <= a.x + a.width) {
            const x = @min(a.x, b.x);
            return .{ .x = x, .y = a.y, .width = @max(a.x + a.width, b.x + b.width) - x, .height = a.height };
        }
        if (a.x == b.x and a.width == b.width and a.y <= b.y + b.height and b.y <= a.y + a.height) {
            const y = @min(a.y, b.y);
            return .{ .x = a.x, .y = y, .width = a.width, .height = @max(a.y + a.height, b.y + b.height) - y };
        }
        return null;
    }
    fn remove(self: *Journal, index: usize) void {
        std.mem.copyForwards(Rect, self.rectangles[index .. self.count - 1], self.rectangles[index + 1 .. self.count]);
        self.count -= 1;
    }
    pub fn append(self: *Journal, rect: Rect) !void {
        try rect.validate(self.width, self.height);
        if (self.full) return;
        var merged = rect;
        var i: usize = 0;
        while (i < self.count) {
            const old = self.rectangles[i];
            if (contains(old, merged)) return;
            if (contains(merged, old)) {
                self.remove(i);
                i = 0;
                continue;
            }
            if (lossless(old, merged)) |combined| {
                merged = combined;
                self.remove(i);
                i = 0;
                continue;
            }
            i += 1;
        }
        if (self.count == 64) {
            self.markFull();
            return;
        }
        self.rectangles[self.count] = merged;
        self.count += 1;
    }
    pub fn merge(self: *Journal, other: Journal) !void {
        if (self.width != other.width or self.height != other.height) return error.InvalidDimensions;
        if (other.isFull()) {
            self.markFull();
            return;
        }
        for (other.rectangles[0..other.count]) |r| try self.append(r);
    }
    pub fn isFull(self: Journal) bool {
        if (self.full) return true;
        if (self.count == 0) return false;
        var upper: u128 = 0;
        for (self.rectangles[0..self.count]) |r| upper += @as(u128, @intCast(r.width)) * @as(u128, @intCast(r.height));
        const area = @as(u128, self.width) * self.height;
        if (upper * 2 < area) return false;
        var edges: [128]i64 = undefined;
        for (self.rectangles[0..self.count], 0..) |r, i| {
            edges[i * 2] = r.x;
            edges[i * 2 + 1] = r.x + r.width;
        }
        std.mem.sort(i64, edges[0 .. self.count * 2], {}, std.sort.asc(i64));
        const Interval = struct { lo: i64, hi: i64 };
        var intervals: [64]Interval = undefined;
        var covered: u128 = 0;
        for (0..self.count * 2 - 1) |edge| {
            const left = edges[edge];
            const right = edges[edge + 1];
            if (right == left) continue;
            var n: usize = 0;
            for (self.rectangles[0..self.count]) |r| {
                if (r.x < right and r.x + r.width > left) {
                    intervals[n] = .{ .lo = r.y, .hi = r.y + r.height };
                    n += 1;
                }
            }
            if (n == 0) continue;
            std.mem.sort(Interval, intervals[0..n], {}, struct {
                fn less(_: void, a: Interval, b: Interval) bool {
                    return a.lo < b.lo or (a.lo == b.lo and a.hi < b.hi);
                }
            }.less);
            var current = intervals[0];
            var height: u128 = 0;
            for (intervals[1..n]) |v| {
                if (v.lo <= current.hi) current.hi = @max(current.hi, v.hi) else {
                    height += @intCast(current.hi - current.lo);
                    current = v;
                }
            }
            height += @intCast(current.hi - current.lo);
            covered += @as(u128, @intCast(right - left)) * height;
        }
        return covered * 2 >= area;
    }
    pub fn bounding(self: Journal) ?Rect {
        if (self.isFull()) return .{ .x = 0, .y = 0, .width = @intCast(self.width), .height = @intCast(self.height) };
        if (self.count == 0) return null;
        var result = self.rectangles[0];
        for (self.rectangles[1..self.count]) |r| {
            const x = @min(result.x, r.x);
            const y = @min(result.y, r.y);
            result = .{ .x = x, .y = y, .width = @max(result.x + result.width, r.x + r.width) - x, .height = @max(result.y + result.height, r.y + r.height) - y };
        }
        return result;
    }
};

/// Per-lifecycle damage owner, independent of the Store's address/lifetime.
/// A publication may return damage after Store destruction without dereferencing
/// a dead Store; closed owners never affect a recreated same-ID surface.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: @import("sync.zig").Mutex = .{},
    alive: bool = true,
    journal: Journal,
    pub fn create(a: std.mem.Allocator, width: usize, height: usize) !*Owner {
        const journal = try Journal.init(width, height, true);
        const self = try a.create(Owner);
        self.* = .{ .allocator = a, .journal = journal };
        return self;
    }
    pub fn retain(self: *Owner) *Owner {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *Owner) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            const a = self.allocator;
            self.mutex.deinit();
            a.destroy(self);
        }
    }
    pub fn close(self: *Owner) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.alive = false;
        self.journal.clear();
    }
    pub fn clear(self: *Owner) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.journal.clear();
    }
    pub fn snapshot(self: *Owner) Journal {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.journal;
    }
    pub fn append(self: *Owner, rectangles: []const Rect) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.alive);
        for (rectangles) |r| self.journal.append(r) catch unreachable; // Store validated these rectangles before committing.
    }
};
