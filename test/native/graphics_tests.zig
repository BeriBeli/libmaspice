const std = @import("std");
const s = @import("spice");
const t = std.testing;
const a = t.allocator;
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;
test "native IOSurface Metal exact scaling and clipped flip; frame survives context" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const context = try s.graphics.Context.init(path);
    var context_live = true;
    defer if (context_live) context.deinit();
    const source = try context.create(a, 3, 2);
    defer source.release();
    const bytes = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255, 13, 14, 15, 255, 16, 17, 18, 255 };
    const mapped = try source.lock(true);
    for (0..2) |y| @memcpy(mapped.bytes[y * mapped.stride ..][0..12], bytes[y * 12 ..][0..12]);
    try mapped.unlock();
    const destination = try context.create(a, 6, 4);
    defer destination.release();
    try context.scaleForPresentation(source, destination, &token);
    var result = try destination.lock(false);
    for (0..4) |y| {
        for (0..6) |x| try t.expectEqualSlices(u8, bytes[(y / 2 * 3 + x / 2) * 4 ..][0..4], result.bytes[y * result.stride + x * 4 ..][0..4]);
    }
    try result.unlock();
    const clone = try context.create(a, 6, 4);
    defer clone.release();
    try context.copy(destination, clone, &token);
    try context.compose(source, clone, .{ .x = 0, .y = 0, .width = 3, .height = 2 }, .{ .x = 0, .y = 0, .width = 6, .height = 4 }, &.{.{ .x = 1, .y = 1, .width = 4, .height = 2 }}, true, &token);
    result = try clone.lock(false);
    for (0..4) |y| {
        for (0..6) |x| {
            const sy = if (y >= 1 and y < 3 and x >= 1 and x < 5) 1 - y / 2 else y / 2;
            try t.expectEqualSlices(u8, bytes[(sy * 3 + x / 2) * 4 ..][0..4], result.bytes[y * result.stride + x * 4 ..][0..4]);
        }
    }
    try result.unlock();
    try t.expect(source.texture() != null and source.surface() != null);
    context.deinit();
    context_live = false;
    result = try source.lock(false);
    try t.expectEqualSlices(u8, bytes[0..12], result.bytes[0..12]);
    try result.unlock();
}
test "native MPS Lanczos preserves constant pixels and cancellation rejects publication" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    const context = try s.graphics.Context.init(path);
    defer context.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const source = try context.create(a, 5, 3);
    defer source.release();
    const destination = try context.create(a, 8, 7);
    defer destination.release();
    const mapped = try source.lock(true);
    for (0..3) |y| {
        for (0..5) |x| @memcpy(mapped.bytes[y * mapped.stride + x * 4 ..][0..4], &[_]u8{ 63, 127, 191, 255 });
    }
    try mapped.unlock();
    try context.scaleForPresentation(source, destination, &token);
    const result = try destination.lock(false);
    for (0..7) |y| {
        for (0..8) |x| try t.expectEqualSlices(u8, &.{ 63, 127, 191, 255 }, result.bytes[y * result.stride + x * 4 ..][0..4]);
    }
    try result.unlock();
    token.cancel();
    try t.expectError(error.Cancelled, context.scaleForPresentation(source, destination, &token));
}
test {
    _ = @import("surface_tests.zig");
    _ = @import("publisher_tests.zig");
    _ = @import("presenter_tests.zig");
    _ = @import("display_tests.zig");
    _ = @import("region_tests.zig");
}
test "Surface native composition publishes only current video generations and CPU drawing invalidates old decode" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    const context = try s.graphics.Context.init(path);
    defer context.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var store = s.surface.Store.init(a, .{}, context);
    defer store.deinit();
    try store.create(1, 4, 2, 32, &token);
    const initial = try store.snapshot(1);
    defer initial.deinit();
    const source = try context.create(a, 2, 1);
    defer source.release();
    const map = try source.lock(true);
    @memcpy(map.bytes[0..8], &[_]u8{ 1, 2, 3, 255, 4, 5, 6, 255 });
    try map.unlock();
    const rect: s.region.Rect = .{ .x = 0, .y = 0, .width = 4, .height = 2 };
    const sr: s.region.Rect = .{ .x = 0, .y = 0, .width = 2, .height = 1 };
    const seq: s.surface.Sequence = .{ .id = 1, .lifecycle = initial.revision.lifecycle, .value = 1 };
    try t.expect((try store.drawNativeVideo(1, source, sr, rect, &.{rect}, false, initial.barrier, seq, &token)) != null);
    const gpu = try store.snapshot(1);
    defer gpu.deinit();
    try t.expect(gpu.backing == .native);
    try t.expect((try store.drawNativeVideo(1, source, sr, rect, &.{rect}, false, initial.barrier, seq, &token)) == null);
    _ = try store.fill(1, &.{.{ .x = 0, .y = 0, .width = 1, .height = 1 }}, 0xffaabbcc, &token);
    try t.expect((try store.drawNativeVideo(1, source, sr, rect, &.{rect}, false, initial.barrier, .{ .id = 1, .lifecycle = seq.lifecycle, .value = 2 }, &token)) == null);
    const current = try store.snapshot(1);
    defer current.deinit();
    const read = try current.backing.read();
    try t.expectEqualSlices(u8, &.{ 0xcc, 0xbb, 0xaa, 0xff }, read.bytes[0..4]);
    try read.finish();
    const old = try gpu.backing.read();
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, old.bytes[0..4]);
    try old.finish();
    try store.destroy(1, &token);
    try store.create(1, 4, 2, 32, &token);
    try t.expect((try store.drawNativeVideo(1, source, sr, rect, &.{rect}, false, initial.barrier, .{ .id = 1, .lifecycle = seq.lifecycle, .value = 99 }, &token)) == null);
}
test "native leases share aligned-byte budget across contexts and outlive Surface generations" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    var budget: s.graphics.Budget = .{ .maximum = 1024 * 1024 };
    defer budget.deinit();
    var first = try s.graphics.Context.init(path);
    defer first.deinit();
    first.budget = &budget;
    var second = try s.graphics.Context.init(path);
    defer second.deinit();
    second.budget = &budget;
    const namespace = try s.graphics.newNamespace();
    const owner: s.graphics.Owner = .{ .namespace = namespace, .surface = 1 };
    const one = try first.createOwned(a, 5, 3, owner);
    var live = true;
    defer if (live) one.release();
    const size = one.allocation_bytes;
    try t.expect(size > 5 * 3 * 4);
    const two = try second.createOwned(a, 5, 3, owner);
    defer two.release();
    const three = try second.createOwned(a, 5, 3, owner);
    defer three.release();
    try t.expectEqual(size * 3, budget.snapshot().bytes);
    try t.expectError(error.NativePoolExhausted, first.createOwned(a, 5, 3, owner));
    one.release();
    live = false;
    const reused = try first.createOwned(a, 5, 3, owner);
    defer reused.release();
    try t.expectEqual(@as(usize, 3), budget.snapshot().frames);
    // This geometry fits a tight 256 MiB BGRA allocation, but its native aligned
    // rows/allocation exceed that ceiling. Reject before allocating IOSurface.
    var limit: s.graphics.Budget = .{};
    defer limit.deinit();
    var bounded = first;
    bounded.budget = &limit;
    try t.expectError(error.NativeBudgetExceeded, bounded.create(a, 4097, 16380));
    try t.expectEqual(@as(usize, 0), limit.snapshot().bytes);
}
extern "c" fn graphics_test_gate(*anyopaque) ?*anyopaque;
extern "c" fn graphics_test_release_gate(*anyopaque) void;
extern "c" fn usleep(u32) c_int;
const GPUJob = struct {
    store: *s.surface.Store,
    source: *s.graphics.Frame,
    barrier: s.surface.Barrier,
    token: s.cancel.Token = .{},
    failure: ?anyerror = null,
    fn run(self: *GPUJob) void {
        const r: s.region.Rect = .{ .x = 0, .y = 0, .width = 2, .height = 1 };
        _ = self.store.drawNativeVideo(0, self.source, r, r, &.{r}, false, self.barrier, .{ .id = 0, .lifecycle = self.barrier.lifecycle, .value = 1 }, &self.token) catch |err| {
            self.failure = err;
            return;
        };
    }
};
test "submitted GPU cancellation and injected completion failure preserve Surface and release candidate leases" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    for (0..2) |scenario| {
        var budget: s.graphics.Budget = .{};
        defer budget.deinit();
        var context = try s.graphics.Context.init(path);
        defer context.deinit();
        context.budget = &budget;
        context.test_failure_after_completion = scenario == 1;
        var store = s.surface.Store.init(a, .{}, context);
        defer store.deinit();
        var token: s.cancel.Token = .{};
        defer token.deinit();
        try store.create(0, 2, 1, 32, &token);
        const original = try store.snapshot(0);
        defer original.deinit();
        const source = try context.create(a, 2, 1);
        defer source.release();
        const mapped = try source.lock(true);
        @memset(mapped.bytes, 255);
        try mapped.unlock();
        const baseline = budget.snapshot();
        var gate = if (scenario == 0) graphics_test_gate(context.handle) orelse return error.GateFailed else null;
        defer if (gate) |g| graphics_test_release_gate(g);
        var job: GPUJob = .{ .store = &store, .source = source, .barrier = original.barrier };
        defer job.token.deinit();
        var joined = false;
        const thread = try std.Thread.spawn(.{}, GPUJob.run, .{&job});
        defer {
            job.token.cancel();
            if (gate) |g| {
                graphics_test_release_gate(g);
                gate = null;
            }
            if (!joined) thread.join();
        }
        if (scenario == 0) {
            var submitted = false;
            for (0..3000) |_| {
                if (context.submitted() > 0) {
                    submitted = true;
                    break;
                }
                _ = usleep(1000);
            }
            try t.expect(submitted);
            job.token.cancel();
            graphics_test_release_gate(gate.?);
            gate = null;
        }
        thread.join();
        joined = true;
        try t.expectEqual(if (scenario == 0) error.Cancelled else error.GPUFailed, job.failure.?);
        const after = try store.snapshot(0);
        defer after.deinit();
        try t.expectEqual(original.revision, after.revision);
        const read = try after.backing.read();
        try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, read.bytes[0..8]);
        try read.finish();
        try t.expectEqual(baseline.bytes, budget.snapshot().bytes);
        try t.expectEqual(baseline.frames, budget.snapshot().frames);
    }
}
test "destroy and resize retain native budget until the last old snapshot is released" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    var budget: s.graphics.Budget = .{};
    defer budget.deinit();
    var context = try s.graphics.Context.init(path);
    defer context.deinit();
    context.budget = &budget;
    var store = s.surface.Store.init(a, .{}, context);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    const source = try context.create(a, 2, 1);
    defer source.release();
    const mapping = try source.lock(true);
    @memset(mapping.bytes, 255);
    try mapping.unlock();
    var held: [3]?s.surface.Snapshot = .{ null, null, null };
    defer for (held) |entry| {
        if (entry) |snapshot| snapshot.deinit();
    };
    const sr: s.region.Rect = .{ .x = 0, .y = 0, .width = 2, .height = 1 };
    for (&held, 0..) |*entry, i| {
        try store.create(7, 2 + i, 1, 32, &token);
        const initial = try store.snapshot(7);
        defer initial.deinit();
        const dr: s.region.Rect = .{ .x = 0, .y = 0, .width = @intCast(2 + i), .height = 1 };
        _ = try store.drawNativeVideo(7, source, sr, dr, &.{dr}, false, initial.barrier, .{ .id = 7, .lifecycle = initial.revision.lifecycle, .value = 1 }, &token);
        entry.* = try store.snapshot(7);
        try store.destroy(7, &token);
    }
    const charged = budget.snapshot();
    try t.expectEqual(@as(usize, 4), charged.frames);
    try store.create(7, 2, 1, 32, &token);
    const initial = try store.snapshot(7);
    defer initial.deinit();
    const seq: s.surface.Sequence = .{ .id = 7, .lifecycle = initial.revision.lifecycle, .value = 1 };
    try t.expectError(error.NativePoolExhausted, store.drawNativeVideo(7, source, sr, sr, &.{sr}, false, initial.barrier, seq, &token));
    try t.expectEqual(charged.bytes, budget.snapshot().bytes);
    const unchanged = try store.snapshot(7);
    defer unchanged.deinit();
    try t.expectEqual(initial.revision, unchanged.revision);
    const old = try held[0].?.backing.read();
    try t.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, old.bytes[0..4]);
    try old.finish();
    held[0].?.deinit();
    held[0] = null;
    try t.expect((try store.drawNativeVideo(7, source, sr, sr, &.{sr}, false, initial.barrier, seq, &token)) != null);
    try t.expectEqual(@as(usize, 4), budget.snapshot().frames);
}

