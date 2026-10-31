//! Owned public C snapshots and subscriptions; all desktop policy lives in Zig.
const std = @import("std");
const s = @import("root.zig");
const desktop = @import("desktop_abi.zig");
const a = std.heap.c_allocator;
pub const Session = s.desktop_source_session.Session(desktop.Desktop);
const Subscription = s.desktop_source.Subscription;
const Snapshot = s.desktop_snapshot.Snapshot;
const Latch = s.desktop_snapshot.ReadyLatch;
pub const Options = extern struct { maximum_subscriptions: usize, maximum_surfaces: usize, maximum_frame_bytes: usize };
pub const Info = extern struct { generation: u64, delivery_sequence: u64, frame_sequence: u64, frame_session: u64, pointer_mode: u32, has_frame: u32, channel_id: u8, reserved: [7]u8 };
pub const CursorInfo = extern struct { x: i32, y: i32, visible: u32, trail_length: u32, trail_frequency: u32, has_image: u32, unique: u64, format: u32, width: u32, height: u32, hot_x: u32, hot_y: u32, flags: u32 };
pub const Metrics = extern struct { delivered: u64, coalesced: u64, handler_deliveries: u64, subscriptions: u64, visible: u64 };
fn status(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -2,
        error.InvalidLimits => -1,
        error.SubscriptionLimit, error.DesktopSurfaceLimit, error.DesktopFrameBudget => -60,
        else => -1,
    };
}
pub export fn spice_zig_source_options(output: ?*Options) void {
    if (output) |out| out.* = .{ .maximum_subscriptions = 256, .maximum_surfaces = 4096, .maximum_frame_bytes = 256 * 1024 * 1024 };
}
pub export fn spice_zig_source_create(runtime: ?*desktop.Desktop, options: ?*const Options, output: ?*?*Session) c_int {
    const out = output orelse return -1;
    out.* = null;
    const owner = runtime orelse return -1;
    const opts = options orelse return -1;
    out.* = Session.create(a, owner, .{ .maximum_subscriptions = opts.maximum_subscriptions, .maximum_surfaces = opts.maximum_surfaces, .maximum_frame_bytes = opts.maximum_frame_bytes }) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_source_destroy(handle: ?*Session) void {
    if (handle) |self| self.destroy();
}
pub export fn spice_zig_source_observe(handle: ?*Session, event: ?*const desktop.Event) c_int {
    const self = handle orelse return -1;
    const value = event orelse return -1;
    self.observe(value.*) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_source_status(handle: ?*Session, error_category: ?*?[*:0]const u8) c_int {
    if (error_category) |out| out.* = null;
    const self = handle orelse return -1;
    self.source.status() catch |err| {
        if (error_category) |out| out.* = @errorName(err).ptr;
        return status(err);
    };
    return 0;
}
pub export fn spice_zig_source_metrics(handle: ?*Session, output: ?*Metrics) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(Metrics);
    const self = handle orelse return -1;
    const v = self.source.metrics();
    out.* = .{ .delivered = v.delivered, .coalesced = v.coalesced, .handler_deliveries = v.handler_deliveries, .subscriptions = v.subscriptions, .visible = v.visible };
    return 0;
}
pub export fn spice_zig_source_subscribe(handle: ?*Session, channel: u8, surface: u32, output: ?*?*Subscription) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    out.* = self.source.subscribe(.{ .channel = channel, .surface = surface }) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_subscription_cancel(handle: ?*Subscription) void {
    if (handle) |self| self.cancel();
}
pub export fn spice_zig_subscription_destroy(handle: ?*Subscription) void {
    if (handle) |self| self.destroy();
}
pub export fn spice_zig_subscription_demand(handle: ?*Subscription, visible: u8) c_int {
    const self = handle orelse return -1;
    if (visible > 1) return -1;
    self.setDemand(visible == 1) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_subscription_request_latest(handle: ?*Subscription) c_int {
    const self = handle orelse return -1;
    self.requestLatest() catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_subscription_acknowledge(handle: ?*Subscription, session: u64, channel: u8, surface: u32, lifecycle: u64, revision: u64) c_int {
    const self = handle orelse return -1;
    self.acknowledge(.{ .session = session, .channel = channel, .surface = .{ .id = surface, .lifecycle = lifecycle, .value = revision } }) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_subscription_next(handle: ?*Subscription, wait: u8, output: ?*?*Snapshot) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    if (wait > 1) return -1;
    const result = a.create(Snapshot) catch return -2;
    result.* = (self.next(wait == 1) catch |err| {
        a.destroy(result);
        return status(err);
    }) orelse {
        a.destroy(result);
        return 0;
    };
    out.* = result;
    return 1;
}
const CHandler = extern struct {
    context: ?*anyopaque,
    retain: ?*const fn (?*anyopaque) callconv(.c) void,
    release: ?*const fn (?*anyopaque) callconv(.c) void,
    emit: ?*const fn (?*anyopaque, *const Snapshot) callconv(.c) void,
};
const Handler = struct {
    refs: std.atomic.Value(usize) = .init(1),
    callbacks: CHandler,
    fn retain(p: *anyopaque) void {
        const self: *Handler = @ptrCast(@alignCast(p));
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
    }
    fn release(p: *anyopaque) void {
        const self: *Handler = @ptrCast(@alignCast(p));
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.callbacks.release.?(self.callbacks.context);
            a.destroy(self);
        }
    }
    fn emit(p: *anyopaque, snapshot: Snapshot) void {
        const self: *Handler = @ptrCast(@alignCast(p));
        self.callbacks.emit.?(self.callbacks.context, &snapshot);
    }
};
pub export fn spice_zig_subscription_handler(handle: ?*Subscription, input: ?*const CHandler) c_int {
    const self = handle orelse return -1;
    const callbacks = if (input) |v| v.* else {
        self.setHandler(null) catch |err| return status(err);
        return 0;
    };
    if (callbacks.retain == null or callbacks.release == null or callbacks.emit == null) return -1;
    const bridge = a.create(Handler) catch return -2;
    bridge.* = .{ .callbacks = callbacks };
    callbacks.retain.?(callbacks.context);
    defer Handler.release(bridge);
    self.setHandler(.{ .context = bridge, .retain = Handler.retain, .release = Handler.release, .emit = Handler.emit }) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_snapshot_clone(handle: ?*const Snapshot, output: ?*?*Snapshot) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    const result = a.create(Snapshot) catch return -2;
    result.* = self.clone();
    out.* = result;
    return 0;
}
pub export fn spice_zig_snapshot_destroy(handle: ?*Snapshot) void {
    if (handle) |self| {
        self.deinit();
        a.destroy(self);
    }
}
pub export fn spice_zig_snapshot_info(handle: ?*const Snapshot, output: ?*Info) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(Info);
    const self = handle orelse return -1;
    out.* = .{ .generation = self.stamp.generation, .delivery_sequence = self.stamp.sequence, .frame_sequence = if (self.frame) |f| f.sequence else 0, .frame_session = if (self.frame) |f| f.session else 0, .pointer_mode = @backingInt(self.pointer), .has_frame = @intFromBool(self.frame != null), .channel_id = if (self.frame) |f| f.channel else 0, .reserved = @splat(0) };
    return 0;
}
pub export fn spice_zig_snapshot_frame(handle: ?*const Snapshot, output: ?*?*desktop.Frame) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    const frame = self.frame orelse return 0;
    const result = a.create(desktop.Frame) catch return -2;
    result.* = .{ .publication = frame.publication.retain(), .damage_override = frame.damage };
    out.* = result;
    return 1;
}
pub export fn spice_zig_snapshot_cursor(handle: ?*const Snapshot, output: ?*CursorInfo, bytes: ?*?[*]const u8, count: ?*usize) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(CursorInfo);
    const data = bytes orelse return -1;
    data.* = null;
    const size = count orelse return -1;
    size.* = 0;
    const self = handle orelse return -1;
    const value = self.cursor orelse return 0;
    out.x = value.position.x;
    out.y = value.position.y;
    out.visible = @intFromBool(value.visible);
    out.trail_length = value.trail.length;
    out.trail_frequency = value.trail.frequency;
    if (value.payload) |payload| {
        const h = payload.header;
        out.has_image = 1;
        out.unique = h.unique;
        out.format = h.kind;
        out.width = h.width;
        out.height = h.height;
        out.hot_x = h.hot_x;
        out.hot_y = h.hot_y;
        out.flags = payload.flags;
        data.* = payload.data.bytes().ptr;
        size.* = payload.data.bytes().len;
    }
    return 1;
}
pub export fn spice_zig_ready_create() ?*Latch {
    const value = a.create(Latch) catch return null;
    value.* = .{};
    return value;
}
pub export fn spice_zig_ready_destroy(handle: ?*Latch) void {
    if (handle) |self| {
        self.deinit();
        a.destroy(self);
    }
}
pub export fn spice_zig_ready_offer(handle: ?*Latch, snapshot: ?*const Snapshot, ready_ns: u64) c_int {
    const self = handle orelse return -1;
    const value = snapshot orelse return -1;
    return @intFromBool(self.offer(value.*, ready_ns));
}
pub export fn spice_zig_ready_take(handle: ?*Latch, selected_ns: u64, output: ?*?*Snapshot, ready_ns: ?*u64, waiting_ns: ?*u64) c_int {
    const out = output orelse return -1;
    out.* = null;
    const ready = ready_ns orelse return -1;
    ready.* = 0;
    const waiting = waiting_ns orelse return -1;
    waiting.* = 0;
    const self = handle orelse return -1;
    const result = a.create(Snapshot) catch return -2;
    const taken = self.take(selected_ns) orelse {
        a.destroy(result);
        return 0;
    };
    result.* = taken.snapshot;
    out.* = result;
    ready.* = taken.ready_ns;
    waiting.* = taken.waiting_ns;
    return 1;
}
pub export fn spice_zig_ready_restore(handle: ?*Latch, snapshot: ?*const Snapshot, ready_ns: u64) c_int {
    const self = handle orelse return -1;
    const value = snapshot orelse return -1;
    return @intFromBool(self.restoreIfEmpty(value.*, ready_ns));
}
pub export fn spice_zig_ready_discard(handle: ?*Latch) void {
    if (handle) |self| self.discard();
}

