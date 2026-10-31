const std = @import("std");
const desktop = @import("desktop_abi.zig");
const audio = @import("audio_abi.zig");
const Route = @import("audio_route.zig").Route(desktop.Desktop, audio.Handle);
const a = std.heap.c_allocator;
pub export fn spice_zig_audio_route_create(output: ?*?*Route) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = a.create(Route) catch return -2;
    self.* = .{};
    out.* = self;
    return 0;
}
pub export fn spice_zig_audio_route_destroy(handle: ?*Route) void {
    if (handle) |self| {
        self.deinit();
        a.destroy(self);
    }
}
pub export fn spice_zig_audio_route_observe(handle: ?*Route, event: ?*const desktop.Event) c_int {
    const self = handle orelse return -1;
    const value = event orelse return -1;
    self.observe(value.*) catch return -48;
    return 0;
}
pub export fn spice_zig_audio_route_attach(handle: ?*Route, recording: u8, runner: ?*audio.Handle) c_int {
    const self = handle orelse return -1;
    const value = runner orelse return -1;
    if (recording > 1 or value.options.playback != (recording == 0) or value.options.capture != (recording == 1) or value.options.playback_id != 0 or value.options.record_id != 0) return -1;
    self.attach(recording != 0, value) catch |err| return if (err == error.AudioAlreadyAttached) -52 else -48;
    return 0;
}
pub export fn spice_zig_audio_route_detach(handle: ?*Route, recording: u8, runner: ?*audio.Handle) void {
    const self = handle orelse return;
    const value = runner orelse return;
    if (recording > 1) return;
    self.detach(recording != 0, value);
}
