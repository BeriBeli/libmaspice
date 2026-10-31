const std = @import("std");
const desktop = @import("desktop_abi.zig");
const usb = @import("usb_abi.zig");
const host = @import("usb_host_abi.zig");
const Route = @import("usb_route.zig").Route(desktop.Desktop, usb.Runner);
const a = std.heap.c_allocator;
pub export fn spice_zig_usb_route_create(output: ?*?*Route) c_int {
    const out = output orelse return -100;
    out.* = null;
    const self = a.create(Route) catch return -101;
    self.* = .{};
    out.* = self;
    return 0;
}
pub export fn spice_zig_usb_route_destroy(handle: ?*Route) void {
    if (handle) |self| {
        self.deinit();
        a.destroy(self);
    }
}
pub export fn spice_zig_usb_route_observe(handle: ?*Route, event: ?*const desktop.Event) c_int {
    const self = handle orelse return -100;
    const value = event orelse return -100;
    return @intFromBool(self.observe(value.*) catch |err| return host.status(err));
}
pub export fn spice_zig_usb_route_attach(handle: ?*Route, desktop_handle: ?*desktop.Desktop, runner: ?*usb.Runner) c_int {
    const self = handle orelse return -100;
    const runtime = desktop_handle orelse return -100;
    const value = runner orelse return -100;
    if (value.runtime != runtime) return -100;
    self.attach(runtime, value) catch |err| return if (err == error.USBAlreadyAttached) -109 else host.status(err);
    return 0;
}
pub export fn spice_zig_usb_route_detach(handle: ?*Route, runner: ?*usb.Runner) void {
    const self = handle orelse return;
    self.detach(runner orelse return);
}
