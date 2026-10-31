const std = @import("std");
const s = @import("spice");
const t = std.testing;
const a = t.allocator;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
extern "c" fn graphics_test_gate(*anyopaque) ?*anyopaque;
extern "c" fn graphics_test_release_gate(*anyopaque) void;
const Observer = struct {
    mutex: s.sync.Mutex = .{},
    completed: usize = 0,
    current: usize = 0,
    failed: usize = 0,
    fn receive(p: *anyopaque, result: s.presenter.Completion) void {
        const self: *Observer = @ptrCast(@alignCast(p));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.completed += 1;
        self.current += @intFromBool(result.current);
        self.failed += @intFromBool(!result.succeeded);
    }
    fn sink(self: *Observer) s.presenter.Sink {
        return .{ .context = self, .completed = receive };
    }
};
fn makeFrame(store: *s.surface.Store, context: s.graphics.Context, token: *s.cancel.Token) !s.surface.Publication {
    try store.create(1, 4, 2, 32, token);
    const input = try context.create(a, 4, 2);
    defer input.release();
    const map = try input.lock(true);
    for (0..2) |y| for (0..4) |x| {
        @memcpy(map.bytes[y * map.stride + x * 4 ..][0..4], &[_]u8{ @intCast(x * 50), @intCast(y * 90), @intCast((x + y) * 20), 255 });
    };
    try map.unlock();
    const admission = try store.admitVideo(1);
    const r: s.region.Rect = .{ .x = 0, .y = 0, .width = 4, .height = 2 };
    const revision = (try store.drawNativeVideo(1, input, r, r, &.{r}, false, admission.barrier, admission.sequence, token)).?;
    return (try store.publicationSnapshot(revision)).?;
}
test "presenter exact nearest and direct Lanczos match native reference with retained frame lifetime" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    const presentation = getenv("SPICE_ZIG_TEST_PRESENTATION_METALLIB") orelse return error.MissingTestMetallib;
    const context = try s.graphics.Context.init(path);
    defer context.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var store = s.surface.Store.init(a, .{}, context);
    defer store.deinit();
    const frame = try makeFrame(&store, context, &token);
    defer frame.release();
    var observer: Observer = .{};
    defer observer.mutex.deinit();
    const presenter = try s.presenter.Presenter.create(a, context, presentation, observer.sink());
    defer presenter.destroy();
    for ([_][2]usize{ .{ 4, 2 }, .{ 8, 4 }, .{ 7, 5 }, .{ 3, 1 } }) |size| {
        const output = try context.create(a, size[0], size[1]);
        defer output.release();
        const reference = try context.create(a, size[0], size[1]);
        defer reference.release();
        try t.expectEqual(s.presenter.Result.submitted, try presenter.submit(frame, .{ .texture = output.texture().?, .width = @intCast(size[0]), .height = @intCast(size[1]) }));
        presenter.waitIdle();
        try context.scaleForPresentation(frame.snapshot().backing.native, reference, &token);
        const actual = try output.lock(false);
        defer actual.unlock() catch unreachable;
        const expected = try reference.lock(false);
        defer expected.unlock() catch unreachable;
        for (0..size[1]) |y| try t.expectEqualSlices(u8, expected.bytes[y * expected.stride ..][0 .. size[0] * 4], actual.bytes[y * actual.stride ..][0 .. size[0] * 4]);
    }
    try t.expectEqual(@as(usize, 4), observer.completed);
    try t.expectEqual(@as(usize, 0), observer.failed);
    const target = try context.create(a, 8, 4);
    defer target.release();
    try t.expectError(error.PresentationFailed, presenter.submit(frame, .{ .texture = target.texture().?, .width = 9, .height = 4 }));
    try t.expectEqual(@as(usize, 0), presenter.metrics().active);
    try t.expectError(error.InvalidDimensions, s.presenter.sampling(0, 1, 1, 1));
}
test "presenter limits actual GPU work to two and retains leases across hide and Store destruction" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    const presentation = getenv("SPICE_ZIG_TEST_PRESENTATION_METALLIB") orelse return error.MissingTestMetallib;
    var context = try s.graphics.Context.init(path);
    var context_live = true;
    defer if (context_live) context.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var store = s.surface.Store.init(a, .{}, context);
    var store_live = true;
    defer if (store_live) store.deinit();
    const frame = try makeFrame(&store, context, &token);
    var frame_live = true;
    defer if (frame_live) frame.release();
    var observer: Observer = .{};
    defer observer.mutex.deinit();
    const presenter = try s.presenter.Presenter.create(a, context, presentation, observer.sink());
    defer presenter.destroy();
    const first = try context.create(a, 8, 4);
    defer first.release();
    const second = try context.create(a, 8, 4);
    defer second.release();
    const gate = graphics_test_gate(context.handle) orelse return error.GateFailed;
    var gate_live = true;
    defer if (gate_live) graphics_test_release_gate(gate);
    const one: s.presenter.Destination = .{ .texture = first.texture().?, .width = 8, .height = 4 };
    const two: s.presenter.Destination = .{ .texture = second.texture().?, .width = 8, .height = 4 };
    try t.expectEqual(s.presenter.Result.submitted, try presenter.submit(frame, one));
    try t.expectEqual(s.presenter.Result.submitted, try presenter.submit(frame, two));
    try t.expectEqual(s.presenter.Result.busy, try presenter.submit(frame, one));
    try presenter.reset(false);
    try t.expectEqual(s.presenter.Result.hidden, try presenter.submit(frame, one));
    frame.release();
    frame_live = false;
    store.deinit();
    store_live = false;
    context.deinit();
    context_live = false;
    graphics_test_release_gate(gate);
    gate_live = false;
    presenter.waitIdle();
    try t.expectEqual(@as(usize, 2), observer.completed);
    try t.expectEqual(@as(usize, 0), observer.current);
    try t.expectEqual(@as(usize, 0), observer.failed);
    try t.expectEqual(@as(usize, 2), presenter.metrics().maximum_active);
    const actual = try first.lock(false);
    defer actual.unlock() catch unreachable;
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, actual.bytes[0..4]);
}
fn allocationFailures(alloc: std.mem.Allocator, context: s.graphics.Context, path: [*:0]const u8, frame: s.surface.Publication, destination: s.presenter.Destination) !void {
    var observer: Observer = .{};
    defer observer.mutex.deinit();
    const presenter = try s.presenter.Presenter.create(alloc, context, path, observer.sink());
    defer presenter.destroy();
    _ = try presenter.submit(frame, destination);
}
test "presenter allocation failures balance callback and frame ownership" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    const presentation = getenv("SPICE_ZIG_TEST_PRESENTATION_METALLIB") orelse return error.MissingTestMetallib;
    const context = try s.graphics.Context.init(path);
    defer context.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var store = s.surface.Store.init(a, .{}, context);
    defer store.deinit();
    const frame = try makeFrame(&store, context, &token);
    defer frame.release();
    const target = try context.create(a, 4, 2);
    defer target.release();
    try t.checkAllAllocationFailures(a, allocationFailures, .{ context, presentation, frame, s.presenter.Destination{ .texture = target.texture().?, .width = 4, .height = 2 } });
}
