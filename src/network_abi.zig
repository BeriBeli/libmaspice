const std = @import("std");
const network = @import("transport.zig");
const link = @import("link.zig");
const a = std.heap.c_allocator;
pub fn status(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => -2,
        error.MessageTooLarge => -6,
        error.Timeout => -30,
        error.Cancelled => -31,
        error.TLSFailure => -32,
        error.ConnectionFailed => -33,
        error.ConnectionClosed => -34,
        error.InvalidState => -35,
        error.InvalidCertificate => -36,
        error.AuthenticationRejected => -37,
        error.LinkRejected => -38,
        error.UnsupportedAuthentication => -39,
        else => -1,
    };
}
pub export fn spice_zig_transport_create(host: ?[*:0]const u8, port: u16, kind: u8, server_name: ?[*:0]const u8, subject: ?[*:0]const u8, certificates: ?[*]const network.tls.DER, count: usize, timeout_ms: u32, output: ?*?*network.Transport) c_int {
    const out = output orelse return -1;
    out.* = null;
    const hostname = host orelse return -1;
    if (kind > 4 or count > 4096 or (count != 0 and certificates == null)) return -1;
    const inputs = a.alloc([]const u8, count) catch return -2;
    defer a.free(inputs);
    for (inputs, 0..) |*input, i| {
        const cert = certificates.?[i];
        if (cert.size > 16 * 1024 * 1024) return -6;
        input.* = cert.data[0..cert.size];
    }
    out.* = network.Transport.create(a, std.mem.span(hostname), port, .{ .kind = @fromBackingInt(@intCast(kind)), .server_name = if (server_name) |n| std.mem.span(n) else null, .expected_subject = if (subject) |s| std.mem.span(s) else "", .certificates = inputs }, timeout_ms) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_transport_connect(handle: ?*network.Transport) c_int {
    const self = handle orelse return -1;
    self.connect() catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_transport_cancel(handle: ?*network.Transport) void {
    if (handle) |self| self.cancel();
}
pub export fn spice_zig_transport_destroy(handle: ?*network.Transport) void {
    if (handle) |self| self.destroy();
}
pub export fn spice_zig_transport_read(handle: ?*network.Transport, data: ?[*]u8, size: usize, minimum: usize, count: ?*usize) c_int {
    const self = handle orelse return -1;
    const out = count orelse return -1;
    out.* = 0;
    const buffer = data orelse return -1;
    out.* = self.read(buffer[0..size], minimum) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_transport_read_exact(handle: ?*network.Transport, data: ?[*]u8, size: usize) c_int {
    const self = handle orelse return -1;
    if (size == 0) return 0;
    const buffer = data orelse return -1;
    self.readExactly(buffer[0..size]) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_transport_write(handle: ?*network.Transport, data: ?[*]const u8, size: usize) c_int {
    const self = handle orelse return -1;
    if (size == 0) {
        self.write(&.{}) catch |err| return status(err);
        return 0;
    }
    const buffer = data orelse return -1;
    self.write(buffer[0..size]) catch |err| return status(err);
    return 0;
}
pub export fn spice_zig_link_handshake(handle: ?*network.Transport, connection: u32, kind: u8, id: u8, common: ?[*]const u32, common_count: usize, channel: ?[*]const u32, channel_count: usize, password: ?[*]const u8, password_size: usize, output: ?*?*link.Negotiated) c_int {
    const out = output orelse return -1;
    out.* = null;
    const self = handle orelse return -1;
    if ((common == null and common_count != 0) or (channel == null and channel_count != 0) or (password == null and password_size != 0)) return -1;
    const result = a.create(link.Negotiated) catch return -2;
    result.* = link.perform(a, self, .{ .connection_id = connection, .channel_type = kind, .channel_id = id, .common = if (common) |p| p[0..common_count] else &.{}, .channel = if (channel) |p| p[0..channel_count] else &.{} }, if (password) |p| p[0..password_size] else &.{}) catch |err| {
        a.destroy(result);
        return status(err);
    };
    out.* = result;
    return 0;
}
pub export fn spice_zig_link_destroy(handle: ?*link.Negotiated) void {
    if (handle) |self| {
        self.deinit();
        a.destroy(self);
    }
}
pub export fn spice_zig_link_mode(handle: ?*const link.Negotiated) c_int {
    const self = handle orelse return -1;
    return if (self.mode() == .mini) 1 else 0;
}
pub export fn spice_zig_link_capabilities(handle: ?*const link.Negotiated, channel: u8, count: ?*usize) ?[*]const u32 {
    const out = count orelse return null;
    out.* = 0;
    const self = handle orelse return null;
    const words = if (channel != 0) self.channel() else self.common();
    out.* = words.len;
    return words.ptr;
}
