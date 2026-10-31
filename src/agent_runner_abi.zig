//! Native optional pasteboard polling executor. Public ABI keeps all protocol,
//! scheduling and bounded queues in Zig; AppKit is a narrow host boundary.
const std = @import("std");
const s = @import("root.zig");
const agent = @import("agent_abi.zig");
const a = std.heap.c_allocator;
const Desktop = s.supervisor.Supervisor(s.desktop_child);
pub const Handle = s.agent_runner.Runner(Desktop, s.pasteboard.Context);
pub const Event = s.agent_runner.Output;
pub const Info = extern struct { kind: u32, reserved: u32, request: u64, key: agent.FileKey };
fn status(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -2,
        error.Cancelled => -31,
        error.AgentWorkQueueFull => -47,
        error.AgentEventQueueFull => -46,
        else => -1,
    };
}
fn bytes(p: ?[*]const u8, size: usize) ![]const u8 {
    if (size > 4096 or (p == null and size != 0)) return error.InvalidArgument;
    return if (p) |v| v[0..size] else &.{};
}
pub export fn spice_zig_agent_runner_create(desktop: ?*Desktop, options: ?*const agent.Options, name: ?[*]const u8, name_size: usize, general: u8, poll_ms: u32, output: ?*?*Handle) c_int {
    return spice_zig_agent_runner_create_seeded(desktop, options, name, name_size, general, poll_ms, 1, output);
}
pub export fn spice_zig_agent_runner_create_seeded(desktop: ?*Desktop, options: ?*const agent.Options, name: ?[*]const u8, name_size: usize, general: u8, poll_ms: u32, first_file_id: u32, output: ?*?*Handle) c_int {
    const out = output orelse return -1;
    out.* = null;
    const runtime = desktop orelse return -1;
    const opts = options orelse return -1;
    if (general > 1 or opts.clipboard_enabled > 1 or (general != 0 and name_size != 0)) return -1;
    const board_name = bytes(name, name_size) catch return -1;
    const board = s.pasteboard.Context.init(if (general != 0) null else board_name) catch |err| return status(err);
    defer board.deinit();
    out.* = Handle.create(a, runtime, board, .{ .manager = .{ .clipboard_enabled = opts.clipboard_enabled != 0, .maximum_text = opts.maximum_text_bytes, .pending_bytes = opts.maximum_pending_bytes, .file_limits = .{ .concurrent = opts.maximum_concurrent_files, .maximum_bytes = opts.maximum_file_bytes, .chunk = opts.file_chunk_bytes } }, .first_file_id = first_file_id, .automatic_poll = poll_ms != 0, .poll_ms = if (poll_ms == 0) 250 else poll_ms }) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_runner_stop(handle: ?*Handle) void {
    if (handle) |self| self.stop();
}
pub export fn spice_zig_agent_runner_destroy(handle: ?*Handle) void {
    if (handle) |self| self.destroy();
}
pub export fn spice_zig_agent_runner_status(handle: ?*Handle) c_int {
    const self = handle orelse return -1;
    const value = self.status();
    if (value.failure) |err| return status(err);
    return @intFromBool(value.finished);
}
pub export fn spice_zig_agent_runner_observe(handle: ?*Handle, event: ?*const Desktop.Event) c_int {
    const self = handle orelse return -1;
    const value = event orelse return -1;
    self.observe(value.*) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_runner_enable_clipboard(handle: ?*Handle, enabled: u8) c_int {
    const self = handle orelse return -1;
    if (enabled > 1) return -1;
    self.setClipboardEnabled(enabled != 0) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_runner_request_display(handle: ?*Handle, request: u64, monitors: ?[*]const agent.Monitor, count: usize) c_int {
    const self = handle orelse return -1;
    if (count == 0 or count > 256 or monitors == null) return -1;
    var input: [256]s.monitor_config.Monitor = undefined;
    for (monitors.?[0..count], input[0..count]) |m, *out| out.* = .{ .id = m.id, .x = m.x, .y = m.y, .width = m.width, .height = m.height };
    const configuration = s.monitor_config.Configuration.init(input[0..count]) catch return -1;
    self.requestDisplay(request, configuration) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_runner_send_file(handle: ?*Handle, request: u64, path: ?[*]const u8, path_size: usize, name: ?[*]const u8, name_size: usize) c_int {
    const self = handle orelse return -1;
    const filename = bytes(path, path_size) catch return -1;
    const basename = bytes(name, name_size) catch return -1;
    const file = s.file_source.Source.open(a, filename) catch |err| return status(err);
    defer file.release();
    self.queueFile(request, file, basename) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_runner_cancel_file(handle: ?*Handle, request: u64, key: agent.FileKey) c_int {
    const self = handle orelse return -1;
    self.cancelFile(request, .{ .id = key.id, .incarnation = key.incarnation }) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_runner_next(handle: ?*Handle, output: ?*?*Event) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    const event = a.create(Event) catch return -2;
    event.* = self.next() orelse {
        a.destroy(event);
        return 0;
    };
    out.* = event;
    return 1;
}
pub export fn spice_zig_agent_runner_event_destroy(handle: ?*Event) void {
    if (handle) |self| {
        self.deinit();
        a.destroy(self);
    }
}
pub export fn spice_zig_agent_runner_event_agent(handle: ?*const Event) ?*const agent.Event {
    const self = handle orelse return null;
    return switch (self.*) {
        .agent => &self.agent,
        else => null,
    };
}
pub export fn spice_zig_agent_runner_event_info(handle: ?*const Event, output: ?*Info) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(Info);
    const self = handle orelse return -1;
    switch (self.*) {
        .agent => out.kind = 1,
        .completed => |v| {
            out.kind = 4;
            out.request = v;
        },
        .failed => |v| {
            out.kind = 2;
            out.request = v.request;
        },
        .file_accepted => |v| {
            out.kind = 3;
            out.request = v.request;
            out.key = .{ .id = v.key.id, .reserved = 0, .incarnation = v.key.incarnation };
        },
    }
    return 0;
}
pub export fn spice_zig_agent_runner_event_error(handle: ?*const Event) ?[*:0]const u8 {
    const self = handle orelse return null;
    return switch (self.*) {
        .failed => |v| @errorName(v.reason).ptr,
        else => null,
    };
}

pub export fn spice_zig_agent_runner_join(handle: ?*Handle) void {
    if (handle) |self| self.join();
}
pub export fn spice_zig_agent_runner_metrics(handle: ?*Handle, output: ?*@import("agent_metrics.zig").Metrics) c_int {
    const self = handle orelse return -1;
    const out = output orelse return -1;
    out.* = self.diagnostics();
    return 0;
}
pub export fn spice_zig_agent_runner_next_file_id(handle: ?*Handle) u32 {
    return if (handle) |self| self.nextFileID() else 0;
}
pub export fn spice_zig_agent_runner_synchronize(handle: ?*Handle, request: u64) c_int {
    const self = handle orelse return -1;
    if (request == 0) return -1;
    self.synchronize(request) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_runner_barrier(handle: ?*Handle, request: u64) c_int {
    const self = handle orelse return -1;
    if (request == 0) return -1;
    self.barrier(request) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_runner_publish(handle: ?*Handle, request: u64, text: ?[*]const u8, size: usize) c_int {
    const self = handle orelse return -1;
    if (request == 0 or size > 16 * 1024 * 1024 or (size != 0 and text == null)) return -1;
    self.publish(request, if (text) |v| v[0..size] else &.{}) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_runner_event_limits(handle: ?*const Event, actual: ?*u64, maximum: ?*u64) c_int {
    const self = handle orelse return -1;
    const x = actual orelse return -1;
    const y = maximum orelse return -1;
    if (self.* != .failed) return -1;
    x.* = self.failed.actual;
    y.* = self.failed.maximum;
    return 0;
}

extern "c" fn pthread_main_np() c_int;
/// Borrows text until return; never invoke on the AppKit main thread.
pub export fn spice_zig_agent_runner_publish_borrowed(handle: ?*Handle, text: ?[*]const u8, size: usize) c_int {
    const self = handle orelse return -1;
    if (pthread_main_np() != 0 or (size != 0 and text == null)) return -1;
    self.publishBorrowed(if (text) |v| v[0..size] else &.{}) catch |err| return status(err);
    return 0;
}
