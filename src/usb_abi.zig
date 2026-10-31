const std = @import("std");
const s = @import("root.zig");
const host = @import("usb_host_abi.zig");
const a = std.heap.c_allocator;
const Desktop = s.supervisor.Supervisor(s.desktop_child);
pub const Runner = s.usb_runner.Runner(Desktop, @import("usb_shared_backend.zig").Backend);
pub const Options = extern struct { channel_id: u8, reserved: [7]u8, host: host.Options, maximum_queued_bytes: usize };
pub const Statistics = extern struct { received_bytes: u64, sent_bytes: u64, sent_packets: u64, queued_bytes: u64 };
pub export fn spice_zig_usb_options(output: ?*Options) void {
    if (output) |out| out.* = .{ .channel_id = 0, .reserved = @splat(0), .host = .{ .maximum_buffered_bytes = 16 * 1024 * 1024, .maximum_packet_bytes = 1024 * 1024 }, .maximum_queued_bytes = 16 * 1024 * 1024 };
}
pub export fn spice_zig_usb_create(desktop: ?*Desktop, options: ?*const Options, output: ?*?*Runner) c_int {
    const out = output orelse return -100;
    out.* = null;
    const runtime = desktop orelse return -100;
    const opts = options orelse return -100;
    if (!std.mem.allEqual(u8, &opts.reserved, 0)) return -100;
    out.* = Runner.create(a, runtime, .{ .channel_id = opts.channel_id, .maximum_queued_bytes = opts.maximum_queued_bytes, .host = .{ .maximum_buffered_bytes = opts.host.maximum_buffered_bytes, .maximum_packet_bytes = opts.host.maximum_packet_bytes } }) catch |err| return host.status(err);
    return 0;
}
pub export fn spice_zig_usb_observe(handle: ?*Runner, event: ?*const Desktop.Event) c_int {
    const self = handle orelse return -100;
    const value = event orelse return -100;
    self.observe(value.*) catch |err| return host.status(err);
    return 0;
}
pub export fn spice_zig_usb_device(handle: ?*Runner, attach: u8, bus: u8, address: u8, native_code: ?*c_int) c_int {
    if (native_code) |out| out.* = 0;
    const self = handle orelse return -100;
    if (attach > 1) return -100;
    self.device(if (attach == 1) .{ .bus = bus, .address = address } else null, native_code) catch |err| return host.status(err);
    return 0;
}
pub export fn spice_zig_usb_stop(handle: ?*Runner) void {
    if (handle) |self| self.stop();
}
pub export fn spice_zig_usb_destroy(handle: ?*Runner) void {
    if (handle) |self| self.destroy();
}
pub export fn spice_zig_usb_status(handle: ?*Runner, error_category: ?*?[*:0]const u8, native_code: ?*c_int) c_int {
    if (error_category) |out| out.* = null;
    if (native_code) |out| out.* = 0;
    const self = handle orelse return -100;
    const state = self.status();
    if (state.failure) |err| {
        if (error_category) |out| out.* = @errorName(err).ptr;
        if (native_code) |out| out.* = if (err == error.USBBackendFailure) state.backend_code else 0;
        return host.status(err);
    }
    return @intFromBool(state.finished);
}
pub export fn spice_zig_usb_statistics(handle: ?*Runner, output: ?*Statistics) c_int {
    const self = handle orelse return -100;
    const out = output orelse return -100;
    const v = self.statistics();
    out.* = .{ .received_bytes = v.received_bytes, .sent_bytes = v.sent_bytes, .sent_packets = v.sent_packets, .queued_bytes = v.queued_bytes };
    return 0;
}
// Retains the provided host; neither success nor failure consumes caller ownership.
pub export fn spice_zig_usb_create_shared(desktop: ?*Desktop, channel_id: u8, existing: ?*host.Host, output: ?*?*Runner) c_int {
    const out = output orelse return -100;
    out.* = null;
    const runtime = desktop orelse return -100;
    const value = existing orelse return -100;
    const backend = @import("usb_shared_backend.zig").Backend.createExisting(a, value) catch |err| return host.status(err);
    var options: s.usb_runner.Options = .{ .channel_id = channel_id, .host = value.value.options };
    options.host.maximum_packet_bytes = @min(options.host.maximum_packet_bytes, 1024 * 1024);
    out.* = Runner.createWithBackend(a, runtime, options, backend) catch |err| {
        backend.abandon();
        return host.status(err);
    };
    return 0;
}
pub export fn spice_zig_usb_ready(handle: ?*Runner) c_int {
    const self = handle orelse return -100;
    self.ready() catch |err| return host.status(err);
    return 0;
}