// Internal optional AppKit archive boundary. Caller holds Session during calls.
pub export fn spice_zig_source_acquire_core(handle: ?*Session) ?*s.desktop_source.Source {
    return if (handle) |self| self.source.retain() else null;
}
pub export fn spice_zig_source_native_context(handle: ?*Session) ?*anyopaque {
    const self = handle orelse return null;
    return if (self.runtime.child_configuration.native) |native| native.handle else null;
}

// Offline consumers use the same checked Surface and Source path as sessions.
// Each Store has one caller; frames retain independent immutable publications.
const Offscreen = s.surface.Store;
pub export fn spice_zig_offscreen_create(output: ?*?*Offscreen) c_int {
    const out = output orelse return -1;
    out.* = null;
    const store = a.create(Offscreen) catch return -2;
    store.* = Offscreen.init(a, .{}, null);
    out.* = store;
    return 0;
}
pub export fn spice_zig_offscreen_destroy(handle: ?*Offscreen) void {
    if (handle) |self| {
        self.deinit();
        a.destroy(self);
    }
}
pub export fn spice_zig_offscreen_surface(handle: ?*Offscreen, id: u32, width: u32, height: u32, format: u32) c_int {
    const self = handle orelse return -1;
    var token: s.cancel.Token = .{};
    defer token.deinit();
    self.create(id, width, height, format, &token) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_offscreen_fill(handle: ?*Offscreen, id: u32, rect: ?*const desktop.Rect, argb: u32) c_int {
    const self = handle orelse return -1;
    const r = rect orelse return -1;
    var token: s.cancel.Token = .{};
    defer token.deinit();
    _ = self.fill(id, &.{.{ .x = r.x, .y = r.y, .width = r.width, .height = r.height }}, argb, &token) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_offscreen_frame(handle: ?*Offscreen, id: u32, output: ?*?*desktop.Frame) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    const frame = a.create(desktop.Frame) catch return -2;
    const snapshot = self.snapshot(id) catch |err| {
        a.destroy(frame);
        return status(err);
    };
    defer snapshot.deinit();
    const publication = self.publicationSnapshot(snapshot.revision) catch |err| {
        a.destroy(frame);
        return status(err);
    };
    frame.* = .{ .publication = publication orelse {
        a.destroy(frame);
        return -1;
    } };
    frame.publication.full_damage = true;
    out.* = frame;
    return 0;
}
pub export fn spice_zig_source_begin_synthetic(handle: ?*Session) c_int {
    const self = handle orelse return -1;
    self.source.begin(.absolute, false, true) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_source_publish_synthetic(handle: ?*Session, frame: ?*const desktop.Frame) c_int {
    const self = handle orelse return -1;
    const value = frame orelse return -1;
    self.source.receiveFrame(0, value.publication) catch |err| return status(err);
    value.publication.commit();
    return 0;
}
