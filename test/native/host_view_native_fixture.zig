const std = @import("std");
const s = @import("spice");
const a = std.heap.c_allocator;
const Fixture = struct { src: *s.desktop_source.Source, context: ?s.graphics.Context, store: s.surface.Store };
pub export fn host_fixture_create(path: ?[*:0]const u8) ?*Fixture {
    return create(path) catch null;
}
fn create(path: ?[*:0]const u8) !*Fixture {
    const f = try a.create(Fixture);
    errdefer a.destroy(f);
    const context = if (path) |p| try s.graphics.Context.init(p) else null;
    errdefer if (context) |c| c.deinit();
    const src = try s.desktop_source.Source.create(a, .{});
    errdefer src.release();
    var store = s.surface.Store.init(a, .{}, context);
    errdefer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(0, 80, 40, 32, &token);
    try src.begin(.absolute, false, true);
    f.* = .{ .src = src, .context = context, .store = store };
    return f;
}
pub export fn host_fixture_destroy(f: *Fixture) void {
    f.src.release();
    f.store.deinit();
    if (f.context) |c| c.deinit();
    a.destroy(f);
}
pub export fn spice_zig_source_acquire_core(f: *Fixture) *s.desktop_source.Source {
    return f.src.retain();
}
pub export fn spice_zig_source_native_context(f: *Fixture) ?*anyopaque {
    return if (f.context) |c| c.handle else null;
}
pub export fn host_fixture_publish(f: *Fixture, native: c_int) c_int {
    publish(f, native != 0) catch return -1;
    return 0;
}
fn publish(f: *Fixture, native: bool) !void {
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const rect: s.region.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 40 };
    const image = try s.image.Image.create(a, 80, 40, true, .opaque_pixels);
    defer image.release();
    for (0..40) |y| for (0..80) |x| {
        const pixel = image.unpublishedPixels()[(y * 80 + x) * 4 ..][0..4];
        @memcpy(pixel, if (y < 20) &[_]u8{ 0, 0, 255, 255 } else &[_]u8{ 255, 0, 0, 255 });
    };
    const revision = if (native) blk: {
        const context = f.context orelse return error.MissingNative;
        const frame = try context.create(a, 80, 40);
        defer frame.release();
        const map = try frame.lock(true);
        for (0..40) |y| @memcpy(map.bytes[y * map.stride ..][0..320], image.pixels()[y * 320 ..][0..320]);
        try map.unlock();
        const admission = try f.store.admitVideo(0);
        break :blk (try f.store.drawNativeVideo(0, frame, rect, rect, &.{rect}, false, admission.barrier, admission.sequence, &token)).?;
    } else (try f.store.copyImage(0, &.{rect}, rect, rect, image, &token)).?;
    const publication = (try f.store.publicationSnapshot(revision)).?;
    defer publication.release();
    try f.src.receiveFrame(0, publication);
}
pub export fn host_fixture_metric(f: *Fixture, index: u32) u64 {
    const m = f.src.diagnostics.snapshot();
    return switch (index) {
        0 => m.count(.command_buffers_committed),
        1 => m.count(.metal_presented),
        2 => m.count(.metal_errors),
        3 => m.fallback_frames,
        4 => m.latency(.commit_to_completion).sample_count,
        5 => f.src.metrics().subscriptions,
        6 => f.src.metrics().visible,
        else => 0,
    };
}
