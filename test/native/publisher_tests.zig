const std = @import("std");
const s = @import("spice");
const t = std.testing;
const a = t.allocator;
extern "c" fn pthread_cond_timedwait_relative_np(*std.c.pthread_cond_t, *std.c.pthread_mutex_t, *const std.c.timespec) std.c.E;
const Harness = struct {
    store: *s.surface.Store,
    mutex: s.sync.Mutex = .{},
    changed: s.sync.Condition = .{},
    frames: [32]?s.frame_publisher.Published = @splat(null),
    count: usize = 0,
    started: usize = 0,
    finished: usize = 0,
    active: usize = 0,
    maximum_active: usize = 0,
    blocked_id: ?u32 = null,
    block_after: bool = false,
    released: bool = false,
    gate_entered: bool = false,
    block_emit: bool = false,
    emit_entered: bool = false,
    failed: ?anyerror = null,
    fn deinit(self: *Harness) void {
        for (self.frames) |frame| if (frame) |v| v.deinit();
        self.changed.deinit();
        self.mutex.deinit();
    }
    fn wake(p: *anyopaque) void {
        const self: *Harness = @ptrCast(@alignCast(p));
        self.mutex.lock();
        self.changed.broadcast();
        self.mutex.unlock();
    }
    fn gate(self: *Harness, token: *s.cancel.Token) !void {
        var registration: s.cancel.Registration = .{ .context = self, .wake = wake };
        token.register(&registration);
        defer token.unregister(&registration);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.gate_entered = true;
        self.changed.broadcast();
        while (!self.released and !token.cancelled.load(.acquire)) self.changed.wait(&self.mutex);
        try token.check();
    }
    fn snapshot(p: *anyopaque, revision: s.surface.Revision, token: *s.cancel.Token) !?s.surface.Publication {
        const self: *Harness = @ptrCast(@alignCast(p));
        self.mutex.lock();
        self.started += 1;
        self.active += 1;
        self.maximum_active = @max(self.maximum_active, self.active);
        const blocked = self.blocked_id == revision.id;
        const after = self.block_after;
        self.changed.broadcast();
        self.mutex.unlock();
        defer {
            self.mutex.lock();
            self.finished += 1;
            self.active -= 1;
            self.changed.broadcast();
            self.mutex.unlock();
        }
        if (blocked and !after) try self.gate(token);
        try token.check();
        const frame = try self.store.publicationSnapshot(revision);
        errdefer if (frame) |v| v.release();
        if (blocked and after) try self.gate(token);
        try token.check();
        return frame;
    }
    fn emit(p: *anyopaque, frame: s.frame_publisher.Published, token: *s.cancel.Token) !void {
        const self: *Harness = @ptrCast(@alignCast(p));
        errdefer frame.deinit();
        self.mutex.lock();
        self.emit_entered = true;
        const block = self.block_emit;
        self.changed.broadcast();
        self.mutex.unlock();
        if (block) try self.gate(token);
        try token.check();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.count == self.frames.len) return error.TestOverflow;
        self.frames[self.count] = frame;
        self.count += 1;
        self.changed.broadcast();
    }
    fn fail(p: *anyopaque, err: anyerror, _: *s.cancel.Token) void {
        const self: *Harness = @ptrCast(@alignCast(p));
        self.mutex.lock();
        self.failed = err;
        self.changed.broadcast();
        self.mutex.unlock();
    }
    fn release(self: *Harness) void {
        self.mutex.lock();
        self.released = true;
        self.changed.broadcast();
        self.mutex.unlock();
    }
    fn wait(self: *Harness, kind: enum { started, finished, emit, gate }, number: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (switch (kind) {
            .started => self.started < number,
            .finished => self.finished < number,
            .emit => !self.emit_entered,
            .gate => !self.gate_entered,
        }) {
            const result = pthread_cond_timedwait_relative_np(&self.changed.value, &self.mutex.value, &.{ .sec = 3, .nsec = 0 });
            if (result != .SUCCESS) return error.TestTimeout;
        }
    }
    fn publisher(self: *Harness, options: s.frame_publisher.Options) !*s.frame_publisher.Publisher {
        const result = try s.frame_publisher.Publisher.create(a, .{ .context = self, .snapshot = snapshot }, options);
        errdefer result.destroy();
        try result.bind(.{ .context = self, .emit = emit, .fail = fail });
        return result;
    }
};
const Flush = struct {
    publisher: *s.frame_publisher.Publisher,
    failure: ?anyerror = null,
    fn run(self: *Flush) void {
        self.publisher.flushNow() catch |err| {
            self.failure = err;
        };
    }
};
fn surfaceRevision(store: *s.surface.Store, id: u32) !s.surface.Revision {
    const frame = try store.snapshot(id);
    defer frame.deinit();
    return frame.revision;
}
fn setup(store: *s.surface.Store, count: u32, token: *s.cancel.Token) !void {
    for (1..count + 1) |i| try store.create(@intCast(i), 8, 4, 32, token);
}
const slow = s.frame_publisher.Options{ .interval_ns = 60_000_000_000 };
test "publisher demand coalescing consumption gating and full redraw after hidden resume" {
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try setup(&store, 1, &token);
    var harness: Harness = .{ .store = &store };
    defer harness.deinit();
    var options = slow;
    options.requires_demand = true;
    options.waits_consumption = true;
    const publisher = try harness.publisher(options);
    defer publisher.destroy();
    const first = try surfaceRevision(&store, 1);
    try publisher.submit(first, null);
    try publisher.flushNow();
    try t.expectEqual(@as(usize, 0), harness.count);
    try t.expectEqual(@as(u64, 0), publisher.metrics().snapshots);
    try publisher.setDemand(1, true);
    try publisher.flushNow();
    try t.expectEqual(@as(usize, 1), harness.count);
    _ = try store.fill(1, &.{.{ .x = 0, .y = 0, .width = 1, .height = 1 }}, 0x112233, &token);
    const newest = (try store.fill(1, &.{.{ .x = 2, .y = 1, .width = 1, .height = 1 }}, 0x445566, &token)).?;
    try publisher.submit(newest, .{ .received_ns = 10, .ready_ns = 20 });
    try publisher.flushNow();
    try t.expectEqual(@as(usize, 1), harness.count);
    publisher.acknowledge(first);
    try publisher.flushNow();
    try t.expectEqual(@as(usize, 2), harness.count);
    try t.expectEqual(newest, harness.frames[1].?.frame.snapshot().revision);
    try t.expectEqual(@as(u64, 10), harness.frames[1].?.timing.?.received_ns);
    try publisher.setDemand(1, false);
    try publisher.flushNow();
    try publisher.setDemand(1, true);
    try publisher.flushNow();
    try t.expectEqual(@as(usize, 3), harness.count);
    try t.expect(harness.frames[2].?.frame.damage().isFull());
    try publisher.submit(newest, null);
    try publisher.flushNow();
    try t.expectEqual(@as(usize, 3), harness.count);
    const metrics = publisher.metrics();
    try t.expectEqual(@as(u64, 3), metrics.submissions);
    try t.expectEqual(@as(u64, 3), metrics.snapshots);
    try t.expectEqual(@as(u64, 3), metrics.emitted_cpu);
    try t.expectEqual(@as(u64, 0), metrics.emitted_native);
    try t.expectEqual(@as(u64, 7), metrics.flushes);
    try t.expectEqual(@as(u64, 4), metrics.empty_flushes);
    try t.expectEqual(@as(u64, 1), metrics.prepared_coalesces);
    try t.expectEqual(@as(usize, 0), metrics.pending);
    try t.expectEqual(@as(usize, 1), metrics.demanded);
    try t.expectEqual(@as(usize, 1), metrics.prepared);
    try t.expectEqual(@as(u64, 1), metrics.receive_to_ready.count);
    try t.expectEqual(@as(u64, 1), metrics.ready_to_submit.count);
    try t.expectEqual(@as(u64, 6), metrics.flush_start_gap.count);
    try t.expectEqual(@as(u64, 7), metrics.flush_scheduling_delay.count);
    try t.expectEqual(@as(u64, 3), metrics.snapshot_duration.count);
    try t.expectEqual(@as(u64, 3), metrics.emit_duration.count);
    var combined: s.frame_publisher.Metrics = .{};
    combined.accumulate(metrics);
    combined.accumulate(metrics);
    try t.expectEqual(@as(u64, 6), combined.emitted_cpu);
    try t.expectEqual(@as(u64, 6), combined.emit_duration.count);
}
test "publisher snapshots two independent surfaces concurrently refills slots and emits in order" {
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try setup(&store, 3, &token);
    var harness: Harness = .{ .store = &store, .blocked_id = 1 };
    defer harness.deinit();
    const publisher = try harness.publisher(slow);
    defer publisher.destroy();
    for (1..4) |id| try publisher.submit(try surfaceRevision(&store, @intCast(id)), null);
    var flush: Flush = .{ .publisher = publisher };
    const thread = try std.Thread.spawn(.{}, Flush.run, .{&flush});
    var joined = false;
    defer if (!joined) {
        publisher.cancelRun();
        harness.release();
        thread.join();
    };
    try harness.wait(.started, 3);
    try harness.wait(.finished, 2);
    harness.release();
    thread.join();
    joined = true;
    try t.expect(flush.failure == null);
    try t.expect(harness.maximum_active > 0 and harness.maximum_active <= 2);
    try t.expectEqual(@as(usize, 3), harness.count);
    for (0..3) |i| try t.expectEqual(@as(u32, @intCast(i + 1)), harness.frames[i].?.frame.snapshot().revision.id);
}
test "publisher cancellation during ordered emit joins snapshots and restores every uncommitted damage lease" {
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try setup(&store, 3, &token);
    var harness: Harness = .{ .store = &store, .block_emit = true };
    defer harness.deinit();
    const publisher = try harness.publisher(slow);
    defer publisher.destroy();
    for (1..4) |id| try publisher.submit(try surfaceRevision(&store, @intCast(id)), null);
    var flush: Flush = .{ .publisher = publisher };
    const thread = try std.Thread.spawn(.{}, Flush.run, .{&flush});
    defer thread.join();
    defer publisher.cancelRun();
    try harness.wait(.emit, 1);
    publisher.unbind();
    try t.expectEqual(@as(usize, 0), harness.count);
    for (1..4) |id| {
        const restored = (try store.publicationSnapshot(try surfaceRevision(&store, @intCast(id)))).?;
        defer restored.release();
        try t.expect(restored.damage().isFull());
        restored.commit();
    }
}
test "publisher newer snapshot uses exact replacement timing and rejects unsubmitted intermediate revisions" {
    for ([_]bool{ true, false }) |submit_replacement| {
        var store = s.surface.Store.init(a, .{}, null);
        defer store.deinit();
        var token: s.cancel.Token = .{};
        defer token.deinit();
        try setup(&store, 1, &token);
        var harness: Harness = .{ .store = &store, .blocked_id = 1 };
        defer harness.deinit();
        const publisher = try harness.publisher(slow);
        defer publisher.destroy();
        const first = try surfaceRevision(&store, 1);
        try publisher.submit(first, .{ .received_ns = 1, .ready_ns = 2 });
        var flush: Flush = .{ .publisher = publisher };
        const thread = try std.Thread.spawn(.{}, Flush.run, .{&flush});
        var joined = false;
        defer if (!joined) {
            publisher.cancelRun();
            harness.release();
            thread.join();
        };
        try harness.wait(.started, 1);
        const newer = (try store.fill(1, &.{.{ .x = 1, .y = 1, .width = 1, .height = 1 }}, 0xabcdef, &token)).?;
        if (submit_replacement) try publisher.submit(newer, .{ .received_ns = 3, .ready_ns = 4 });
        harness.release();
        thread.join();
        joined = true;
        try t.expect(flush.failure == null);
        try t.expectEqual(@as(usize, if (submit_replacement) 1 else 0), harness.count);
        if (!submit_replacement) {
            try publisher.submit(newer, .{ .received_ns = 3, .ready_ns = 4 });
            try publisher.flushNow();
        }
        try t.expectEqual(newer, harness.frames[0].?.frame.snapshot().revision);
        try t.expectEqual(@as(u64, 3), harness.frames[0].?.timing.?.received_ns);
        try publisher.submit(newer, null);
        try publisher.flushNow();
        try t.expectEqual(@as(usize, 1), harness.count);
    }
}
test "publisher discards captured old lifecycle and retains explicit demand across same-ID recreation" {
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try setup(&store, 1, &token);
    var harness: Harness = .{ .store = &store, .blocked_id = 1, .block_after = true };
    defer harness.deinit();
    var options = slow;
    options.requires_demand = true;
    const publisher = try harness.publisher(options);
    defer publisher.destroy();
    try publisher.setDemand(1, true);
    try publisher.submit(try surfaceRevision(&store, 1), null);
    var flush: Flush = .{ .publisher = publisher };
    const thread = try std.Thread.spawn(.{}, Flush.run, .{&flush});
    var joined = false;
    defer if (!joined) {
        publisher.cancelRun();
        harness.release();
        thread.join();
    };
    try harness.wait(.gate, 1);
    try store.destroy(1, &token);
    try publisher.remove(1);
    try store.create(1, 4, 4, 32, &token);
    const recreated = try surfaceRevision(&store, 1);
    try publisher.submit(recreated, null);
    harness.release();
    thread.join();
    joined = true;
    try t.expect(flush.failure == null);
    try t.expectEqual(@as(usize, 0), harness.count);
    try publisher.flushNow();
    try t.expectEqual(@as(usize, 1), harness.count);
    try t.expectEqual(recreated, harness.frames[0].?.frame.snapshot().revision);
}

fn publisherAllocationFailures(alloc: std.mem.Allocator) !void {
    var store = s.surface.Store.init(alloc, .{}, null);
    defer store.deinit();
    var harness: Harness = .{ .store = &store };
    defer harness.deinit();
    var options = slow;
    options.maximum_pending = 2;
    options.maximum_surfaces = 3;
    const publisher = try s.frame_publisher.Publisher.create(alloc, .{ .context = &harness, .snapshot = Harness.snapshot }, options);
    defer publisher.destroy();
    try publisher.bind(.{ .context = &harness, .emit = Harness.emit, .fail = Harness.fail });
    for (1..4) |id| try publisher.submit(.{ .id = @intCast(id), .lifecycle = 1, .value = 1 }, null);
    try t.expectEqual(@as(u64, 1), publisher.metrics().evictions);
    try t.expectError(error.PublisherSurfaceLimit, publisher.setDemand(4, true));
}
test "publisher creation pending eviction and state allocation failures join every started worker" {
    try t.checkAllAllocationFailures(a, publisherAllocationFailures, .{});
}
