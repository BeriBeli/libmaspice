const std = @import("std");
const s = @import("spice");
const t = std.testing;
const header = [_]u8{ 77, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0, 0 };
const initial = [_]u8{ 10, 0, 20, 0, 2, 0, 3, 0, 1, 2, 0 } ++ header ++ [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
const cached = [_]u8{ 11, 0, 21, 0, 1, 4, 0 } ++ header;
fn cursorLifetime(a: std.mem.Allocator) !void {
    var state = s.cursor.State.init(a);
    defer state.deinit();
    const first = try state.apply(try s.cursor_wire.decode(101, &initial));
    defer first.deinit();
    const second = try state.apply(try s.cursor_wire.decode(103, &cached));
    defer second.deinit();
    const invalidated = try state.apply(.{ .invalidate_one = 77 });
    defer invalidated.deinit();
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, first.snapshot.payload.?.data.bytes());
    try t.expectEqual(@as(i16, 11), second.snapshot.position.x);
    try t.expectError(error.UnknownCursor, state.apply(try s.cursor_wire.decode(103, &cached)));
    const reset = try state.apply(.reset);
    defer reset.deinit();
    try t.expect(!reset.snapshot.visible and reset.snapshot.payload == null);
    try t.expectEqualSlices(u8, first.snapshot.payload.?.data.bytes(), second.snapshot.payload.?.data.bytes());
}
test "cursor snapshots retain pixels through cache invalidation reset and every allocation failure" {
    try t.checkAllAllocationFailures(t.allocator, cursorLifetime, .{});
    var state = s.cursor.State.init(t.allocator);
    const event = try state.apply(try s.cursor_wire.decode(101, &initial));
    defer event.deinit();
    state.deinit();
    try t.expectEqual(@as(usize, 8), event.snapshot.payload.?.data.bytes().len);
}
test "cursor init ordering repeated init reset cache bounds and strict wire sizes" {
    var state = s.cursor.State.init(t.allocator);
    defer state.deinit();
    try t.expectError(error.CursorInitRequired, state.apply(.{ .move = .{ .x = 1 } }));
    var event = try state.apply(try s.cursor_wire.decode(101, &initial));
    event.deinit();
    event = try state.apply(try s.cursor_wire.decode(101, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0 }));
    event.deinit();
    try t.expectError(error.UnknownCursor, state.apply(try s.cursor_wire.decode(103, &cached)));
    state.maximum_entries = 0;
    try t.expectError(error.CursorCacheFull, state.apply(try s.cursor_wire.decode(101, &initial)));
    for (0..initial.len) |end| {
        if (s.cursor_wire.decode(101, initial[0..end])) |_| return error.AcceptedTruncation else |_| {}
    }
    try t.expectEqual(@as(usize, 12), try s.cursor_wire.dataSize(1, 9, 3));
    try t.expectEqual(@as(usize, 72), try s.cursor_wire.dataSize(2, 3, 3));
    try t.expectError(error.UnsupportedFormat, s.cursor_wire.dataSize(3, 2, 1));
}
test "Inputs encodes PC XT extended keys and mouse button ordering without allocation" {
    var buttons: u16 = 0;
    var packet = try s.inputs.encode(.{ .key_down = 0x14b }, &buttons);
    try t.expectEqualSlices(u8, &.{ 0xe0, 0x4b, 0, 0 }, packet.bytes[0..packet.length]);
    packet = try s.inputs.encode(.{ .key_up = 0x14b }, &buttons);
    try t.expectEqualSlices(u8, &.{ 0xe0, 0xcb, 0, 0 }, packet.bytes[0..packet.length]);
    try t.expectError(error.InvalidScanCode, s.inputs.encode(.{ .key_down = 0 }, &buttons));
    try t.expectError(error.InvalidScanCode, s.inputs.encode(.{ .key_up = 0x380 }, &buttons));
    packet = try s.inputs.encode(.{ .press = .left }, &buttons);
    try t.expectEqualSlices(u8, &.{ 1, 1, 0 }, packet.bytes[0..packet.length]);
    packet = try s.inputs.encode(.{ .motion = .{ .dx = -2, .dy = 4 } }, &buttons);
    try t.expectEqualSlices(u8, &.{ 254, 255, 255, 255, 4, 0, 0, 0, 1, 0 }, packet.bytes[0..packet.length]);
    packet = try s.inputs.encode(.{ .release = .left }, &buttons);
    try t.expectEqualSlices(u8, &.{ 1, 0, 0 }, packet.bytes[0..packet.length]);
    packet = try s.inputs.encode(.{ .position = .{ .x = 100, .y = 200, .display_id = 1 } }, &buttons);
    try t.expectEqualSlices(u8, &.{ 100, 0, 0, 0, 200, 0, 0, 0, 0, 0, 1 }, packet.bytes[0..packet.length]);
    try t.expectEqual(@as(u16, 3), (try s.inputs.decode(102, &.{ 3, 0 })).?.modifiers);
    try t.expectError(error.TrailingBytes, s.inputs.decode(111, &.{1}));
}
