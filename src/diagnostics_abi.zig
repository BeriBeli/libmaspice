//! Thin C ownership/conversion boundary for native presentation and trace hosts.
const std = @import("std");
const s = @import("root.zig");
const Source = s.desktop_source.Source;
const Session = @import("desktop_source_abi.zig").Session;
const Capture = s.interaction_capture.Capture;
const a = std.heap.c_allocator;
const Timing = extern struct { count: u64, p95_ms: f64, maximum_ms: f64, has_values: u32, reserved: u32 = 0 };
const Metrics = extern struct { counters: [15]u64, latency: [4]Timing, fallback_frames: u64, fallback_counts: [6]u64, last_fallback: u32, has_fallback: u32 };
const Identity = extern struct {
    desktop_generation: u64,
    surface_generation: u64,
    frame_revision: u64,
    delivery_sequence: u64,
    surface_id: u32,
    channel_id: u8,
    reserved: [3]u8 = @splat(0),
    fn from(id: s.interaction_trace.Identity) Identity {
        return .{ .desktop_generation = id.desktop_generation, .surface_generation = id.surface_generation, .frame_revision = id.revision, .delivery_sequence = id.sequence, .surface_id = id.surface, .channel_id = id.channel };
    }
    fn value(self: Identity) s.interaction_trace.Identity {
        return .{ .desktop_generation = self.desktop_generation, .channel = self.channel_id, .surface = self.surface_id, .surface_generation = self.surface_generation, .revision = self.frame_revision, .sequence = self.delivery_sequence };
    }
};
const String = extern struct {
    data: ?[*]const u8,
    size: usize,
    fn slice(self: String, maximum: usize) ![]const u8 {
        if (self.size > maximum or (self.data == null and self.size != 0)) return error.InvalidArgument;
        return if (self.data) |p| p[0..self.size] else &.{};
    }
};
const Config = extern struct { pair_id: String, version: String, run_id: String, token: String, path: String, order: u64, action: u32, checksum: u32 };
const Record = struct { bytes: []u8 };
fn status(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -2,
        error.Cancelled => -31,
        error.CaptureAlreadyFinished => -61,
        error.CaptureAlreadyActive, error.PresentationWaitAlreadyRegistered => -62,
        error.RecordTooLarge, error.OutputTooLarge => -63,
        else => -1,
    };
}
pub export fn spice_zig_source_diagnostics(handle: ?*Session, output: ?*?*Source) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    out.* = self.source.retain();
    return 0;
}
pub export fn spice_zig_diagnostics_destroy(handle: ?*Source) void {
    if (handle) |self| self.release();
}
pub export fn spice_zig_diagnostics_now_ns() u64 {
    var timebase: std.c.mach_timebase_info_data = undefined;
    if (std.c.mach_timebase_info(&timebase) != 0 or timebase.denom == 0) return 0;
    return s.clock.nanoseconds(timebase);
}
pub export fn spice_zig_diagnostics_epoch(handle: ?*Source) u64 {
    return if (handle) |self| self.diagnostics.currentEpoch() else 0;
}
pub export fn spice_zig_diagnostics_reset(handle: ?*Source) void {
    if (handle) |self| self.diagnostics.reset();
}
pub export fn spice_zig_diagnostics_metrics(handle: ?*Source, output: ?*Metrics) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(Metrics);
    const self = handle orelse return -1;
    const value = self.diagnostics.snapshot();
    out.counters = value.counters;
    out.fallback_frames = value.fallback_frames;
    out.fallback_counts = value.fallback_counts;
    out.has_fallback = @intFromBool(value.last_fallback != null);
    out.last_fallback = if (value.last_fallback) |v| @backingInt(v) else 0;
    for (value.histograms, &out.latency) |h, *dest| {
        const summary = h.summary();
        dest.* = .{ .count = summary.sample_count, .p95_ms = summary.p95_ms orelse 0, .maximum_ms = summary.maximum_ms orelse 0, .has_values = @intFromBool(summary.p95_ms != null) };
    }
    return 0;
}
pub export fn spice_zig_diagnostics_count(handle: ?*Source, counter: u32, count: u64, epoch: ?*const u64) c_int {
    const self = handle orelse return -1;
    const kind = std.enums.fromInt(s.presentation_diagnostics.Counter, counter) orelse return -1;
    self.diagnostics.add(kind, count, if (epoch) |p| p.* else null);
    return 0;
}
pub export fn spice_zig_diagnostics_presented(handle: ?*Source, advanced: u8, epoch: ?*const u64) c_int {
    const self = handle orelse return -1;
    if (advanced > 1) return -1;
    self.diagnostics.presented(advanced == 1, if (epoch) |p| p.* else null);
    return 0;
}
pub export fn spice_zig_diagnostics_interval(handle: ?*Source, kind: u32, start: u64, end: u64, epoch: ?*const u64) c_int {
    const self = handle orelse return -1;
    const value = std.enums.fromInt(s.presentation_diagnostics.Latency, kind) orelse return -1;
    self.diagnostics.interval(value, start, end, if (epoch) |p| p.* else null);
    return 0;
}
pub export fn spice_zig_diagnostics_fallback(handle: ?*Source, reason: u32) c_int {
    const self = handle orelse return -1;
    const value = std.enums.fromInt(s.presentation_diagnostics.Fallback, reason) orelse return -1;
    self.diagnostics.fallback(value);
    return 0;
}
pub export fn spice_zig_snapshot_trace_identity(handle: ?*const s.desktop_snapshot.Snapshot, output: ?*Identity) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(Identity);
    const snapshot = handle orelse return -1;
    const id = s.interaction_trace.Identity.from(snapshot.*) orelse return 0;
    out.* = .from(id);
    return 1;
}
pub export fn spice_zig_diagnostics_trace_stage(handle: ?*Source, stage: u32, identity: ?*const Identity, ns: u64, ready: u64) c_int {
    const self = handle orelse return -1;
    const id = (identity orelse return -1).value();
    switch (stage) {
        0 => self.traces.selected(id, ready, ns),
        1 => self.traces.committed(id, ns),
        2 => self.traces.presented(id, ns),
        3 => self.traces.dropped(id),
        else => return -1,
    }
    return 0;
}
pub export fn spice_zig_trace_create(handle: ?*Source, config: ?*const Config, output: ?*?*Capture, category: ?*?[*:0]const u8) c_int {
    if (category) |out| out.* = null;
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    const c = config orelse return -1;
    const pair = c.pair_id.slice(65536) catch return -1;
    const version = c.version.slice(65536) catch return -1;
    const run = c.run_id.slice(65536) catch return -1;
    const token = c.token.slice(65536) catch return -1;
    const path = c.path.slice(4096) catch return -1;
    const action = std.enums.fromInt(s.interaction_record.Action, c.action) orelse return -1;
    out.* = Capture.create(a, self.traces, .{ .pair_id = pair, .version = version, .run_id = run, .order = c.order, .action = action, .token = token, .checksum = c.checksum }, path) catch |err| {
        if (category) |p| p.* = @errorName(err).ptr;
        return status(err);
    };
    return 0;
}
pub export fn spice_zig_trace_destroy(handle: ?*Capture) void {
    if (handle) |self| self.destroy();
}
pub export fn spice_zig_trace_host_input(handle: ?*Capture, scheduled: u64, input: u64, started: u64) c_int {
    const self = handle orelse return -1;
    self.hostInput(scheduled, input, started) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_trace_send_completed(handle: ?*Capture, ns: u64, ack: ?*const u64) c_int {
    const self = handle orelse return -1;
    self.sendCompleted(ns, if (ack) |p| p.* else null) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_trace_motion_ack(handle: ?*Capture, ns: u64) c_int {
    const self = handle orelse return -1;
    self.motionAcknowledged(ns) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_trace_guest(handle: ?*Capture, received: u64, drawn: u64, revision: u64) c_int {
    const self = handle orelse return -1;
    self.guestEvidence(received, drawn, revision) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_trace_wait(handle: ?*Capture, token: ?*s.cancel.Token, output: ?*Identity) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(Identity);
    const self = handle orelse return -1;
    const cancellation = token orelse return -1;
    out.* = .from(self.waitPresented(cancellation) catch |err| return status(err));
    return 0;
}
pub export fn spice_zig_trace_finish(handle: ?*Capture, reason: String, output: ?*?*Record, category: ?*?[*:0]const u8) c_int {
    if (category) |out| out.* = null;
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    const external = reason.slice(65536) catch return -1;
    const result = a.create(Record) catch return -2;
    result.* = .{ .bytes = self.finish(a, if (reason.data != null) external else null) catch |err| {
        a.destroy(result);
        if (category) |p| p.* = @errorName(err).ptr;
        return status(err);
    } };
    out.* = result;
    return 0;
}
pub export fn spice_zig_trace_record_bytes(handle: ?*const Record, output: ?*?[*]const u8, size: ?*usize) c_int {
    const out = output orelse return -1;
    out.* = null;
    const count = size orelse return -1;
    count.* = 0;
    const self = handle orelse return -1;
    out.* = self.bytes.ptr;
    count.* = self.bytes.len;
    return 0;
}
pub export fn spice_zig_trace_record_destroy(handle: ?*Record) void {
    if (handle) |self| {
        a.free(self.bytes);
        a.destroy(self);
    }
}
