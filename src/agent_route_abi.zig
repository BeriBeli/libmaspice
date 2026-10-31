const std = @import("std");
const desktop = @import("desktop_abi.zig");
const agent = @import("agent_runner_abi.zig");
const Route = @import("agent_route.zig").Route(desktop.Desktop, agent.Handle);
const a = std.heap.c_allocator;
pub export fn spice_zig_agent_route_create(output: ?*?*Route) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = a.create(Route) catch return -2;
    self.* = .{};
    out.* = self;
    return 0;
}
pub export fn spice_zig_agent_route_destroy(handle: ?*Route) void {
    if (handle) |self| {
        self.deinit();
        a.destroy(self);
    }
}
pub export fn spice_zig_agent_route_observe(handle: ?*Route, event: ?*const desktop.Event) c_int {
    const self = handle orelse return -1;
    const value = event orelse return -1;
    self.observe(value.*) catch return -47;
    return 0;
}
pub export fn spice_zig_agent_route_attach(handle: ?*Route, runner: ?*agent.Handle) c_int {
    const self = handle orelse return -1;
    const value = runner orelse return -1;
    self.attach(value) catch |err| return if (err == error.AgentAlreadyAttached) -53 else -47;
    return 0;
}
pub export fn spice_zig_agent_route_detach(handle: ?*Route, runner: ?*agent.Handle) void {
    const self = handle orelse return;
    const value = runner orelse return;
    self.detach(value);
}
