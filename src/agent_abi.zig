//! Optional public Agent manager boundary. The manager borrows its Desktop;
//! callers serialize manager operations and destroy it before the Desktop.
const std = @import("std");
const s = @import("root.zig");
const a = std.heap.c_allocator;
const Desktop = s.supervisor.Supervisor(s.desktop_child);
const Binding = s.agent_session.Binding(Desktop);
const WriteCallback = *const fn (?*anyopaque, [*]const u8, usize, *i64, *s.cancel.Token) callconv(.c) c_int;
pub const Options = extern struct { maximum_text_bytes: usize, maximum_pending_bytes: usize, maximum_concurrent_files: usize, maximum_file_bytes: u64, file_chunk_bytes: usize, clipboard_enabled: u8, reserved: [7]u8 };
pub const EventInfo = extern struct { kind: u32, detail: u32, values: [8]u32, wide: [4]u64 };
pub const Monitor = extern struct { id: i64, x: i64, y: i64, width: i64, height: i64 };
pub const FileKey = extern struct { id: u32, reserved: u32, incarnation: u64 };
pub const Event = s.agent_manager.Event;
pub const Handle = struct {
    binding: *Binding,
    write: ?WriteCallback,
    user: ?*anyopaque,
    events: [64]Event = undefined,
    head: usize = 0,
    count: usize = 0,
    failure: ?anyerror = null,
    fn check(p: *anyopaque) !void {
        const self: *Handle = @ptrCast(@alignCast(p));
        if (self.failure) |err| return err;
    }
    fn emit(p: *anyopaque, event: Event) void {
        const self: *Handle = @ptrCast(@alignCast(p));
        if (self.count == self.events.len) {
            event.deinit();
            self.failure = error.AgentEventQueueFull;
            return;
        }
        self.events[(self.head + self.count) % self.events.len] = event;
        self.count += 1;
    }
    fn writeText(p: *anyopaque, text: []const u8, token: *s.cancel.Token) !i64 {
        const self: *Handle = @ptrCast(@alignCast(p));
        try check(p);
        try token.check();
        const callback = self.write orelse return error.MissingPasteboardWriter;
        var change: i64 = 0;
        if (callback(self.user, text.ptr, text.len, &change, token) != 0) return error.PasteboardWriteFailed;
        try token.check();
        return change;
    }
};
fn status(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -2,
        error.Cancelled => -31,
        error.StaleAgentGeneration => -45,
        error.AgentEventQueueFull => -46,
        else => -1,
    };
}
fn bytes(p: ?[*]const u8, size: usize, maximum: usize) ![]const u8 {
    if (size > maximum or (p == null and size != 0)) return error.InvalidArgument;
    return if (p) |v| v[0..size] else &.{};
}
pub export fn spice_zig_agent_options(output: ?*Options) void {
    if (output) |out| out.* = .{ .maximum_text_bytes = 16 * 1024 * 1024 - 4, .maximum_pending_bytes = 32 * 1024 * 1024, .maximum_concurrent_files = 4, .maximum_file_bytes = 8 * 1024 * 1024 * 1024, .file_chunk_bytes = 16000, .clipboard_enabled = 1, .reserved = @splat(0) };
}
pub export fn spice_zig_agent_manager_create(desktop: ?*Desktop, options: ?*const Options, write: ?WriteCallback, user: ?*anyopaque, output: ?*?*Handle) c_int {
    const out = output orelse return -1;
    out.* = null;
    const runtime = desktop orelse return -1;
    const opts = options orelse return -1;
    if (opts.clipboard_enabled > 1 or (opts.clipboard_enabled != 0 and write == null)) return -1;
    const self = a.create(Handle) catch return -2;
    self.* = .{ .binding = undefined, .write = write, .user = user };
    self.binding = Binding.create(a, runtime, .{ .context = self, .check = Handle.check, .write_text = Handle.writeText, .emit = Handle.emit }, .{ .clipboard_enabled = opts.clipboard_enabled != 0, .maximum_text = opts.maximum_text_bytes, .pending_bytes = opts.maximum_pending_bytes, .file_limits = .{ .concurrent = opts.maximum_concurrent_files, .maximum_bytes = opts.maximum_file_bytes, .chunk = opts.file_chunk_bytes } }) catch |err| {
        for (0..self.count) |i| self.events[(self.head + i) % self.events.len].deinit();
        a.destroy(self);
        return status(err);
    };
    out.* = self;
    return 0;
}
pub export fn spice_zig_agent_manager_destroy(handle: ?*Handle) void {
    if (handle) |self| {
        self.binding.destroy();
        for (0..self.count) |i| self.events[(self.head + i) % self.events.len].deinit();
        a.destroy(self);
    }
}
pub export fn spice_zig_agent_manager_observe(handle: ?*Handle, event: ?*const Desktop.Event) c_int {
    const self = handle orelse return -1;
    const input = event orelse return -1;
    Handle.check(self) catch |err| return status(err);
    self.binding.observe(input.*) catch |err| return status(err);
    Handle.check(self) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_manager_pump(handle: ?*Handle, token: ?*s.cancel.Token, maximum: usize) c_int {
    const self = handle orelse return -1;
    const cancellation = token orelse return -1;
    Handle.check(self) catch |err| return status(err);
    const result = self.binding.manager.pump(cancellation, maximum) catch |err| return status(err);
    Handle.check(self) catch |err| return status(err);
    return @backingInt(result);
}
pub export fn spice_zig_agent_manager_enable_clipboard(handle: ?*Handle, enabled: u8) c_int {
    const self = handle orelse return -1;
    if (enabled > 1 or (enabled != 0 and self.write == null)) return -1;
    Handle.check(self) catch |err| return status(err);
    self.binding.manager.setClipboardEnabled(enabled != 0) catch |err| return status(err);
    Handle.check(self) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_manager_local_text(handle: ?*Handle, change: i64, present: u8, data: ?[*]const u8, size: usize) c_int {
    const self = handle orelse return -1;
    if (present > 1) return -1;
    const text = bytes(data, size, 16 * 1024 * 1024) catch return -1;
    Handle.check(self) catch |err| return status(err);
    self.binding.manager.localChanged(change, if (present != 0) text else null) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_manager_request_display(handle: ?*Handle, monitors: ?[*]const Monitor, count: usize) c_int {
    const self = handle orelse return -1;
    if (count == 0 or count > 256 or monitors == null) return -1;
    Handle.check(self) catch |err| return status(err);
    var input: [256]s.monitor_config.Monitor = undefined;
    for (monitors.?[0..count], input[0..count]) |m, *out| out.* = .{ .id = m.id, .x = m.x, .y = m.y, .width = m.width, .height = m.height };
    const configuration = s.monitor_config.Configuration.init(input[0..count]) catch return -1;
    self.binding.manager.requestDisplay(configuration) catch |err| return status(err);
    Handle.check(self) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_manager_send_file(handle: ?*Handle, path: ?[*]const u8, path_size: usize, name: ?[*]const u8, name_size: usize, output: ?*FileKey) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(FileKey);
    const self = handle orelse return -1;
    Handle.check(self) catch |err| return status(err);
    const support = self.binding.manager.state.support();
    if (!support.connected or (support.file_state and !support.files) or self.binding.manager.transfers.count() >= self.binding.manager.transfers.limits.concurrent) return -1;
    const filename = bytes(path, path_size, 4096) catch return -1;
    const basename = bytes(name, name_size, 4096) catch return -1;
    const file = s.file_source.Source.open(a, filename) catch |err| return status(err);
    defer file.release();
    const key = self.binding.manager.queueFile(file, basename) catch |err| return status(err);
    Handle.check(self) catch |err| return status(err);
    out.* = .{ .id = key.id, .reserved = 0, .incarnation = key.incarnation };
    return 0;
}
pub export fn spice_zig_agent_manager_cancel_file(handle: ?*Handle, key: FileKey) c_int {
    const self = handle orelse return -1;
    Handle.check(self) catch |err| return status(err);
    self.binding.manager.cancelFile(.{ .id = key.id, .incarnation = key.incarnation }) catch |err| return status(err);
    Handle.check(self) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_agent_manager_next(handle: ?*Handle, output: ?*?*Event) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    if (self.count == 0) {
        Handle.check(self) catch |err| return status(err);
        return 0;
    }
    const event = a.create(Event) catch return -2;
    event.* = self.events[self.head];
    self.head = (self.head + 1) % self.events.len;
    self.count -= 1;
    out.* = event;
    return 1;
}
pub export fn spice_zig_agent_event_destroy(handle: ?*Event) void {
    if (handle) |self| {
        self.deinit();
        a.destroy(self);
    }
}
fn request(event: Event) ?s.monitor_config.Request {
    if (event != .display) return null;
    return switch (event.display) {
        .queued, .sent, .acknowledged, .rejected, .unsupported => |v| v,
        .failed => |v| v.request,
    };
}
pub export fn spice_zig_agent_event_info(handle: ?*const Event, output: ?*EventInfo) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(EventInfo);
    const self = handle orelse return -1;
    switch (self.*) {
        .clipboard => |event| {
            out.kind = 1;
            switch (event) {
                .ready => out.detail = 1,
                .unavailable => out.detail = 2,
                .guest_text => out.detail = 3,
                .local_offered => |v| {
                    out.detail = 4;
                    out.wide[0] = v;
                },
                .oversized_local => |v| {
                    out.detail = 5;
                    out.wide[0] = v.size;
                    out.wide[1] = v.maximum;
                },
            }
        },
        .support => |v| {
            out.kind = 2;
            inline for (.{ v.connected, v.explicit, v.monitors, v.sparse, v.positions, v.file_state, v.files, v.detailed_errors }, 0..) |flag, i| {
                if (flag) out.values[0] |= @as(u32, 1) << i;
            }
        },
        .display => |v| {
            out.kind = 3;
            out.detail = @backingInt(std.meta.activeTag(v)) + 1;
            if (request(self.*)) |r| {
                out.wide[0] = r.id;
                out.values[0] = @intCast(r.configuration.count);
            }
        },
        .file => |v| {
            out.kind = 4;
            out.detail = @backingInt(std.meta.activeTag(v)) + 1;
            switch (v) {
                .queued => |e| {
                    out.values[0] = e.key.id;
                    out.wide[0] = e.key.incarnation;
                    out.wide[2] = e.total;
                },
                .awaiting_approval, .completed, .cancelled => |key| {
                    out.values[0] = key.id;
                    out.wide[0] = key.incarnation;
                },
                .progress => |e| {
                    out.values[0] = e.key.id;
                    out.wide[0] = e.key.incarnation;
                    out.wide[1] = e.sent;
                    out.wide[2] = e.total;
                },
                .failed => |e| {
                    if (e.id) |id| {
                        out.values[0] = id;
                        out.values[1] = 1;
                    }
                    if (e.detail) |detail| switch (detail) {
                        .glib_io => |n| {
                            out.values[2] = 1;
                            out.wide[2] = n;
                        },
                        .free_space => |n| {
                            out.values[2] = 2;
                            out.wide[2] = n;
                        },
                    };
                },
            }
        },
    }
    return 0;
}
pub export fn spice_zig_agent_event_data(handle: ?*const Event, count: ?*usize) ?[*]const u8 {
    const size = count orelse return null;
    size.* = 0;
    const self = handle orelse return null;
    const data: s.bytes.Slice = switch (self.*) {
        .clipboard => |event| switch (event) {
            .guest_text => |v| v,
            else => return null,
        },
        .file => |event| switch (event) {
            .queued => |v| v.name,
            else => return null,
        },
        else => return null,
    };
    size.* = data.bytes().len;
    return data.bytes().ptr;
}
pub export fn spice_zig_agent_event_error(handle: ?*const Event) ?[*:0]const u8 {
    const self = handle orelse return null;
    return switch (self.*) {
        .display => |v| switch (v) {
            .failed => |e| @errorName(e.reason),
            else => null,
        },
        .file => |v| switch (v) {
            .failed => |e| @errorName(e.reason),
            else => null,
        },
        else => null,
    };
}
pub export fn spice_zig_agent_event_monitor(handle: ?*const Event, index: usize, output: ?*Monitor) c_int {
    const out = output orelse return -1;
    out.* = std.mem.zeroes(Monitor);
    const self = handle orelse return -1;
    const r = request(self.*) orelse return -1;
    if (index >= r.configuration.count) return -1;
    const m = r.configuration.monitors[index];
    out.* = .{ .id = m.id, .x = m.x, .y = m.y, .width = m.width, .height = m.height };
    return 0;
}
pub export fn spice_zig_agent_token_cancelled(token: ?*s.cancel.Token) c_int {
    const value = token orelse return 1;
    return @intFromBool(value.cancelled.load(.acquire));
}
