const std = @import("std");
const session = @import("session.zig");
const channel = @import("channel.zig");
const barriers = @import("barrier.zig");
const network = @import("network_abi.zig");
const tls = @import("tls.zig");
const a = std.heap.c_allocator;
const Event = struct { value: channel.Event };
pub const Requirement = extern struct { kind: u8, id: u8, serial: u64 };
fn status(err: anyerror) c_int {
    return switch (err) {
        error.DuplicateChannel => -40,
        error.TooManyChannels => -41,
        error.ChannelTerminated => -42,
        error.InvalidMigrationFlags, error.UnexpectedMigrationData => -43,
        else => network.status(err),
    };
}
pub export fn spice_zig_session_create(maximum: usize) ?*session.Session {
    return session.Session.create(a, maximum) catch null;
}
pub export fn spice_zig_session_cancel(self: ?*session.Session) void {
    if (self) |s| s.cancel();
}
pub export fn spice_zig_session_destroy(self: ?*session.Session) void {
    if (self) |s| s.destroy();
}
pub export fn spice_zig_session_connect(self: ?*session.Session, host: ?[*:0]const u8, port: u16, kind: u8, name: ?[*:0]const u8, subject: ?[*:0]const u8, certificates: ?[*]const tls.DER, count: usize, timeout_ms: u32, connection_id: u32, channel_type: u8, channel_id: u8, common: ?[*]const u32, common_count: usize, caps: ?[*]const u32, caps_count: usize, password: ?[*]const u8, password_size: usize, output: ?*?*session.Connection) c_int {
    const out = output orelse return -1;
    out.* = null;
    const s = self orelse return -1;
    const hostname = host orelse return -1;
    if (kind > 4 or count > 4096 or common_count > 4096 or caps_count > 4096 or (count != 0 and certificates == null) or (common_count != 0 and common == null) or (caps_count != 0 and caps == null) or (password_size != 0 and password == null)) return -1;
    const inputs = a.alloc([]const u8, count) catch return -2;
    defer a.free(inputs);
    for (inputs, 0..) |*input, i| {
        const cert = certificates.?[i];
        if (cert.size > 16 * 1024 * 1024) return -6;
        input.* = cert.data[0..cert.size];
    }
    out.* = s.connect(std.mem.span(hostname), port, .{ .kind = @fromBackingInt(@intCast(kind)), .server_name = if (name) |p| std.mem.span(p) else null, .expected_subject = if (subject) |p| std.mem.span(p) else "", .certificates = inputs }, timeout_ms, .{ .connection_id = connection_id, .channel_type = channel_type, .channel_id = channel_id, .common = if (common) |p| p[0..common_count] else &.{}, .channel = if (caps) |p| p[0..caps_count] else &.{} }, if (password) |p| p[0..password_size] else &.{}) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_channel_receive(self: ?*session.Connection, output: ?*?*Event) c_int {
    const out = output orelse return -1;
    out.* = null;
    const s = self orelse return -1;
    const event = a.create(Event) catch return -2;
    event.value = s.channel.receive() catch |err| {
        a.destroy(event);
        return status(err);
    };
    out.* = event;
    return if (event.value == .message) 0 else 1;
}
pub export fn spice_zig_event_destroy(self: ?*Event) void {
    if (self) |e| {
        e.value.deinit();
        a.destroy(e);
    }
}
pub export fn spice_zig_event_data(self: ?*const Event, size: ?*usize) ?[*]const u8 {
    const out = size orelse return null;
    out.* = 0;
    const e = self orelse return null;
    const body = switch (e.value) {
        .message => |m| m.body,
        .migration => |m| m orelse return null,
    };
    out.* = body.bytes().len;
    return body.bytes().ptr;
}
pub export fn spice_zig_event_kind(self: ?*const Event) c_int {
    const e = self orelse return -1;
    return switch (e.value) {
        .message => |m| m.kind,
        .migration => -1,
    };
}
pub export fn spice_zig_event_serial(self: ?*const Event) u64 {
    const e = self orelse return 0;
    return switch (e.value) {
        .message => |m| m.effective_serial,
        .migration => 0,
    };
}
pub export fn spice_zig_channel_complete(self: ?*session.Connection) c_int {
    const s = self orelse return -1;
    s.channel.complete() catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_channel_set_ack(self: ?*session.Connection, generation: u32, window: u32) void {
    if (self) |s| s.channel.configureAck(generation, window);
}
pub export fn spice_zig_channel_send(self: ?*session.Connection, kind: u16, bytes: ?[*]const u8, size: usize) c_int {
    const s = self orelse return -1;
    if (bytes == null and size != 0) return -1;
    s.channel.send(kind, if (bytes) |p| p[0..size] else &.{}) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_wait_create() ?*barriers.Token {
    const t = a.create(barriers.Token) catch return null;
    t.* = .{};
    return t;
}
pub export fn spice_zig_wait_destroy(self: ?*barriers.Token) void {
    if (self) |t| a.destroy(t);
}
pub export fn spice_zig_wait_cancel(self: ?*session.Session, token: ?*barriers.Token) void {
    if (self) |s| {
        if (token) |t| s.barrier.cancel(t);
    }
}
pub export fn spice_zig_session_wait(self: ?*session.Session, requirements: ?[*]const Requirement, count: usize, token: ?*barriers.Token) c_int {
    const s = self orelse return -1;
    const t = token orelse return -1;
    if (count > 65536 or (count != 0 and requirements == null)) return -1;
    const values = a.alloc(barriers.Requirement, count) catch return -2;
    defer a.free(values);
    for (values, 0..) |*value, i| {
        const r = requirements.?[i];
        value.* = .{ .key = .{ .kind = r.kind, .id = r.id }, .serial = r.serial };
    }
    s.barrier.wait(values, t) catch |err| return status(err);
    return 0;
}
