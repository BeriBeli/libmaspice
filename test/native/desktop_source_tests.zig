const std = @import("std");
const s = @import("spice");
const d = s.desktop_snapshot;
const source = s.desktop_source;
const t = std.testing;
const a = t.allocator;
const Hook = struct {
    demanded: bool = false,
    demand_count: usize = 0,
    ack_count: usize = 0,
    last: ?d.Revision = null,
    fail: bool = false,
    fn demand(p: *anyopaque, _: u64, _: d.Key, visible: bool) !void {
        const self: *Hook = @ptrCast(@alignCast(p));
        self.demanded = visible;
        self.demand_count += 1;
        if (self.fail) return error.InjectedFailure;
    }
    fn ack(p: *anyopaque, _: u64, revision: d.Revision) !void {
        const self: *Hook = @ptrCast(@alignCast(p));
        self.last = revision;
        self.ack_count += 1;
    }
    fn hooks(self: *Hook) source.Hooks {
        return .{ .context = self, .demand = demand, .acknowledge = ack };
    }
};
const Handler = struct {
    refs: usize = 0,
    received: usize = 0,
    latest: ?d.Snapshot = null,
    reenter: ?*source.Subscription = null,
    fn retain(p: *anyopaque) void {
        const self: *Handler = @ptrCast(@alignCast(p));
        self.refs += 1;
    }
    fn release(p: *anyopaque) void {
        const self: *Handler = @ptrCast(@alignCast(p));
        self.refs -= 1;
    }
    fn emit(p: *anyopaque, snapshot: d.Snapshot) void {
        const self: *Handler = @ptrCast(@alignCast(p));
        self.received += 1;
        if (self.latest) |v| v.deinit();
        self.latest = snapshot.clone();
        if (self.reenter) |sub| {
            self.reenter = null;
            sub.cancel();
        }
    }
    fn handler(self: *Handler) source.Handler {
        return .{ .context = self, .retain = retain, .release = release, .emit = emit };
    }
    fn deinit(self: *Handler) void {
        std.debug.assert(self.refs == 0);
        if (self.latest) |v| v.deinit();
    }
};
fn publish(store: *s.surface.Store, token: *s.cancel.Token, x: i64) !s.surface.Publication {
    const revision = (try store.fill(0, &.{.{ .x = x, .y = 1, .width = 1, .height = 1 }}, 0x123456, token)).?;
    const result = (try store.publicationSnapshot(revision)).?;
    result.commit();
    return result;
}
fn drain(sub: *source.Subscription) !void {
    if (try sub.next(false)) |v| v.deinit();
}
test "source visible demand releases hidden canonical frames and waits for fresh publication" {
    const owner = try source.Source.create(a, .{});
    defer owner.release();
    var hooks: Hook = .{};
    try owner.bind(hooks.hooks());
    const sub = try owner.subscribe(.{});
    defer sub.destroy();
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(0, 10, 10, 32, &token);
    try owner.begin(.absolute, false, false);
    try sub.setDemand(true);
    try t.expect(hooks.demanded);
    try drain(sub);
    const first = try publish(&store, &token, 1);
    defer first.release();
    try owner.receiveFrame(0, first);
    const received = (try sub.next(false)).?;
    defer received.deinit();
    try t.expectEqual(@as(usize, 1), hooks.ack_count);
    try t.expect(received.frame.?.damage.isFull());
    try sub.setDemand(false);
    try t.expect(!hooks.demanded);
    try t.expectEqual(@as(usize, 0), owner.frame_bytes);
    try sub.setDemand(true);
    try t.expect((try sub.next(false)) == null);
    const second = try publish(&store, &token, 2);
    defer second.release();
    try owner.receiveFrame(0, second);
    const fresh = (try sub.next(false)).?;
    defer fresh.deinit();
    try t.expectEqual(second.snapshot().revision, fresh.frame.?.revision().surface);
    try owner.updateCursor(.{ .visible = true, .position = .{ .x = 8, .y = 9 } });
    const cursor = (try sub.next(false)).?;
    defer cursor.deinit();
    try t.expect(cursor.frame.?.damage.isEmpty());
    try t.expectEqual(fresh.frame.?.sequence, cursor.frame.?.sequence);
    try owner.updatePointer(.relative);
    const pointer = (try sub.next(false)).?;
    defer pointer.deinit();
    try t.expectEqual(.relative, pointer.pointer);
}
test "handlers suppress autoack shared visible subscribers get full frame and callback can cancel" {
    const owner = try source.Source.create(a, .{});
    defer owner.release();
    var hooks: Hook = .{};
    try owner.bind(hooks.hooks());
    var handler: Handler = .{};
    defer handler.deinit();
    const first = try owner.subscribe(.{});
    defer first.destroy();
    const second = try owner.subscribe(.{});
    defer second.destroy();
    const wrong = try owner.subscribe(.{ .channel = 1 });
    defer wrong.destroy();
    try first.setHandler(handler.handler());
    try first.setDemand(true);
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(0, 10, 10, 32, &token);
    const frame = try publish(&store, &token, 1);
    defer frame.release();
    try owner.receiveFrame(0, frame);
    try t.expectEqual(@as(usize, 0), hooks.ack_count);
    try t.expect((try first.next(false)) == null);
    try second.setDemand(true);
    const shared = (try second.next(false)).?;
    defer shared.deinit();
    try t.expect(shared.frame.?.damage.isFull());
    try wrong.acknowledge(shared.frame.?.revision());
    try t.expectEqual(@as(usize, 0), hooks.ack_count);
    try first.acknowledge(shared.frame.?.revision());
    try t.expectEqual(@as(usize, 1), hooks.ack_count);
    try first.setHandler(null);
    try t.expectEqual(@as(usize, 2), hooks.ack_count);
    try t.expectEqual(@as(usize, 0), handler.refs);
    try first.setHandler(handler.handler());
    handler.reenter = first;
    try first.requestLatest();
    try t.expectEqual(@as(usize, 0), handler.refs);
    try t.expect(hooks.demanded);
    try t.expectEqual(@as(usize, 1), owner.metrics().visible);
    second.cancel();
    try t.expect(!hooks.demanded);
}
test "source migration preserves static frames and switch guest clears pending data" {
    const owner = try source.Source.create(a, .{});
    defer owner.release();
    const sub = try owner.subscribe(.{});
    defer sub.destroy();
    try sub.setDemand(true);
    try drain(sub);
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(0, 10, 10, 32, &token);
    const frame = try publish(&store, &token, 1);
    defer frame.release();
    try owner.receiveFrame(0, frame);
    try drain(sub);
    try owner.begin(.relative, true, false);
    const migrated = (try sub.next(false)).?;
    defer migrated.deinit();
    try t.expect(migrated.frame.?.damage.isFull());
    try t.expectEqual(.relative, migrated.pointer);
    try sub.requestLatest();
    const redraw = (try sub.next(false)).?;
    defer redraw.deinit();
    try t.expectEqual(migrated.frame.?.sequence, redraw.frame.?.sequence);
    try t.expect(redraw.stamp.sequence > migrated.stamp.sequence);
    try owner.begin(.absolute, false, false);
    const replaced = (try sub.next(false)).?;
    defer replaced.deinit();
    try t.expect(replaced.frame == null);
    try t.expect(replaced.stamp.generation > migrated.stamp.generation);
    try owner.receiveFrame(0, frame);
    try owner.surfaceDestroyed(.{});
    const destroyed = (try sub.next(false)).?;
    defer destroyed.deinit();
    try t.expect(destroyed.frame == null);
}
test "subscription retains source and stream coalesces pending damage" {
    const owner = try source.Source.create(a, .{});
    const sub = try owner.subscribe(.{});
    defer sub.destroy();
    owner.release();
    try sub.setDemand(true);
    try sub.source.updatePointer(.relative);
    try sub.source.updateCursor(.{ .position = .{ .x = 3, .y = 4 } });
    const next = (try sub.next(false)).?;
    defer next.deinit();
    try t.expectEqual(.relative, next.pointer);
    try t.expectEqual(@as(i16, 3), next.cursor.?.position.x);
    try t.expectEqual(@as(u64, 2), sub.source.metrics().coalesced);
}
test "synthetic hidden frame stays retained and handler receives immediate full update" {
    const owner = try source.Source.create(a, .{});
    defer owner.release();
    var handler: Handler = .{};
    defer handler.deinit();
    const sub = try owner.subscribe(.{});
    defer sub.destroy();
    try owner.begin(.absolute, false, true);
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(0, 10, 10, 32, &token);
    const frame = try publish(&store, &token, 1);
    defer frame.release();
    try owner.receiveFrame(0, frame);
    try sub.setDemand(true);
    try drain(sub);
    try sub.setHandler(handler.handler());
    try t.expectEqual(@as(usize, 1), handler.received);
    try t.expect(handler.latest.?.frame.?.damage.isFull());
    try sub.setDemand(false);
    try t.expectEqual(@as(usize, 400), owner.frame_bytes);
    try sub.setDemand(true);
    try t.expectEqual(@as(usize, 2), handler.received);
}
fn allocations(alloc: std.mem.Allocator) !void {
    const owner = try source.Source.create(alloc, .{});
    defer owner.release();
    var handler: Handler = .{};
    defer handler.deinit();
    const sub = try owner.subscribe(.{});
    defer sub.destroy();
    try sub.setDemand(true);
    try sub.setHandler(handler.handler());
    try owner.begin(.absolute, false, false);
    try owner.updateCursor(.{ .visible = true });
    try owner.updatePointer(.relative);
    try sub.requestLatest();
    try owner.surfaceDestroyed(.{});
    try sub.setDemand(false);
    try sub.setHandler(null);
}
test "desktop source allocation failures release source subscription snapshots and callback contexts" {
    try t.checkAllAllocationFailures(a, allocations, .{});
}
test "bounded source rejects subscription surface and canonical frame excess" {
    const owner = try source.Source.create(a, .{ .maximum_subscriptions = 1, .maximum_surfaces = 1, .maximum_frame_bytes = 399 });
    defer owner.release();
    const sub = try owner.subscribe(.{});
    defer sub.destroy();
    try t.expectError(error.SubscriptionLimit, owner.subscribe(.{}));
    sub.cancel();
    try t.expectError(error.DesktopSurfaceLimit, owner.subscribe(.{ .channel = 1 }));
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(0, 10, 10, 32, &token);
    const frame = try publish(&store, &token, 1);
    defer frame.release();
    try t.expectError(error.DesktopFrameBudget, owner.receiveFrame(0, frame));
    try t.expectEqual(@as(usize, 0), owner.frame_bytes);
}
test "demand replay includes false states and hook failure remains visible during safe cleanup" {
    const owner = try source.Source.create(a, .{});
    defer owner.release();
    const sub = try owner.subscribe(.{});
    defer sub.destroy();
    try sub.setDemand(true);
    var hooks: Hook = .{};
    try owner.bind(hooks.hooks());
    try t.expect(hooks.demanded);
    owner.unbind();
    try sub.setDemand(false);
    try owner.bind(hooks.hooks());
    try t.expect(!hooks.demanded);
    hooks.fail = true;
    try t.expectError(error.InjectedFailure, sub.setDemand(true));
    try t.expectError(error.InjectedFailure, owner.status());
    sub.cancel();
    try t.expect(!hooks.demanded);
    owner.unbind();
}