test "native Surface ring reuses only released frames and retires without invalidating snapshots" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    var budget: s.graphics.Budget = .{};
    defer budget.deinit();
    var context = try s.graphics.Context.init(path);
    context.budget = &budget;
    defer context.deinit();
    const retained = context.retain();
    retained.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var store = s.surface.Store.init(a, .{}, context);
    defer store.deinit();
    try store.create(42, 4, 2, 32, &token);
    const source = try context.create(a, 4, 2);
    defer source.release();
    const rect: s.region.Rect = .{ .x = 0, .y = 0, .width = 4, .height = 2 };
    var held: ?s.surface.Snapshot = null;
    defer if (held) |frame| frame.deinit();
    for (0..12) |i| {
        const map = try source.lock(true);
        @memset(map.bytes, @intCast(i));
        try map.unlock();
        const admission = try store.admitVideo(42);
        _ = try store.drawNativeVideo(42, source, rect, rect, &.{rect}, false, admission.barrier, admission.sequence, &token);
        if (i == 0) held = try store.snapshot(42);
    }
    try t.expectEqual(@as(u64, 3), store.native_pool.allocations);
    try t.expectEqual(@as(u64, 9), store.native_pool.reuses);
    const old = try held.?.backing.read();
    try t.expectEqual(@as(u8, 0), old.bytes[0]);
    try old.finish();
    const current = try store.snapshot(42);
    defer current.deinit();
    const bytes = try current.backing.read();
    try t.expectEqual(@as(u8, 11), bytes.bytes[0]);
    try bytes.finish();
    try store.destroy(42, &token);
    // Only source + two consumer-held snapshots survive the retired ring.
    try t.expectEqual(@as(usize, 3), budget.snapshot().frames);
    try t.expectEqual(@as(usize, 0), store.native_pool.slots.items.len);
}
fn poolAllocationFailures(alloc: std.mem.Allocator, context: s.graphics.Context) !void {
    var pool: s.graphics.FramePool = .{ .allocator = alloc };
    defer pool.deinit();
    const owner: s.graphics.Owner = .{ .namespace = try s.graphics.newNamespace(), .surface = 9 };
    const frame = try pool.checkout(context, 3, 2, owner);
    frame.release();
    const reused = try pool.checkout(context, 3, 2, owner);
    defer reused.release();
    try t.expect(reused == frame);
    pool.retire(owner);
}
test "native pool allocation failures release all budget charges" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    var budget: s.graphics.Budget = .{};
    defer budget.deinit();
    var context = try s.graphics.Context.init(path);
    context.budget = &budget;
    defer context.deinit();
    try t.checkAllAllocationFailures(a, poolAllocationFailures, .{context});
    try t.expectEqual(@as(usize, 0), budget.snapshot().frames);
}

