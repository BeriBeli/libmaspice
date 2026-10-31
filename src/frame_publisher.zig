//! Bounded demand-driven publication. Persistent snapshot workers prepare
//! independent surfaces concurrently; one coordinator emits in submission order.
//! Every uncommitted publication restores damage on discard/cancel. Sink.emit
//! consumes its publication on both success and failure and honors the token.
const std = @import("std");
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
const surface = @import("surface.zig");
const Histogram = @import("timing.zig").Histogram;
extern "c" fn pthread_cond_timedwait_relative_np(*std.c.pthread_cond_t, *std.c.pthread_mutex_t, *const std.c.timespec) std.c.E;
pub const Timing = struct { received_ns: u64, ready_ns: u64 };
pub const Published = struct {
    frame: surface.Publication,
    timing: ?Timing = null,
    pub fn deinit(self: Published) void {
        self.frame.release();
    }
    pub fn weight(self: Published) usize {
        const snapshot = self.frame.snapshot();
        return snapshot.width * snapshot.height * 4;
    }
};
pub const Provider = struct { context: *anyopaque, snapshot: *const fn (*anyopaque, surface.Revision, *cancel.Token) anyerror!?surface.Publication };
pub const Sink = struct { context: *anyopaque, emit: *const fn (*anyopaque, Published, *cancel.Token) anyerror!void, fail: *const fn (*anyopaque, anyerror, *cancel.Token) void };
pub const Options = struct { interval_ns: u64 = 16_000_000, maximum_pending: usize = 16, maximum_snapshots: usize = 2, maximum_surfaces: usize = 4096, requires_demand: bool = false, waits_consumption: bool = false };
pub const Metrics = struct {
    submissions: u64 = 0,
    snapshots: u64 = 0,
    emitted: u64 = 0,
    emitted_native: u64 = 0,
    emitted_cpu: u64 = 0,
    stale: u64 = 0,
    evictions: u64 = 0,
    coalesced: u64 = 0,
    prepared_coalesces: u64 = 0,
    suppressed: u64 = 0,
    flushes: u64 = 0,
    empty_flushes: u64 = 0,
    pending: usize = 0,
    demanded: usize = 0,
    prepared: usize = 0,
    batch_start_gap: Histogram = .{},
    framed_receive_batch_start_gap: Histogram = .{},
    receive_to_ready: Histogram = .{},
    ready_to_submit: Histogram = .{},
    flush_start_gap: Histogram = .{},
    flush_scheduling_delay: Histogram = .{},
    snapshot_duration: Histogram = .{},
    emit_duration: Histogram = .{},
    pub fn accumulate(self: *Metrics, other: Metrics) void {
        inline for (comptime std.meta.fieldNames(Metrics)) |field| {
            if (@FieldType(Metrics, field) == Histogram) @field(self, field).accumulate(@field(other, field)) else @field(self, field) +|= @field(other, field);
        }
    }
};
const Request = struct { revision: surface.Revision, invalidation: u64, timing: ?Timing };
const Entry = struct { invalidation: u64 = 0, latest: ?surface.Revision = null, last_emitted: ?surface.Revision = null, pending: ?Request = null, prepared: ?surface.Revision = null, demanded: bool = false, force_full: bool = false };
const Job = struct { request: Request, frame: ?surface.Publication = null, failure: ?anyerror = null };
pub const Publisher = struct {
    allocator: std.mem.Allocator,
    provider: Provider,
    options: Options,
    timebase: std.c.mach_timebase_info_data,
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    token: cancel.Token = .{},
    closed: bool = false,
    bound: bool = false,
    sink: ?Sink = null,
    manager: ?std.Thread = null,
    workers: []?std.Thread,
    jobs: []Job,
    entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
    order: std.ArrayList(u32) = .empty,
    batch_count: usize = 0,
    next_job: usize = 0,
    active: usize = 0,
    batch_active: bool = false,
    flushing: bool = false,
    deadline: ?u64 = null,
    last_flush: ?u64 = null,
    last_batch: ?u64 = null,
    last_received_batch: ?u64 = null,
    requested_flush: u64 = 0,
    completed_flush: u64 = 0,
    counts: Metrics = .{},
    pub fn create(a: std.mem.Allocator, provider: Provider, options: Options) !*Publisher {
        if (options.maximum_pending == 0 or options.maximum_pending > 4096 or options.maximum_snapshots == 0 or options.maximum_snapshots > 32 or options.maximum_surfaces < options.maximum_pending or options.maximum_surfaces > 65536 or options.interval_ns > std.math.maxInt(i64)) return error.InvalidLimits;
        var timebase: std.c.mach_timebase_info_data = undefined;
        if (std.c.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) return error.ClockUnavailable;
        const self = try a.create(Publisher);
        errdefer a.destroy(self);
        const workers = try a.alloc(?std.Thread, @min(options.maximum_snapshots, options.maximum_pending));
        errdefer a.free(workers);
        @memset(workers, null);
        const jobs = try a.alloc(Job, options.maximum_pending);
        errdefer a.free(jobs);
        var order: std.ArrayList(u32) = .empty;
        errdefer order.deinit(a);
        try order.ensureTotalCapacity(a, options.maximum_pending);
        self.* = .{ .allocator = a, .provider = provider, .options = options, .timebase = timebase, .workers = workers, .jobs = jobs, .order = order };
        // On partial thread creation, close/join without freeing allocations
        // whose earlier errdefers still own them.
        errdefer {
            self.stopThreads();
            self.token.deinit();
            self.changed.deinit();
            self.mutex.deinit();
        }
        for (workers) |*thread| thread.* = try std.Thread.spawn(.{}, worker, .{self});
        self.manager = try std.Thread.spawn(.{}, coordinate, .{self});
        return self;
    }
    pub fn bind(self: *Publisher, sink: Sink) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        if (self.bound) return error.AlreadyBound;
        std.debug.assert(!self.flushing and self.active == 0);
        self.token.deinit();
        self.token = .{};
        self.sink = sink;
        self.bound = true;
        self.deadline = null;
        self.last_flush = null;
        self.last_batch = null;
        self.last_received_batch = null;
        var iterator = self.entries.iterator();
        while (iterator.next()) |item| {
            const entry = item.value_ptr;
            entry.prepared = null;
            if (entry.latest) |revision| {
                entry.force_full = true;
                self.enqueue(item.key_ptr.*, entry, .{ .revision = revision, .invalidation = entry.invalidation, .timing = null });
            }
        }
        self.schedule();
    }
    pub fn cancelRun(self: *Publisher) void {
        self.token.cancel();
        self.mutex.lock();
        self.changed.broadcast();
        self.mutex.unlock();
    }
    pub fn cancelCallback(context: *anyopaque) void {
        const self: *Publisher = @ptrCast(@alignCast(context));
        self.cancelRun();
    }
    pub fn unbind(self: *Publisher) void {
        self.cancelRun();
        self.mutex.lock();
        defer self.mutex.unlock();
        self.bound = false;
        self.deadline = null;
        self.changed.broadcast();
        while (self.flushing or self.active != 0) self.changed.wait(&self.mutex);
        self.sink = null;
        self.completed_flush = self.requested_flush;
        self.changed.broadcast();
    }
    fn stopThreads(self: *Publisher) void {
        self.token.cancel();
        self.mutex.lock();
        self.closed = true;
        self.changed.broadcast();
        self.mutex.unlock();
        if (self.manager) |thread| thread.join();
        for (self.workers) |thread| if (thread) |v| v.join();
    }
    pub fn destroy(self: *Publisher) void {
        self.unbind();
        self.stopThreads();
        self.entries.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.allocator.free(self.jobs);
        self.allocator.free(self.workers);
        self.token.deinit();
        self.changed.deinit();
        self.mutex.deinit();
        self.allocator.destroy(self);
    }
    fn now(self: *Publisher) u64 {
        return @intCast(@min(std.math.maxInt(u64), @as(u128, std.c.mach_continuous_time()) * self.timebase.numer / self.timebase.denom));
    }
    fn newer(a: surface.Revision, b: surface.Revision) bool {
        return a.lifecycle > b.lifecycle or (a.lifecycle == b.lifecycle and a.value > b.value);
    }
    fn equal(a: surface.Revision, b: surface.Revision) bool {
        return a.id == b.id and a.lifecycle == b.lifecycle and a.value == b.value;
    }
    fn entryFor(self: *Publisher, id: u32) !*Entry {
        if (self.entries.getPtr(id)) |entry| return entry;
        if (self.entries.count() >= self.options.maximum_surfaces) return error.PublisherSurfaceLimit;
        const result = try self.entries.getOrPut(self.allocator, id);
        result.value_ptr.* = .{};
        return result.value_ptr;
    }
    fn eligible(self: *Publisher, entry: Entry) bool {
        return entry.pending != null and entry.demanded and (!self.options.waits_consumption or entry.prepared == null);
    }
    fn hasEligible(self: *Publisher) bool {
        for (self.order.items) |id| if (self.eligible(self.entries.get(id).?)) return true;
        return false;
    }
    fn schedule(self: *Publisher) void {
        if (self.bound and !self.token.cancelled.load(.acquire) and self.deadline == null and !self.flushing and self.hasEligible()) self.deadline = (self.last_flush orelse self.now()) +| self.options.interval_ns;
        self.changed.broadcast();
    }
    fn removeOrder(self: *Publisher, id: u32) void {
        for (self.order.items, 0..) |v, i| if (v == id) {
            _ = self.order.orderedRemove(i);
            return;
        };
    }
    fn enqueue(self: *Publisher, id: u32, entry: *Entry, request: Request) void {
        if (entry.pending == null) {
            if (self.order.items.len >= self.options.maximum_pending) {
                const oldest = self.order.orderedRemove(0);
                self.entries.getPtr(oldest).?.pending = null;
                self.counts.evictions +|= 1;
            }
            self.order.appendAssumeCapacity(id);
        } else self.counts.coalesced +|= 1;
        entry.pending = request;
    }
    pub fn submit(self: *Publisher, revision: surface.Revision, timing: ?Timing) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.counts.submissions +|= 1;
        const submitted_ns = self.now();
        if (timing) |value| {
            self.counts.receive_to_ready.interval(value.received_ns, value.ready_ns);
            self.counts.ready_to_submit.interval(value.ready_ns, submitted_ns);
        }
        if (self.closed) return error.Closed;
        const entry = try self.entryFor(revision.id);
        if (entry.latest) |latest| if (newer(latest, revision)) return;
        entry.latest = revision;
        if (!self.options.requires_demand) entry.demanded = true else if (!entry.demanded) self.counts.suppressed +|= 1;
        if (entry.last_emitted) |last| if (!newer(revision, last)) return;
        if (entry.pending) |pending| if (pending.invalidation == entry.invalidation and newer(pending.revision, revision)) return;
        if (self.order.items.len == 0) {
            if (self.last_batch) |previous| self.counts.batch_start_gap.interval(previous, submitted_ns);
            self.last_batch = submitted_ns;
            if (timing) |value| {
                if (self.last_received_batch) |previous| self.counts.framed_receive_batch_start_gap.interval(previous, value.received_ns);
                self.last_received_batch = value.received_ns;
            }
        }
        if (entry.prepared != null) self.counts.prepared_coalesces +|= 1;
        self.enqueue(revision.id, entry, .{ .revision = revision, .invalidation = entry.invalidation, .timing = timing });
        self.schedule();
    }
    pub fn setDemand(self: *Publisher, id: u32, demanded: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        const entry = try self.entryFor(id);
        entry.demanded = demanded;
        if (!demanded) {
            entry.prepared = null;
            if (entry.latest) |latest| {
                entry.force_full = true;
                self.enqueue(id, entry, .{ .revision = latest, .invalidation = entry.invalidation, .timing = null });
            }
        }
        self.schedule();
    }
    pub fn remove(self: *Publisher, id: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = try self.entryFor(id);
        const invalidation = try std.math.add(u64, entry.invalidation, 1);
        const demand = self.options.requires_demand and entry.demanded;
        entry.* = .{ .invalidation = invalidation, .demanded = demand };
        self.removeOrder(id);
        self.schedule();
    }
    pub fn acknowledge(self: *Publisher, revision: surface.Revision) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.options.waits_consumption) return;
        if (self.entries.getPtr(revision.id)) |entry| if (entry.prepared) |prepared| {
            if (prepared.lifecycle == revision.lifecycle and revision.value >= prepared.value) {
                entry.prepared = null;
                self.schedule();
            }
        };
    }
    pub fn metrics(self: *Publisher) Metrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        var value = self.counts;
        value.pending = self.order.items.len;
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry| {
            if (entry.demanded) value.demanded += 1;
            if (entry.prepared != null) value.prepared += 1;
        }
        return value;
    }
    pub fn flushNow(self: *Publisher) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.bound or self.token.cancelled.load(.acquire)) return error.Cancelled;
        const ticket = try std.math.add(u64, self.requested_flush, 1);
        self.requested_flush = ticket;
        self.changed.broadcast();
        while (self.completed_flush < ticket and self.bound and !self.token.cancelled.load(.acquire)) self.changed.wait(&self.mutex);
        if (!self.bound or self.token.cancelled.load(.acquire)) return error.Cancelled;
    }
    fn worker(self: *Publisher) void {
        while (true) {
            self.mutex.lock();
            while (!self.closed and (!self.batch_active or self.next_job >= self.batch_count or self.token.cancelled.load(.acquire))) self.changed.wait(&self.mutex);
            if (self.closed) {
                self.mutex.unlock();
                return;
            }
            const index = self.next_job;
            self.next_job += 1;
            self.active += 1;
            self.counts.snapshots +|= 1;
            const request = self.jobs[index].request;
            self.mutex.unlock();
            const snapshot_started = self.now();
            var failure: ?anyerror = null;
            const frame = self.provider.snapshot(self.provider.context, request.revision, &self.token) catch |err| blk: {
                failure = err;
                break :blk null;
            };
            const snapshot_completed = self.now();
            self.mutex.lock();
            self.counts.snapshot_duration.interval(snapshot_started, snapshot_completed);
            self.jobs[index].frame = frame;
            self.jobs[index].failure = failure;
            self.active -= 1;
            self.changed.broadcast();
            self.mutex.unlock();
        }
    }
    fn coordinate(self: *Publisher) void {
        while (true) {
            self.mutex.lock();
            while (!self.closed) {
                if (!self.bound or self.token.cancelled.load(.acquire)) {
                    self.changed.wait(&self.mutex);
                    continue;
                }
                if (self.requested_flush > self.completed_flush) break;
                if (self.deadline) |deadline| {
                    const now_ns = self.now();
                    if (now_ns >= deadline) break;
                    const delta = deadline - now_ns;
                    const timeout: std.c.timespec = .{ .sec = @intCast(delta / 1_000_000_000), .nsec = @intCast(delta % 1_000_000_000) };
                    _ = pthread_cond_timedwait_relative_np(&self.changed.value, &self.mutex.value, &timeout);
                } else self.changed.wait(&self.mutex);
            }
            if (self.closed) {
                self.mutex.unlock();
                return;
            }
            const ticket = self.requested_flush;
            const flush_started = self.now();
            if (self.last_flush) |previous| self.counts.flush_start_gap.interval(previous, flush_started);
            self.counts.flush_scheduling_delay.interval(self.deadline orelse flush_started, flush_started);
            self.last_flush = flush_started;
            const emitted_before = self.counts.emitted;
            self.deadline = null;
            self.flushing = true;
            self.counts.flushes +|= 1;
            self.batch_count = 0;
            self.next_job = 0;
            var i: usize = 0;
            while (i < self.order.items.len) {
                const id = self.order.items[i];
                const entry = self.entries.getPtr(id).?;
                if (self.eligible(entry.*)) {
                    self.jobs[self.batch_count] = .{ .request = entry.pending.? };
                    self.batch_count += 1;
                    entry.pending = null;
                    _ = self.order.orderedRemove(i);
                } else i += 1;
            }
            self.batch_active = true;
            self.changed.broadcast();
            while (self.active != 0 or (self.next_job < self.batch_count and !self.token.cancelled.load(.acquire))) self.changed.wait(&self.mutex);
            self.batch_active = false;
            self.mutex.unlock();
            self.emitBatch() catch |err| {
                if (!self.token.cancelled.load(.acquire)) {
                    const sink = self.sink.?;
                    sink.fail(sink.context, err, &self.token);
                    self.token.cancel();
                }
            };
            for (self.jobs[0..self.batch_count]) |*job| {
                if (job.frame) |frame| frame.release();
                job.frame = null;
            }
            self.mutex.lock();
            if (self.counts.emitted == emitted_before) self.counts.empty_flushes +|= 1;
            self.flushing = false;
            self.batch_count = 0;
            self.completed_flush = ticket;
            self.schedule();
            self.changed.broadcast();
            self.mutex.unlock();
        }
    }
    fn discard(self: *Publisher, job: *Job, force_full: bool) void {
        self.counts.stale +|= 1;
        if (force_full) if (self.entries.getPtr(job.request.revision.id)) |entry| {
            entry.force_full = true;
        };
    }
    fn removeCovered(self: *Publisher, entry: *Entry, revision: surface.Revision, invalidation: u64) void {
        if (entry.pending) |pending| if (pending.invalidation == invalidation and pending.revision.lifecycle == revision.lifecycle and pending.revision.value <= revision.value) {
            entry.pending = null;
            self.removeOrder(revision.id);
        };
    }
    fn emitBatch(self: *Publisher) !void {
        for (self.jobs[0..self.batch_count]) |*job| {
            try self.token.check();
            if (job.failure) |failure| return failure;
            const publication = job.frame orelse {
                self.mutex.lock();
                self.counts.stale +|= 1;
                self.mutex.unlock();
                continue;
            };
            const revision = publication.snapshot().revision;
            const request = job.request;
            self.mutex.lock();
            const entry = self.entries.getPtr(request.revision.id).?;
            if (entry.invalidation != request.invalidation or !entry.demanded or (self.options.waits_consumption and entry.prepared != null) or revision.id != request.revision.id or revision.lifecycle != request.revision.lifecycle or revision.value < request.revision.value) {
                self.discard(job, true);
                self.mutex.unlock();
                continue;
            }
            const replacement = entry.pending;
            if (replacement) |pending| if (pending.invalidation != request.invalidation or pending.revision.lifecycle != request.revision.lifecycle) {
                self.discard(job, false);
                self.mutex.unlock();
                continue;
            };
            if (!equal(revision, request.revision) and !(replacement != null and equal(revision, replacement.?.revision))) {
                self.discard(job, true);
                self.mutex.unlock();
                continue;
            }
            self.removeCovered(entry, revision, request.invalidation);
            var emitted = publication.retain();
            if (entry.force_full) {
                emitted.full_damage = true;
                entry.force_full = false;
            }
            if (self.options.waits_consumption) entry.prepared = revision;
            const timing = if (equal(revision, request.revision)) request.timing else if (replacement) |pending| pending.timing else null;
            const sink = self.sink.?;
            self.mutex.unlock();
            // Sink consumes emitted even on failure. Our independent lease keeps
            // pending damage alive until successful handoff commits ownership.
            const emit_started = self.now();
            const outcome = sink.emit(sink.context, .{ .frame = emitted, .timing = timing }, &self.token);
            const emit_completed = self.now();
            self.mutex.lock();
            self.counts.emit_duration.interval(emit_started, emit_completed);
            self.mutex.unlock();
            try outcome;
            publication.commit();
            self.mutex.lock();
            const current = self.entries.getPtr(request.revision.id).?;
            if (current.invalidation == request.invalidation) {
                current.last_emitted = revision;
                self.removeCovered(current, revision, request.invalidation);
            }
            self.counts.emitted +|= 1;
            if (publication.snapshot().backing == .native) self.counts.emitted_native +|= 1 else self.counts.emitted_cpu +|= 1;
            self.mutex.unlock();
        }
    }
};
