//! Native presentation submission and GPU lease ownership. The host supplies a
//! BGRA Metal texture (optionally its CAMetalDrawable) during a real draw cycle.
//! One Presenter belongs to one view. Calls may run concurrently; callbacks run
//! on a Metal completion thread and must not destroy/wait on this Presenter.
//! Host visibility/window/drawable acquisition and CPU fallback remain separate.
const std = @import("std");
const sync = @import("sync.zig");
const graphics = @import("graphics.zig");
const surface = @import("surface.zig");
extern "c" fn spice_zig_presenter_create(*anyopaque, [*:0]const u8) ?*anyopaque;
extern "c" fn spice_zig_presenter_destroy(*anyopaque) void;
extern "c" fn spice_zig_presenter_submit(*anyopaque, *anyopaque, *anyopaque, ?*anyopaque, u32, u32, c_int, *const fn (*anyopaque, c_int) callconv(.c) void, *anyopaque) c_int;
extern "c" fn spice_zig_presenter_submit_observed(*anyopaque, *anyopaque, *anyopaque, ?*anyopaque, u32, u32, c_int, *const fn (*anyopaque, c_int) callconv(.c) void, *anyopaque, ?*const Observer, ?*u64) c_int;
/// This context has independent ownership from Presenter and its GPU Job.
/// Events run on the main queue; context release may run on any native thread.
pub const Observation = extern struct { stage: u32, status: i32, continuous_ns: u64, media_time: f64, media_now: f64 };
pub const Observer = extern struct {
    context: *anyopaque,
    retain: *const fn (*anyopaque) callconv(.c) void,
    release: *const fn (*anyopaque) callconv(.c) void,
    event: *const fn (*anyopaque, *const Observation) callconv(.c) void,
};
pub const Filter = enum { nearest, lanczos };
pub fn sampling(sw: usize, sh: usize, dw: usize, dh: usize) !Filter {
    if (sw == 0 or sh == 0 or dw == 0 or dh == 0 or sw > 16384 or sh > 16384 or dw > 16384 or dh > 16384) return error.InvalidDimensions;
    return if (dw >= sw and dh >= sh and dw % sw == 0 and dh % sh == 0) .nearest else .lanczos;
}
pub const Destination = struct { texture: *anyopaque, width: u32, height: u32, drawable: ?*anyopaque = null, observer: ?*const Observer = null, commit_ns: ?*u64 = null };
pub const Result = enum { submitted, busy, hidden, stale };
pub const Completion = struct { revision: surface.Revision, epoch: u64, succeeded: bool, current: bool };
pub const Sink = struct { context: *anyopaque, completed: *const fn (*anyopaque, Completion) void };
pub const Metrics = struct { submitted: u64 = 0, completed: u64 = 0, failures: u64 = 0, busy: u64 = 0, active: usize = 0, maximum_active: usize = 0 };
pub const Presenter = struct {
    allocator: std.mem.Allocator,
    native: *anyopaque,
    sink: Sink,
    mutex: sync.Mutex = .{},
    changed: sync.Condition = .{},
    closed: bool = false,
    visible: bool = true,
    epoch: u64 = 1,
    latest: ?surface.Revision = null,
    counts: Metrics = .{},
    const Job = struct { owner: *Presenter, frame: surface.Publication, epoch: u64 };
    pub fn create(a: std.mem.Allocator, context: graphics.Context, metallib: [*:0]const u8, sink: Sink) !*Presenter {
        const self = try a.create(Presenter);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .native = spice_zig_presenter_create(context.handle, metallib) orelse return error.MetalUnavailable, .sink = sink };
        return self;
    }
    /// Reset before selecting another Surface/session. Outstanding callbacks are
    /// marked stale; their leases remain held until actual GPU completion.
    pub fn reset(self: *Presenter, visible: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        self.epoch = try std.math.add(u64, self.epoch, 1);
        self.latest = null;
        self.visible = visible;
    }
    pub fn submit(self: *Presenter, frame: surface.Publication, destination: Destination) !Result {
        if (destination.commit_ns) |value| value.* = 0;
        const snapshot = frame.snapshot();
        const source = switch (snapshot.backing) {
            .native => |v| v,
            else => return error.MissingNativeFrame,
        };
        const filter = try sampling(snapshot.width, snapshot.height, destination.width, destination.height);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return error.Closed;
        if (!self.visible) return .hidden;
        if (self.latest) |latest| {
            if (snapshot.revision.id != latest.id) return error.DifferentSurface;
            if (snapshot.revision.lifecycle < latest.lifecycle or (snapshot.revision.lifecycle == latest.lifecycle and snapshot.revision.value < latest.value)) return .stale;
        }
        if (self.counts.active >= 2) {
            self.counts.busy +|= 1;
            return .busy;
        }
        const job = try self.allocator.create(Job);
        job.* = .{ .owner = self, .frame = frame.retain(), .epoch = self.epoch };
        // The adapter returns either failure with no callback, or success with
        // exactly one completion. Its callback may race this function's return.
        self.counts.active += 1;
        if (spice_zig_presenter_submit_observed(self.native, source.handle, destination.texture, destination.drawable, destination.width, destination.height, @intFromBool(filter == .lanczos), complete, job, destination.observer, destination.commit_ns) != 0) {
            self.counts.active -= 1;
            job.frame.release();
            self.allocator.destroy(job);
            self.counts.failures +|= 1;
            return error.PresentationFailed;
        }
        self.latest = snapshot.revision;
        self.counts.submitted +|= 1;
        self.counts.maximum_active = @max(self.counts.maximum_active, self.counts.active);
        return .submitted;
    }
    fn complete(p: *anyopaque, status: c_int) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(p));
        const self = job.owner;
        self.mutex.lock();
        const result: Completion = .{ .revision = job.frame.snapshot().revision, .epoch = job.epoch, .succeeded = status == 0, .current = !self.closed and self.visible and job.epoch == self.epoch };
        self.counts.completed +|= 1;
        if (status != 0) self.counts.failures +|= 1;
        self.mutex.unlock();
        self.sink.completed(self.sink.context, result);
        job.frame.release();
        self.allocator.destroy(job);
        self.mutex.lock();
        self.counts.active -= 1;
        self.changed.broadcast();
        self.mutex.unlock();
    }
    pub fn metrics(self: *Presenter) Metrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.counts;
    }
    pub fn waitIdle(self: *Presenter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.counts.active != 0) self.changed.wait(&self.mutex);
    }
    /// Close rejects new submissions and joins callbacks. GPU work cannot be
    /// cancelled; destruction waits for its real fence before releasing leases.
    pub fn destroy(self: *Presenter) void {
        self.mutex.lock();
        self.closed = true;
        while (self.counts.active != 0) self.changed.wait(&self.mutex);
        self.mutex.unlock();
        spice_zig_presenter_destroy(self.native);
        self.changed.deinit();
        self.mutex.deinit();
        self.allocator.destroy(self);
    }
};