fn lazyReadbackFailures(alloc: std.mem.Allocator, context: s.graphics.Context) !void {
    var store = s.surface.Store.init(alloc, .{}, context);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(1, 3, 2, 32, &token);
    const source = try context.create(alloc, 3, 2);
    defer source.release();
    const map = try source.lock(true);
    @memset(map.bytes, 255);
    try map.unlock();
    const admission = try store.admitVideo(1);
    const rect: s.region.Rect = .{ .x = 0, .y = 0, .width = 3, .height = 2 };
    const revision = (try store.drawNativeVideo(1, source, rect, rect, &.{rect}, false, admission.barrier, admission.sequence, &token)).?;
    const frame = (try store.publicationSnapshot(revision)).?;
    defer frame.release();
    try store.destroy(1, &token);
    const before = store.metrics();
    try t.expectEqual(@as(u64, 1), before.native_video_frames);
    try t.expectEqual(@as(u64, 24), before.direct_native_write_bytes);
    try t.expectEqual(@as(u64, 0), before.cpu_materializations);
    try t.expectEqual(@as(usize, 0), before.allocated_frames);
    const pixels = try frame.pixels();
    try t.expectEqual(@as(usize, 24), pixels.len);
    for (pixels) |byte| try t.expectEqual(@as(u8, 255), byte);
    try t.expect(pixels.ptr == (try frame.pixels()).ptr);
    const after = store.metrics();
    try t.expectEqual(@as(u64, 1), after.cpu_materializations);
    try t.expectEqual(@as(u64, 24), after.cpu_materialization_bytes);
    try t.expect(after.recommended_working_set > 0);
}
test "lazy native readback allocation failures preserve publication and release every lease" {
    const path = getenv("SPICE_ZIG_TEST_METALLIB") orelse return error.MissingTestMetallib;
    var budget: s.graphics.Budget = .{};
    defer budget.deinit();
    var context = try s.graphics.Context.init(path);
    context.budget = &budget;
    defer context.deinit();
    try t.checkAllAllocationFailures(a, lazyReadbackFailures, .{context});
    try t.expectEqual(@as(usize, 0), budget.snapshot().frames);
}
