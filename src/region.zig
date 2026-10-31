//! Canonical union of clipped rectangles. Sweep events update compressed x
//! intervals; output bands are disjoint and bounded before any Surface write.
const std = @import("std");
pub const Rect = struct {
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    pub fn right(self: Rect) !i64 {
        if (self.width < 0) return error.InvalidRectangle;
        return std.math.add(i64, self.x, self.width);
    }
    pub fn bottom(self: Rect) !i64 {
        if (self.height < 0) return error.InvalidRectangle;
        return std.math.add(i64, self.y, self.height);
    }
    pub fn intersect(self: Rect, other: Rect) !?Rect {
        const r = @min(try self.right(), try other.right());
        const b = @min(try self.bottom(), try other.bottom());
        const x = @max(self.x, other.x);
        const y = @max(self.y, other.y);
        if (r <= x or b <= y) return null;
        return .{ .x = x, .y = y, .width = try std.math.sub(i64, r, x), .height = try std.math.sub(i64, b, y) };
    }
    pub fn validate(self: Rect, width: usize, height: usize) !void {
        if (self.x < 0 or self.y < 0 or self.width <= 0 or self.height <= 0 or try self.right() > width or try self.bottom() > height) return error.InvalidRectangle;
    }
};
pub const Limits = struct { clips: usize = 4096, segments: usize = 65536 };
pub const Region = struct {
    allocator: std.mem.Allocator,
    rectangles: std.ArrayList(Rect) = .empty,
    pub fn deinit(self: *Region) void {
        self.rectangles.deinit(self.allocator);
    }
    pub fn init(a: std.mem.Allocator, destination: Rect, bounds: Rect, clips: ?[]const Rect, limits: Limits) !Region {
        var self: Region = .{ .allocator = a };
        errdefer self.deinit();
        const bounded = try destination.intersect(bounds);
        if (clips) |items| {
            if (items.len > limits.clips) return error.ClipLimit;
            for (items) |r| {
                _ = try r.right();
                _ = try r.bottom();
            }
        } else {
            if (bounded) |r| {
                if (limits.segments == 0) return error.SegmentLimit;
                try self.rectangles.append(a, r);
            }
            return self;
        }
        const area = bounded orelse return self;
        const Event = struct { y: i64, left: i64, right: i64, delta: i32 };
        var events: std.ArrayList(Event) = .empty;
        defer events.deinit(a);
        var xs: std.ArrayList(i64) = .empty;
        defer xs.deinit(a);
        for (clips.?) |clip| {
            if (try area.intersect(clip)) |r| {
                const right = try r.right();
                try events.append(a, .{ .y = r.y, .left = r.x, .right = right, .delta = 1 });
                try events.append(a, .{ .y = try r.bottom(), .left = r.x, .right = right, .delta = -1 });
                try xs.appendSlice(a, &.{ r.x, right });
            }
        }
        if (events.items.len == 0) return self;
        std.mem.sort(Event, events.items, {}, struct {
            fn less(_: void, l: Event, r: Event) bool {
                return l.y < r.y;
            }
        }.less);
        std.mem.sort(i64, xs.items, {}, std.sort.asc(i64));
        var unique: usize = 0;
        for (xs.items) |x| {
            if (unique == 0 or xs.items[unique - 1] != x) {
                xs.items[unique] = x;
                unique += 1;
            }
        }
        xs.items.len = unique;
        const coverage = try a.alloc(i32, unique - 1);
        defer a.free(coverage);
        @memset(coverage, 0);
        var current: usize = 0;
        var previous_band_start: usize = 0;
        var previous_band_count: usize = 0;
        while (current < events.items.len) {
            const y = events.items[current].y;
            while (current < events.items.len and events.items[current].y == y) : (current += 1) {
                const e = events.items[current];
                const left = std.sort.binarySearch(i64, xs.items, e.left, compare).?;
                const right = std.sort.binarySearch(i64, xs.items, e.right, compare).?;
                for (coverage[left..right]) |*count| {
                    count.* += e.delta;
                    std.debug.assert(count.* >= 0);
                }
            }
            if (current == events.items.len) break;
            const next_y = events.items[current].y;
            const start = self.rectangles.items.len;
            var x: usize = 0;
            while (x < coverage.len) {
                if (coverage[x] == 0) {
                    x += 1;
                    continue;
                }
                const left = x;
                while (x < coverage.len and coverage[x] > 0) x += 1;
                // At most one extra band's intervals are built before coalescing.
                if (self.rectangles.items.len >= limits.segments +| unique) return error.SegmentLimit;
                try self.rectangles.append(a, .{ .x = xs.items[left], .y = y, .width = xs.items[x] - xs.items[left], .height = next_y - y });
            }
            const count = self.rectangles.items.len - start;
            var same = count > 0 and count == previous_band_count;
            if (same) {
                for (0..count) |i| {
                    const old = self.rectangles.items[previous_band_start + i];
                    const new = self.rectangles.items[start + i];
                    if (old.x != new.x or old.width != new.width or try old.bottom() != new.y) {
                        same = false;
                        break;
                    }
                }
            }
            if (same) {
                for (0..count) |i| self.rectangles.items[previous_band_start + i].height += next_y - y;
                self.rectangles.items.len = start;
            } else {
                previous_band_start = start;
                previous_band_count = count;
            }
            if (self.rectangles.items.len > limits.segments) return error.SegmentLimit;
        }
        return self;
    }
    fn compare(key: i64, value: i64) std.math.Order {
        return std.math.order(key, value);
    }
};
