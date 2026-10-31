//! Two joined workers per Display service, bounded retained-byte admission and
//! per-stream order. MJPEG keeps one newest pending frame; reference codecs keep
//! FIFO input. Bind/unbind drains one channel generation while retaining codecs.
//! Public producer methods are serialized by the channel worker; cancel may run
//! concurrently. Sink callbacks must honor the supplied cancellation token.
const std = @import("std");
const sync = @import("sync.zig");
const cancel = @import("cancel.zig");
const wire = @import("bytes.zig");
const protocol = @import("stream_wire.zig");
const renderer = @import("stream_decoder.zig");
const surface = @import("surface.zig");
const region = @import("region.zig");
const clock = @import("clock.zig");
const executor = @import("codec_executor.zig");
const report = @import("flow.zig").StreamReportWindow;
const Timing = @import("frame_publisher.zig").Timing;
const generated = @import("generated.zig");
pub const Sink = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, surface.Revision, ?Timing, *cancel.Token) anyerror!void,
    fail: *const fn (*anyopaque, anyerror, *cancel.Token) void,
};
pub const Limits = struct { jobs: usize = 64, bytes: usize = 256 * 1024 * 1024 };
pub const Scheduler = struct {
    const Work = struct { next: ?*Work = null, job: renderer.Job, received_ns: ?u64 };
    const Slot = struct {
        stream: renderer.Stream,
        sampled_metrics: renderer.Metrics = .{},
        clips: ?[]region.Rect,
        head: ?*Work = null,
        tail: ?*Work = null,
        busy: bool = false,
        retired: bool = false,
        active_token: ?*cancel.Token = null,
        reporting: ?report = null,
    };
    allocator: std.mem.Allocator,
    store: *surface.Store,
    pool: *executor.Executor,
    media: ?*clock.Clock,
    limits: Limits,
    timebase: std.c.mach_timebase_info_data,
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    workers: [2]?std.Thread = .{ null, null },
    slots: [64]?*Slot = @splat(null),
    closed: bool = false,
    bound: bool = false,
    run_token: cancel.Token = .{},
    sink: ?Sink = null,
    active: usize = 0,
    jobs: usize = 0,
    bytes: usize = 0,
    cursor: usize = 0,
    failure: ?anyerror = null,
    video_failure: ?@import("video_failure.zig").Failure = null,
    superseded: usize = 0,
    counts: renderer.Metrics = .{},
    decode_activity: renderer.Activity = .{},
    pub fn create(a: std.mem.Allocator, store: *surface.Store, pool: *executor.Executor, media: ?*clock.Clock, limits: Limits) !*Scheduler {
        if (limits.jobs == 0 or limits.bytes == 0) return error.InvalidLimits;
        var timebase: std.c.mach_timebase_info_data = undefined;
        if (std.c.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) return error.ClockUnavailable;
        const self = try a.create(Scheduler);
        self.* = .{ .allocator = a, .store = store, .pool = pool, .media = media, .limits = limits, .timebase = timebase };
        errdefer self.destroy();
        for (&self.workers) |*thread| thread.* = try std.Thread.spawn(.{}, worker, .{self});
        return self;
    }
    pub fn bind(self: *Scheduler, sink: Sink) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        if (self.bound) return error.AlreadyBound;
        std.debug.assert(self.jobs == 0 and self.active == 0);
        self.run_token.deinit();
        self.run_token = .{};
        self.sink = sink;
        self.failure = null;
        self.video_failure = null;
        self.bound = true;
        for (self.slots) |slot| if (slot) |p| {
            p.reporting = null;
        };
    }
    /// Can be called from an enclosing cancellation registration. Never joins.
    pub fn cancelRun(self: *Scheduler) void {
        self.run_token.cancel();
        wake(self);
    }
    pub fn cancelCallback(p: *anyopaque) void {
        const self: *Scheduler = @ptrCast(@alignCast(p));
        self.cancelRun();
    }
    pub fn unbind(self: *Scheduler) void {
        self.cancelRun();
        self.mutex.lock();
        defer self.mutex.unlock();
        self.bound = false;
        for (self.slots) |slot| if (slot) |p| self.clearPending(p);
        self.changed.broadcast();
        while (self.active != 0) self.changed.wait(&self.mutex);
        self.sink = null;
        std.debug.assert(self.jobs == 0 and self.bytes == 0);
    }
    fn disposeWork(self: *Scheduler, work: *Work) void {
        self.bytes -= work.job.weight();
        self.jobs -= 1;
        work.job.deinit();
        self.allocator.destroy(work);
    }
    fn clearPending(self: *Scheduler, slot: *Slot) void {
        var current = slot.head;
        slot.head = null;
        slot.tail = null;
        while (current) |work| {
            current = work.next;
            self.disposeWork(work);
        }
    }
    pub fn destroy(self: *Scheduler) void {
        self.unbind();
        self.mutex.lock();
        self.closed = true;
        self.changed.broadcast();
        self.mutex.unlock();
        for (self.workers) |thread| if (thread) |t| t.join();
        for (self.slots) |slot| if (slot) |p| self.disposeSlot(p);
        self.run_token.deinit();
        self.decode_activity.deinit();
        self.changed.deinit();
        self.mutex.deinit();
        self.allocator.destroy(self);
    }
    fn disposeSlot(self: *Scheduler, slot: *Slot) void {
        std.debug.assert(!slot.busy and slot.head == null);
        if (slot.clips) |clips| self.allocator.free(clips);
        slot.stream.deinit();
        self.allocator.destroy(slot);
    }
    pub fn add(self: *Scheduler, config: protocol.Create) !void {
        if (config.id >= self.slots.len) return error.InvalidStreamID;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        if (self.slots[config.id] != null) return error.DuplicateStream;
        const slot = try self.allocator.create(Slot);
        errdefer self.allocator.destroy(slot);
        const clips = if (config.clips) |c| try self.allocator.dupe(region.Rect, c) else null;
        errdefer if (clips) |c| self.allocator.free(c);
        slot.* = .{ .stream = try renderer.Stream.init(self.allocator, self.store, config), .clips = clips };
        slot.stream.activity = &self.decode_activity;
        slot.sampled_metrics = slot.stream.metrics();
        self.counts.accumulate(slot.sampled_metrics);
        self.slots[config.id] = slot;
    }
    pub fn remove(self: *Scheduler, id: u32) !void {
        self.mutex.lock();
        const slot = if (id < 64) self.slots[id] else null;
        if (slot == null) {
            self.mutex.unlock();
            return error.UnknownStream;
        }
        const p = slot.?;
        self.slots[id] = null;
        p.retired = true;
        self.clearPending(p);
        if (p.active_token) |token| token.cancel();
        self.changed.broadcast();
        while (p.busy) self.changed.wait(&self.mutex);
        self.mutex.unlock();
        self.disposeSlot(p);
    }
    pub fn removeAll(self: *Scheduler) void {
        for (0..64) |id| self.remove(@intCast(id)) catch {};
    }
    pub fn removeSurface(self: *Scheduler, id: u32) void {
        for (0..64) |index| {
            self.mutex.lock();
            const matches = if (self.slots[index]) |slot| slot.stream.config.surface == id else false;
            self.mutex.unlock();
            if (matches) self.remove(@intCast(index)) catch {};
        }
    }
    pub fn setClip(self: *Scheduler, id: u32, clips: ?[]const region.Rect) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = (if (id < 64) self.slots[id] else null) orelse return error.UnknownStream;
        const snapshot = try self.store.snapshot(slot.stream.config.surface);
        defer snapshot.deinit();
        var checked = try region.Region.init(self.allocator, slot.stream.config.destination, .{ .x = 0, .y = 0, .width = @intCast(snapshot.width), .height = @intCast(snapshot.height) }, clips, .{});
        defer checked.deinit();
        const copy = if (clips) |c| try self.allocator.dupe(region.Rect, c) else null;
        if (slot.clips) |c| self.allocator.free(c);
        slot.clips = copy;
    }
    pub fn codec(self: *Scheduler, id: u32) !protocol.Codec {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = (if (id < 64) self.slots[id] else null) orelse return error.UnknownStream;
        return slot.stream.config.codec;
    }
    pub fn videoFailure(self: *Scheduler, failure: anyerror) ?@import("video_failure.zig").Failure {
        self.mutex.lock();
        defer self.mutex.unlock();
        const current = self.failure orelse return null;
        return if (current == failure) self.video_failure else null;
    }
    pub fn currentFailure(self: *Scheduler) ?anyerror {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failure;
    }
    pub fn activateReport(self: *Scheduler, activation: generated.SpiceMsgDisplayStreamActivateReport) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = (if (activation.streamID < 64) self.slots[activation.streamID] else null) orelse return error.UnknownStream;
        slot.reporting = .{ .activation = activation };
    }
    fn wake(p: *anyopaque) void {
        const self: *Scheduler = @ptrCast(@alignCast(p));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.changed.broadcast();
    }
    /// Reports count every arrival, including superseded or late frames. Caller
    /// sends the returned report on the connection that supplied this packet.
    pub fn submit(self: *Scheduler, id: u32, payload: wire.Slice, time: u32, sizing: ?protocol.Sizing, now_ms: u64) !?generated.SpiceMsgcDisplayStreamReport {
        return self.submitTimed(id, payload, time, sizing, now_ms, null);
    }
    pub fn submitTimed(self: *Scheduler, id: u32, payload: wire.Slice, time: u32, sizing: ?protocol.Sizing, now_ms: u64, received_ns: ?u64) !?generated.SpiceMsgcDisplayStreamReport {
        var registration: cancel.Registration = .{ .context = self, .wake = wake };
        self.run_token.register(&registration);
        defer self.run_token.unregister(&registration);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.bound or self.closed) return error.NotBound;
        try self.run_token.check();
        if (self.failure) |failure| return failure;
        const slot = (if (id < 64) self.slots[id] else null) orelse return error.UnknownStream;
        var result: ?generated.SpiceMsgcDisplayStreamReport = null;
        if (slot.reporting) |*window| {
            const margin = if (self.media) |media| clock.margin(media.current(), time) else 0;
            const audio = if (self.media) |media| media.playbackDelay() orelse std.math.maxInt(u32) else std.math.maxInt(u32);
            result = window.record(time, margin, audio, now_ms);
        }
        const work = try self.allocator.create(Work);
        errdefer self.allocator.destroy(work);
        work.* = .{ .job = try slot.stream.prepare(self.store, payload, time, sizing, slot.clips), .received_ns = received_ns };
        errdefer work.job.deinit();
        const size = work.job.weight();
        if (size > self.limits.bytes) return error.QueuedRetainedBytesExceeded;
        while (true) {
            try self.run_token.check();
            if (self.closed or !self.bound or slot.retired) return error.Cancelled;
            if (self.failure) |failure| return failure;
            const replace = if (slot.stream.config.codec == .mjpeg) slot.head else null;
            const removed = if (replace) |old| old.job.weight() else 0;
            if (self.jobs - @as(usize, if (replace != null) 1 else 0) < self.limits.jobs and size <= self.limits.bytes - (self.bytes - removed)) {
                if (replace) |old| {
                    std.debug.assert(old.next == null);
                    slot.head = null;
                    slot.tail = null;
                    self.disposeWork(old);
                    self.superseded += 1;
                }
                break;
            }
            self.changed.wait(&self.mutex);
        }
        if (slot.tail) |tail| tail.next = work else slot.head = work;
        slot.tail = work;
        self.jobs += 1;
        self.bytes += size;
        self.changed.broadcast();
        return result;
    }
    fn next(self: *Scheduler) ?struct { slot: *Slot, work: *Work, sink: Sink } {
        if (!self.bound or self.run_token.cancelled.load(.acquire) or self.failure != null) return null;
        for (0..64) |offset| {
            const index = (self.cursor + offset) % 64;
            const slot = self.slots[index] orelse continue;
            if (slot.busy or slot.head == null) continue;
            const work = slot.head.?;
            slot.head = work.next;
            if (slot.head == null) slot.tail = null;
            work.next = null;
            slot.busy = true;
            self.active += 1;
            self.cursor = (index + 1) % 64;
            return .{ .slot = slot, .work = work, .sink = self.sink.? };
        }
        return null;
    }
    fn forward(p: *anyopaque) void {
        const token: *cancel.Token = @ptrCast(@alignCast(p));
        token.cancel();
    }
    fn reportFailure(self: *Scheduler, slot: *Slot, sink: Sink, err: anyerror, token: *cancel.Token) void {
        self.mutex.lock();
        const notify = err != error.Cancelled and !slot.retired and self.bound and self.failure == null and !self.run_token.cancelled.load(.acquire);
        if (notify) {
            self.failure = err;
            self.video_failure = slot.stream.videoFailure(err);
        }
        self.changed.broadcast();
        self.mutex.unlock();
        if (notify) sink.fail(sink.context, err, token);
    }
    fn worker(self: *Scheduler) void {
        while (true) {
            self.mutex.lock();
            var picked = self.next();
            while (picked == null and !self.closed) {
                self.changed.wait(&self.mutex);
                picked = self.next();
            }
            if (self.closed) {
                self.mutex.unlock();
                return;
            }
            const job = picked.?;
            self.mutex.unlock();
            var token: cancel.Token = .{};
            var registration: cancel.Registration = .{ .context = &token, .wake = forward };
            self.run_token.register(&registration);
            self.mutex.lock();
            job.slot.active_token = &token;
            if (job.slot.retired or !self.bound) token.cancel();
            self.mutex.unlock();
            const rendered = job.slot.stream.render(job.work.job, self.store, self.pool, self.media, &token);
            if (rendered) |revision| {
                if (revision) |value| job.sink.publish(job.sink.context, value, if (job.work.received_ns) |received| .{ .received_ns = received, .ready_ns = clock.nanoseconds(self.timebase) } else null, &token) catch |err| self.reportFailure(job.slot, job.sink, err, &token);
            } else |err| self.reportFailure(job.slot, job.sink, err, &token);
            self.run_token.unregister(&registration);
            self.mutex.lock();
            const completed_metrics = job.slot.stream.metrics();
            self.counts.accumulate(completed_metrics.delta(job.slot.sampled_metrics));
            job.slot.sampled_metrics = completed_metrics;
            job.slot.active_token = null;
            job.slot.busy = false;
            self.active -= 1;
            self.disposeWork(job.work);
            self.changed.broadcast();
            self.mutex.unlock();
            token.deinit();
        }
    }
    /// A barrier for lifecycle handoff/tests; queued input continues processing.
    pub fn metrics(self: *Scheduler) renderer.Metrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        var result = self.counts;
        result.mjpeg_superseded = self.superseded;
        self.decode_activity.sample(&result);
        return result;
    }
    pub fn drain(self: *Scheduler) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.jobs != 0 and self.failure == null and !self.run_token.cancelled.load(.acquire)) self.changed.wait(&self.mutex);
        if (self.failure) |failure| return failure;
        try self.run_token.check();
    }
};
