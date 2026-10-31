//! Multi-subscriber desktop state. Source owns canonical snapshots; subscriptions
//! retain Source, and each stream owns at most one coalesced snapshot. UI handlers
//! run outside the state lock with retained callback contexts and borrowed snapshots.
//! Hooks only enqueue publisher demand/ACK work: they run under the state mutex,
//! MUST NOT call Source, wait for publications, or invoke user code. This makes
//! demand/cancel linearizable and avoids a late visibility update reviving demand.
const std = @import("std");
const d = @import("desktop_snapshot.zig");
const sync = @import("sync.zig");
const surface = @import("surface.zig");
const cursor = @import("cursor.zig");
const diagnostics = @import("presentation_diagnostics.zig");
const interaction = @import("interaction_capture.zig");
const Timing = @import("frame_publisher.zig").Timing;
pub const Hooks = struct {
    lifecycle: u64 = 0,
    context: *anyopaque,
    demand: *const fn (*anyopaque, u64, d.Key, bool) anyerror!void,
    acknowledge: *const fn (*anyopaque, u64, d.Revision) anyerror!void,
};
pub const Handler = struct {
    context: *anyopaque,
    retain: *const fn (*anyopaque) void,
    release: *const fn (*anyopaque) void,
    emit: *const fn (*anyopaque, d.Snapshot) void,
    fn clone(self: Handler) Handler {
        self.retain(self.context);
        return self;
    }
    fn deinit(self: Handler) void {
        self.release(self.context);
    }
};
const Entry = struct { frame: ?d.Frame = null, awaiting: bool = false, lifecycle: ?u64 = null };
const Subscriber = struct { key: d.Key, visible: bool = false, handler: ?Handler = null, pending: ?d.Snapshot = null };
const Delivery = struct { handler: Handler, snapshot: d.Snapshot };
const Deliveries = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Delivery) = .empty,
    fn emit(self: *Deliveries) void {
        for (self.items.items) |item| {
            item.handler.emit(item.handler.context, item.snapshot);
            item.snapshot.deinit();
            item.handler.deinit();
        }
        self.items.deinit(self.allocator);
    }
};
pub const Options = struct { maximum_subscriptions: usize = 256, maximum_surfaces: usize = 4096, maximum_frame_bytes: usize = 256 * 1024 * 1024 };
pub const Metrics = struct { delivered: u64 = 0, coalesced: u64 = 0, handler_deliveries: u64 = 0, subscriptions: usize = 0, visible: usize = 0 };
pub const Source = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    hooks: ?Hooks = null,
    failure: ?anyerror = null,
    options: Options,
    diagnostics: diagnostics.Recorder = .{},
    traces: *interaction.Registry,
    stamp: d.Stamp = .{ .generation = 0, .sequence = 0 },
    pointer: d.PointerMode = .absolute,
    current_cursor: ?cursor.Snapshot = null,
    synthetic: bool = false,
    next_id: u64 = 0,
    session: u64 = 0,
    frame_bytes: usize = 0,
    entries: std.AutoHashMapUnmanaged(d.Key, Entry) = .empty,
    subscribers: std.AutoHashMapUnmanaged(u64, Subscriber) = .empty,
    counts: Metrics = .{},
    pub fn create(a: std.mem.Allocator, options: Options) !*Source {
        if (options.maximum_subscriptions == 0 or options.maximum_subscriptions > 4096 or options.maximum_surfaces == 0 or options.maximum_surfaces > 65536 or options.maximum_frame_bytes == 0) return error.InvalidLimits;
        const self = try a.create(Source);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .options = options, .traces = try interaction.Registry.create(a) };
        return self;
    }
    pub fn retain(self: *Source) *Source {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *Source) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(self.subscribers.count() == 0);
        self.clearFrames();
        if (self.current_cursor) |c| c.deinit();
        self.entries.deinit(self.allocator);
        self.subscribers.deinit(self.allocator);
        self.traces.release();
        self.diagnostics.deinit();
        self.changed.deinit();
        self.mutex.deinit();
        self.allocator.destroy(self);
    }
    fn check(self: *Source) !void {
        if (self.failure) |err| return err;
    }
    pub fn status(self: *Source) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.check();
    }
    fn demand(self: *Source, key: d.Key, visible: bool) void {
        if (self.hooks) |h| h.demand(h.context, h.lifecycle, key, visible) catch |err| {
            if (self.failure == null) self.failure = err;
            self.changed.broadcast();
        };
    }
    fn acknowledge(self: *Source, revision: d.Revision) void {
        if (self.hooks) |h| h.acknowledge(h.context, h.lifecycle, revision) catch |err| {
            if (self.failure == null) self.failure = err;
            self.changed.broadcast();
        };
    }
    /// Binding borrows context until unbind/rebind returns. Replays all visible
    /// keys, including subscriptions created before a connection existed.
    pub fn bind(self: *Source, hooks: ?Hooks) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.check();
        self.hooks = hooks;
        if (hooks != null) {
            var it = self.entries.keyIterator();
            while (it.next()) |key| self.demand(key.*, self.visibility(key.*).count != 0);
        }
        try self.check();
    }
    /// Always usable during teardown, including after a terminal hook failure.
    pub fn unbind(self: *Source) void {
        self.mutex.lock();
        self.hooks = null;
        self.mutex.unlock();
    }
    fn entry(self: *Source, key: d.Key) !*Entry {
        if (self.entries.getPtr(key)) |v| return v;
        if (self.entries.count() >= self.options.maximum_surfaces) return error.DesktopSurfaceLimit;
        const result = try self.entries.getOrPut(self.allocator, key);
        result.value_ptr.* = .{};
        return result.value_ptr;
    }
    pub fn subscribe(self: *Source, key: d.Key) !*Subscription {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.check();
        if (self.subscribers.count() >= self.options.maximum_subscriptions) return error.SubscriptionLimit;
        const id = try std.math.add(u64, self.next_id, 1);
        const result = try self.allocator.create(Subscription);
        errdefer self.allocator.destroy(result);
        try self.subscribers.ensureUnusedCapacity(self.allocator, 1);
        _ = try self.entry(key);
        self.subscribers.putAssumeCapacity(id, .{ .key = key });
        self.next_id = id;
        result.* = .{ .source = self.retain(), .id = id };
        return result;
    }
    fn visibility(self: *Source, key: d.Key) struct { count: usize = 0, auto_ack: bool = false } {
        var count: usize = 0;
        var manual = false;
        var it = self.subscribers.valueIterator();
        while (it.next()) |sub| if (std.meta.eql(sub.key, key) and sub.visible) {
            count += 1;
            manual = manual or sub.handler != null;
        };
        return .{ .count = count, .auto_ack = count != 0 and !manual };
    }
    fn weight(frame: d.Frame) usize {
        const v = frame.publication.snapshot();
        return v.width * v.height * 4;
    }
    fn clearFrame(self: *Source, item: *Entry) void {
        if (item.frame) |f| {
            self.frame_bytes -= weight(f);
            f.deinit();
            item.frame = null;
        }
    }
    fn clearFrames(self: *Source) void {
        var it = self.entries.valueIterator();
        while (it.next()) |v| {
            self.clearFrame(v);
            v.awaiting = false;
            v.lifecycle = null;
        }
    }
    fn deliveries(self: *Source) !Deliveries {
        var batch: Deliveries = .{ .allocator = self.allocator };
        try batch.items.ensureTotalCapacity(self.allocator, self.subscribers.count());
        return batch;
    }
    fn authoritative(self: *Source, key: d.Key, full: bool) d.Snapshot {
        var result: d.Snapshot = .{ .stamp = self.stamp, .pointer = self.pointer };
        if (self.current_cursor) |c| result.cursor = c.clone();
        if (self.entries.get(key)) |v| if (v.frame) |f| {
            result.frame = f.clone();
            if (full) result.frame.?.damage.markFull();
        };
        return result;
    }
    /// Input snapshot is consumed; no allocation after the operation commits.
    fn deliver(self: *Source, sub: *Subscriber, snapshot: d.Snapshot, batch: *Deliveries) void {
        self.counts.delivered +|= 1;
        if (sub.handler) |h| {
            self.counts.handler_deliveries +|= 1;
            batch.items.appendAssumeCapacity(.{ .handler = h.clone(), .snapshot = snapshot });
        } else {
            if (sub.pending) |old| {
                const merged = d.Snapshot.merge(old, snapshot);
                old.deinit();
                snapshot.deinit();
                sub.pending = merged;
                self.counts.coalesced +|= 1;
            } else sub.pending = snapshot;
            self.changed.broadcast();
        }
    }
    fn deliverAll(self: *Source, batch: *Deliveries, full: bool) void {
        var it = self.subscribers.valueIterator();
        while (it.next()) |sub| if (sub.visible) self.deliver(sub, self.authoritative(sub.key, full), batch);
    }
    /// Caller controls session boundaries. Retain=true is the same-guest
    /// migration path; false retires every cached frame and pending fresh flag.
    pub fn begin(self: *Source, pointer: d.PointerMode, retain_frames: bool, synthetic: bool) !void {
        var batch: Deliveries = undefined;
        self.mutex.lock();
        {
            defer self.mutex.unlock();
            try self.check();
            const generation = try std.math.add(u64, self.stamp.generation, 1);
            const session = if (retain_frames) self.session else try std.math.add(u64, self.session, 1);
            const sequence = try std.math.add(u64, self.stamp.sequence, 1);
            batch = try self.deliveries();
            self.traces.retireDesktop(self.stamp.generation);
            self.stamp = .{ .generation = generation, .sequence = sequence };
            self.session = session;
            self.pointer = pointer;
            self.synthetic = synthetic;
            if (self.current_cursor) |c| c.deinit();
            self.current_cursor = null;
            if (!retain_frames) self.clearFrames();
            self.deliverAll(&batch, true);
        }
        batch.emit();
    }
    pub fn receiveFrame(self: *Source, channel: u8, publication: surface.Publication) !void {
        try self.receiveFrameTimed(channel, publication, null);
    }
    pub fn receiveFrameTimed(self: *Source, channel: u8, publication: surface.Publication, timing: ?Timing) !void {
        var batch: Deliveries = undefined;
        self.mutex.lock();
        {
            defer self.mutex.unlock();
            try self.check();
            const next = try std.math.add(u64, self.stamp.sequence, 1);
            const v = publication.snapshot();
            const key: d.Key = .{ .channel = channel, .surface = v.revision.id };
            const bytes = v.width * v.height * 4;
            const old_bytes = if (self.entries.get(key)) |old| if (old.frame) |f| weight(f) else @as(usize, 0) else 0;
            if (bytes > self.options.maximum_frame_bytes - (self.frame_bytes - old_bytes)) return error.DesktopFrameBudget;
            batch = try self.deliveries();
            const item = self.entry(key) catch |err| {
                batch.items.deinit(self.allocator);
                return err;
            };
            self.stamp.sequence = next;
            self.clearFrame(item);
            item.frame = .{ .session = self.session, .publication = publication.retain(), .channel = channel, .damage = publication.damage(), .sequence = next, .timing = timing };
            item.frame.?.damage.clear();
            item.awaiting = false;
            item.lifecycle = v.revision.lifecycle;
            self.frame_bytes += bytes;
            // Record once before handlers can select/commit this identity. ROI
            // reads are bounded and invoke no user code under the Source lock.
            self.traces.frame(.{ .stamp = self.stamp, .frame = item.frame }, if (timing) |tm| tm.received_ns else null, if (timing) |tm| tm.ready_ns else null);
            var it = self.subscribers.valueIterator();
            while (it.next()) |sub| if (sub.visible and std.meta.eql(sub.key, key)) {
                var update = self.authoritative(key, false);
                update.frame.?.damage = publication.damage();
                self.deliver(sub, update, &batch);
            };
            if (self.visibility(key).auto_ack) self.acknowledge(item.frame.?.revision());
        }
        batch.emit();
        try self.status();
    }
    pub fn surfaceDestroyed(self: *Source, key: d.Key) !void {
        var batch: Deliveries = undefined;
        self.mutex.lock();
        {
            defer self.mutex.unlock();
            try self.check();
            const next = try std.math.add(u64, self.stamp.sequence, 1);
            batch = try self.deliveries();
            self.stamp.sequence = next;
            if (self.entries.getPtr(key)) |v| {
                if (v.lifecycle) |generation| self.traces.retireSurface(key.channel, key.surface, generation);
                v.lifecycle = null;
                self.clearFrame(v);
                v.awaiting = false;
            }
            var it = self.subscribers.valueIterator();
            while (it.next()) |sub| if (sub.visible and std.meta.eql(sub.key, key)) self.deliver(sub, self.authoritative(key, false), &batch);
        }
        batch.emit();
    }
    pub fn updateCursor(self: *Source, value: ?cursor.Snapshot) !void {
        var batch: Deliveries = undefined;
        self.mutex.lock();
        {
            defer self.mutex.unlock();
            try self.check();
            const next = try std.math.add(u64, self.stamp.sequence, 1);
            batch = try self.deliveries();
            const owned = if (value) |v| v.clone() else null;
            if (self.current_cursor) |c| c.deinit();
            self.current_cursor = owned;
            self.stamp.sequence = next;
            self.deliverAll(&batch, false);
        }
        batch.emit();
    }
    pub fn updatePointer(self: *Source, pointer: d.PointerMode) !void {
        var batch: Deliveries = undefined;
        self.mutex.lock();
        {
            defer self.mutex.unlock();
            try self.check();
            const next = try std.math.add(u64, self.stamp.sequence, 1);
            batch = try self.deliveries();
            self.pointer = pointer;
            self.stamp.sequence = next;
            self.deliverAll(&batch, false);
        }
        batch.emit();
    }
    fn releaseHidden(self: *Source, key: d.Key) void {
        const visible = self.visibility(key);
        const item = self.entries.getPtr(key).?;
        if (visible.auto_ack) {
            if (item.frame) |f| self.acknowledge(f.revision());
        }
        if (visible.count == 0 and !self.synthetic) {
            if (item.frame != null) item.awaiting = true;
            self.clearFrame(item);
        }
    }
    fn setDemand(self: *Source, id: u64, visible: bool) !void {
        var batch: Deliveries = undefined;
        self.mutex.lock();
        {
            defer self.mutex.unlock();
            try self.check();
            const sub = self.subscribers.getPtr(id) orelse return;
            if (sub.visible == visible) return;
            batch = try self.deliveries();
            const before = self.visibility(sub.key).count;
            const entry_value = self.entries.get(sub.key).?;
            sub.visible = visible;
            const after = self.visibility(sub.key).count;
            if ((before == 0) != (after == 0)) self.demand(sub.key, after != 0);
            if (visible and (self.synthetic or before != 0 or (entry_value.frame == null and !entry_value.awaiting))) self.deliver(sub, self.authoritative(sub.key, true), &batch);
            if (!visible) self.releaseHidden(sub.key);
        }
        batch.emit();
        try self.status();
    }
    fn setHandler(self: *Source, id: u64, handler: ?Handler) !void {
        var batch: Deliveries = undefined;
        var old: ?Handler = null;
        self.mutex.lock();
        {
            defer self.mutex.unlock();
            try self.check();
            const sub = self.subscribers.getPtr(id) orelse return;
            batch = try self.deliveries();
            old = sub.handler;
            sub.handler = if (handler) |h| h.clone() else null;
            if (handler != null) {
                if (sub.pending) |v| v.deinit();
                sub.pending = null;
            }
            if (handler != null and sub.visible and self.synthetic) self.deliver(sub, self.authoritative(sub.key, true), &batch);
            if (handler == null and self.visibility(sub.key).auto_ack) if (self.entries.get(sub.key).?.frame) |f| self.acknowledge(f.revision());
        }
        if (old) |h| h.deinit();
        batch.emit();
        try self.status();
    }
    fn cancel(self: *Source, id: u64) void {
        self.mutex.lock();
        const sub = if (self.subscribers.fetchRemove(id)) |removed| removed.value else {
            self.mutex.unlock();
            return;
        };
        if (sub.visible and self.visibility(sub.key).count == 0) self.demand(sub.key, false);
        self.releaseHidden(sub.key);
        self.changed.broadcast();
        self.mutex.unlock();
        if (sub.pending) |v| v.deinit();
        if (sub.handler) |h| h.deinit();
    }
    fn requestLatest(self: *Source, id: u64) !void {
        var batch: Deliveries = undefined;
        self.mutex.lock();
        {
            defer self.mutex.unlock();
            try self.check();
            const sub = self.subscribers.getPtr(id) orelse return;
            if (!sub.visible) return;
            const next = try std.math.add(u64, self.stamp.sequence, 1);
            batch = try self.deliveries();
            self.stamp.sequence = next;
            self.deliver(sub, self.authoritative(sub.key, true), &batch);
        }
        batch.emit();
    }
    pub fn metrics(self: *Source) Metrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        var result = self.counts;
        result.subscriptions = self.subscribers.count();
        var it = self.subscribers.valueIterator();
        while (it.next()) |sub| if (sub.visible) {
            result.visible += 1;
        };
        return result;
    }
};
pub const Subscription = struct {
    source: *Source,
    id: u64,
    /// cancel wakes next; join blocked callers before destroy. A retained
    /// callback may finish after cancel, carrying its original generation stamp.
    pub fn cancel(self: *Subscription) void {
        self.source.cancel(self.id);
    }
    pub fn destroy(self: *Subscription) void {
        const owner = self.source;
        self.cancel();
        owner.allocator.destroy(self);
        owner.release();
    }
    pub fn setDemand(self: *Subscription, visible: bool) !void {
        try self.source.setDemand(self.id, visible);
    }
    pub fn setHandler(self: *Subscription, handler: ?Handler) !void {
        try self.source.setHandler(self.id, handler);
    }
    pub fn requestLatest(self: *Subscription) !void {
        try self.source.requestLatest(self.id);
    }
    pub fn acknowledge(self: *Subscription, revision: d.Revision) !void {
        const owner = self.source;
        owner.mutex.lock();
        defer owner.mutex.unlock();
        try owner.check();
        const sub = owner.subscribers.get(self.id) orelse return;
        if (revision.session == owner.session and sub.visible and sub.key.channel == revision.channel and sub.key.surface == revision.surface.id) owner.acknowledge(revision);
        try owner.check();
    }
    /// Owned stream snapshot. With wait=false, null also means no update yet.
    /// Handler subscriptions deliver only through their callback.
    pub fn next(self: *Subscription, wait: bool) !?d.Snapshot {
        const owner = self.source;
        owner.mutex.lock();
        defer owner.mutex.unlock();
        while (true) {
            try owner.check();
            const sub = owner.subscribers.getPtr(self.id) orelse return null;
            if (sub.pending) |snapshot| {
                sub.pending = null;
                return snapshot;
            }
            if (!wait) return null;
            owner.changed.wait(&owner.mutex);
        }
    }
};
