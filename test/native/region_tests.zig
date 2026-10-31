const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
fn region(alloc: std.mem.Allocator) !void {
    var value = try s.region.Region.init(alloc, .{ .x = 0, .y = 0, .width = 8, .height = 8 }, .{ .x = 0, .y = 0, .width = 8, .height = 8 }, &.{ .{ .x = 1, .y = 1, .width = 5, .height = 4 }, .{ .x = 3, .y = 3, .width = 4, .height = 4 }, .{ .x = -2, .y = 0, .width = 5, .height = 3 } }, .{});
    defer value.deinit();
    var coverage: [64]u8 = @splat(0);
    for (value.rectangles.items) |r| {
        for (@intCast(r.y)..@intCast(r.y + r.height)) |y| {
            for (@intCast(r.x)..@intCast(r.x + r.width)) |x| coverage[y * 8 + x] += 1;
        }
    }
    for (0..8) |y| {
        for (0..8) |x| {
            const expected = (x >= 1 and x < 6 and y >= 1 and y < 5) or (x >= 3 and x < 7 and y >= 3 and y < 7) or (x < 3 and y < 3);
            try t.expectEqual(@as(u8, @intFromBool(expected)), coverage[y * 8 + x]);
        }
    }
}
test "region union clips exactly once with disjoint bounded bands" {
    try region(a);
}
test "region allocation failure releases sweep and output storage" {
    try t.checkAllAllocationFailures(a, region, .{});
}
test "region empty overflow and input output limits" {
    const full: s.region.Rect = .{ .x = 0, .y = 0, .width = 8, .height = 8 };
    var empty = try s.region.Region.init(a, full, full, &.{}, .{});
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.rectangles.items.len);
    try t.expectError(error.SegmentLimit, s.region.Region.init(a, full, full, null, .{ .segments = 0 }));
    try t.expectError(error.ClipLimit, s.region.Region.init(a, full, full, &.{full}, .{ .clips = 0 }));
    try t.expectError(error.InvalidRectangle, s.region.Region.init(a, .{ .x = 0, .y = 0, .width = -1, .height = 1 }, full, null, .{}));
    try t.expectError(error.Overflow, s.region.Region.init(a, .{ .x = std.math.maxInt(i64), .y = 0, .width = 1, .height = 1 }, full, null, .{}));
}
