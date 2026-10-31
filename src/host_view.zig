//! Main-thread desktop view controller. The native host owns one reference and
//! weak UI storage; Source deliveries and queued GPU observations own independent
//! references. close severs subscriptions before releasing display resources.
//! Host callbacks are synchronous/non-reentrant except input (which may close)
//! and schedule (which MUST enqueue and consume the supplied retained reference).
const std = @import("std");
const d = @import("desktop_snapshot.zig");
const source = @import("desktop_source.zig");
const policy = @import("presentation_policy.zig");
const input = @import("host_input.zig");
const inputs = @import("inputs.zig");
const graphics = @import("graphics.zig");
const gpu = @import("presenter.zig");
const diag = @import("presentation_diagnostics.zig");
const trace = @import("interaction_trace.zig");
const timing = @import("timing.zig");
const clock = @import("clock.zig");
pub const DrawResult = enum { submitted, retry, fallback };
pub const Cursor = struct {
    kind: enum { arrow, transparent, image } = .arrow,
    bytes: []const u8 = &.{},
    width: u16 = 0,
    height: u16 = 0,
    hotspot: input.Point = .{},
    size: input.Point = .{},
    overlay: ?input.Rect = null,
};
pub const Content = enum { empty, cpu, metal };
pub const Host = struct {
    context: *anyopaque,
    destroy: *const fn (*anyopaque) void,
    schedule: *const fn (*anyopaque, *Controller) void,
    ticking: *const fn (*anyopaque, bool) void,
    layout: *const fn (*anyopaque, input.Rect, policy.Size) void,
    draw: *const fn (*anyopaque, *Controller) DrawResult,
    content: *const fn (*anyopaque, Content) void,
    cursor: *const fn (*anyopaque, Cursor) void,
    input: *const fn (*anyopaque, inputs.Input) void,
    failure: *const fn (*anyopaque, anyerror) void,
    capture: input.CaptureSystem,
};
pub const Controller = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    closed: std.atomic.Value(bool) = .init(false),
    source: *source.Source,
    subscription: ?*source.Subscription = null,
    host: Host,
    timebase: std.c.mach_timebase_info_data,
    latch: d.ReadyLatch = .{},
    presenter: ?*gpu.Presenter = null,
    recovery: policy.MetalRecovery,
    drops: policy.DropRecovery = .{},
    pacing: policy.Pacing = .{},
    keyboard: input.Keyboard = .{},
    capture: input.Capture = .{},
    visible: bool = false,
    bounds: input.Rect = .{},
    scale: f64 = 1,
    latest: ?d.Snapshot = null,
    selected: ?d.Revision = null,
    acknowledged: ?d.Revision = null,
    forced_cpu: ?d.Revision = null,
    redraw: bool = true,
    cpu: bool = false,
    cpu_frame: ?d.Frame = null,
    pending: ?Pending = null,
    const Pending = struct { snapshot: d.Snapshot, attempt: policy.MetalRecovery.Attempt, requested: u64 };
    /// Takes ownership of host only on success. Native context is retained by
    /// Presenter; neither Runtime nor SourceSession is borrowed after creation.
    pub fn create(a: std.mem.Allocator, src: *source.Source, surface_key: d.Key, host: Host, native: ?graphics.Context, metallib: ?[*:0]const u8) !*Controller {
        var tb: std.c.mach_timebase_info_data = undefined;
        if (std.c.mach_timebase_info(&tb) != 0 or tb.denom == 0) return error.ClockUnavailable;
        const self = try a.create(Controller);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .source = src.retain(), .host = host, .timebase = tb, .recovery = .{ .allocator = a } };
        errdefer src.release();
        self.subscription = try src.subscribe(surface_key);
        errdefer self.subscription.?.destroy();
        if (native) |context| if (metallib) |path| {
            self.presenter = gpu.Presenter.create(a, context, path, .{ .context = self, .completed = gpuCompleted }) catch |err| switch (err) {
                error.MetalUnavailable => null,
                else => return err,
            };
        };
        errdefer if (self.presenter) |p| p.destroy();
        try self.subscription.?.setHandler(.{ .context = self, .retain = retainHandler, .release = releaseHandler, .emit = receive });
        return self;
    }
    pub fn retain(self: *Controller) *Controller {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *Controller) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        std.debug.assert(self.closed.load(.acquire));
        self.latch.deinit();
        self.recovery.deinit();
        self.source.release();
        self.host.destroy(self.host.context);
        self.allocator.destroy(self);
    }
    fn retainHandler(p: *anyopaque) void {
        _ = cast(p).retain();
    }
    fn releaseHandler(p: *anyopaque) void {
        cast(p).release();
    }
    fn cast(p: *anyopaque) *Controller {
        return @ptrCast(@alignCast(p));
    }
    fn now(self: *Controller) u64 {
        return clock.nanoseconds(self.timebase);
    }
    fn count(self: *Controller, kind: diag.Counter) void {
        self.source.diagnostics.add(kind, 1, null);
    }
    fn fail(self: *Controller, err: anyerror) void {
        self.host.failure(self.host.context, err);
    }
    fn gpuCompleted(_: *anyopaque, _: gpu.Completion) void {} // Policy uses queued observations, never Metal's worker thread.
    fn receive(p: *anyopaque, snapshot: d.Snapshot) void {
        const self = cast(p);
        if (self.closed.load(.acquire)) return;
        if (self.latch.offer(snapshot, self.now())) self.host.schedule(self.host.context, self.retain());
    }
    /// Called by the queued main-thread wake; caller releases its queue reference.
    pub fn ready(self: *Controller) void {
        if (self.closed.load(.acquire)) return;
        if (!self.visible) {
            self.latch.discard();
            return;
        }
        if (self.latch.isEmpty()) return;
        if (self.pacing.ready() == .select_immediately) {
            self.count(.display_link_wakeups);
            self.count(.immediate_selections);
            self.host.ticking(self.host.context, true);
            self.select();
        }
    }
    pub fn tick(self: *Controller) void {
        if (self.closed.load(.acquire) or !self.visible) return;
        self.count(.display_link_ticks);
        if (self.pacing.tick(!self.latch.isEmpty()) == .select_on_display_link) self.select() else {
            self.count(.display_link_idle_pauses);
            self.host.ticking(self.host.context, false);
        }
    }
    fn clear(self: *Controller) void {
        if (self.latest) |s| s.deinit();
        self.latest = null;
        self.selected = null;
        self.acknowledged = null;
        self.forced_cpu = null;
        self.cpu = false;
        if (self.cpu_frame) |frame| frame.deinit();
        self.cpu_frame = null;
        self.recovery.reset();
        self.drops.reset();
        self.host.content(self.host.context, .empty);
    }
    pub fn close(self: *Controller) void {
        if (self.closed.swap(true, .acq_rel)) return;
        _ = self.retain();
        defer self.release();
        self.visible = false;
        if (self.subscription) |s| s.destroy();
        self.subscription = null;
        self.host.ticking(self.host.context, false);
        self.pacing.reset();
        self.latch.discard();
        self.focusLost();
        self.clear();
        if (self.presenter) |p| p.destroy();
        self.presenter = null;
    }
    /// Native view supplies actual window/occlusion/hidden/visibleRect state.
    pub fn configure(self: *Controller, visible: bool, bounds: input.Rect, scale: f64) void {
        if (self.closed.load(.acquire)) return;
        const geometry_changed = !std.meta.eql(bounds, self.bounds) or scale != self.scale;
        self.bounds = bounds;
        self.scale = scale;
        const active = visible and std.math.isFinite(bounds.width) and std.math.isFinite(bounds.height) and bounds.width > 0 and bounds.height > 0;
        const visibility_changed = self.visible != active;
        self.visible = active;
        if (!active) {
            if (visibility_changed) {
                self.subscription.?.setDemand(false) catch |err| self.fail(err);
                self.latch.discard();
                self.pacing.reset();
                self.host.ticking(self.host.context, false);
                self.focusLost();
                self.clear();
                self.redraw = true;
                if (self.presenter) |p| p.reset(false) catch |err| self.fail(err);
            }
            return;
        }
        if (visibility_changed) {
            self.redraw = true;
            if (self.presenter) |p| p.reset(true) catch |err| self.fail(err);
            self.subscription.?.setDemand(true) catch |err| self.fail(err);
            // A retained synthetic frame can have the same delivery stamp as
            // the last visible frame. Request an authoritative new delivery.
            self.requestLatest();
        } else if (geometry_changed) {
            self.redraw = true;
            self.requestLatest();
        }
        self.updateGeometry();
        self.updateCursor();
        self.ready();
    }
    fn requestLatest(self: *Controller) void {
        if (self.subscription) |s| s.requestLatest() catch |err| self.fail(err);
    }
    fn geometry(self: *Controller) input.Rect {
        const snapshot = self.latest orelse return .{};
        const frame = snapshot.frame orelse return .{};
        const v = frame.publication.snapshot();
        return input.contentRect(self.bounds, @intCast(v.width), @intCast(v.height));
    }
    fn updateGeometry(self: *Controller) void {
        const rect = self.geometry();
        self.host.layout(self.host.context, rect, policy.drawableSize(.{ .width = rect.width, .height = rect.height }, self.scale));
    }
    fn select(self: *Controller) void {
        const selected_ns = self.now();
        const ready_frame = self.latch.take(selected_ns) orelse return;
        defer ready_frame.deinit();
        const update = ready_frame.snapshot;
        if (self.latest) |last| {
            if (update.stamp.order(last.stamp) == .lt) return;
            if (update.stamp.generation != last.stamp.generation) {
                self.clear();
                self.redraw = true;
                if (self.presenter) |p| p.reset(true) catch |err| self.fail(err);
            }
        }
        if (self.latest) |last| last.deinit();
        self.latest = update.clone();
        if (update.pointer == .absolute) self.capture.release(self.host.capture);
        self.updateGeometry();
        self.updateCursor();
        const frame = update.frame orelse {
            self.clear();
            self.latest = update.clone();
            self.redraw = false;
            return;
        };
        const revision = frame.revision();
        if (!policy.needsFramebuffer(self.selected, revision, self.redraw)) return;
        if (self.selected) |previous| if (!previous.sameSurface(revision)) {
            self.recovery.reset();
            self.forced_cpu = null;
            if (self.presenter) |p| p.reset(true) catch |err| self.fail(err);
        };
        self.source.diagnostics.interval(.ready_to_selection, ready_frame.ready_ns, selected_ns, null);
        if (trace.Identity.from(update)) |id| self.source.traces.selected(id, ready_frame.ready_ns, selected_ns);
        var result: DrawResult = .fallback;
        var fallback: diag.Fallback = .metal_unavailable;
        if (self.presenter != null) {
            if (frame.publication.snapshot().backing != .native) fallback = .missing_iosurface else if (self.forced_cpu != null and self.forced_cpu.?.equal(revision)) fallback = .metal_command_failure else attempt_block: {
                const attempt = self.recovery.begin(revision) catch |err| {
                    self.fail(err);
                    fallback = .metal_command_failure;
                    break :attempt_block;
                };
                self.pending = .{ .snapshot = update, .attempt = attempt, .requested = selected_ns };
                result = self.host.draw(self.host.context, self);
                self.pending = null;
                if (result != .submitted) self.recovery.cancel(attempt);
                fallback = .metal_command_failure;
            }
        }
        if (result == .retry) {
            _ = self.latch.restoreIfEmpty(update, ready_frame.ready_ns);
            return;
        }
        if (self.cpu_frame) |previous| previous.deinit();
        self.cpu_frame = if (result == .fallback) frame.clone() else null;
        self.cpu = result == .fallback;
        if (self.cpu) self.source.diagnostics.fallback(fallback);
        if (self.selected) |previous| if (previous.sameSurface(revision) and revision.surface.value > previous.surface.value) self.source.diagnostics.add(.frames_superseded, revision.surface.value - previous.surface.value - 1, null);
        self.selected = revision;
        self.redraw = false;
        self.drops.selected(revision);
        self.host.content(self.host.context, if (self.cpu) .cpu else .metal);
        if (self.acknowledged == null or !self.acknowledged.?.equal(revision)) {
            self.subscription.?.acknowledge(revision) catch |err| {
                self.fail(err);
                return;
            };
            self.acknowledged = revision;
        }
    }
    /// Invoked synchronously inside MTKView.draw, with a freshly acquired drawable.
    pub fn submit(self: *Controller, destination: ?gpu.Destination) DrawResult {
        const pending = self.pending orelse return .fallback;
        const dest = destination orelse {
            self.count(.drawable_misses);
            return .retry;
        };
        const observer = Observation.create(self, pending) catch |err| {
            self.fail(err);
            return .fallback;
        };
        defer observer.release();
        var target = dest;
        const descriptor = observer.descriptor();
        target.observer = &descriptor;
        target.commit_ns = &observer.committed;
        const result = self.presenter.?.submit(pending.snapshot.frame.?.publication, target) catch |err| {
            self.count(.command_creation_failures);
            self.fail(err);
            return .fallback;
        };
        switch (result) {
            .busy => {
                self.count(.gpu_busy_skips);
                return .retry;
            },
            .hidden, .stale => return .retry,
            .submitted => {
                self.count(.command_buffers_committed);
                self.source.diagnostics.interval(.view_update_to_commit, pending.requested, observer.committed, observer.epoch);
                self.source.traces.committed(observer.identity, observer.committed);
                return .submitted;
            },
        }
    }
    pub fn cpuFrame(self: *Controller) ?d.Frame {
        if (self.closed.load(.acquire) or !self.visible or !self.cpu) return null;
        return self.cpu_frame; // Borrowed for synchronous native drawing only.
    }
    fn updateCursor(self: *Controller) void {
        var result: Cursor = .{};
        const latest = self.latest orelse {
            self.host.cursor(self.host.context, result);
            return;
        };
        const rect = self.geometry();
        const frame = if (latest.frame) |f| f.publication.snapshot() else null;
        const desc = policy.systemCursor(latest.pointer, latest.cursor, if (frame) |f| .{ .width = @floatFromInt(f.width), .height = @floatFromInt(f.height) } else null, .{ .width = rect.width, .height = rect.height }, self.capture.captured);
        result.kind = switch (desc) {
            .arrow => .arrow,
            .transparent => .transparent,
            .image => .image,
        };
        if (latest.cursor) |c| if (c.payload) |payload| if (frame) |f| {
            const h = payload.header;
            if (h.kind == 0 and h.width > 0 and h.height > 0 and payload.data.bytes().len == @as(usize, h.width) * h.height * 4) {
                const sx = rect.width / @as(f64, @floatFromInt(f.width));
                const sy = rect.height / @as(f64, @floatFromInt(f.height));
                result.bytes = payload.data.bytes();
                result.width = h.width;
                result.height = h.height;
                result.size = .{ .x = @as(f64, @floatFromInt(h.width)) * sx, .y = @as(f64, @floatFromInt(h.height)) * sy };
                result.hotspot = .{ .x = @as(f64, @floatFromInt(h.hot_x)) * sx, .y = @as(f64, @floatFromInt(h.hot_y)) * sy };
                if (c.visible and policy.cursorLayer(latest.pointer, self.capture.captured) == .overlay) result.overlay = .{ .x = rect.x + @as(f64, @floatFromInt(c.position.x)) * sx - result.hotspot.x, .y = rect.y + @as(f64, @floatFromInt(c.position.y)) * sy - result.hotspot.y, .width = result.size.x, .height = result.size.y };
            }
        };
        self.host.cursor(self.host.context, result);
    }
    fn deliver(self: *Controller, events: []const inputs.Input) void {
        _ = self.retain();
        defer self.release();
        for (events) |event| {
            if (self.closed.load(.acquire)) break;
            self.host.input(self.host.context, event);
        }
    }
    pub fn key(self: *Controller, down: bool, code: u16, flags: u64, decimal: bool) bool {
        if (self.closed.load(.acquire)) return false;
        const batch = self.keyboard.key(down, code, flags, decimal) orelse return false;
        self.deliver(batch.events());
        return true;
    }
    pub fn flagsChanged(self: *Controller, code: u16, flags: u64) void {
        if (self.closed.load(.acquire)) return;
        const batch = self.keyboard.flagsChanged(code, flags);
        self.deliver(batch.events());
    }
    pub fn focusLost(self: *Controller) void {
        const batch = self.keyboard.releaseAll();
        self.capture.release(self.host.capture);
        // Close still releases guest keys. Hold self across a reentrant native callback.
        _ = self.retain();
        defer self.release();
        for (batch.events()) |event| self.host.input(self.host.context, event);
        self.updateCursor();
    }
    pub fn button(self: *Controller, down: bool, button_value: inputs.Button, key_window: bool) void {
        if (self.closed.load(.acquire)) return;
        if (down and key_window and self.latest != null and self.latest.?.pointer == .relative) {
            _ = self.capture.acquire(self.host.capture);
            self.updateCursor();
        }
        self.deliver(&.{if (down) .{ .press = button_value } else .{ .release = button_value }});
    }
    pub fn motion(self: *Controller, point: input.Point, dx: f64, dy: f64) void {
        if (self.closed.load(.acquire)) return;
        const latest = self.latest orelse return;
        const event = if (latest.pointer == .relative) input.relative(self.capture.captured, dx, dy) else blk: {
            const f = (latest.frame orelse return).publication.snapshot();
            break :blk input.absolute(self.bounds, @intCast(f.width), @intCast(f.height), point);
        };
        if (event) |e| self.deliver(&.{e});
    }
    pub fn scroll(self: *Controller, dy: f64) void {
        const batch = input.scroll(dy);
        self.deliver(batch.events());
    }
};
const Observation = struct {
    refs: std.atomic.Value(usize) = .init(1),
    owner: *Controller,
    identity: trace.Identity,
    revision: d.Revision,
    attempt: policy.MetalRecovery.Attempt,
    epoch: u64,
    requested: u64,
    committed: u64 = 0,
    advanced: bool,
    fn create(owner: *Controller, p: Controller.Pending) !*Observation {
        const self = try owner.allocator.create(Observation);
        self.* = .{ .owner = owner.retain(), .identity = trace.Identity.from(p.snapshot).?, .revision = p.snapshot.frame.?.revision(), .attempt = p.attempt, .epoch = owner.source.diagnostics.currentEpoch(), .requested = p.requested, .advanced = p.snapshot.frame.?.publication.snapshot().advanced_video };
        return self;
    }
    fn release(self: *Observation) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const owner = self.owner;
        owner.allocator.destroy(self);
        owner.release();
    }
    fn cast(p: *anyopaque) *Observation {
        return @ptrCast(@alignCast(p));
    }
    fn retainC(p: *anyopaque) callconv(.c) void {
        const old = cast(p).refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
    }
    fn releaseC(p: *anyopaque) callconv(.c) void {
        cast(p).release();
    }
    fn descriptor(self: *Observation) gpu.Observer {
        return .{ .context = self, .retain = retainC, .release = releaseC, .event = event };
    }
    fn event(p: *anyopaque, value: *const gpu.Observation) callconv(.c) void {
        const self = cast(p);
        const owner = self.owner;
        if (owner.closed.load(.acquire)) return;
        const current = owner.latest != null and owner.latest.?.stamp.generation == self.identity.desktop_generation;
        if (value.stage == 1) {
            owner.source.diagnostics.interval(.commit_to_completion, self.committed, value.continuous_ns, self.epoch);
            if (value.status != 0) {
                owner.source.diagnostics.add(.metal_errors, 1, self.epoch);
                owner.source.traces.dropped(self.identity);
            }
            if (current) switch (owner.recovery.complete(self.attempt, value.status == 0, owner.selected)) {
                .none => {},
                .request_latest => {
                    owner.redraw = true;
                    owner.requestLatest();
                },
                .cpu_fallback => {
                    owner.forced_cpu = self.revision;
                    owner.redraw = true;
                    owner.requestLatest();
                },
            };
        } else if (value.stage == 2) {
            if (value.status == 0) {
                owner.source.diagnostics.presented(self.advanced, self.epoch);
                if (timing.mediaTimestamp(value.media_time, value.media_now, value.continuous_ns)) |ns| {
                    if (ns >= self.requested) owner.source.diagnostics.interval(.request_to_presented, self.requested, ns, self.epoch);
                    owner.source.traces.presented(self.identity, ns);
                }
                if (current) owner.drops.succeeded(self.revision);
            } else {
                owner.source.traces.dropped(self.identity);
                if (current and owner.drops.dropped(self.revision, owner.selected, owner.visible)) {
                    owner.redraw = true;
                    owner.requestLatest();
                }
            }
        }
    }
};