const DemandRace = struct {
    mutex: s.sync.Mutex = .{},
    changed: s.sync.Condition = .{},
    entered: bool = false,
    released: bool = false,
    demanded: bool = false,
    fn demand(p: *anyopaque, _: u64, _: d.Key, visible: bool) !void {
        const self: *DemandRace = @ptrCast(@alignCast(p));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (visible) {
            self.entered = true;
            self.changed.broadcast();
            while (!self.released) self.changed.wait(&self.mutex);
        }
        self.demanded = visible;
    }
    fn ack(_: *anyopaque, _: u64, _: d.Revision) !void {}
    fn show(sub: *source.Subscription) void {
        sub.setDemand(true) catch unreachable;
    }
    fn cancelSub(sub: *source.Subscription) void {
        sub.cancel();
    }
    fn release(self: *DemandRace) void {
        self.mutex.lock();
        self.released = true;
        self.changed.broadcast();
        self.mutex.unlock();
    }
};
test "concurrent cancellation cannot leave late visibility demand enabled" {
    const owner = try source.Source.create(a, .{});
    defer owner.release();
    var race: DemandRace = .{};
    defer race.mutex.deinit();
    defer race.changed.deinit();
    try owner.bind(.{ .context = &race, .demand = DemandRace.demand, .acknowledge = DemandRace.ack });
    const sub = try owner.subscribe(.{});
    defer sub.destroy();
    const showing = try std.Thread.spawn(.{}, DemandRace.show, .{sub});
    defer showing.join();
    defer race.release();
    race.mutex.lock();
    while (!race.entered) race.changed.wait(&race.mutex);
    race.mutex.unlock();
    const cancelling = try std.Thread.spawn(.{}, DemandRace.cancelSub, .{sub});
    race.release();
    cancelling.join();
    try t.expect(!race.demanded);
    try t.expectEqual(@as(usize, 0), owner.metrics().subscriptions);
}
const Waiter = struct {
    sub: *source.Subscription,
    result: bool = false,
    fn run(self: *Waiter) void {
        const value = self.sub.next(true) catch unreachable;
        self.result = value == null;
        if (value) |v| v.deinit();
    }
};
test "subscription cancellation wakes a blocked stream and guest identity fences stale ACK" {
    const owner = try source.Source.create(a, .{});
    defer owner.release();
    var hooks: Hook = .{};
    try owner.bind(hooks.hooks());
    const sub = try owner.subscribe(.{});
    defer sub.destroy();
    var waiter: Waiter = .{ .sub = sub };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&waiter});
    sub.cancel();
    thread.join();
    try t.expect(waiter.result);
    const other = try owner.subscribe(.{});
    defer other.destroy();
    try other.setDemand(true);
    try owner.begin(.absolute, false, false);
    const old: d.Revision = .{ .session = owner.session, .channel = 0, .surface = .{ .id = 0, .lifecycle = 1, .value = 1 } };
    try owner.begin(.absolute, false, false);
    try other.acknowledge(old);
    try t.expectEqual(@as(usize, 0), hooks.ack_count);
}

