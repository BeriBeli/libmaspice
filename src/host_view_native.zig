//! Optional native-host archive. Scalar ABI and system calls only; controller
//! policy remains in host_view. Source/Runtime lifetime ends at creation boundary.
const std = @import("std");
const view = @import("host_view.zig");
const input = @import("host_input.zig");
const inputs = @import("inputs.zig");
const source = @import("desktop_source.zig");
const graphics = @import("graphics.zig");
const C = view.Controller;
extern "c" fn spice_zig_source_acquire_core(*anyopaque) ?*source.Source;
extern "c" fn spice_zig_source_native_context(*anyopaque) ?*anyopaque;
extern "c" fn sz_host_box_destroy(*anyopaque) void;
extern "c" fn sz_host_schedule(*anyopaque, *C) void;
extern "c" fn sz_host_ticking(*anyopaque, c_int) void;
extern "c" fn sz_host_layout(*anyopaque, input.Rect, f64, f64) void;
extern "c" fn sz_host_draw(*anyopaque, *C) c_int;
extern "c" fn sz_host_content(*anyopaque, c_int) void;
extern "c" fn sz_host_cursor(*anyopaque, c_int, [*]const u8, usize, u16, u16, input.Point, input.Point, ?*const input.Rect) void;
extern "c" fn sz_host_input(*anyopaque, u8, i32, i32, u8) void;
extern "c" fn sz_host_failure(*anyopaque, [*:0]const u8) void;
extern "c" fn sz_host_location(*anyopaque, *input.Point) c_int;
extern "c" fn sz_host_disconnect(*anyopaque) c_int;
extern "c" fn sz_host_warp(*anyopaque, input.Point) void;
extern "c" fn sz_host_reconnect(*anyopaque) void;
extern "c" fn sz_host_hide(*anyopaque) void;
extern "c" fn sz_host_unhide(*anyopaque) void;
extern "c" fn sz_host_cpu_pixels(*anyopaque, [*]const u8, usize, u32, u32, c_int, input.Rect) void;
fn destroy(p: *anyopaque) void {
    sz_host_box_destroy(p);
}
fn schedule(p: *anyopaque, c: *C) void {
    sz_host_schedule(p, c);
}
fn ticking(p: *anyopaque, b: bool) void {
    sz_host_ticking(p, @intFromBool(b));
}
fn layout(p: *anyopaque, r: input.Rect, size: @import("presentation_policy.zig").Size) void {
    sz_host_layout(p, r, size.width, size.height);
}
fn draw(p: *anyopaque, c: *C) view.DrawResult {
    return switch (sz_host_draw(p, c)) {
        0 => .submitted,
        1 => .retry,
        else => .fallback,
    };
}
fn content(p: *anyopaque, v: view.Content) void {
    sz_host_content(p, @intCast(@backingInt(v)));
}
fn cursor(p: *anyopaque, v: view.Cursor) void {
    sz_host_cursor(p, @intCast(@backingInt(v.kind)), v.bytes.ptr, v.bytes.len, v.width, v.height, v.hotspot, v.size, if (v.overlay) |*r| r else null);
}
fn emit(p: *anyopaque, v: inputs.Input) void {
    switch (v) {
        .key_down => |x| sz_host_input(p, 0, @bitCast(x), 0, 0),
        .key_up => |x| sz_host_input(p, 1, @bitCast(x), 0, 0),
        .lock_modifiers => |x| sz_host_input(p, 2, x, 0, 0),
        .motion => |m| sz_host_input(p, 3, m.dx, m.dy, 0),
        .position => |m| sz_host_input(p, 4, @bitCast(m.x), @bitCast(m.y), m.display_id),
        .press => |b| sz_host_input(p, 5, @intCast(@backingInt(b)), 0, 0),
        .release => |b| sz_host_input(p, 6, @intCast(@backingInt(b)), 0, 0),
    }
}
fn failure(p: *anyopaque, err: anyerror) void {
    sz_host_failure(p, @errorName(err).ptr);
}
fn location(p: *anyopaque) ?input.Point {
    var point: input.Point = undefined;
    return if (sz_host_location(p, &point) != 0) point else null;
}
fn disconnect(p: *anyopaque) bool {
    return sz_host_disconnect(p) != 0;
}
fn warp(p: *anyopaque, point: input.Point) void {
    sz_host_warp(p, point);
}
fn reconnect(p: *anyopaque) void {
    sz_host_reconnect(p);
}
fn hide(p: *anyopaque) void {
    sz_host_hide(p);
}
fn unhide(p: *anyopaque) void {
    sz_host_unhide(p);
}
pub fn host(box: *anyopaque) view.Host {
    return .{ .context = box, .destroy = destroy, .schedule = schedule, .ticking = ticking, .layout = layout, .draw = draw, .content = content, .cursor = cursor, .input = emit, .failure = failure, .capture = .{ .context = box, .location = location, .disconnect = disconnect, .warp = warp, .reconnect = reconnect, .hide = hide, .unhide = unhide } };
}
pub export fn spice_zig_host_controller_create(session: ?*anyopaque, box: ?*anyopaque, channel: u8, surface: u32, path: ?[*:0]const u8) ?*C {
    const owner = session orelse return null;
    const context = box orelse return null;
    const src = spice_zig_source_acquire_core(owner) orelse return null;
    defer src.release();
    const native = spice_zig_source_native_context(owner);
    return C.create(std.heap.c_allocator, src, .{ .channel = channel, .surface = surface }, host(context), if (native) |n| graphics.Context{ .handle = n } else null, path) catch |err| {
        failure(context, err);
        return null;
    };
}
pub export fn spice_zig_host_close(c: *C) void {
    c.close();
}
pub export fn spice_zig_host_release(c: *C) void {
    c.release();
}
pub export fn spice_zig_host_ready(c: *C) void {
    c.ready();
}
pub export fn spice_zig_host_tick(c: *C) void {
    c.tick();
}
pub export fn spice_zig_host_configure(c: *C, visible: c_int, bounds: input.Rect, scale: f64) void {
    c.configure(visible != 0, bounds, scale);
}
pub export fn spice_zig_host_submit(c: *C, texture: ?*anyopaque, drawable: ?*anyopaque, width: u32, height: u32) c_int {
    return @intCast(@backingInt(c.submit(if (texture) |tex| .{ .texture = tex, .drawable = drawable, .width = width, .height = height } else null)));
}
pub export fn spice_zig_host_cpu_draw(c: *C, cg: *anyopaque) void {
    const f = c.cpuFrame() orelse return;
    const v = f.publication.snapshot();
    const bytes = f.publication.pixels() catch |err| {
        failure(c.host.context, err);
        return;
    };
    sz_host_cpu_pixels(cg, bytes.ptr, bytes.len, @intCast(v.width), @intCast(v.height), @intFromBool(v.format == .argb), input.contentRect(c.bounds, @intCast(v.width), @intCast(v.height)));
}
pub export fn spice_zig_host_key(c: *C, down: c_int, code: u16, flags: u64, decimal: c_int) c_int {
    return @intFromBool(c.key(down != 0, code, flags, decimal != 0));
}
pub export fn spice_zig_host_flags(c: *C, code: u16, flags: u64) void {
    c.flagsChanged(code, flags);
}
pub export fn spice_zig_host_focus_lost(c: *C) void {
    c.focusLost();
}
pub export fn spice_zig_host_button(c: *C, down: c_int, number: i64, key_window: c_int) void {
    c.button(down != 0, switch (number) {
        0 => .left,
        1 => .right,
        else => input.otherButton(number),
    }, key_window != 0);
}
pub export fn spice_zig_host_motion(c: *C, point: input.Point, dx: f64, dy: f64) void {
    c.motion(point, dx, dy);
}
pub export fn spice_zig_host_scroll(c: *C, dy: f64) void {
    c.scroll(dy);
}
