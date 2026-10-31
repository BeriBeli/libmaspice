const std = @import("std");
const t = std.testing;
const s = @import("spice");
const a = t.allocator;
fn pixel(alloc: std.mem.Allocator, value: u8) !s.image.Image {
    const image = try s.image.Image.create(alloc, 1, 1, true, .opaque_pixels);
    @memset(image.unpublishedPixels(), value);
    return image;
}
fn basic(alloc: std.mem.Allocator) !void {
    var cache = try s.image_cache.Cache.init(alloc, .{});
    defer cache.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const first = try pixel(alloc, 1);
    defer first.release();
    const next = try pixel(alloc, 2);
    defer next.release();
    const m = try cache.begin(4, true, .cache, 0, &token);
    errdefer cache.abort(m);
    try t.expectEqual(.staged, try cache.stage(m, first));
    try t.expectEqual(.committed, cache.commit(m));
    const held = try cache.resolve(4, .any, 0, &token);
    defer held.release();
    const duplicate = try cache.begin(4, true, .cache, 0, &token);
    errdefer cache.abort(duplicate);
    _ = try cache.stage(duplicate, first);
    try t.expectEqual(.committed, cache.commit(duplicate));
    try t.expectEqual(@as(u32, 2), cache.references(4));
    const replacement = try cache.begin(4, false, .replace, 0, &token);
    errdefer cache.abort(replacement);
    _ = try cache.stage(replacement, next);
    try t.expectEqual(.committed, cache.commit(replacement));
    try t.expectEqual(@as(u32, 2), cache.references(4));
    const current = try cache.resolve(4, .lossless, 0, &token);
    defer current.release();
    try t.expectEqual(@as(u8, 2), current.pixels()[0]);
    try t.expectEqual(@as(u8, 1), held.pixels()[0]);
    cache.invalidate(4);
    try t.expectEqual(@as(u32, 1), cache.references(4));
    cache.invalidateAll();
    try t.expectEqual(@as(u32, 0), cache.references(4));
    try t.expectEqual(@as(u8, 2), current.pixels()[0]);
}
test "cache references lossless replacement and immutable outstanding readers" {
    try basic(a);
}
test "cache allocation failure never leaks staged images or mutation state" {
    try t.checkAllAllocationFailures(a, basic, .{});
}
test "cache invalidation between stage and Surface completion cannot fail or publish" {
    var cache = try s.image_cache.Cache.init(a, .{});
    defer cache.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const image = try pixel(a, 9);
    defer image.release();
    const m = try cache.begin(1, false, .cache, 7, &token);
    _ = try cache.stage(m, image);
    cache.invalidate(1);
    try t.expectEqual(.invalidated, cache.commit(m));
    try t.expectEqual(@as(usize, 0), cache.diagnostics().reserved_bytes);
    try t.expectEqual(@as(u32, 0), cache.references(1));
    const before_decode = try cache.begin(1, false, .cache, 7, &token);
    cache.invalidateAll();
    try t.expectEqual(.invalidated, try cache.stage(before_decode, image));
    try t.expectEqual(.invalidated, cache.commit(before_decode));
    const cleared = try cache.begin(1, false, .cache, 0, &token);
    cache.clear();
    try t.expectEqual(.discarded, cache.commit(cleared));
}
test "cache projects concurrent stages before Surface and enforces independent budgets" {
    var cache = try s.image_cache.Cache.init(a, .{ .entries = 2, .bytes = 8 });
    defer cache.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const image = try pixel(a, 1);
    defer image.release();
    const first = try cache.begin(1, false, .cache, 0, &token);
    defer cache.abort(first);
    _ = try cache.stage(first, image);
    const second = try cache.begin(2, false, .cache, 1, &token);
    defer cache.abort(second);
    try t.expectError(error.TemporaryBytesExceeded, cache.stage(second, image));
    try t.expectError(error.EntryLimit, cache.begin(3, false, .cache, 0, &token));
    try t.expectEqual(.committed, cache.commit(first));
    _ = try cache.stage(second, image);
    try t.expectEqual(.committed, cache.commit(second));
    const bad = try cache.begin(1, false, .replace, 0, &token);
    defer cache.abort(bad);
    try t.expectError(error.ReplacementRequiresLossy, cache.stage(bad, image));
    try t.expectError(error.LossyReplacement, cache.begin(1, true, .replace, 0, &token));
}
