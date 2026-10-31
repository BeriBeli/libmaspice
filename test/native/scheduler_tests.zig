const std = @import("std");
const s = @import("spice");
const data = @import("video_data");
const t = std.testing;
const a = t.allocator;
extern "c" fn pthread_cond_timedwait_relative_np(*std.c.pthread_cond_t, *std.c.pthread_mutex_t, *const std.c.timespec) std.c.E;
const Probe = struct {
    mutex: s.sync.Mutex = .{},
    changed: s.sync.Condition = .{},
    hold: bool = true,
    count: usize = 0,
    failure: ?anyerror = null,
    fn sink(self: *Probe) s.stream_scheduler.Sink {
        return .{ .context = self, .publish = publish, .fail = fail };
    }
    fn wake(p: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(p));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.changed.broadcast();
    }
    fn publish(p: *anyopaque, _: s.surface.Revision, _: ?s.frame_publisher.Timing, token: *s.cancel.Token) !void {
        const self: *Probe = @ptrCast(@alignCast(p));
        var registration: s.cancel.Registration = .{ .context = self, .wake = wake };
        token.register(&registration);
        defer token.unregister(&registration);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.count += 1;
        self.changed.broadcast();
        while (self.hold) {
            try token.check();
            self.changed.wait(&self.mutex);
        }
        try token.check();
    }
    fn fail(p: *anyopaque, err: anyerror, _: *s.cancel.Token) void {
        const self: *Probe = @ptrCast(@alignCast(p));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.failure = err;
        self.changed.broadcast();
    }
    fn wait(self: *Probe, count: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.count < count and self.failure == null) {
            const timeout: std.c.timespec = .{ .sec = 5, .nsec = 0 };
            const result = pthread_cond_timedwait_relative_np(&self.changed.value, &self.mutex.value, &timeout);
            if (result == .TIMEDOUT) return error.TestTimeout;
            if (result != .SUCCESS) return error.WaitFailed;
        }
        if (self.failure) |err| return err;
    }
    fn release(self: *Probe) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.hold = false;
        self.changed.broadcast();
    }
    fn deinit(self: *Probe) void {
        self.changed.deinit();
        self.mutex.deinit();
    }
};
fn config(codec: s.stream_wire.Codec) s.stream_wire.Create {
    const size: u32 = if (codec == .mjpeg) 8 else 128;
    return .{ .surface = 1, .id = 0, .top_down = true, .codec = codec, .stamp = 0, .width = size, .height = size, .source_width = size, .source_height = size, .destination = .{ .x = 0, .y = 0, .width = size, .height = size }, .clips = null };
}
test "MJPEG replaces only pending input while reports count every arrival" {
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    try store.create(1, 8, 8, 32, &token);
    var pool: s.codec_executor.Executor = .{};
    defer pool.deinit();
    var probe: Probe = .{};
    defer probe.deinit();
    const queue = try s.stream_scheduler.Scheduler.create(a, &store, &pool, null, .{});
    defer queue.destroy();
    try queue.bind(probe.sink());
    try queue.add(config(.mjpeg));
    try queue.activateReport(.{ .streamID = 0, .uniqueID = 19, .maximumWindowSize = 4, .timeoutMilliseconds = 1000 });
    const payload = try s.bytes.Slice.copy(a, data.jpeg);
    defer payload.release();
    const invalid = try s.bytes.Slice.copy(a, &.{ 1, 2, 3 });
    defer invalid.release();
    _ = try queue.submit(0, payload, 0, null, 0);
    try probe.wait(1);
    _ = try queue.submit(0, invalid, 1, null, 1);
    _ = try queue.submit(0, invalid, 2, null, 2);
    const report = (try queue.submit(0, payload, 3, null, 3)).?;
    try t.expectEqual(@as(u32, 4), report.frameCount);
    try t.expectEqual(@as(u32, 19), report.uniqueID);
    probe.release();
    try queue.drain();
    try t.expectEqual(@as(usize, 2), probe.count);
    try t.expectEqual(@as(usize, 2), queue.superseded);
    try t.expect(probe.failure == null);
    queue.unbind();
    try t.expectEqual(@as(usize, 0), queue.bytes);
}
test "reference-coded queue preserves every frame and rebind preserves decoder session" {
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    try store.create(1, 128, 128, 32, &token);
    var pool: s.codec_executor.Executor = .{};
    defer pool.deinit();
    var probe: Probe = .{};
    defer probe.deinit();
    const queue = try s.stream_scheduler.Scheduler.create(a, &store, &pool, null, .{});
    defer queue.destroy();
    try queue.bind(probe.sink());
    try queue.add(config(.h264));
    const payload = try s.bytes.Slice.copy(a, data.baseline);
    defer payload.release();
    _ = try queue.submit(0, payload, 0, null, 0);
    try probe.wait(1);
    for (1..4) |i| _ = try queue.submit(0, payload, @intCast(i), null, i);
    probe.release();
    try queue.drain();
    try t.expectEqual(@as(usize, 4), probe.count);
    try t.expectEqual(@as(usize, 0), queue.superseded);
    queue.unbind();
    try queue.bind(probe.sink());
    _ = try queue.submit(0, payload, 4, null, 4);
    try queue.drain();
    try t.expectEqual(@as(usize, 5), probe.count);
    try t.expectEqual(@as(usize, 1), queue.slots[0].?.stream.backend.advanced.stats.sessions);
}
test "run cancellation drains bounded queue and releases blocked publication without stale events" {
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    try store.create(1, 128, 128, 32, &token);
    var pool: s.codec_executor.Executor = .{};
    defer pool.deinit();
    var probe: Probe = .{};
    defer probe.deinit();
    const queue = try s.stream_scheduler.Scheduler.create(a, &store, &pool, null, .{ .jobs = 2 });
    defer queue.destroy();
    try queue.bind(probe.sink());
    try queue.add(config(.h264));
    const payload = try s.bytes.Slice.copy(a, data.baseline);
    defer payload.release();
    _ = try queue.submit(0, payload, 0, null, 0);
    try probe.wait(1);
    _ = try queue.submit(0, payload, 1, null, 1);
    queue.cancelRun();
    queue.unbind();
    try t.expectEqual(@as(usize, 1), probe.count);
    try t.expectEqual(@as(usize, 0), queue.bytes);
    try t.expectEqual(@as(usize, 0), queue.jobs);
    probe.release();
    try queue.bind(probe.sink());
    _ = try queue.submit(0, payload, 2, null, 2);
    try queue.drain();
    try t.expectEqual(@as(usize, 2), probe.count);
}
test "stream retirement cancels blocked publication and allows same ID to be recreated" {
    var token: s.cancel.Token = .{};
    defer token.deinit();
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    try store.create(1, 8, 8, 32, &token);
    var pool: s.codec_executor.Executor = .{};
    defer pool.deinit();
    var probe: Probe = .{};
    defer probe.deinit();
    const queue = try s.stream_scheduler.Scheduler.create(a, &store, &pool, null, .{});
    defer queue.destroy();
    try queue.bind(probe.sink());
    try queue.add(config(.mjpeg));
    const payload = try s.bytes.Slice.copy(a, data.jpeg);
    defer payload.release();
    _ = try queue.submit(0, payload, 0, null, 0);
    try probe.wait(1);
    _ = try queue.submit(0, payload, 1, null, 1);
    try queue.remove(0);
    try t.expectEqual(@as(usize, 0), queue.jobs);
    probe.release();
    try queue.add(config(.mjpeg));
    _ = try queue.submit(0, payload, 2, null, 2);
    try queue.drain();
    try t.expectEqual(@as(usize, 2), probe.count);
}
