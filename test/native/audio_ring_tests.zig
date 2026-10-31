const std = @import("std");
const t = std.testing;
const s = @import("spice");
const r = s.audio_ring;
const b = s.audio_buffer;
const a = t.allocator;
fn allocations(allocator: std.mem.Allocator) !void {
    var queue = try r.Ring.init(allocator, .{ .bytes = 16, .slots = 4 }, true);
    defer queue.deinit();
    _ = queue.enqueue(12, &.{ 1, 2, 3 });
    const packet = (try queue.dequeue(allocator)).?;
    defer packet.deinit();
    try t.expectEqualSlices(u8, &.{ 1, 2, 3 }, packet.bytes);
}
test "audio fixed capacity validates before allocation and allocation failures release leases" {
    try t.expectError(error.InvalidAudioCapacity, r.Ring.init(a, .{ .bytes = 0, .slots = 1 }, false));
    try t.expectError(error.InvalidAudioCapacity, r.Capacity.pcm(192000, 8, std.math.maxInt(u32)));
    try t.expectEqual(r.Capacity{ .bytes = 88200, .slots = 22050 }, try r.Capacity.pcm(44100, 2, 500));
    try t.checkAllAllocationFailures(a, allocations, .{});
    var queue = try r.Ring.init(a, .{ .bytes = 8, .slots = 2 }, false);
    defer queue.deinit();
    _ = queue.enqueue(7, &.{ 3, 4 });
    var fail = t.FailingAllocator.init(a, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, queue.dequeue(fail.allocator()));
    try t.expectEqual(@as(usize, 2), queue.diagnostics().queued_bytes);
    const packet = (try queue.dequeue(a)).?;
    defer packet.deinit();
    try t.expectEqualSlices(u8, &.{ 3, 4 }, packet.bytes);
}
const LeaseProbe = struct {
    queue: *r.Ring,
    close: bool = false,
    reset: bool = false,
    passed: bool = false,
    fn run(raw: *anyopaque) void {
        const self: *LeaseProbe = @ptrCast(@alignCast(raw));
        var bytes: [4]u8 = undefined;
        self.passed = self.queue.read(&bytes) == 0 and std.mem.eql(u8, &bytes, &.{ 0, 0, 0, 0 });
        self.passed = self.passed and (self.queue.dequeue(a) catch unreachable) == null;
        const append = self.queue.enqueue(8, &.{ 5, 6 });
        self.passed = self.passed and append == .enqueued;
        self.passed = self.passed and self.queue.enqueue(9, &.{ 0, 0, 0, 0, 0 }) == .lease_conflict;
        if (self.reset) self.queue.reset();
        if (self.close) self.queue.close();
    }
};
test "audio pinned head permits disjoint append and defers reset close through allocation failure" {
    for (0..3) |mode| {
        var queue = try r.Ring.init(a, .{ .bytes = 8, .slots = 3 }, false);
        defer queue.deinit();
        _ = queue.enqueue(4, &.{ 1, 2, 3, 4 });
        var probe: LeaseProbe = .{ .queue = &queue, .reset = mode == 1, .close = mode == 2 };
        const packet = (try queue.dequeueObserved(a, .{ .context = &probe, .call = LeaseProbe.run })).?;
        defer packet.deinit();
        try t.expect(probe.passed);
        try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, packet.bytes);
        try t.expectEqual(@as(usize, if (mode == 0) 2 else 0), queue.diagnostics().queued_bytes);
        try t.expectEqual(@as(u64, 1), queue.diagnostics().lease_finishes);
    }
    var queue = try r.Ring.init(a, .{ .bytes = 8, .slots = 3 }, false);
    defer queue.deinit();
    _ = queue.enqueue(4, &.{ 1, 2, 3, 4 });
    var probe: LeaseProbe = .{ .queue = &queue, .reset = true, .close = true };
    var fail = t.FailingAllocator.init(a, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, queue.dequeueObserved(fail.allocator(), .{ .context = &probe, .call = LeaseProbe.run }));
    try t.expect(queue.diagnostics().closed);
    try t.expectEqual(@as(usize, 0), queue.diagnostics().queued_slots);
}
const StageProbe = struct {
    queue: *r.Ring,
    action: enum { read, reset, close, skip },
    seen: [8]u8 = @splat(0),
    copied: usize = 0,
    fn observe(raw: *anyopaque) void {
        const self: *StageProbe = @ptrCast(@alignCast(raw));
        switch (self.action) {
            .read => self.copied = self.queue.read(&self.seen),
            .reset => self.queue.reset(),
            .close => self.queue.close(),
            .skip => {},
        }
    }
    fn publish(self: *StageProbe, commit: *r.Ring.Commit) r.Result {
        if (self.action == .skip) return .{ .enqueued = .{} };
        const result = commit.publish();
        std.debug.assert(std.meta.eql(result, commit.publish()));
        return result;
    }
};
test "audio staged unpublished bytes leave render readable and reset close abort never revive old PCM" {
    for ([_]StageProbe{ .{ .queue = undefined, .action = .read }, .{ .queue = undefined, .action = .reset }, .{ .queue = undefined, .action = .close }, .{ .queue = undefined, .action = .skip } }) |input| {
        var queue = try r.Ring.init(a, .{ .bytes = 8, .slots = 2 }, true);
        defer queue.deinit();
        _ = queue.enqueue(1, &.{ 1, 2, 3, 4, 5, 6 });
        var probe = input;
        probe.queue = &queue;
        const result = queue.enqueueStaged(2, &.{ 7, 8, 9, 10 }, .{ .context = &probe, .call = StageProbe.observe }, &probe, StageProbe.publish);
        if (probe.action == .read) {
            try t.expectEqual(@as(usize, 6), probe.copied);
            try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 0, 0 }, &probe.seen);
        }
        if (probe.action == .close) {
            try t.expect(result == .closed);
            continue;
        }
        const packet = (try queue.dequeue(a)).?;
        defer packet.deinit();
        try t.expectEqualSlices(u8, if (probe.action == .skip) &.{ 1, 2, 3, 4, 5, 6 } else &.{ 7, 8, 9, 10 }, packet.bytes);
    }
    var queue = try r.Ring.init(a, .{ .bytes = 8, .slots = 3 }, true);
    defer queue.deinit();
    _ = queue.enqueue(1, &.{ 1, 2 });
    var probe: StageProbe = .{ .queue = &queue, .action = .reset };
    _ = queue.enqueueStaged(2, &.{ 7, 8 }, .{ .context = &probe, .call = StageProbe.observe }, &probe, StageProbe.publish);
    const packet = (try queue.dequeue(a)).?;
    defer packet.deinit();
    try t.expectEqualSlices(u8, &.{ 7, 8 }, packet.bytes);
}
test "audio playback startup overflow and partial underflow rearm without allocating in callback" {
    var playback = try b.Playback.init(a, .{ .bytes = 16, .slots = 8 }, 2, 1000, 4);
    defer playback.deinit();
    var out: [6]u8 = undefined;
    _ = playback.enqueue(1, &.{ 1, 2, 3, 4 });
    try t.expectEqual(@as(usize, 0), playback.render(&out));
    _ = playback.enqueue(2, &.{ 5, 6, 7, 8 });
    try t.expectEqual(@as(usize, 6), playback.render(&out));
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &out);
    try t.expectEqual(@as(usize, 2), playback.render(&out));
    try t.expectEqualSlices(u8, &.{ 7, 8, 0, 0, 0, 0 }, &out);
    _ = playback.enqueue(3, &.{ 1, 2 });
    try t.expectEqual(@as(usize, 0), playback.render(&out));
    playback.setMinimumStartup(0);
    try t.expectEqual(@as(usize, 2), playback.render(&out));
    _ = playback.enqueue(4, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    _ = playback.render(out[0..2]);
    playback.setMinimumStartup(8);
    const result = playback.enqueue(5, &.{ 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 });
    try t.expectEqual(@as(usize, 6), result.enqueued.dropped_bytes);
    try t.expectEqual(@as(usize, 0), playback.render(&out));
    playback.close();
    try t.expectEqual(@as(usize, 0), playback.render(&out));
}
fn captureAllocations(allocator: std.mem.Allocator) !void {
    var capture = try b.Capture.init(allocator, .{ .bytes = 8, .slots = 2 });
    defer capture.deinit();
    _ = capture.queue.enqueue(1, &.{ 1, 2 });
    _ = capture.queue.enqueue(2, &.{ 3, 4 });
    capture.fail(.converter);
    const drain = try capture.drain(allocator);
    defer drain.deinit();
    // A successfully returned partial drain is intentionally allowed on a later
    // packet OOM: all consumed bytes are owned by the returned result.
    try t.expect(drain.packets.len > 0);
    try t.expectEqual(b.CaptureFailure.converter, drain.failure.?);
}
test "capture drain owns consumed prefix and reports first failure and drop deltas once" {
    // Exhaustive allocator harness requires propagating every injected failure;
    // partial drains intentionally recover, so probe fail indices explicitly.
    for (0..10) |index| {
        var fail = t.FailingAllocator.init(a, .{ .fail_index = index });
        captureAllocations(fail.allocator()) catch |err| {
            try t.expectEqual(error.OutOfMemory, err);
        };
    }
    var capture = try b.Capture.init(a, .{ .bytes = 4, .slots = 2 });
    defer capture.deinit();
    _ = capture.queue.enqueue(1, &.{ 1, 2, 3 });
    _ = capture.queue.enqueue(2, &.{ 4, 5 });
    capture.fail(.converter);
    capture.fail(.invalid_input_storage);
    const first = try capture.drain(a);
    defer first.deinit();
    try t.expectEqual(@as(u64, 3), first.dropped_bytes);
    try t.expectEqual(b.CaptureFailure.converter, first.failure.?);
    const second = try capture.drain(a);
    defer second.deinit();
    try t.expectEqual(@as(u64, 0), second.dropped_bytes);
    try t.expect(second.failure == null);
}
