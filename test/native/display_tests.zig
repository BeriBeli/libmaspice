const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
fn writer(alloc: std.mem.Allocator) s.bytes.Writer {
    return .{ .allocator = alloc, .limit = 1024 * 1024 };
}
fn rect(w: *s.bytes.Writer) !void {
    try w.write(i32, 0);
    try w.write(i32, 0);
    try w.write(i32, 1);
    try w.write(i32, 2);
}
fn mask(w: *s.bytes.Writer) !void {
    try w.write(u8, 0);
    try w.write(u64, 0);
    try w.write(u32, 0);
}
fn copy(alloc: std.mem.Allocator, kind: u8, flags: u8, data: []const u8) !s.bytes.Writer {
    var w = writer(alloc);
    errdefer w.deinit();
    try w.write(u32, 0);
    try rect(&w);
    try w.write(u8, 0);
    try w.write(u32, 57);
    try rect(&w);
    try w.write(u16, 8);
    try w.write(u8, 0);
    try mask(&w);
    try w.write(u64, 501);
    try w.write(u8, kind);
    try w.write(u8, flags);
    try w.write(u32, 2);
    try w.write(u32, 1);
    switch (kind) {
        0 => {
            try w.write(u8, 8);
            try w.write(u8, 4);
            try w.write(u32, 2);
            try w.write(u32, 1);
            try w.write(u32, 8);
            try w.write(u32, 0);
            try w.append(data);
        },
        103, 106 => {},
        else => {
            try w.write(u32, @intCast(data.len));
            try w.append(data);
        },
    }
    return w;
}
fn create(state: *s.display.State, token: *s.cancel.Token) !void {
    var w = writer(state.allocator);
    defer w.deinit();
    try w.write(u32, 0);
    try w.write(u32, 2);
    try w.write(u32, 1);
    try w.write(u32, 32);
    try w.write(u32, 0);
    _ = try state.handle(314, w.bytes.items, w.bytes.items.len, null, token);
}
fn sequence(alloc: std.mem.Allocator) !void {
    const world = try s.display.World.create(alloc);
    defer world.destroy();
    var first = s.display.State.init(alloc, world, null);
    defer first.deinit();
    var second = s.display.State.init(alloc, world, null);
    defer second.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try create(&first, &token);
    try create(&second, &token);
    var raw = try copy(alloc, 0, 1, &.{ 1, 2, 3, 0, 4, 5, 6, 0 });
    defer raw.deinit();
    try t.expect((try first.handle(304, raw.bytes.items, raw.bytes.items.len, null, &token)) == .frame);
    var cached = try copy(alloc, 103, 0, &.{});
    defer cached.deinit();
    try t.expect((try second.handle(304, cached.bytes.items, cached.bytes.items.len, null, &token)) == .frame);
    const snapshot = try second.surfaces.snapshot(0);
    defer snapshot.deinit();
    const read = try snapshot.backing.read();
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255 }, read.bytes[0..8]);
    try read.finish();
    try t.expectEqual(@as(u32, 1), world.images.references(501));
    // Invalid source geometry fails after mutation registration, before stage.
    raw.bytes.items[25] = 0xff;
    raw.bytes.items[26] = 0xff;
    raw.bytes.items[27] = 0xff;
    raw.bytes.items[28] = 0x7f;
    _ = first.handle(304, raw.bytes.items, raw.bytes.items.len, null, &token) catch |err| {
        if (err == error.OutOfMemory) return err;
        try t.expectEqual(@as(u32, 1), world.images.references(501));
        try t.expectEqual(@as(usize, 0), world.images.diagnostics().mutations);
        return;
    };
    return error.AcceptedMalformedDraw;
}
test "Display RAW cache transaction crosses real shared image cache into independent Surfaces" {
    try sequence(a);
}
test "Display allocation failures drain parsed payload mutations and shared resources" {
    try t.checkAllAllocationFailures(a, sequence, .{});
}
test "Display GLZ draws, exact payload offsets and truncations" {
    const world = try s.display.World.create(a);
    defer world.destroy();
    var state = s.display.State.init(a, world, null);
    defer state.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try create(&state, &token);
    const glz = [_]u8{ 0x20, 0x20, 0x5a, 0x4c, 0, 1, 0, 1, 24, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 4, 5, 6 };
    var command = try copy(a, 102, 1, &glz);
    defer command.deinit();
    try t.expect((try state.handle(304, command.bytes.items, command.bytes.items.len, null, &token)) == .frame);
    for (0..command.bytes.items.len) |end| {
        var parsed = s.display_wire.decode(a, 304, command.bytes.items[0..end]) catch continue;
        parsed.deinit();
        return error.AcceptedTruncation;
    }
    try command.append(&.{0});
    try t.expectError(error.TrailingBytes, s.display_wire.decode(a, 304, command.bytes.items));
    command.bytes.items.len -= 1;
    command.bytes.items[21] = 56;
    try t.expectError(error.InvalidOffset, s.display_wire.decode(a, 304, command.bytes.items));
}
