const std = @import("std");
const desktop = @import("desktop_abi.zig");
const webdav = @import("webdav_abi.zig");

const Route = @import("webdav_route.zig").Route(desktop.Desktop, webdav.Runner);
const a = std.heap.c_allocator;
pub export fn spice_zig_webdav_route_create(output: ?*?*Route) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = a.create(Route) catch return -2;
    self.* = .{};
    out.* = self;
    return 0;
}
pub export fn spice_zig_webdav_route_destroy(handle: ?*Route) void {
    if (handle) |self| {
        self.deinit();
        a.destroy(self);
    }
}
pub export fn spice_zig_webdav_route_observe(handle: ?*Route, event: ?*const desktop.Event) c_int {
    const self = handle orelse return -1;
    const value = event orelse return -1;
    return @intFromBool(self.observe(value.*) catch |err| return webdav.status(err));
}
pub export fn spice_zig_webdav_route_attach(handle: ?*Route, desktop_handle: ?*desktop.Desktop, runner: ?*webdav.Handle) c_int {
    const self = handle orelse return -1;
    const runtime = desktop_handle orelse return -1;
    const value = (runner orelse return -1).runner;
    if (value.runtime != runtime) return -1;
    self.attach(runtime, value) catch |err| return if (err == error.WebDAVAlreadyAttached) -59 else webdav.status(err);
    return 0;
}
pub export fn spice_zig_webdav_route_detach(handle: ?*Route, runner: ?*webdav.Handle) void {
    const self = handle orelse return;
    self.detach((runner orelse return).runner);
}