fn frameAllocations(alloc: std.mem.Allocator, publication: s.surface.Publication) !void {
    const owner = try source.Source.create(alloc, .{});
    defer owner.release();
    const sub = try owner.subscribe(.{});
    defer sub.destroy();
    try sub.setDemand(true);
    try owner.receiveFrame(0, publication);
    try owner.updateCursor(.{ .visible = true });
    try owner.begin(.relative, true, false);
    try owner.receiveFrame(1, publication);
    try owner.begin(.absolute, false, false);
    try owner.receiveFrame(0, publication);
    try owner.surfaceDestroyed(.{});
}
test "source frame retention and migration unwind every allocation failure" {
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(0, 10, 10, 32, &token);
    const frame = try publish(&store, &token, 1);
    defer frame.release();
    try t.checkAllAllocationFailures(a, frameAllocations, .{frame});
}

test "source trace preserves original timing and retires hidden surface evidence" {
    const owner = try source.Source.create(a, .{});
    defer owner.release();
    const sub = try owner.subscribe(.{});
    defer sub.destroy();
    try owner.begin(.absolute, false, false);
    try sub.setDemand(true);
    try drain(sub);
    const capture = try s.interaction_capture.Capture.create(a, owner.traces, .{ .pair_id = "p", .version = "z", .run_id = "r", .order = 1, .action = .key, .token = "0123456789abcdef", .checksum = 0xaabbccdd }, "unused-trace-output.jsonl");
    defer capture.destroy();
    try capture.hostInput(1, 2, 3);
    var store = s.surface.Store.init(a, .{}, null);
    defer store.deinit();
    var token: s.cancel.Token = .{};
    defer token.deinit();
    try store.create(0, 10, 10, 32, &token);
    const publication = try publish(&store, &token, 1);
    defer publication.release();
    try owner.receiveFrameTimed(0, publication, .{ .received_ns = 4, .ready_ns = 5 });
    const snapshot = (try sub.next(false)).?;
    defer snapshot.deinit();
    const id = s.interaction_trace.Identity.from(snapshot).?;
    owner.traces.selected(id, 6, 7);
    try owner.updateCursor(.{ .visible = true });
    const cursor_snapshot = (try sub.next(false)).?;
    defer cursor_snapshot.deinit();
    try t.expectEqual(id, s.interaction_trace.Identity.from(cursor_snapshot).?);
    try t.expectEqual(@as(u64, 4), cursor_snapshot.frame.?.timing.?.received_ns);
    try sub.setDemand(false);
    try t.expectEqual(@as(usize, 0), owner.frame_bytes);
    try owner.surfaceDestroyed(.{});
    const encoded = try capture.assembler.finishEncoded(a, null);
    defer a.free(encoded);
    const record = try s.interaction_record.decode(a, encoded);
    defer record.deinit();
    try t.expectEqualStrings("surface_lifecycle_retired", record.value.invalid_reason.?);
    try t.expectEqual(@as(?u64, 4), record.value.display_receive_ns);
    owner.diagnostics.presented(true, null);
    const epoch = owner.diagnostics.currentEpoch();
    try owner.begin(.absolute, true, false);
    try t.expectEqual(epoch, owner.diagnostics.currentEpoch());
    try t.expectEqual(@as(u64, 1), owner.diagnostics.snapshot().count(.metal_presented));
}
