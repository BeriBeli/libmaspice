//! Optional audio owner; this is a binding to the actual Zig executor, not a
//! Swift scheduler. Creation is inert until explicitly enabled matching START.
const std = @import("std");
const s = @import("root.zig");
const a = std.heap.c_allocator;
const Desktop = s.supervisor.Supervisor(s.desktop_child);
pub const Handle = s.audio_runner.Runner(Desktop, s.audio_runner.NativeDevices);
pub const Options = extern struct { playback: u8, capture: u8, playback_id: u8, record_id: u8, maximum_queued_ms: u32, delay_interval_ms: u32, reserved: u32, maximum_event_bytes: usize };
pub const EventInfo = extern struct { kind: u32, recording: u32, channels: u32, frequency: u32, milliseconds: u32, muted: u32, volume_count: u32, reserved: u32, volume: [32]u16, count: u64, error_category: ?[*:0]const u8 };
pub const Statistics = extern struct { scheduled_packets: u64, scheduled_frames: u64, queued_playback_bytes: u64, queued_capture_bytes: u64, underflows: u64, notifications_dropped: u64 };
fn status(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -2,
        error.Cancelled => -31,
        error.AudioEventQueueFull => -48,
        error.AudioStreamChanged => -49,
        else => -1,
    };
}
pub export fn spice_zig_audio_options(output: ?*Options) void {
    if (output) |out| out.* = .{ .playback = 0, .capture = 0, .playback_id = 0, .record_id = 0, .maximum_queued_ms = 500, .delay_interval_ms = 50, .reserved = 0, .maximum_event_bytes = 32 * 1024 * 1024 };
}
pub export fn spice_zig_audio_create(desktop: ?*Desktop, options: ?*const Options, output: ?*?*Handle) c_int {
    const out = output orelse return -1;
    out.* = null;
    const runtime = desktop orelse return -1;
    const opts = options orelse return -1;
    if (opts.playback > 1 or opts.capture > 1 or opts.reserved != 0) return -1;
    out.* = Handle.create(a, runtime, .{}, .{ .playback = opts.playback != 0, .capture = opts.capture != 0, .playback_id = opts.playback_id, .record_id = opts.record_id, .maximum_queued_ms = opts.maximum_queued_ms, .delay_interval_ms = opts.delay_interval_ms, .maximum_event_bytes = opts.maximum_event_bytes }) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_audio_observe(handle: ?*Handle, event: ?*const Desktop.Event) c_int {
    const self = handle orelse return -1;
    const value = event orelse return -1;
    self.observe(value.*) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_audio_stop(handle: ?*Handle) void {
    if (handle) |self| self.stop();
}
pub export fn spice_zig_audio_join(handle: ?*Handle) void {
    if (handle) |self| self.join();
}
pub export fn spice_zig_audio_destroy(handle: ?*Handle) void {
    if (handle) |self| self.destroy();
}
pub export fn spice_zig_audio_status(handle: ?*Handle) c_int {
    const self = handle orelse return -1;
    const value = self.status();
    if (value.failure) |err| return status(err);
    return @intFromBool(value.finished);
}
pub export fn spice_zig_audio_statistics(handle: ?*Handle, output: ?*Statistics) c_int {
    const self = handle orelse return -1;
    const out = output orelse return -1;
    const v = self.statistics();
    out.* = .{ .scheduled_packets = v.scheduled_packets, .scheduled_frames = v.scheduled_frames, .queued_playback_bytes = v.queued_playback_bytes, .queued_capture_bytes = v.queued_capture_bytes, .underflows = v.underflows, .notifications_dropped = v.notifications_dropped };
    return 0;
}
pub export fn spice_zig_audio_next(handle: ?*Handle, output: ?*EventInfo) c_int {
    const self = handle orelse return -1;
    const out = output orelse return -1;
    out.* = std.mem.zeroes(EventInfo);
    const v = self.next() orelse return 0;
    out.* = .{ .kind = @backingInt(v.kind) + 1, .recording = @intFromBool(v.recording), .channels = v.configuration.channels, .frequency = v.configuration.frequency, .milliseconds = v.milliseconds, .muted = @intFromBool(v.muted), .volume_count = v.volume.count, .reserved = 0, .volume = @splat(0), .count = v.count, .error_category = if (v.failure) |err| @errorName(err).ptr else null };
    @memcpy(out.volume[0..v.volume.count], v.volume.values[0..v.volume.count]);
    return 1;
}
