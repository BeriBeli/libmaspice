const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
fn payload(alloc: std.mem.Allocator, kind: u8, width: u32, height: u32, id: u64, window: u32, compressed: []const u8) !s.bytes.Writer {
    var w: s.bytes.Writer = .{ .allocator = alloc, .limit = 1024 * 1024 };
    errdefer w.deinit();
    try w.write(u32, @byteSwap(@as(u32, 0x20205a4c)));
    try w.write(u32, @byteSwap(@as(u32, 0x10001)));
    try w.write(u8, kind | 16);
    try w.write(u32, @byteSwap(width));
    try w.write(u32, @byteSwap(height));
    try w.write(u32, @byteSwap(width * @as(u32, if (kind == 6) 2 else if (kind == 7) 3 else 4)));
    try w.write(u64, @byteSwap(id));
    try w.write(u32, @byteSwap(window));
    try w.append(compressed);
    return w;
}
fn sequence(alloc: std.mem.Allocator) !void {
    var pool: s.codec_executor.Executor = .{};
    defer pool.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var decoder = s.glz.Decoder.init(alloc, &pool, .{});
    defer decoder.deinit();
    var first = try payload(alloc, 8, 2, 1, 0, 0, &.{ 1, 1, 2, 3, 4, 5, 6 });
    defer first.deinit();
    const image = try decoder.decode(first.bytes.items, 2, 1, 0, &token);
    defer image.release();
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 0, 4, 5, 6, 0 }, image.pixels());
    var cross = try payload(alloc, 8, 2, 1, 1, 1, &.{ 0x40, 0, 1 });
    defer cross.deinit();
    const second = try decoder.decode(cross.bytes.items, 2, 1, 0, &token);
    defer second.release();
    try t.expectEqualSlices(u8, image.pixels(), second.pixels());
    var overlap = try payload(alloc, 8, 7, 1, 2, 0, &.{ 1, 1, 2, 3, 4, 5, 6, 0xa1, 0, 0 });
    defer overlap.deinit();
    const third = try decoder.decode(overlap.bytes.items, 7, 1, 0, &token);
    defer third.release();
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 0, 4, 5, 6, 0, 1, 2, 3, 0, 4, 5, 6, 0, 1, 2, 3, 0, 4, 5, 6, 0, 1, 2, 3, 0 }, third.pixels());
    try t.expectEqual(@as(usize, 1), decoder.diagnostics().images);
    try decoder.clear();
    try t.expectEqual(@as(usize, 0), decoder.diagnostics().images);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 0, 4, 5, 6, 0 }, image.pixels());
}
test "GLZ exact literal cross-image overlap and retained lifetime through eviction/reset" {
    try sequence(a);
}
test "GLZ every allocation failure releases reservations and immutable snapshots" {
    try t.checkAllAllocationFailures(a, sequence, .{});
}
test "GLZ RGB16 RGBA alpha planes and exact consumption" {
    var pool: s.codec_executor.Executor = .{};
    defer pool.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var decoder = s.glz.Decoder.init(a, &pool, .{});
    defer decoder.deinit();
    var rgb = try payload(a, 6, 2, 1, 0, 0, &.{ 1, 0x7c, 0, 3, 0xe0 });
    defer rgb.deinit();
    const image = try decoder.decode(rgb.bytes.items, 2, 1, 0, &token);
    defer image.release();
    try t.expectEqualSlices(u8, &.{ 0, 0, 255, 0, 0, 255, 0, 0 }, image.pixels());
    var rgba = try payload(a, 9, 4, 1, 1, 1, &.{ 0, 9, 8, 7, 0x60, 0, 0, 0, 123, 0x20, 0, 0 });
    defer rgba.deinit();
    const alpha = try decoder.decode(rgba.bytes.items, 4, 1, 0, &token);
    defer alpha.release();
    try t.expectEqualSlices(u8, &.{ 9, 8, 7, 123, 9, 8, 7, 123, 9, 8, 7, 123, 9, 8, 7, 123 }, alpha.pixels());
    for (0..rgba.bytes.items.len) |n| {
        var program = s.glz.parse(a, rgba.bytes.items[0..n], 4, 1, .{}) catch continue;
        program.deinit();
        return error.AcceptedTruncation;
    }
    try rgba.append(&.{0});
    try t.expectError(error.TrailingBytes, s.glz.parse(a, rgba.bytes.items, 4, 1, .{}));
}
test "GLZ failed capacity commit leaves dictionary and retry intact" {
    var pool: s.codec_executor.Executor = .{};
    defer pool.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var decoder = s.glz.Decoder.init(a, &pool, .{ .dictionary_images = 1 });
    defer decoder.deinit();
    var first = try payload(a, 8, 1, 1, 0, 0, &.{ 0, 1, 2, 3 });
    defer first.deinit();
    const image = try decoder.decode(first.bytes.items, 1, 1, 0, &token);
    defer image.release();
    var second = try payload(a, 8, 1, 1, 1, 1, &.{ 0, 4, 5, 6 });
    defer second.deinit();
    try t.expectError(error.DictionaryImagesExceeded, decoder.decode(second.bytes.items, 1, 1, 0, &token));
    try t.expectEqual(@as(usize, 1), decoder.diagnostics().images);
    try t.expectEqual(@as(usize, 0), decoder.diagnostics().reservations);
    // Narrowing the window allows the exact same ID to commit after failure.
    second.bytes.items[32] = 0;
    const retry = try decoder.decode(second.bytes.items, 1, 1, 0, &token);
    defer retry.release();
    try t.expectEqual(@as(usize, 1), decoder.diagnostics().images);
}
