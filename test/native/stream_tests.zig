const std = @import("std");
const s = @import("spice");
const t = std.testing;
fn monitor(a: std.mem.Allocator) !void {
    const data = [_]u8{ 1, 0, 1, 0 } ++ @as([8]u8, @splat(0)) ++ [_]u8{ 2, 0, 0, 0, 3, 0, 0, 0 } ++ @as([12]u8, @splat(0));
    var parsed = try s.stream_wire.decode(a, 317, &data);
    defer parsed.deinit();
    try t.expectEqual(@as(u32, 3), parsed.command.monitors.heads[0].height);
}
test "monitor bounds duplicate IDs exact body and all metadata allocation failures" {
    try t.checkAllAllocationFailures(t.allocator, monitor, .{});
    const data = [_]u8{ 1, 0, 1, 0 } ++ @as([8]u8, @splat(0)) ++ [_]u8{ 2, 0, 0, 0, 3, 0, 0, 0 } ++ @as([12]u8, @splat(0));
    for (0..data.len) |end| {
        if (s.stream_wire.decode(t.allocator, 317, data[0..end])) |value| {
            var p = value;
            p.deinit();
            return error.AcceptedTruncation;
        } else |_| {}
    }
    var duplicated = [_]u8{ 2, 0, 2, 0 } ++ data[4..].* ++ data[4..].*;
    try t.expectError(error.InvalidMonitorID, s.stream_wire.decode(t.allocator, 317, &duplicated));
}
fn annex(a: std.mem.Allocator) !void {
    const bytes = [_]u8{ 0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 4, 0, 0, 0, 1, 0x65, 9, 8, 7, 0, 0 };
    const unit = try s.annexb.parse(a, .h264, &bytes, .{});
    defer unit.deinit();
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 4, 0x65, 9, 8, 7 }, unit.sample);
    try t.expect(unit.picture and unit.random_access and unit.nals.len == 3);
    try t.expectEqual(@intFromPtr(&bytes) + 4, @intFromPtr(unit.nals[0].bytes.ptr));
}
test "Annex B preserves borrowed NALs and one exact AVCC sample through all allocation failures" {
    try t.checkAllAllocationFailures(t.allocator, annex, .{});
    try t.expectError(error.EmptyNAL, s.annexb.parse(t.allocator, .h264, &.{ 0, 0, 1 }, .{}));
    try t.expectError(error.InvalidHEVCHeader, s.annexb.parse(t.allocator, .h265, &.{ 0, 0, 1, 0x26, 0 }, .{}));
    try t.expectError(error.ForbiddenBit, s.annexb.parse(t.allocator, .h264, &.{ 0, 0, 1, 0x85, 1 }, .{}));
    try t.expectError(error.NALLimit, s.annexb.parse(t.allocator, .h264, &.{ 0, 0, 1, 0x65, 1 }, .{ .units = 0 }));
    const unit = try s.annexb.parse(t.allocator, .h265, &.{ 0, 0, 1, 0x40, 1, 2, 0, 0, 1, 0x26, 1, 9 }, .{});
    defer unit.deinit();
    try t.expect(unit.picture and unit.random_access and unit.nals[0].parameter);
}
