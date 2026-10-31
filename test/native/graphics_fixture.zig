const std = @import("std");
const s = @import("spice");
const a = std.heap.c_allocator;
fn scale(path: [*:0]const u8, input: [*]const u8, w: usize, h: usize, output: [*]u8, tw: usize, th: usize) !void {
    const context = try s.graphics.Context.init(path);
    defer context.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const source = try context.create(a, w, h);
    defer source.release();
    const target = try context.create(a, tw, th);
    defer target.release();
    const map = try source.lock(true);
    for (0..h) |y| @memcpy(map.bytes[y * map.stride ..][0 .. w * 4], input[y * w * 4 ..][0 .. w * 4]);
    try map.unlock();
    try context.scaleForPresentation(source, target, &token);
    const read = try target.lock(false);
    defer read.unlock() catch {};
    for (0..th) |y| @memcpy(output[y * tw * 4 ..][0 .. tw * 4], read.bytes[y * read.stride ..][0 .. tw * 4]);
}
pub export fn graphics_fixture_scale(path: [*:0]const u8, input: [*]const u8, w: usize, h: usize, output: [*]u8, tw: usize, th: usize) c_int {
    scale(path, input, w, h, output, tw, th) catch return -1;
    return 0;
}

pub export fn graphics_fixture_damage(width: usize, height: usize, input: [*]const i64, count: usize, output: [*]i64, full: *bool) c_int {
    var journal = s.damage.Journal.init(width, height, false) catch return -1;
    if (count > 65536) return -1;
    for (0..count) |i| journal.append(.{ .x = input[i * 4], .y = input[i * 4 + 1], .width = input[i * 4 + 2], .height = input[i * 4 + 3] }) catch return -1;
    full.* = journal.isFull();
    if (full.*) {
        output[0] = 0;
        output[1] = 0;
        output[2] = @intCast(width);
        output[3] = @intCast(height);
        return 1;
    }
    for (journal.rectangles[0..journal.count], 0..) |r, i| {
        output[i * 4] = r.x;
        output[i * 4 + 1] = r.y;
        output[i * 4 + 2] = r.width;
        output[i * 4 + 3] = r.height;
    }
    return @intCast(journal.count);
}
